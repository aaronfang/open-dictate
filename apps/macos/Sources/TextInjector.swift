import AppKit
import ApplicationServices

final class TextInjector {
    func insert(text: String) {
        if tryInsertViaAccessibility(text: text) {
            return
        }
        pasteViaClipboard(text: text)
    }

    private func tryInsertViaAccessibility(text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else {
            return false
        }

        // 优先写入选区（如果存在），否则尝试写 value
        let cfText = text as CFString
        let setSelected = AXUIElementSetAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, cfText)
        if setSelected == .success {
            return true
        }

        let setValue = AXUIElementSetAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, cfText)
        return setValue == .success
    }

    private func pasteViaClipboard(text: String) {
        let pb = NSPasteboard.general
        let oldItems = pb.pasteboardItems

        pb.clearContents()
        pb.setString(text, forType: .string)

        // 发送 Cmd+V
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // 尝试恢复原剪贴板（尽力而为）
        if let oldItems {
            pb.clearContents()
            pb.writeObjects(oldItems)
        }
    }
}

