import AppKit
import Carbon.HIToolbox

/// Listens for Escape while a dictation/Ask session or post-process is active.
final class EscapeCancelMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// Return `true` if the Esc event was handled (should be swallowed).
    var onEscape: (() -> Bool)?

    func start() {
        guard eventTap == nil else { return }

        let mask = 1 << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<EscapeCancelMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("EscapeCancelMonitor: failed to create event tap")
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
        NSLog("EscapeCancelMonitor started")
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
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == kVK_Escape else {
            return Unmanaged.passUnretained(event)
        }

        var handled = false
        if Thread.isMainThread {
            handled = onEscape?() ?? false
        } else {
            DispatchQueue.main.sync {
                handled = onEscape?() ?? false
            }
        }
        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
