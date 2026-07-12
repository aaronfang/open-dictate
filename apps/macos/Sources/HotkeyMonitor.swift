import AppKit

final class HotkeyMonitor {
    private var hotkey: DictationHotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    private(set) var isActive = false

    init(keyCode: CGKeyCode = DictationHotkey.defaultKeyCode) {
        self.hotkey = DictationHotkey(keyCode: UInt16(keyCode))
    }

    init(hotkey: DictationHotkey) {
        self.hotkey = hotkey
    }

    func update(keyCode: CGKeyCode) {
        update(hotkey: DictationHotkey(keyCode: UInt16(keyCode)))
    }

    func update(hotkey: DictationHotkey) {
        let wasActive = isActive
        if wasActive {
            stop()
        }
        self.hotkey = hotkey
        isPressed = false
        if wasActive {
            start()
        }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        // defaultTap so regular keys used as PTT can be consumed (no typed characters).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("Failed to create event tap. Check Accessibility permission.")
            isActive = false
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        NSLog("Hotkey monitor started for %@", hotkey.displayName)
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        if isPressed {
            isPressed = false
            let callback = onHotkeyUp
            DispatchQueue.main.async { callback?() }
        }
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if hotkey.isModifierOnly {
            return handleModifierOnly(type: type, event: event)
        }
        return handleChordOrKey(type: type, event: event)
    }

    /// Lone modifier PTT (e.g. Right Option) — existing behavior.
    private func handleModifierOnly(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == CGKeyCode(hotkey.keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            setPressed(Self.modifierFlagIsDown(keyCode: eventKeyCode, flags: event.flags))
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Chord (⌥空格) or plain non-modifier key (F6).
    ///
    /// For chords in hold mode: start on primary keyDown, but stay "pressed" until the
    /// required modifiers are released. Releasing Space while still holding Option must
    /// NOT end the session (otherwise Ask flashes and exits immediately).
    private func handleChordOrKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let present = HotkeyModifierFlags.from(cgFlags: event.flags)

        switch type {
        case .keyDown:
            guard eventKeyCode == CGKeyCode(hotkey.keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return nil
            }
            guard modifiersMatchForChord(present) else {
                return Unmanaged.passUnretained(event)
            }
            setPressed(true)
            return nil

        case .keyUp:
            guard eventKeyCode == CGKeyCode(hotkey.keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            guard isPressed else {
                return Unmanaged.passUnretained(event)
            }
            if hotkey.isChord, modifiersMatchForChord(present) {
                // Keep holding via Option/Control/etc.; end only when modifiers drop.
                NSLog("Hotkey %@: primary up, modifiers still held — keep pressed", hotkey.displayName)
                return nil
            }
            setPressed(false)
            return nil

        case .flagsChanged:
            if isPressed, hotkey.isChord, !modifiersMatchForChord(present) {
                setPressed(false)
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Chord requires all configured modifiers; ignore Fn/caps bits outside our set.
    private func modifiersMatchForChord(_ present: HotkeyModifierFlags) -> Bool {
        if hotkey.modifiers.isEmpty {
            return present.isEmpty
        }
        // Require at least the configured modifiers (exact among the four we track).
        return hotkey.modifiers.matchesExact(present)
    }

    private static func modifierFlagIsDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 58, 61:
            return flags.contains(.maskAlternate)
        case 59, 62:
            return flags.contains(.maskControl)
        case 56, 60:
            return flags.contains(.maskShift)
        case 55, 54:
            return flags.contains(.maskCommand)
        case 63:
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        NSLog("Hotkey %@ %@", hotkey.displayName, pressed ? "down" : "up")

        let callback = pressed ? onHotkeyDown : onHotkeyUp
        DispatchQueue.main.async {
            callback?()
        }
    }
}
