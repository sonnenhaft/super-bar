import AppKit

// Shared device switcher for the popover and the two native menus.
struct BrandReading: Equatable {
    var value = "—"
    var name = ""
}

@MainActor private final class BrandTab: NSButton {
    var reading = BrandReading()
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        (selected ? BarTheme.ocean : BarTheme.panel).setFill()
        shape.fill()
        (selected ? NSColor.systemTeal : NSColor.separatorColor).setStroke()
        shape.lineWidth = selected ? 1.5 : 0.6
        shape.stroke()
        func text(_ string: String, at y: CGFloat, size: CGFloat, bold: Bool, color: NSColor) {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byTruncatingTail
            let height = size + 4
            let rect = NSRect(x: 4, y: isFlipped ? y : bounds.height - y - height, width: bounds.width-8, height: height)
            (string as NSString).draw(in: rect, withAttributes: [.paragraphStyle:p, .font:NSFont.systemFont(ofSize:size, weight:bold ? .bold : .regular), .foregroundColor:color])
        }
        if let image {
            let size = image.size
            image.draw(in: NSRect(x: (bounds.width-size.width)/2, y: (isFlipped ? 13 : bounds.height-13)-size.height/2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else { text(title, at: 5, size: 11, bold: true, color: .labelColor) }
        text(reading.value, at: 25, size: 13, bold: true, color: .labelColor)
        text(reading.name, at: 43, size: 10, bold: selected, color: .secondaryLabelColor)
    }
}

@MainActor final class SuperHeader: NSView {
    let choose: (Brand) -> Void
    let state: BarSelection
    let reading: (Brand) -> BrandReading
    static let height: CGFloat = 70
    init(state: BarSelection = .shared, reading: @escaping (Brand) -> BrandReading = { _ in BrandReading() }, choose: @escaping (Brand) -> Void) {
        self.state = state
        self.reading = reading
        self.choose = choose
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        for (i, brand) in Brand.allCases.enumerated() {
            let b = BrandTab(title: brand.rawValue, target: self, action: #selector(openBrand(_:)))
            b.isBordered = false
            b.setButtonType(.toggle)
            let asset: NSImage?
            switch brand {
            case .bluetti: asset = NSImage(named: "bluetti-icon")
            case .tcl: asset = NSImage(named: "TCLWordmark")
            case .lg: asset = lgIcon()
            }
            if let img = asset?.copy() as? NSImage {
                img.size = brand == .tcl ? NSSize(width: 36, height: 13) : NSSize(width: 19, height: 19)
                b.image = img
            }
            b.frame = NSRect(x: 6 + i * 97, y: 4, width: 94, height: 62)
            b.tag = i
            addSubview(b)
        }
        sync()
    }
    func sync() {
        for case let b as BrandTab in subviews {
            let brand = Brand.allCases[b.tag]
            let selected: NSControl.StateValue = brand == state.current ? .on : .off
            let updated = reading(brand)
            guard b.state != selected || b.reading != updated || b.toolTip == nil else { continue }
            b.state = selected
            b.reading = updated
            b.toolTip = [brand.rawValue, b.reading.name, b.reading.value].filter { !$0.isEmpty }.joined(separator: " · ")
            b.setAccessibilityLabel(b.toolTip)
            b.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc func openBrand(_ b: NSButton) {
        let brand = Brand.allCases[b.tag]
        if brand == state.current { b.state = .on } else { choose(brand) }
    }
}

@MainActor final class SuperFooter: NSView {
    static let height: CGFloat = 40
    let state: BarSelection
    let changed: () -> Void
    let slider = NSSlider()
    let value = NSTextField(labelWithString: "")
    let swatch = NSColorWell()
    init(state: BarSelection = .shared, changed: @escaping () -> Void) {
        self.state = state
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        slider.frame = NSRect(x: 14, y: 9, width: 136, height: 22)
        slider.minValue = 9; slider.maxValue = 18
        slider.isContinuous = true; slider.target = self; slider.action = #selector(changeTextSize)
        slider.trackFillColor = BarTheme.cobalt
        slider.setAccessibilityLabel("Text size")
        value.frame = NSRect(x: 155, y: 11, width: 36, height: 18)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        swatch.frame = NSRect(x: 194, y: 8, width: 35, height: 24)
        swatch.colorWellStyle = .minimal
        swatch.target = self; swatch.action = #selector(recolor)
        swatch.setAccessibilityLabel("Text color")
        let exit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        exit.bezelStyle = .rounded
        exit.frame = NSRect(x: 232, y: 5, width: 63, height: 30)
        exit.keyEquivalent = "q"; exit.keyEquivalentModifierMask = .command
        [slider,value,swatch,exit].forEach(addSubview)
        sync()
    }
    required init?(coder: NSCoder) { nil }
    func sync() {
        slider.doubleValue = Double(state.size)
        value.stringValue = "\(state.size) pt"
        swatch.color = state.color ?? .labelColor
    }
    @objc private func changeTextSize() {
        let n = Int(slider.doubleValue.rounded())
        guard n != state.size else { return }
        state.setSize(n); value.stringValue = "\(n) pt"; changed()
    }
    @objc private func recolor() { state.color = swatch.color; changed() }
}

enum BarTheme {
    static let background = NSColor(srgbRed: 0.055, green: 0.10, blue: 0.17, alpha: 1)
    static let panel = NSColor(srgbRed: 0.075, green: 0.145, blue: 0.23, alpha: 1)
    static let navy = NSColor(srgbRed: 0.09, green: 0.18, blue: 0.29, alpha: 1)
    static let ocean = NSColor(srgbRed: 0.14, green: 0.32, blue: 0.42, alpha: 1)
    static let cobalt = NSColor(srgbRed: 0.13, green: 0.40, blue: 0.76, alpha: 1)
}
