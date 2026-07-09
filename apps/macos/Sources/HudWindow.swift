import AppKit

final class HudWindow {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(text: String) {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
            p.hasShadow = true
            p.isOpaque = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let l = NSTextField(labelWithString: "")
            l.alignment = .center
            l.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            l.frame = NSRect(x: 12, y: 18, width: 196, height: 24)

            let view = NSView(frame: p.contentView?.bounds ?? .zero)
            view.addSubview(l)
            p.contentView = view

            panel = p
            label = l
        }

        label?.stringValue = text
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 110
            let y = screen.visibleFrame.maxY - 90
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

