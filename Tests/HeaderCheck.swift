import AppKit
@main struct HeaderCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let domain = "SuperBar.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(Brand.bluetti.rawValue, forKey: "super.current")
        let state = BarSelection(defaults)
        precondition(state.current == .tcl, "Startup must use TCL even after BLUETTI was saved")
        precondition(Brand.allCases == [.tcl, .lg, .bluetti])
        let header = SuperHeader(state: state, choose: { state.current = $0 })
        let buttons = header.subviews.compactMap { $0 as? NSButton }
        precondition(buttons.count == 3)
        for width: CGFloat in [300, 390, 401] {
            header.setFrameSize(NSSize(width: width, height: SuperHeader.height))
            header.layout()
            precondition(buttons.first!.frame.minX == 8 && abs(buttons.last!.frame.maxX - (width - 8)) < 0.001)
            for button in buttons {
                precondition(abs(button.frame.width - (width - 32) / 3) < 0.001)
                precondition(header.bounds.maxY - button.frame.maxY == 8)
            }
        }
        buttons[2].performClick(nil)
        precondition(state.current == .bluetti)
        buttons[1].performClick(nil)
        precondition(state.current == .lg)
        buttons[0].performClick(nil)
        precondition(state.current == .tcl)
        let read = Date(timeIntervalSince1970:1000)
        ReadingAge.panelOpened()
        precondition(ReadingAge.label(read,now:read) == "Last read Just now")
        ReadingAge.panelOpened()
        precondition(ReadingAge.label(read,now:read.addingTimeInterval(120)) == "Last read 2m ago")
        precondition(ReadingAge.label(read,now:read.addingTimeInterval(240)) == "Last read 2m ago")
        ReadingAge.panelOpened()
        precondition(ReadingAge.label(read,now:read.addingTimeInterval(240)) == "Last read 4m ago")
        let footer = SuperFooter(state: state, changed: {})
        footer.slider.doubleValue = 17
        _ = footer.slider.sendAction(footer.slider.action,to:footer.slider.target)
        precondition(!footer.subviews.contains { $0 is NSSwitch })
        let restored = BarSelection(defaults)
        precondition(restored.current == .tcl && restored.size == 17)
        precondition(!footer.subviews.contains { $0 is NSColorWell })
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        for step in 0...100 {
            let foreground = luminance(TemperatureStyle.color(16 + Double(step) / 10))
            let background = luminance(BarTheme.ocean)
            precondition((foreground + 0.05) / (background + 0.05) >= 4.5, "Card contrast below 4.5:1")
        }
        let temperature = TemperatureStyle.attributed(NSAttributedString(string:"21 °C"))
        precondition(temperature.attribute(.foregroundColor,at:3,effectiveRange:nil) as? NSColor == .white)
        print("TCL starts first; tabs and text size work; color picker removed; degree sign stays white.")
    }
}
