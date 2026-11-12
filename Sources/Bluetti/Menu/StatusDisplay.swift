import AppKit

extension BlueBarDelegate {
    private func scheduleMenuAgeUpdate(at date: Date?) {
        lastReadTimer?.invalidate()
        lastReadTimer = nil
        guard mainMenuIsOpen, let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.mainMenuIsOpen else { return }
            self.scheduleMenuAgeUpdate(at: self.nextStationAgeUpdate(now: Date()))
        }
        lastReadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func render() {
        var displayChanged = false
        defer { if displayChanged { didRender?() } }
        let pinned = pinnedDisplay
        let reading = pinned.reading
        let pinnedIsActive = defaults.string(forKey: "bluetti.pinnedStation") == nil || pinnedStationKey == selectedKnownStation?.key
        let now = Date()
        let stale = reading.map { now.timeIntervalSince($0.measuredAt) >= maximumAge } ?? false
        let offline = !pinnedIsActive || sleeping || hasConnectionFailure || stale
        if pinnedIsActive && (offline || reading?.runtimeCarriedForward == true) { freezeRuntime() }
        let displayTime = pinnedIsActive ? (runtimeFrozenAt ?? now) : (pinned.frozenAt ?? reading?.measuredAt ?? now)
        let visibility = StatusVisibility(defaults: defaults, reading: reading, station: pinnedStationKey)
        let fields = visibility.visibleFields(for: reading)
        let title = reading.map { StatusVisibility.title(for: $0, fields: fields, at: displayTime) } ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: statusFontSize, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        if let custom = customStatusTextColor { attributes[.foregroundColor] = custom }
        let styledTitle = NSAttributedString(string: title, attributes: attributes)
        if !readout.attributedTitle.isEqual(to: styledTitle) {
            readout.attributedTitle = styledTitle
            displayChanged = true
        }
        let showInitialLoading = pinnedIsActive && awaitingFirstRead && isLoadingReading
        let image = statusIcons.image(
            battery: fields.contains(.battery) ? reading?.percent : nil,
            brand: nil,
            hasReading: reading != nil, loading: showInitialLoading, offline: offline,
            fontSize: statusFontSize, customColor: customStatusTextColor,
            appearance: readout.effectiveAppearance)
        let displayImage = image
        if readout.image !== displayImage {
            readout.image = displayImage
            displayChanged = true
        }
        let position: NSControl.ImagePosition = displayImage == nil ? .noImage : .imageLeft
        if readout.imagePosition != position { readout.imagePosition = position; displayChanged = true }
        if readout.imageScaling != .scaleNone { readout.imageScaling = .scaleNone; displayChanged = true }
        readout.setAccessibilityLabel((demo ? "DEMO, " : "") + "BLUETTI, " + title
            + (showInitialLoading ? ", reading station" : (offline ? ", offline" : "")))
        let detail = lastError ?? (stale ? "Waiting for a fresh Bluetooth reading." : "")
        let lastRead = reading.map { shortDate($0.measuredAt) }
        let pinnedName = stationDirectory.stations.first { $0.key == pinnedStationKey }?.displayName ?? stationDisplayName
        readout.toolTip = (demo ? "DEMO\n" : "") + pinnedName
            + (lastRead.map { "\n" + $0 } ?? "")
            + (detail.isEmpty ? "" : "\n" + detail)
        guard mainMenuIsOpen else { return }
        defer { panelChanged?() }
        let nextAgeUpdate = rebuildStationMenu(now: now)
        scheduleMenuAgeUpdate(at: nextAgeUpdate)
        emptyRefreshItem.isHidden = hasStationRows
        let status = refreshState == .idle ? "Not connected" : refreshState.rawValue
        refreshRow.update(status: status, loading: !hasStationRows && isLoadingReading, enabled: !sleeping && !quitting)
        loadGraphItem.isHidden = lastGood == nil
        graphBottomSeparator.isHidden = loadGraphItem.isHidden
        if lastGood != nil { loadGraph.update(points: loadHistory.visiblePoints(at: now), now: now) }
    }
}
