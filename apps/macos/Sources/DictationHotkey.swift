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

/// Modifier bits for chord hotkeys (Control / Option / Shift / Command).
struct HotkeyModifierFlags: OptionSet, Hashable, Codable {
    let rawValue: Int

    static let control = HotkeyModifierFlags(rawValue: 1 << 0)
    static let option = HotkeyModifierFlags(rawValue: 1 << 1)
    static let shift = HotkeyModifierFlags(rawValue: 1 << 2)
    static let command = HotkeyModifierFlags(rawValue: 1 << 3)

    /// Human-readable prefix, e.g. `⌃⌥`.
    var displayPrefix: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    static func from(nsFlags: NSEvent.ModifierFlags) -> HotkeyModifierFlags {
        var flags: HotkeyModifierFlags = []
        if nsFlags.contains(.control) { flags.insert(.control) }
        if nsFlags.contains(.option) { flags.insert(.option) }
        if nsFlags.contains(.shift) { flags.insert(.shift) }
        if nsFlags.contains(.command) { flags.insert(.command) }
        return flags
    }

    static func from(cgFlags: CGEventFlags) -> HotkeyModifierFlags {
        var flags: HotkeyModifierFlags = []
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        return flags
    }

    /// True when all required modifiers are down and no extra among the four are pressed.
    func matchesExact(_ present: HotkeyModifierFlags) -> Bool {
        present == self
    }
}

/// Push-to-talk / Ask hotkey: single key (incl. lone modifier) or modifier chord.
struct DictationHotkey: Equatable, Hashable, Identifiable {
    var keyCode: UInt16
    var modifiers: HotkeyModifierFlags

    var id: String { "\(keyCode)|\(modifiers.rawValue)" }

    static let defaultKeyCode: UInt16 = 61 // Right Option
    static let defaultAskKeyCode: UInt16 = 97 // F6
    static let `default` = DictationHotkey(keyCode: defaultKeyCode)
    static let defaultAsk = DictationHotkey(keyCode: defaultAskKeyCode)

    init(keyCode: UInt16, modifiers: HotkeyModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let presets: [DictationHotkey] = [
        .init(keyCode: 61), // Right Option
        .init(keyCode: 58), // Left Option
        .init(keyCode: 62), // Right Control
        .init(keyCode: 59), // Left Control
        .init(keyCode: 63), // Fn
        .init(keyCode: 96), // F5
        .init(keyCode: 97), // F6
        .init(keyCode: 49, modifiers: .control), // ⌃空格
        .init(keyCode: 2, modifiers: [.control, .shift]), // ⌃⇧D (D key)
    ]

    /// True when the hotkey is a lone modifier key (Right Option, etc.).
    var isModifierOnly: Bool {
        modifiers.isEmpty && isModifierKey
    }

    var isChord: Bool { !modifiers.isEmpty }

    var isModifierKey: Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    /// Escape cannot be bound. Command/Right Command cannot be the primary key
    /// (they break paste); Command as a chord *modifier* is allowed.
    static func isAllowedPrimaryKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Escape, kVK_Command, kVK_RightCommand:
            return false
        default:
            return true
        }
    }

    /// Legacy alias.
    static func isAllowed(_ keyCode: UInt16) -> Bool {
        isAllowedPrimaryKey(keyCode)
    }

    var displayName: String {
        if modifiers.isEmpty {
            return keyLabel
        }
        return modifiers.displayPrefix + keyLabel
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

    private var keyLabel: String {
        switch keyCode {
        case 61: return "右 Option"
        case 58: return "左 Option"
        case 62: return "右 Control"
        case 59: return "左 Control"
        case 60: return "右 Shift"
        case 56: return "左 Shift"
        case 55: return "右 Command"
        case 54: return "左 Command"
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
