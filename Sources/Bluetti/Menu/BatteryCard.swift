import AppKit

final class BatteryCard: NSView {
    let selectButton = PanelButton()
    let refreshButton = RefreshRowButton(frame: .zero, style: .iconOnly)
    let renameButton = PanelButton()
    var onToggle: ((MenuBarField) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private var selected = false
    private(set) var contentHeight: CGFloat = 112
    private let eye = NSImageView()
    private weak var editor: BlueBarAliasEditor?
    private var connected = false
    private var percent: Int?

    private let percentage = BatteryCardButton(.percentage, name: "Battery percentage")
    private let brand = BatteryCardButton(.brand, name: "BLUETTI logo")
    private let input = BatteryCardButton(.input, name: "Input power")
    private let output = BatteryCardButton(.output, name: "Output power")
    private let charge = BatteryCardButton(.chargeTime, name: "Time to full charge")
    private let runtime = BatteryCardButton(.runtime, name: "Battery runtime")
    private var buttons: [BatteryCardButton] { [percentage, brand, input, output, charge, runtime] }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
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
        refreshButton.iconTint = .white
        addSubview(refreshButton)
        renameButton.title = ""
        renameButton.isBordered = false
        renameButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        renameButton.contentTintColor = .white
        renameButton.imagePosition = .imageOnly
        renameButton.toolTip = "Rename station"
        addSubview(renameButton)

        for button in buttons {
            button.target = self
            button.action = #selector(toggleField(_:))
            button.onHover = { [weak self] shown in self?.eye.isHidden = !shown }
            addSubview(button)
        }
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
        nameLabel.font = .systemFont(ofSize: 13, weight: checked ? .bold : .regular)
        if selected != checked { selected = checked; needsDisplay = true }
        selectButton.isEnabled = enabled
        selectButton.setAccessibilityLabel(title.accessibilityLabel)
        selectButton.setAccessibilityValue(NSNumber(value: checked))
        selectButton.state = checked ? .on : .off
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
        brand.isHidden = image == nil || percent == nil
        for button in buttons { button.updateShown(fields.contains(button.field)) }
    }

    func update(readingPercent: Int?, power: MenuPowerRow, chargeTime: String, batteryTime: String) {
        percent = readingPercent
        for (button, text) in [(percentage, readingPercent.map { "\($0)%" } ?? ""),
                               (input, power.input), (output, power.output),
                               (charge, chargeTime), (runtime, batteryTime)] {
            updateText(button, text)
        }
        brand.isHidden = readingPercent == nil || brand.image == nil
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: main ? 25 : 11, weight: button.shown == true ? .bold : .regular)
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
        let left = bounds.minX + 18, right = max(left, bounds.maxX - 17)
        let header = NSRect(x: left, y: 4, width: right - left, height: 22)
        selectButton.frame = header
        let slot = min(22, header.width / 5)
        renameButton.frame = NSRect(x: right - slot, y: header.minY, width: slot, height: header.height)
        refreshButton.frame = renameButton.frame.offsetBy(dx: -slot, dy: 0)
        eye.frame = NSRect(x: refreshButton.frame.minX - 15, y: header.minY, width: 14, height: header.height)
        nameLabel.frame = NSRect(x: left, y: 7, width: max(0, eye.frame.minX - left - 8), height: 16)
        editor?.frame = nameLabel.frame.insetBy(dx: 0, dy: -2)
        guard percent != nil else { setHeight(30); return }

        let bodyY: CGFloat = 28
        let percentWidth = ceil(percentage.attributedTitle.size().width) + 4
        let leftWidth = max(64, percentWidth)
        percentage.frame = NSRect(x: left, y: bodyY, width: leftWidth, height: 31)
        brand.frame = NSRect(x: left, y: bodyY + 32, width: 20, height: 19)

        // Power and time share a right edge for each direction. For unusually
        // long dual AC/DC readings, stack the pairs rather than cutting off watts.
        let pairs = [(input, charge), (output, runtime)].filter { !$0.0.isHidden || !$0.1.isHidden }
        guard !pairs.isEmpty else { setHeight(bodyY + 58); return }
        let otherLeft = left + leftWidth + 6
        let available = max(0, right - otherLeft)
        let widths = pairs.map { ceil(max($0.0.attributedTitle.size().width, $0.1.attributedTitle.size().width)) + 6 }
        let nextLine = (widths.max() ?? 0) > available
        let start = nextLine ? left : otherLeft
        let y = nextLine ? bodyY + 55 : bodyY + 5
        let sideBySide = widths.reduce(0, +) + 4 <= right - start
        var x = right
        var bottom = y
        for index in pairs.indices.reversed() {
            let pair = pairs[index]
            let width = sideBySide ? widths[index] : right - start
            let top = y + (sideBySide ? 0 : CGFloat(index) * 32)
            pair.0.frame = NSRect(x: x - width, y: top, width: width, height: 16)
            pair.1.frame = pair.0.frame.offsetBy(dx: 0, dy: 16)
            bottom = max(bottom, pair.1.isHidden ? pair.0.frame.maxY : pair.1.frame.maxY)
            if sideBySide { x -= width + 4 }
        }
        setHeight(max(bodyY + 52, bottom) + 6)
    }

    private func setHeight(_ height: CGFloat) {
        contentHeight = max(112, height + 24)
        if let footer = subviews.last as? RefreshRowButton, footer !== refreshButton {
            footer.frame = NSRect(x: 6, y: contentHeight - 23, width: max(0, bounds.width - 12), height: 20)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 2), xRadius: 9, yRadius: 9)
        NSGradient(starting: selected ? BarTheme.navy : BarTheme.panel, ending: selected ? BarTheme.ocean : BarTheme.navy)?.draw(in: card, angle: 0)
        if connected && editor == nil {
            let textWidth = min(nameLabel.frame.width, ceil(nameLabel.intrinsicContentSize.width))
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: nameLabel.frame.minX + textWidth + 3,
                                        y: nameLabel.frame.midY - 2, width: 4, height: 4)).fill()
        }
    }
}
