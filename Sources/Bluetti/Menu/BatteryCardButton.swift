import AppKit

/// A card value is itself the switch for that value in the menu bar.
final class BatteryCardButton: NSButton {
    let field: MenuBarField
    private let fieldName: String
    private(set) var shown: Bool?
    private var hovered = false
    var onHover: ((Bool) -> Void)?
    var helpDetail: String? {
        didSet { if helpDetail != oldValue { updateHelp() } }
    }

    init(_ field: MenuBarField, name: String) {
        self.field = field
        self.fieldName = name
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        title = ""
        setAccessibilityLabel(name)
        setAccessibilityRole(.checkBox)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        updateShown(false)
    }

    required init?(coder: NSCoder) { nil }

    func updateShown(_ value: Bool) {
        guard shown != value else { return }
        shown = value
        setAccessibilityValue(NSNumber(value: value))
        updateHelp()
        if hovered { onHover?(value) }
    }

    private func updateHelp() {
        let hint = shown == true ? "Hide \(fieldName) from menu bar" : "Show \(fieldName) in menu bar"
        toolTip = helpDetail.map { hint + "\n" + $0 } ?? hint
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(shown == true)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func clearHover() {
        guard hovered else { return }
        hovered = false
        needsDisplay = true
        onHover?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearHover()
    }

    override func viewDidHide() {
        super.viewDidHide()
        clearHover()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            BarTheme.cobalt.withAlphaComponent(isHighlighted ? 0.45 : 0.28).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
    }
}
