import AppKit
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView(statusController: StatusController.shared))
        // Avoid NSHostingView ↔ Auto Layout size feedback loop that crashes
        // `_postWindowNeedsUpdateConstraints` when Form content grows.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 640)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenDictate 设置"
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
