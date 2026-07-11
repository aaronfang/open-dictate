import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TextInjector {
    enum InsertOutcome: Equatable {
        /// Likely landed in an editable field (clipboard still keeps the text).
        case pasted
        /// No reliable input focus — text is on the clipboard for manual Cmd+V.
        case clipboardOnly
    }

    private var targetApp: NSRunningApplication?
    private var focusedElement: AXUIElement?
    private var pendingPasteWorkItem: DispatchWorkItem?
    private var pasteGeneration: UInt64 = 0

    /// Bundle ID of the app that was focused when recording started.
    var targetBundleId: String? { targetApp?.bundleIdentifier }

    var targetAppName: String? { targetApp?.localizedName }

    func rememberTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSLog("TextInjector: no frontmost app")
            targetApp = nil
            focusedElement = nil
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        if app.processIdentifier == selfPID {
            NSLog("TextInjector: frontmost app is self, skip")
            targetApp = nil
            focusedElement = nil
            return
        }

        targetApp = app
        focusedElement = copyFocusedElement()

        NSLog(
            "TextInjector remembered target: %@ pid=%d role=%@ editable=%@",
            app.localizedName ?? "unknown",
            app.processIdentifier,
            focusedRole() ?? "nil",
            isFocusedElementStrictlyEditable() ? "yes" : "no"
        )
    }

    /// Cancel any delayed Cmd+V so silence / failed sessions never paste stale clipboard.
    func cancelPendingPaste() {
        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        pasteGeneration &+= 1
        NSLog("TextInjector: pending paste cancelled (gen=%llu)", pasteGeneration)
    }

    /// Best-effort string value of the focused AX element (text field contents).
    func focusedStringValue(refreshFocus: Bool = true) -> String? {
        if refreshFocus {
            rememberTarget()
        }
        guard let focusedElement else { return nil }

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String,
           !text.isEmpty {
            return text
        }
        return nil
    }

    /// Best-effort selected text from the focused AX element, else Cmd+C clipboard snapshot.
    func captureSelectedText() -> String? {
        rememberTarget()
        if let ax = selectedTextFromAX(), !ax.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ax
        }
        return copySelectionViaClipboard()
    }

    /// Always writes `text` to the general pasteboard and keeps it there.
    /// Attempts Cmd+V only when focus looks like a real text field.
    @discardableResult
    func insert(text: String, refreshFocus: Bool = true) -> InsertOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelPendingPaste()
            return .clipboardOnly
        }

        cancelPendingPaste()

        if refreshFocus {
            rememberTarget()
        }

        guard copyToClipboard(trimmed) else {
            NSLog("TextInjector: failed to write clipboard — skip paste")
            return .clipboardOnly
        }

        guard targetApp != nil else {
            NSLog("TextInjector: no target app — clipboard only")
            return .clipboardOnly
        }

        // Always try Cmd+V when we have a frontmost app. Many apps (WeChat, Electron)
        // don't expose AXTextField even when the input is focused; skipping paste there
        // felt like "never pastes". Clipboard is still retained as fallback.
        let editable = isFocusedElementStrictlyEditable()
        activateTarget()
        if editable {
            restoreFocus()
        }

        let generation = pasteGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.pasteGeneration else {
                NSLog("TextInjector: skip stale paste gen=%llu", generation)
                return
            }
            let current = NSPasteboard.general.string(forType: .string) ?? ""
            if current != trimmed {
                guard self.copyToClipboard(trimmed) else {
                    NSLog("TextInjector: clipboard lost before paste — abort")
                    return
                }
            }
            self.postPaste()
        }
        pendingPasteWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        NSLog(
            "TextInjector: paste scheduled (clipboard retained, editable=%@, gen=%llu)",
            editable ? "yes" : "no",
            generation
        )
        return .pasted
    }

    /// Strict: only trust real text roles / AXEditable.
    private func isFocusedElementStrictlyEditable() -> Bool {
        guard let focusedElement else { return false }

        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, "AXEditable" as CFString, &editable) == .success {
            if let flag = editable as? Bool { return flag }
            if let num = editable as? NSNumber { return num.boolValue }
        }

        switch focusedRole() {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
             "AXTextView", "AXSecureTextField":
            return true
        default:
            return false
        }
    }

    private func focusedRole() -> String? {
        guard let focusedElement else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role) == .success else {
            return nil
        }
        return role as? String
    }

    private func copyFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private func selectedTextFromAX() -> String? {
        guard let focusedElement else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    private func copySelectionViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()

        activateTarget()
        restoreFocus()
        usleep(40_000)
        simulateCommandKey(CGKeyCode(kVK_ANSI_C))
        usleep(80_000)

        let copied = pb.string(forType: .string)
        if let saved {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        } else {
            pb.clearContents()
        }

        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : copied
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

    @discardableResult
    private func copyToClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        let verify = pb.string(forType: .string) ?? ""
        let matched = ok && verify == text
        NSLog(
            "TextInjector: clipboard set ok=%@ chars=%d verify=%@",
            matched ? "yes" : "no",
            text.count,
            matched ? "match" : "mismatch"
        )
        return matched
    }

    private func postPaste() {
        simulateCommandKey(CGKeyCode(kVK_ANSI_V))
        NSLog("TextInjector: posted Cmd+V (clipboard retained)")
    }

    private func simulateCommandKey(_ key: CGKeyCode) {
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

        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true) {
            cmdDown.flags = .maskCommand
            post(cmdDown)
        }
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            keyDown.flags = .maskCommand
            post(keyDown)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            keyUp.flags = .maskCommand
            post(keyUp)
        }
        if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) {
            post(cmdUp)
        }
    }
}
