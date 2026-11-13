import AppKit

extension BlueBarDelegate {
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
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let styledTitle = NSAttributedString(string: title, attributes: attributes)
        if !readout.attributedTitle.isEqual(to: styledTitle) {
            readout.attributedTitle = styledTitle
            displayChanged = true
        }
        let showInitialLoading = pinnedIsActive && awaitingFirstRead && isLoadingReading
        let displayImage = statusIcons.image(
            battery: fields.contains(.battery) ? reading?.percent : nil,
            fontSize: statusFontSize, appearance: readout.effectiveAppearance)
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
        rebuildStationMenu(now: now)
        emptyRefreshItem.isHidden = hasStationRows
        let status = refreshState == .idle ? "Not connected" : refreshState.rawValue
        refreshRow.update(status: status, loading: !hasStationRows && isLoadingReading, enabled: !sleeping && !quitting)
        loadGraphItem.isHidden = lastGood == nil
        graphBottomSeparator.isHidden = loadGraphItem.isHidden
        if lastGood != nil { loadGraph.update(points: loadHistory.visiblePoints(at: now), now: now) }
    }
}

/// Reuse the battery image while readings stay within the same battery level.
final class StatusItemIcons {
    private struct Style: Equatable {
        let battery: String?
        let fontSize: CGFloat
        let appearance: NSAppearance.Name
    }

    private var lastStyle: Style?
    private var lastImage: NSImage?

    func image(battery: Int?, fontSize: CGFloat, appearance: NSAppearance) -> NSImage? {
        let style = Style(battery: battery.map(MenuPresentation.batterySymbol),
                          fontSize: fontSize, appearance: appearance.name)
        if style != lastStyle {
            appearance.performAsCurrentDrawingAppearance { lastImage = compose(style) }
            lastStyle = style
        }
        return lastImage
    }

    private func compose(_ style: Style) -> NSImage? {
        guard let battery = style.battery,
              let symbol = NSImage(systemSymbolName: battery, accessibilityDescription: nil),
              symbol.size.width > 0 else { return nil }
        let width = 18 * (style.fontSize / 11)
        let height = width * symbol.size.height / symbol.size.width
        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)))
        image.lockFocus()
        let rect = NSRect(x: 0, y: (image.size.height - height) / 2, width: width, height: height)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill()
        rect.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
