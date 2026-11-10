import AppKit

final class RefreshRowButton: NSButton {
    enum Style { case statusAndIcon, iconOnly, textOnly }
    private let style: Style

    private static let loadingCursor: NSCursor = {
        let hand = NSCursor.pointingHand
        let hasHandImage = hand.image.size.width > 0 && hand.image.size.height > 0
        let pointer = hasHandImage ? hand.image : NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)
        let handSize = hasHandImage ? hand.image.size : NSSize(width: 20, height: 20)
        let size = NSSize(width: handSize.width + 4, height: handSize.height)
        let image = NSImage(size: size, flipped: false) { _ in
            pointer?.draw(in: NSRect(origin: .zero, size: handSize))
            let badge = NSBezierPath(ovalIn: NSRect(x: size.width - 11, y: 1, width: 10, height: 10))
            NSColor.black.setFill()
            badge.fill()
            NSColor.white.setStroke()
            badge.lineWidth = 1.2
            badge.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: size.width - 6, y: 9))
            hands.line(to: NSPoint(x: size.width - 6, y: 6))
            hands.line(to: NSPoint(x: size.width - 4, y: 5))
            hands.lineWidth = 1.2
            hands.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: hasHandImage ? hand.hotSpot : NSPoint(x: 3, y: 2))
    }()

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
        return loading ? Self.loadingCursor : .pointingHand
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
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.isHidden = style == .iconOnly
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        arrow.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        arrow.imageScaling = .scaleNone
        arrow.isHidden = style == .textOnly
        for view in [statusLabel, arrow] as [NSView] {
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
        arrow.frame = icon
        let labelEnd = style == .textOnly ? bounds.maxX : icon.minX
        statusLabel.frame = NSRect(x: 12, y: bounds.midY - 8, width: max(0, labelEnd - 16), height: 16)
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
            arrow.image = NSImage(systemSymbolName: loading ? "hourglass" : "arrow.clockwise", accessibilityDescription: nil)
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
