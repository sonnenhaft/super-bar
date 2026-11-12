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
        precondition(Brand.allCases == [.tcl, .lg, .bluetti, .deye, .tuya])
        state.expanded = .bluetti
        precondition(state.current == .tcl, "Expanding a card must not change pinned readings")
        state.pin(.lg)
        precondition(state.expanded == .bluetti && state.current == .lg)
        state.chartOverride = .deye
        precondition(state.chartBrand == .deye && state.expanded == .bluetti && state.current == .lg)
        precondition(state.detailsCollapsed, "Opening Deye must collapse device controls")
        precondition(state.openBrand == .deye)
        state.expanded = .bluetti
        precondition(state.chartBrand == .bluetti)
        state.detailsCollapsed = false
        var activated: [Brand] = []
        state.didExpand = { activated.append($0) }
        state.select(.bluetti, sameDevice: true)
        precondition(state.detailsCollapsed && state.current == .lg && state.chartBrand == .bluetti)
        precondition(state.openBrand == nil, "A collapsed section must also hide its chart")
        precondition(activated.isEmpty)
        state.select(.bluetti, sameDevice: true)
        precondition(!state.detailsCollapsed && state.current == .bluetti && activated == [.bluetti])
        precondition(state.openBrand == .bluetti)
        state.select(.lg, sameDevice: false)
        precondition(!state.detailsCollapsed && state.chartBrand == .lg && state.current == .lg)
        precondition(state.openBrand == .lg, "Only the newly selected section remains open")
        state.select(.lg, sameDevice: true)
        precondition(state.detailsCollapsed && state.current == .lg && activated == [.bluetti, .lg])
        state.toggleEnergy()
        precondition(state.openBrand == .deye && state.detailsCollapsed)
        state.toggleEnergy()
        precondition(state.openBrand == nil && state.current == .lg, "Closing Energy hides its charts without changing the readout")
        state.toggleEnergy()
        state.select(.tcl, sameDevice: false)
        precondition(state.openBrand == .tcl && state.chartOverride == nil)
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
        print("Expanding activates the readout; collapsing preserves it; text size and degree styling verified.")
    }
}
