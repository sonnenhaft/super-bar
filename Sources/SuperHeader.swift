import AppKit
import SwiftUI
import ServiceManagement

enum BrandArtwork {
    static let bluetti = Bundle.main.url(forResource:"bluetti-icon",withExtension:"jpg").flatMap(NSImage.init(contentsOf:))

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
        (hovered || isHighlighted ? BarTheme.ocean : BarTheme.panel.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
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
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = CGFloat(min(1, max(0, (doubleValue - minValue) / max(1, maxValue - minValue))))
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height),
                     xRadius: 2, yRadius: 2).fill()
    }
    override func drawTickMarks() {
        for index in 0..<numberOfTickMarks {
            let rect = rectOfTickMark(at:index)
            (abs(doubleValue - tickMarkValue(at:index)) < 0.01 ? NSColor.white : NSColor.white.withAlphaComponent(0.45)).setFill()
            NSBezierPath(ovalIn:NSRect(x:rect.midX-1.5,y:rect.midY-1.5,width:3,height:3)).fill()
        }
    }
}

@MainActor final class SuperFooter: NSView {
    static let height: CGFloat = 176
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
        super.init(frame:NSRect(x:0,y:0,width: 420,height:Self.height))
        slider.cell = IntervalSliderCell()
        slider.minValue = Double(BarSelection.sizeRange.lowerBound)
        slider.maxValue = Double(BarSelection.sizeRange.upperBound); slider.isContinuous = true
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
        settingsButton.isHidden = state.chartBrand != .lg
        let (choices,current) = interval()
        intervalSlider.numberOfTickMarks = choices.count
        intervalSlider.isEnabled = choices.count > 1
        intervalSlider.minValue = 0; intervalSlider.maxValue = Double(max(1,choices.count-1))
        intervalSlider.doubleValue = Double(choices.firstIndex(of:current) ?? 0)
        intervalTitle.stringValue = state.chartBrand.rawValue + " refresh"
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

// AppKit adapter for the same sRGB palette used by SwiftUI on every platform.
enum BarTheme {
    static let backgroundTop = PanelPalette.backgroundTop.nsColor
    static let background = PanelPalette.background.nsColor
    static let backgroundBottom = PanelPalette.backgroundBottom.nsColor
    static let panel = PanelPalette.panel.nsColor
    static let navy = PanelPalette.selected.nsColor
    static let ocean = PanelPalette.ocean.nsColor
    static let energy = PanelPalette.yellow.nsColor
    static let cobalt = PanelPalette.cyan.nsColor
    static let selection = PanelPalette.outline.nsColor
    static let green = PanelPalette.green.nsColor
}

final class PanelBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [BarTheme.backgroundTop, BarTheme.background, BarTheme.backgroundBottom])?.draw(in: bounds, angle: -90)
    }
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
    static func color(_ degrees: Double, menuBar: Bool = false) -> NSColor {
        let clamped = min(26, max(16, degrees))
        return palette(clamped, light:false)
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
            text = text + Text(number).foregroundColor(menuBar ? Color(nsColor:TemperatureStyle.color(degrees,menuBar:true)) : .white)
                + Text(string.substring(with:match.range(at:2))).foregroundColor(.white)
            cursor = NSMaxRange(match.range)
        }
        return text + Text(string.substring(from:cursor))
    }
    var body: some View {
        styled.shadow(color: menuBar ? .black.opacity(0.65) : .clear, radius:menuBar ? 0.5 : 0)
    }
}
