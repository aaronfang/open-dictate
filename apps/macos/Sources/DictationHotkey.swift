import AppKit
import Carbon.HIToolbox

enum DictationTriggerMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "按住说话"
        case .toggle: return "点按切换"
        }
    }

    var hint: String {
        switch self {
        case .hold: return "按住热键说话，松开后识别"
        case .toggle: return "按一下开始，再按一下结束并识别"
        }
    }
}

/// Push-to-talk hotkey identified by a hardware key code.
struct DictationHotkey: Equatable, Hashable, Identifiable {
    var keyCode: UInt16

    var id: UInt16 { keyCode }

    static let defaultKeyCode: UInt16 = 61 // Right Option
    static let defaultAskKeyCode: UInt16 = 97 // F6
    static let `default` = DictationHotkey(keyCode: defaultKeyCode)
    static let defaultAsk = DictationHotkey(keyCode: defaultAskKeyCode)

    static let presets: [DictationHotkey] = [
        .init(keyCode: 61), // Right Option
        .init(keyCode: 58), // Left Option
        .init(keyCode: 62), // Right Control
        .init(keyCode: 59), // Left Control
        .init(keyCode: 63), // Fn
        .init(keyCode: 96), // F5
        .init(keyCode: 97), // F6
    ]

    var isModifier: Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    /// Escape / Command interfere with cancel and paste.
    static func isAllowed(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Escape, kVK_Command, kVK_RightCommand:
            return false
        default:
            return true
        }
    }

    var displayName: String {
        switch keyCode {
        case 61: return "右 Option"
        case 58: return "左 Option"
        case 62: return "右 Control"
        case 59: return "左 Control"
        case 60: return "右 Shift"
        case 56: return "左 Shift"
        case 63: return "Fn"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 49: return "空格"
        case 53: return "Esc"
        default:
            if let label = Self.characters(forKeyCode: keyCode) {
                return label
            }
            return "键码 \(keyCode)"
        }
    }

    var settingsLabel: String {
        settingsLabel(mode: .hold)
    }

    func settingsLabel(mode: DictationTriggerMode) -> String {
        switch mode {
        case .hold: return "\(displayName)（按住说话）"
        case .toggle: return "\(displayName)（点按切换）"
        }
    }

    private static func characters(forKeyCode keyCode: UInt16) -> String? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return nil
        }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        if let chars = nsEvent.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chars.isEmpty {
            return chars.uppercased()
        }
        return nil
    }
}
