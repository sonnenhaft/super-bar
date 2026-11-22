import AppKit
@main struct HeaderCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let domain = "SuperBar.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let refresh = RefreshPreferences()
        refresh.set(.deye, seconds: 60, preferences: defaults)
        refresh.set(.tuya, seconds: 15, preferences: defaults)
        refresh.set(.tcl, seconds: 300, preferences: defaults)
        precondition(RefreshPreferences.seconds(.deye, preferences: defaults) == 60)
        precondition(RefreshPreferences.seconds(.tuya, preferences: defaults) == 15)
        precondition(RefreshPreferences.seconds(.tcl, preferences: defaults) == 300)
        var polling = AutomaticPollSchedule()
        precondition(polling.due(.deye, at: 100, preferences: defaults))
        precondition(polling.due(.tuya, at: 100, preferences: defaults))
        precondition(!polling.due(.deye, at: 115, preferences: defaults) && polling.due(.tuya, at: 115, preferences: defaults),
                     "One brand's slider must not control another brand's reader")
        refresh.set(.deye, seconds: 15, preferences: defaults)
        precondition(polling.due(.deye, at: 116, preferences: defaults), "A shorter interval takes effect in the existing loop")
        refresh.set(.deye, seconds: 1, preferences: defaults)
        precondition(RefreshPreferences.seconds(.deye, preferences: defaults) == 15,
                     "Unsupported polling intervals must not increase provider requests")
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
        for brand in [Brand.tcl, .lg] {
            state.showEnergy()
            state.activate(brand)
            precondition(state.current == brand && state.openBrand == brand && state.chartOverride == nil)
            state.pin(.bluetti)
            let count = activated.count
            state.activate(brand)
            precondition(state.current == brand && state.openBrand == brand && activated.count == count + 1,
                         "Clicking an already open device must restore its readout and keep its controls and chart open")
            state.select(brand, sameDevice: true)
            precondition(state.openBrand == nil && state.current == brand, "Section headers can still collapse charts")
        }
        state.showEnergy()
        state.openSettings()
        precondition(state.showSettings && state.openBrand == nil && state.chartOverride == nil)
        state.openTelevision()
        precondition(state.showTelevision && !state.showSettings && state.openBrand == nil)
        state.toggleEnergy()
        precondition(!state.showTelevision && !state.showSettings && state.openBrand == .deye)
        state.openSettings()
        state.select(.bluetti, sameDevice: true)
        precondition(!state.showSettings && state.openBrand == .bluetti)
        state.openSettings()
        state.activate(.lg)
        precondition(!state.showSettings && state.openBrand == .lg)
        state.openSettings()
        state.collapseSections()
        precondition(!state.showSettings && state.openBrand == nil && state.current == .lg)
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
