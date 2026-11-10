import AppKit
import SwiftUI
import ServiceManagement

// Shared device switcher for the popover and the two native menus.
struct BrandReading: Equatable {
    var value = "—"
    var name = ""
}

enum BrandArtwork {
    static let bluetti = Bundle.main.url(forResource:"bluetti-icon",withExtension:"jpg").flatMap(NSImage.init(contentsOf:))
    static let tcl: NSImage? = {
        guard let source = NSImage(named:"TCLWordmark") else { return nil }
        let image = NSImage(size:NSSize(width:36,height:19),flipped:false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill()
            source.draw(in:rect.insetBy(dx:3,dy:3))
            return true
        }
        image.isTemplate = false
        return image
    }()
}

@MainActor private final class BrandTab: NSButton {
    var reading = BrandReading()
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (selected ? BarTheme.ocean : BarTheme.panel).setFill()
        shape.fill()
        (selected ? NSColor.systemTeal : NSColor.separatorColor).setStroke()
        shape.lineWidth = selected ? 1 : 0.5
        shape.stroke()
        func text(_ string: String, at y: CGFloat, size: CGFloat, bold: Bool, color: NSColor) {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byTruncatingTail
            let height = size + 4
            let rect = NSRect(x: 8, y: isFlipped ? y : bounds.height - y - height, width: bounds.width-16, height: height)
            let attrs: [NSAttributedString.Key:Any] = [.paragraphStyle:p,.font:NSFont.systemFont(ofSize:size,weight:bold ? .bold : .regular),.foregroundColor:color]
            let value = NSMutableAttributedString(string:string,attributes:attrs)
            if string.hasPrefix("OFF") {
                let suffix = String(string.dropFirst(3)).trimmingCharacters(in:CharacterSet(charactersIn:" /"))
                value.setAttributedString(PowerGlyph.off(size:size))
                if !suffix.isEmpty { value.append(NSAttributedString(string:" " + suffix,attributes:attrs)) }
                value.addAttribute(.paragraphStyle,value:p,range:NSRange(location:0,length:value.length))
            }
            TemperatureStyle.attributed(value).draw(in:rect)
        }
        if let image {
            let size = image.size
            image.draw(in: NSRect(x: (bounds.width-size.width)/2, y: (isFlipped ? 17.5 : bounds.height-17.5)-size.height/2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else { text(title, at: 5, size: 11, bold: true, color: .labelColor) }
        text(reading.value, at: 35, size: 13, bold: false, color: .labelColor)
        text(DeviceDisplayName.clean(reading.name), at: 60, size: 10, bold: false, color: .secondaryLabelColor)
    }
}

@MainActor final class SuperHeader: NSView {
    let choose: (Brand) -> Void
    let state: BarSelection
    let reading: (Brand) -> BrandReading
    static let height: CGFloat = 98
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
            case .bluetti: asset = BrandArtwork.bluetti
            case .tcl: asset = BrandArtwork.tcl
            case .lg: asset = lgIcon()
            }
            if let img = asset?.copy() as? NSImage {
                img.size = brand == .tcl ? NSSize(width: 36, height: 19) : NSSize(width: 19, height: 19)
                b.image = img
            }
            b.frame = NSRect(x: 8 + CGFloat(i) * 96, y: 8, width: 90, height: 82)
            b.tag = i
            addSubview(b)
        }
        sync()
    }
    override func layout() {
        super.layout()
        let tabs = subviews.compactMap { $0 as? BrandTab }
        guard !tabs.isEmpty else { return }
        for (index, tab) in tabs.enumerated() {
            let gap: CGFloat = 8
            let width = max(0, (bounds.width - 16 - gap * CGFloat(tabs.count - 1)) / CGFloat(tabs.count))
            tab.frame = NSRect(x: 8 + CGFloat(index) * (width + gap), y: 8, width: width, height: 82)
        }
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

@MainActor private final class FooterMenuButton: NSButton {
    var marked = false { didSet { needsDisplay = true } }
    private var hovered = false
    override init(frame:NSRect) {
        super.init(frame:frame)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited],owner:self))
    }
    required init?(coder:NSCoder) { nil }
    override func mouseEntered(with event:NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        (hovered || isHighlighted ? BarTheme.ocean : BarTheme.navy.withAlphaComponent(0.65)).setFill()
        bounds.fill()
        (title as NSString).draw(in:NSRect(x:image == nil ? 8 : 32,y:(bounds.height-18)/2,width:bounds.width-64,height:20),
                                withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.white])
        if marked {
            NSImage(systemSymbolName:"checkmark",accessibilityDescription:nil)?
                .withSymbolConfiguration(.init(pointSize:14,weight:.semibold))?
                .withSymbolConfiguration(.init(paletteColors:[.white]))?
                .draw(in:NSRect(x:bounds.width-30,y:bounds.midY-8,width:16,height:16),from:.zero,
                      operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        if !keyEquivalent.isEmpty {
            ("⌘" + keyEquivalent.uppercased() as NSString).draw(in:NSRect(x:bounds.width-48,y:(bounds.height-18)/2,width:36,height:20),
                withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.white])
        }
        if let image {
            image.draw(in:NSRect(x:8,y:bounds.midY-8,width:16,height:16),from:.zero,
                       operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
    }
}

@MainActor private final class IntervalSliderCell: NSSliderCell {
    override func drawTickMarks() {
        for index in 0..<numberOfTickMarks {
            let rect = rectOfTickMark(at:index)
            (abs(doubleValue - tickMarkValue(at:index)) < 0.01 ? NSColor.white : NSColor.white.withAlphaComponent(0.45)).setFill()
            NSBezierPath(ovalIn:NSRect(x:rect.midX-1.5,y:rect.midY-1.5,width:3,height:3)).fill()
        }
    }
}

@MainActor final class SuperFooter: NSView {
    static var height: CGFloat { BarSelection.shared.current == .lg ? 176 : 140 }
    let state: BarSelection
    let changed: () -> Void
    let refresh: () -> Void
    let settings: (NSView) -> Void
    let interval: () -> ([Int],Int)
    let setInterval: (Int) -> Void
    private var loginEnabled = SMAppService.mainApp.status == .enabled
    let slider = NSSlider()
    let value = NSTextField(labelWithString:"")
    private let login = FooterMenuButton(title:"Launch at login",target:nil,action:nil)
    private let intervalTitle = NSTextField(labelWithString:"Refresh interval")
    private let intervalValue = NSTextField(labelWithString:"")
    private let intervalSlider = NSSlider()
    private let settingsButton = FooterMenuButton(title:"LG settings…",target:nil,action:nil)
    private let exit = FooterMenuButton(title:"Quit",target:NSApp,action:#selector(NSApplication.terminate(_:)))
    init(state:BarSelection = .shared, refresh:@escaping () -> Void = {}, settings:@escaping (NSView)->Void = { _ in },
         interval:@escaping () -> ([Int],Int) = { ([1,5,30,60,300,600],60) }, setInterval:@escaping (Int)->Void = { _ in },
         changed:@escaping () -> Void) {
        self.state = state; self.changed = changed; self.refresh = refresh; self.settings = settings
        self.interval = interval; self.setInterval = setInterval
        super.init(frame:NSRect(x:0,y:0,width:390,height:Self.height))
        slider.minValue = 9; slider.maxValue = 18; slider.isContinuous = true
        slider.trackFillColor = BarTheme.cobalt; slider.target = self; slider.action = #selector(changeTextSize)
        slider.setAccessibilityLabel("Text size")
        value.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); value.alignment = .center
        login.isBordered = false; login.alignment = .left; login.font = .systemFont(ofSize:12)
        login.target = self; login.action = #selector(toggleLogin)
        settingsButton.isBordered = false; settingsButton.alignment = .left
        settingsButton.target = self; settingsButton.action = #selector(showSettings)
        intervalTitle.font = .systemFont(ofSize:12); intervalValue.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        intervalSlider.cell = IntervalSliderCell()
        intervalSlider.allowsTickMarkValuesOnly = true
        intervalSlider.tickMarkPosition = .below
        intervalSlider.isContinuous = false; intervalSlider.target = self; intervalSlider.action = #selector(changeInterval)
        intervalSlider.trackFillColor = BarTheme.cobalt; intervalSlider.setAccessibilityLabel("Refresh interval")
        exit.isBordered = false; exit.keyEquivalent = "q"; exit.keyEquivalentModifierMask = .command
        [slider,value,login,settingsButton,intervalTitle,intervalValue,intervalSlider,exit].forEach(addSubview)
        sync()
    }
    required init?(coder:NSCoder) { nil }
    func sync() {
        value.stringValue = "\(state.size) pt"
        slider.doubleValue = Double(state.size)
        login.marked = loginEnabled
        settingsButton.isHidden = state.current != .lg
        let (choices,current) = interval()
        intervalSlider.numberOfTickMarks = choices.count
        intervalSlider.minValue = 0; intervalSlider.maxValue = Double(max(1,choices.count-1))
        intervalSlider.doubleValue = Double(choices.firstIndex(of:current) ?? 0)
        intervalValue.stringValue = current < 60 ? "\(current)s" : "\(current/60)m"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        exit.frame = NSRect(x:0,y:0,width:bounds.width,height:34)
        login.frame = NSRect(x:0,y:34,width:bounds.width,height:36)
        slider.frame = NSRect(x:14,y:79,width:bounds.width-76,height:24)
        value.frame = NSRect(x:bounds.width-50,y:82,width:36,height:18)
        intervalTitle.frame = NSRect(x:14,y:110,width:110,height:18)
        intervalSlider.frame = NSRect(x:125,y:107,width:max(30,bounds.width-187),height:24)
        intervalValue.frame = NSRect(x:bounds.width-50,y:110,width:36,height:18)
        settingsButton.frame = NSRect(x:0,y:140,width:bounds.width,height:36)
    }
    private func resize(_ value:Int) {
        guard value != state.size else { return }
        state.setSize(value); sync(); changed()
    }
    @objc private func changeTextSize() { resize(Int(slider.doubleValue.rounded())) }
    @objc private func showSettings() { settings(settingsButton) }
    @objc private func changeInterval() {
        let choices = interval().0
        let index = Int(intervalSlider.doubleValue.rounded())
        guard choices.indices.contains(index) else { return }
        setInterval(choices[index]); sync()
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSAlert(error:error).runModal() }
        loginEnabled = SMAppService.mainApp.status == .enabled; sync()
    }
}

enum BarTheme {
    static let background = NSColor(srgbRed: 0.055, green: 0.10, blue: 0.17, alpha: 1)
    static let panel = NSColor(srgbRed: 0.075, green: 0.145, blue: 0.23, alpha: 1)
    static let navy = NSColor(srgbRed: 0.09, green: 0.18, blue: 0.29, alpha: 1)
    static let ocean = NSColor(srgbRed: 0.14, green: 0.32, blue: 0.42, alpha: 1)
    static let energy = NSColor(srgbRed: 1, green: 0.84, blue: 0.25, alpha: 1)
    static let cobalt = NSColor(srgbRed: 0.13, green: 0.40, blue: 0.76, alpha: 1)
}


// Temperature is semantic: the same scale has a bright card palette and a darker
// palette for a light menu bar. A white degree sign keeps a subtle dark outline.
enum TemperatureStyle {
    static let pattern = try! NSRegularExpression(pattern: #"(-?[0-9]+(?:[.,][0-9]+)?)(\s*°(?:C)?)"#)
    private static func palette(_ degrees: Double, light: Bool) -> NSColor {
            let stops: [(CGFloat, CGFloat, CGFloat)] = light
                ? [(0.20,0.32,0.49),(0.44,0.30,0.18),(0.50,0.26,0.28)]
                : [(0.83,0.92,1),(1,0.90,0.77),(1,0.87,0.88)]
            let t = min(1, max(0, (degrees - 16) / 10))
            let index = t <= 0.5 ? 0 : 1
            let u = CGFloat(index == 0 ? t * 2 : (t - 0.5) * 2)
            let a = stops[index], b = stops[index+1]
            return NSColor(srgbRed:a.0+(b.0-a.0)*u, green:a.1+(b.1-a.1)*u, blue:a.2+(b.2-a.2)*u, alpha:1)
    }
    private static let menuColors: [NSColor] = (0...100).map { index in
        let degrees = 16 + Double(index) / 10
        return NSColor(name:nil) { appearance in
            palette(degrees, light: appearance.bestMatch(from:[.aqua,.darkAqua]) != .darkAqua)
        }
    }
    static func color(_ degrees: Double, menuBar: Bool = false) -> NSColor {
        let clamped = min(26, max(16, degrees))
        return menuBar ? menuColors[Int(((clamped - 16) * 10).rounded())] : palette(clamped, light:false)
    }
    static func attributed(_ source: NSAttributedString, menuBar: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let string = source.string as NSString
        for match in pattern.matches(in: source.string, range:NSRange(location:0,length:source.length)) {
            let number = match.range(at:1), unit = match.range(at:2)
            guard let value = Double(string.substring(with:number).replacingOccurrences(of:",",with:".")) else { continue }
            result.addAttribute(.foregroundColor, value:color(value,menuBar:menuBar), range:number)
            result.addAttribute(.foregroundColor, value:NSColor.white, range:unit)
            if menuBar {
                result.addAttributes([.strokeColor:NSColor.black.withAlphaComponent(0.7),.strokeWidth: -1.5],range:unit)
            }
        }
        return result
    }
}

struct TemperatureText: View {
    let value: String
    var menuBar = false
    private var styled: Text {
        let string = value as NSString
        var text = Text("")
        var cursor = 0
        for match in TemperatureStyle.pattern.matches(in:value,range:NSRange(location:0,length:string.length)) {
            text = text + Text(string.substring(with:NSRange(location:cursor,length:match.range.location-cursor)))
            let number = string.substring(with:match.range(at:1))
            let degrees = Double(number.replacingOccurrences(of:",",with:".")) ?? 21
            text = text + Text(number).foregroundColor(Color(nsColor:TemperatureStyle.color(degrees,menuBar:menuBar)))
                + Text(string.substring(with:match.range(at:2))).foregroundColor(.white)
            cursor = NSMaxRange(match.range)
        }
        return text + Text(string.substring(from:cursor))
    }
    var body: some View {
        styled.shadow(color: menuBar ? .black.opacity(0.65) : .clear, radius:menuBar ? 0.5 : 0)
    }
}


enum DisplayUnits {
    static func powerAxis(_ value: Double) -> String { axis(value,small:"W",large:"kW") }
    static func energyAxis(_ value: Double) -> String { axis(value,small:"Wh",large:"kWh") }
    private static func axis(_ value: Double, small: String, large: String) -> String {
        if abs(value) < 1000 { return format(value,small:small,large:large) }
        return (value/1000).formatted(.number.locale(Locale(identifier:"en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2))) + " " + large
    }
    static func power(_ watts: Double) -> String { format(watts, small: "W", large: "kW") }
    static func energy(_ wattHours: Double) -> String { format(wattHours, small: "Wh", large: "kWh") }
    private static func format(_ value: Double, small: String, large: String) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 1000 {
            return String(format:"%.2f %@", locale:Locale(identifier:"en_US_POSIX"), value / 1000, large)
        }
        return String(format:"%.0f %@", locale:Locale(identifier:"en_US_POSIX"), value, small)
    }
}

enum DeviceDisplayName {
    static func clean(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"(?i)\b(?:air\s*con(?:ditioner)?|aricon)\b|\ba\s*/\s*c\b"#, with:"", options:.regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#,with:" ",options:.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"-–·")))
        return cleaned.isEmpty ? "Unit" : cleaned
    }
}

enum PowerGlyph {
    private static let cache = NSCache<NSNumber,NSAttributedString>()
    static func off(size:CGFloat) -> NSAttributedString {
        let key = NSNumber(value:Double(size))
        if let cached = cache.object(forKey:key) { return cached }
        let symbol = NSImage(systemSymbolName:"power",accessibilityDescription:"OFF")!
        let image = NSImage(size:NSSize(width:size,height:size),flipped:false) { rect in
            symbol.draw(in:rect)
            NSColor.systemRed.setFill(); rect.fill(using:.sourceIn)
            return true
        }
        image.isTemplate = false
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x:0,y:-size*0.15,width:size,height:size)
        let value = NSAttributedString(attachment:attachment)
        cache.setObject(value,forKey:key)
        return value
    }
}

// Relative ages update only while the panel is open; no device polling is involved.
final class ReadingAge: ObservableObject {
    static let shared = ReadingAge()
    private static var labels: [Date:String] = [:]
    private static var timer: Timer?
    static func start(tick:@escaping () -> Void) {
        stop()
        panelOpened()
        let timer = Timer(timeInterval:3,repeats:true) { _ in
            panelOpened()
            tick()
        }
        self.timer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    static func stop() { timer?.invalidate(); timer = nil }
    static func panelOpened() {
        labels.removeAll(keepingCapacity:true)
        shared.objectWillChange.send()
    }
    static func label(_ date:Date, now:Date = Date()) -> String {
        if let label = labels[date] { return label }
        let seconds = max(0,Int(now.timeIntervalSince(date)))
        let age = seconds < 3 ? "Just now" : seconds < 60 ? "\(seconds)s ago" : seconds < 3600 ? "\(seconds/60)m ago" : seconds < 86400 ? "\(seconds/3600)h ago" : "\(seconds/86400)d ago"
        let text = "Last read " + age
        if labels.count > 128 { labels.removeAll(keepingCapacity:true) }
        labels[date] = text
        return text
    }
}
