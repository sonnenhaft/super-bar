import AppKit

final class RefreshRowButton: NSButton {
    enum Style { case statusAndIcon, iconOnly, textOnly }
    private let style: Style

    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    var iconTint: NSColor? {
        get { arrow.contentTintColor }
        set { arrow.contentTintColor = newValue }
    }
    private var loading = false
    private var hovered = false { didSet { needsDisplay = true } }
    private var rowCursor: NSCursor {
        guard isEnabled else { return .arrow }
        return .pointingHand
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, style: .statusAndIcon)
    }

    init(frame: NSRect, style: Style) {
        self.style = style
        super.init(frame: frame)
        title = ""
        isBordered = false
        setAccessibilityLabel("Refresh")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = style == .iconOnly
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        arrow.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        arrow.imageScaling = .scaleNone
        arrow.isHidden = style == .textOnly
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        for view in [statusLabel, arrow, spinner] as [NSView] {
            addSubview(view)
            view.setAccessibilityElement(false)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    override func layout() {
        super.layout()
        let icon = NSRect(x: style == .iconOnly ? bounds.midX - 8 : bounds.maxX - 23, y: bounds.midY - 8, width: 16, height: 16)
        spinner.frame = icon.insetBy(dx: 2, dy: 2)
        arrow.frame = icon
        let labelEnd = style == .textOnly ? bounds.maxX : icon.minX
        statusLabel.frame = NSRect(x: 8, y: bounds.midY - 8, width: max(0, labelEnd - 16), height: 16)
    }

    func update(status: String, loading: Bool, enabled: Bool) {
        if statusLabel.stringValue != status {
            statusLabel.stringValue = status
            setAccessibilityValue(status)
        }
        let cursorChanged = isEnabled != enabled || self.loading != loading
        if isEnabled != enabled { isEnabled = enabled }
        if self.loading != loading {
            self.loading = loading
            arrow.isHidden = loading || style == .textOnly
            if loading && style != .textOnly { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        if cursorChanged, let window = window {
            window.invalidateCursorRects(for: self)
            if hovered && window.isVisible && visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                rowCursor.set()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
    }

    // Mouse tracking belongs to the button even over the text or spinning indicator.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        rowCursor.set()
    }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: rowCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
            bounds.insetBy(dx: 0, dy: 1).fill()
        }
        super.draw(dirtyRect)
    }
}
