import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TextInjector {
    private var targetApp: NSRunningApplication?
    private var focusedElement: AXUIElement?

    /// Bundle ID of the app that was focused when recording started.
    var targetBundleId: String? { targetApp?.bundleIdentifier }

    var targetAppName: String? { targetApp?.localizedName }

    func rememberTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSLog("TextInjector: no frontmost app")
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        if app.processIdentifier == selfPID {
            NSLog("TextInjector: frontmost app is self, skip")
            return
        }

        targetApp = app

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success {
            focusedElement = (focused as! AXUIElement)
        } else {
            focusedElement = nil
        }

        NSLog("TextInjector remembered target: \(app.localizedName ?? "unknown") pid=\(app.processIdentifier)")
    }

    func insert(text: String) {
        guard targetApp != nil else {
            NSLog("TextInjector: insert skipped, no target app")
            return
        }

        activateTarget()
        restoreFocus()

        // 等待 Option 等修饰键完全释放，否则 Cmd+V 会被目标应用忽略
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pasteViaClipboard(text: text)
        }
    }

    private func activateTarget() {
        guard let targetApp else { return }
        targetApp.activate(options: [.activateIgnoringOtherApps])
    }

    private func restoreFocus() {
        guard let focusedElement else { return }
        AXUIElementSetAttributeValue(focusedElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(focusedElement, kAXRaiseAction as CFString)
    }

    private func pasteViaClipboard(text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        usleep(20_000)

        simulateExplicitPaste()
        NSLog("TextInjector: posted Cmd+V to paste")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let saved {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    private func simulateExplicitPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let pid = targetApp?.processIdentifier

        let post: (CGEvent) -> Void = { event in
            if let pid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }

        let cmdKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true) {
            cmdDown.flags = .maskCommand
            post(cmdDown)
        }
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            vDown.flags = .maskCommand
            post(vDown)
        }
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            vUp.flags = .maskCommand
            post(vUp)
        }
        if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) {
            post(cmdUp)
        }
    }
}
