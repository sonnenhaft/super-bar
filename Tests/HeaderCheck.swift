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
        buttons[2].performClick(nil)
        precondition(state.current == .bluetti)
        buttons[1].performClick(nil)
        precondition(state.current == .lg)
        buttons[0].performClick(nil)
        precondition(state.current == .tcl)
        let footer = SuperFooter(state: state, changed: {})
        let slider = footer.slider
        slider.doubleValue = 17
        _ = slider.sendAction(slider.action, to: slider.target)
        let restored = BarSelection(defaults)
        precondition(restored.current == .tcl && restored.size == 17)
        footer.swatch.color = .systemPurple
        _ = footer.swatch.sendAction(footer.swatch.action, to: footer.swatch.target)
        precondition(BarSelection(defaults).color != nil)
        print("TCL starts first; tabs are TCL, LG, BLUETTI; size and color persist.")
    }
}
