import AppKit

struct StationRowTitle {
    let name: String
    let accessibilityLabel: String
    let isConnected: Bool

    init(name: String, watts: Double?, connectedPercent: Int?) {
        self.name = name
        let output = watts.flatMap { $0 > 0 ? MenuPresentation.watts($0) : nil } ?? "off"
        let summary = name + " · " + output
        isConnected = connectedPercent != nil
        accessibilityLabel = connectedPercent.map { "\(summary), connected, \($0)%" } ?? summary
    }
}

final class BatteryCard: NSView {
    let selectButton = PanelButton()
    let refreshButton = RefreshRowButton(frame: .zero, style: .iconOnly)
    let renameButton = PanelButton()
    var onToggle: ((MenuBarField) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private var selected = false
    var expanded = true { didSet { arrangeContents(); needsDisplay = true } }
    private(set) var contentHeight: CGFloat = 112
    private let eye = NSImageView()
    private weak var editor: BlueBarAliasEditor?
    private var connected = false
    private var percent: Int?
    var summaryName: String { nameLabel.stringValue }
    var summaryPercent: String { percent.map { "\($0)%" } ?? "—" }
    var summaryBatterySymbol: String { "battery.\(min(100, max(0, ((percent ?? 0) + 12) / 25 * 25)))percent" }
    func selectSummary() { _ = selectButton.sendAction(selectButton.action, to: selectButton.target) }
    func toggleSummaryPercent() { onToggle?(.percentage) }

    private let percentage = BatteryCardButton(.percentage, name: "Battery percentage")
    private let battery = BatteryCardButton(.battery, name:"Battery icon")
    private let brand = BatteryCardButton(.brand, name: "BLUETTI logo")
    private let input = BatteryCardButton(.input, name: "Input power")
    private let output = BatteryCardButton(.output, name: "Output power")
    private let charge = BatteryCardButton(.chargeTime, name: "Time to full charge")
    private let runtime = BatteryCardButton(.runtime, name: "Battery runtime")
    private var buttons: [BatteryCardButton] { [percentage, battery, brand, input, output, charge, runtime] }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.usesSingleLineMode = true
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setAccessibilityElement(false)
        addSubview(nameLabel)
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        eye.contentTintColor = .white
        eye.isHidden = true
        eye.setAccessibilityElement(false)
        addSubview(eye)
        selectButton.setButtonType(.momentaryChange)
        selectButton.isBordered = false
        selectButton.title = ""
        selectButton.setAccessibilityRole(.radioButton)
        addSubview(selectButton)
        refreshButton.isHidden = true
        refreshButton.iconTint = .white
        addSubview(refreshButton)
        renameButton.title = ""
        renameButton.isBordered = false
        renameButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        renameButton.contentTintColor = .white
        renameButton.imagePosition = .imageOnly
        renameButton.toolTip = "Rename station"
        addSubview(renameButton)

        for button in buttons {
            button.target = self
            button.action = #selector(toggleField(_:))
            button.onHover = nil
            addSubview(button)
        }
        battery.imagePosition = .imageOnly
        battery.imageScaling = .scaleNone
        battery.contentTintColor = .white
        brand.imagePosition = .imageOnly
        brand.imageScaling = .scaleProportionallyUpOrDown
        for button in [percentage, input, output, charge, runtime] {
            button.imagePosition = .noImage
            button.lineBreakMode = .byTruncatingTail
        }
        update(readingPercent: nil, power: MenuPowerRow(input: "", output: "", toolTip: nil),
               chargeTime: "", batteryTime: "")
    }

    required init?(coder: NSCoder) { nil }

    func updateHeader(title: StationRowTitle, checked: Bool, enabled: Bool, canRename: Bool) {
        if nameLabel.stringValue != title.name || connected != title.isConnected {
            nameLabel.stringValue = title.name
            connected = title.isConnected
            needsLayout = true
            needsDisplay = true
        }
        nameLabel.font = .systemFont(ofSize: 15, weight: checked ? .bold : .regular)
        if selected != checked { selected = checked; needsDisplay = true }
        selectButton.isEnabled = enabled
        selectButton.setAccessibilityLabel(title.accessibilityLabel)
        selectButton.setAccessibilityValue(NSNumber(value: checked))
        selectButton.state = checked ? .on : .off
        refreshButton.isHidden = !expanded
        renameButton.isEnabled = canRename
    }

    func editName(with editor: BlueBarAliasEditor) {
        self.editor = editor
        addSubview(editor)
        editor.frame = nameLabel.frame.insetBy(dx: 0, dy: -2)
        needsDisplay = true
    }

    func endEditingName() {
        editor?.removeFromSuperview()
        editor = nil
        needsDisplay = true
    }

    func setFields(_ fields: Set<MenuBarField>, brand image: NSImage?) {
        if brand.image !== image { brand.image = image }
        brand.isHidden = false
        brand.alphaValue = 1
        for button in buttons { button.updateShown(fields.contains(button.field)) }
    }

    func update(readingPercent: Int?, power: MenuPowerRow, chargeTime: String, batteryTime: String) {
        percent = readingPercent
        for (button, text) in [(percentage, readingPercent.map { "\($0)%" } ?? ""),
                               (input, power.input), (output, power.output),
                               (charge, chargeTime), (runtime, batteryTime)] {
            updateText(button, text)
        }
        brand.isHidden = false
        brand.alphaValue = 1
        battery.isHidden = readingPercent == nil
        if let readingPercent { battery.image = NSImage(systemSymbolName:MenuPresentation.batterySymbol(percent:readingPercent),accessibilityDescription:"Battery")?.withSymbolConfiguration(.init(pointSize:16,weight:.medium)) }
        output.helpDetail = power.toolTip
        arrangeContents()
    }

    private func updateText(_ button: BatteryCardButton, _ text: String) {
        button.isHidden = text.isEmpty

        let main = button === percentage
        let style = NSMutableParagraphStyle()
        style.alignment = main ? .left : .right
        style.lineBreakMode = .byTruncatingTail
        let color: NSColor = button === charge || button === runtime ? .init(srgbRed: 0.62, green: 0.88, blue: 0.96, alpha: 1) : .white
        let font = NSFont.monospacedDigitSystemFont(ofSize: main ? (expanded ? 28 : 13) : 13, weight: button.shown == true ? .bold : .regular)
        if !text.isEmpty, button.attributedTitle.string == text, button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font { return }
        button.alignment = style.alignment
        button.attributedTitle = NSAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    @objc private func toggleField(_ sender: BatteryCardButton) { onToggle?(sender.field) }

    override func layout() {
        super.layout()
        arrangeContents()
    }

    private func arrangeContents() {
        let left = bounds.minX + 8, right = max(left, bounds.maxX - 8)
        let header = NSRect(x: left, y: 8, width: right - left, height: 22)
        selectButton.frame = header
        let slot = min(22, header.width / 5)
        renameButton.frame = NSRect(x: right - slot, y: header.minY, width: slot, height: header.height)
        refreshButton.frame = renameButton.frame.offsetBy(dx: -slot, dy: 0)
        eye.frame = NSRect(x: refreshButton.frame.minX - 15, y: header.minY, width: 14, height: header.height)
        nameLabel.frame = NSRect(x: left + 32, y: 9, width: max(0, eye.frame.minX - left - 40), height: 21)
        editor?.frame = nameLabel.frame.insetBy(dx: 0, dy: -2)
        brand.frame = NSRect(x: left, y: 9, width: 25, height: 21)
        battery.frame = NSRect(x: right - 20, y: 38, width: 20, height: 20)
        refreshButton.isHidden = !expanded
        renameButton.isHidden = !expanded
        for button in [input, output, charge, runtime] { button.isHidden = !expanded || button.title.isEmpty }
        if let footer = subviews.last as? RefreshRowButton { footer.isHidden = !expanded }
        if !expanded {
            brand.frame = NSRect(x: left, y: 6, width: 24, height: 14)
            percentage.frame = NSRect(x: right - 48, y: 3, width: 48, height: 20)
            nameLabel.frame = NSRect(x: left + 30, y: 3, width: max(0, right - left - 86), height: 20)
            nameLabel.font = .systemFont(ofSize: 13)
            selectButton.frame = NSRect(x: left, y: 3, width: max(0, right - left - 52), height: 20)
            battery.isHidden = true
            contentHeight = 26
            return
        }
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        battery.isHidden = percent == nil
        guard percent != nil else { setHeight(30); return }

        let bodyY: CGFloat = 32
        let percentWidth = ceil(percentage.attributedTitle.size().width) + 4
        let leftWidth = max(64, percentWidth)
        percentage.frame = NSRect(x: left, y: bodyY, width: leftWidth, height: 35)

        // Power and time share a right edge for each direction. For unusually
        // long dual AC/DC readings, stack the pairs rather than cutting off watts.
        let pairs = [(input, charge), (output, runtime)].filter { !$0.0.isHidden || !$0.1.isHidden }
        guard !pairs.isEmpty else { setHeight(bodyY + 66); return }
        let otherLeft = left + leftWidth + 6
        let available = max(0, right - otherLeft)
        let widths = pairs.map { ceil(max($0.0.attributedTitle.size().width, $0.1.attributedTitle.size().width)) + 6 }
        let nextLine = (widths.max() ?? 0) > available
        let start = nextLine ? left : otherLeft
        let y = nextLine ? bodyY + 66 : bodyY + 5
        let sideBySide = widths.reduce(0, +) + 4 <= right - start
        var x = right
        var bottom = y
        for index in pairs.indices.reversed() {
            let pair = pairs[index]
            let width = sideBySide ? widths[index] : right - start
            let top = y + (sideBySide ? 0 : CGFloat(index) * 40)
            pair.0.frame = NSRect(x: x - width, y: top, width: width, height: 20)
            pair.1.frame = pair.0.frame.offsetBy(dx: 0, dy: 20)
            bottom = max(bottom, pair.1.isHidden ? pair.0.frame.maxY : pair.1.frame.maxY)
            if sideBySide { x -= width + 4 }
        }
        setHeight(max(bodyY + 66, bottom) + 6)
    }

    private func setHeight(_ height: CGFloat) {
        contentHeight = max(144, height + 24)
        if let footer = subviews.last as? RefreshRowButton, footer !== refreshButton {
            footer.frame = NSRect(x: 0, y: contentHeight - 28, width: bounds.width, height: 20)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if connected && editor == nil {
            let textWidth = min(nameLabel.frame.width, ceil(nameLabel.intrinsicContentSize.width))
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: nameLabel.frame.minX + textWidth + 3,
                                        y: nameLabel.frame.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

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
        if field == .brand || field == .battery { alphaValue = value ? 1 : 0.4 }
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
