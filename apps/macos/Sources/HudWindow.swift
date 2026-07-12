import AppKit

final class HudWindow {
    enum Style {
        case recording
        case processing
        case success
        case warning
        case error
        case cancel
        case info

        var symbolName: String {
            switch self {
            case .recording: return "mic.fill"
            case .processing: return "waveform"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .cancel: return "hand.raised.fill"
            case .info: return "info.circle.fill"
            }
        }

        var accent: NSColor {
            switch self {
            case .recording: return NSColor.systemRed
            case .processing: return NSColor.systemTeal
            case .success: return NSColor.systemGreen
            case .warning: return NSColor.systemOrange
            case .error: return NSColor.systemRed
            case .cancel: return NSColor.secondaryLabelColor
            case .info: return NSColor.systemBlue
            }
        }
    }

    private var panel: NSPanel?
    private var container: NSView?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var hideWorkItem: DispatchWorkItem?
    private var currentStyle: Style = .info
    /// Bumped on every `show` so an in-flight `hide` animation cannot orderOut a newer HUD.
    private var displayGeneration: UInt64 = 0

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12
    private let iconSize: CGFloat = 22
    private let minWidth: CGFloat = 200
    private let maxWidth: CGFloat = 420

    func show(_ text: String, style: Style = .info, detail: String? = nil) {
        ensurePanel()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        displayGeneration &+= 1
        currentStyle = style

        titleLabel?.stringValue = text
        detailLabel?.stringValue = detail ?? ""
        detailLabel?.isHidden = (detail?.isEmpty ?? true)

        let symbol = NSImage(
            systemSymbolName: style.symbolName,
            accessibilityDescription: nil
        )
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView?.image = symbol?.withSymbolConfiguration(config)
        iconView?.contentTintColor = style.accent

        layoutContent()
        positionOnScreen()
        panel?.alphaValue = 1
        animateInIfNeeded()
        panel?.orderFrontRegardless()
    }

    /// Compatibility shim for older call sites.
    func show(text: String) {
        show(text, style: .info)
    }

    func showTemporary(
        _ text: String,
        style: Style = .info,
        detail: String? = nil,
        duration: TimeInterval = 1.8
    ) {
        show(text, style: style, detail: detail)
        let generation = displayGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            self.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel, panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        let generation = displayGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.displayGeneration == generation else {
                // A newer show() won — leave the panel alone.
                return
            }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
        })
    }

    private func ensurePanel() {
        if panel != nil { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.alphaValue = 0

        let root = NSView(frame: p.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        applyCardChrome(to: card)

        let icon = NSImageView(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .left
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: "")
        detail.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = true

        card.addSubview(icon)
        card.addSubview(title)
        card.addSubview(detail)
        root.addSubview(card)
        p.contentView = root

        panel = p
        container = card
        iconView = icon
        titleLabel = title
        detailLabel = detail
    }

    private func applyCardChrome(to view: NSView) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.92).cgColor
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.94).cgColor
            view.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        }
    }

    private func layoutContent() {
        guard let panel, let container, let iconView, let titleLabel, let detailLabel else { return }
        applyCardChrome(to: container)

        let hasDetail = !detailLabel.isHidden && !detailLabel.stringValue.isEmpty
        let textMax = maxWidth - horizontalPadding * 2 - iconSize - 10
        let titleSize = titleLabel.sizeThatFits(NSSize(width: textMax, height: 64))
        let detailSize = hasDetail
            ? detailLabel.sizeThatFits(NSSize(width: textMax, height: 24))
            : .zero

        let textWidth = max(titleSize.width, detailSize.width)
        let contentWidth = min(maxWidth, max(minWidth, horizontalPadding * 2 + iconSize + 10 + textWidth))
        let textBlockHeight = titleSize.height + (hasDetail ? 3 + detailSize.height : 0)
        let contentHeight = max(iconSize, textBlockHeight) + verticalPadding * 2

        panel.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        container.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let iconY = (contentHeight - iconSize) / 2
        iconView.frame = NSRect(x: horizontalPadding, y: iconY, width: iconSize, height: iconSize)

        let textX = horizontalPadding + iconSize + 10
        let textW = contentWidth - textX - horizontalPadding
        let textTop = contentHeight - verticalPadding - titleSize.height
        titleLabel.frame = NSRect(x: textX, y: textTop, width: textW, height: titleSize.height)
        if hasDetail {
            detailLabel.frame = NSRect(
                x: textX,
                y: textTop - 3 - detailSize.height,
                width: textW,
                height: detailSize.height
            )
        }
    }

    private func positionOnScreen() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = panel.frame
        let x = screen.visibleFrame.midX - frame.width / 2
        let y = screen.visibleFrame.maxY - frame.height - 72
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func animateInIfNeeded() {
        guard let panel else { return }
        if panel.alphaValue < 0.99 {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }
}
