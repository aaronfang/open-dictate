import AppKit

final class HotkeyMonitor {
    struct Hotkey {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
    }

    private let hotkey: Hotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    private var isPressed = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            // 常见原因：未授予“辅助功能(Accessibility)”权限
            NSLog("Failed to create event tap. Check Accessibility permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let matches = keyCode == hotkey.keyCode && flags.contains(hotkey.flags)
        if !matches {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if !isPressed {
                isPressed = true
                onHotkeyDown?()
            }
        case .keyUp:
            if isPressed {
                isPressed = false
                onHotkeyUp?()
            }
        default:
            break
        }

        // 不拦截键盘事件：返回原事件继续传递
        return Unmanaged.passUnretained(event)
    }
}

