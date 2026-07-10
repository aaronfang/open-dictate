import AppKit
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            // Refresh root view so rebuilt UI is picked up after relaunch / hot rebuilds.
            window.contentView = makeHostingView(fitting: window.contentLayoutRect.size)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initialSize = NSSize(width: 820, height: 580)
        let hosting = makeHostingView(fitting: initialSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenDictate 设置"
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.setContentSize(initialSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func makeHostingView(fitting size: NSSize) -> NSHostingView<SettingsView> {
        let hosting = NSHostingView(rootView: SettingsView(statusController: StatusController.shared))
        // Avoid NSHostingView ↔ Auto Layout size feedback loop that crashes
        // `_postWindowNeedsUpdateConstraints` when Form content grows.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        return hosting
    }
}
