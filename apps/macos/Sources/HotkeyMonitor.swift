import AppKit

final class HotkeyMonitor {
    private var keyCode: CGKeyCode
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    private(set) var isActive = false

    init(keyCode: CGKeyCode = DictationHotkey.defaultKeyCode) {
        self.keyCode = keyCode
    }

    func update(keyCode: CGKeyCode) {
        let wasActive = isActive
        if wasActive {
            stop()
        }
        self.keyCode = keyCode
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
        NSLog("Hotkey monitor started for keyCode \(keyCode)")
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

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let hotkey = DictationHotkey(keyCode: UInt16(keyCode))

        switch type {
        case .flagsChanged:
            guard hotkey.isModifier else { break }
            setPressed(Self.modifierFlagIsDown(keyCode: eventKeyCode, flags: event.flags))
            return Unmanaged.passUnretained(event)

        case .keyDown:
            guard !hotkey.isModifier else { break }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                setPressed(true)
            }
            return nil

        case .keyUp:
            guard !hotkey.isModifier else { break }
            setPressed(false)
            return nil

        default:
            break
        }

        return Unmanaged.passUnretained(event)
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
        NSLog("Hotkey \(keyCode) \(pressed ? "down" : "up")")

        let callback = pressed ? onHotkeyDown : onHotkeyUp
        DispatchQueue.main.async {
            callback?()
        }
    }
}
