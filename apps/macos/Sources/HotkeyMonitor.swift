import AppKit

final class HotkeyMonitor {
    struct Hotkey {
        var keyCode: CGKeyCode
    }

    private let hotkey: Hotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    private(set) var isActive = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        NSLog("Hotkey monitor started for keyCode \(hotkey.keyCode)")
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isPressed = false
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            // 每个 flagsChanged 对应该物理按键的一次按下/松开，不依赖聚合的 Option 标志位
            setPressed(!isPressed)
        case .keyUp:
            if isPressed {
                setPressed(false)
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        NSLog("Hotkey \(hotkey.keyCode) \(pressed ? "down" : "up")")

        let callback = pressed ? onHotkeyDown : onHotkeyUp
        DispatchQueue.main.async {
            callback?()
        }
    }
}
