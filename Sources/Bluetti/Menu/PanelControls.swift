import AppKit

final class PanelButton: NSButton {
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.28 : 0.17).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
}

final class PanelSlider: NSSlider {
    override init(frame: NSRect) {
        super.init(frame: frame)
        trackFillColor = BarTheme.cobalt
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); trackFillColor = BarTheme.cobalt }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); trackFillColor = BarTheme.cobalt }
}
