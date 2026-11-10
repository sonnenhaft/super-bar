import AppKit

extension BlueBarDelegate {
    func toggleMenuBarField(_ field: MenuBarField) {
        var choices = visibility
        choices.toggle(field, reading: lastGood, defaults: defaults)
        render()
    }

    @objc func togglePercent() { toggleMenuBarField(.percentage) }
    @objc func toggleTime() { toggleMenuBarField(.runtime) }
    @objc func toggleOutput() { toggleMenuBarField(.output) }
    @objc func toggleBrandIcon() { toggleMenuBarField(.brand) }

    func intervalControl() -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        row.autoresizingMask = [.width]
        refreshValue.frame = NSRect(x: 12, y: 25, width: 180, height: 15)
        refreshValue.autoresizingMask = [.width]
        refreshValue.font = .systemFont(ofSize: 11)
        refreshValue.textColor = .secondaryLabelColor
        row.addSubview(refreshValue)
        refreshSlider.frame = NSRect(x: 10, y: 1, width: 180, height: 24)
        refreshSlider.autoresizingMask = [.width]
        refreshSlider.controlSize = .small
        refreshSlider.minValue = 0
        refreshSlider.maxValue = Double(PollInterval.allCases.count - 1)
        refreshSlider.numberOfTickMarks = PollInterval.allCases.count
        refreshSlider.allowsTickMarkValuesOnly = true
        refreshSlider.isContinuous = true
        refreshSlider.target = self
        refreshSlider.action = #selector(changeRefreshInterval(_:))
        refreshSlider.toolTip = PollInterval.allCases.map { $0.label }.joined(separator: " / ")
        refreshSlider.setAccessibilityLabel("Refresh interval")
        row.addSubview(refreshSlider)
        updateRefreshControl()
        return row
    }

    private func updateRefreshControl() {
        guard let index = PollInterval.allCases.firstIndex(of: selectedInterval) else { return }
        refreshSlider.doubleValue = Double(index)
        refreshValue.stringValue = "Refresh: " + selectedInterval.label
        refreshSlider.setAccessibilityValue(selectedInterval.label)
    }

    @objc func changeRefreshInterval(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let index = Int(min(Double(PollInterval.allCases.count - 1), max(0, sender.doubleValue)).rounded())
        let seconds = PollInterval.allCases[index].rawValue
        guard seconds != Int(refreshInterval) else { updateRefreshControl(); return }
        defaults.set(seconds, forKey: "refreshIntervalSeconds")
        updateRefreshControl()
        if consecutiveReadFailures > 0 {
            nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        }
        if streaming { stopPollingSession() }
        restartAgeTimer()
        restartPollTimer()
        refresh()
    }
}
