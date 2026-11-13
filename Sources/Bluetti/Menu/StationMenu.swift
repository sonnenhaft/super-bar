import AppKit

extension BlueBarDelegate {
    var pinnedStationKey: String {
        get { defaults.string(forKey: "bluetti.pinnedStation") ?? selectedKnownStation?.key ?? identifier }
        set { defaults.set(newValue, forKey: "bluetti.pinnedStation") }
    }
    var pinnedReading: Reading? { pinnedDisplay.reading }
    var pinnedDisplay: (reading: Reading?, frozenAt: Date?) {
        guard defaults.string(forKey: "bluetti.pinnedStation") != nil,
              pinnedStationKey != selectedKnownStation?.key else { return (lastGood, runtimeFrozenAt) }
        guard let station = stationDirectory.stations.first(where: { $0.key == pinnedStationKey }),
              let saved = readingStore.savedSnapshot(for: station, knownStations: stationDirectory.stations),
              var reading = try? Reading.decode(saved, previous: nil, now: Date(), maximumAge: nil)
        else { return (nil, nil) }
        let frozenAt = restoreDisplayMetadata(saved["_bluebar_display"], into: &reading) ?? reading.runtimeMeasuredAt
        return (reading, frozenAt)
    }

    var selectedKnownStation: BlueBarKnownStation? {
        if !identifier.isEmpty {
            let stations = stationDirectory.stations
            if let exact = stations.first(where: {
                $0.deviceID?.caseInsensitiveCompare(identifier) == .orderedSame
            }) { return exact }
            if UUID(uuidString: identifier) != nil { return nil }
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping.lowercased()
            let matches = stations.filter { $0.seenNames.contains(name) }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let sample = lastGood else { return nil }
        return stationDirectory.station(deviceID: sample.deviceID, bluetoothName: sample.device)
    }

    var stationDisplayName: String {
        if let sample = lastGood {
            return stationDirectory.displayName(deviceID: sample.deviceID, bluetoothName: sample.device)
        }
        return selectedKnownStation?.displayName ?? (identifier.isEmpty ? "Automatic" : identifier)
    }

    func switchStation(to value: String) {
        guard !demo, !quitting, value != identifier else { return }
        if defaults.string(forKey: "bluetti.pinnedStation") == nil { pinnedStationKey = selectedKnownStation?.key ?? identifier }
        cancelStationRename()
        // Save the previous station before changing the selector. Its values
        // never remain on-screen while the next station is connecting.
        freezeRuntime()
        saveReadingState()
        defaults.set(value, forKey: "stationIdentifier")
        generation += 1
        resetReadRetryBudget()
        awaitingFirstRead = true
        refreshState = .connecting
        restoreSelectedReading()
        loadHistory.clear()
        pendingRefresh = true
        lastError = "Waiting for a reading from the selected station."
        hasConnectionFailure = false
        writeFailure(lastError!)
        render()
        if let running = job { running.cancel() }
        else { runQueuedWork() }
    }
}

struct StationMenuEntry {
    let key: String
    let details = StationDetails()
    let divider = NSMenuItem.separator()

    var items: [NSMenuItem] { [divider] + details.items }
}

extension BlueBarDelegate {
    var hasStationRows: Bool { !stationRows.isEmpty }

    func addStationControl() {
        syncStationEntries(stationDirectory.stations)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { mainMenuWillOpen() }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { mainMenuDidClose() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { syncStationEntries(stationDirectory.stations) }
    }

    private func syncStationEntries(_ stations: [BlueBarKnownStation]) {
        guard stationRows.map(\.key) != stations.map(\.key) else { return }
        // Reordering stations must not interrupt an in-progress inline rename.
        if !aliasField.isHidden { return }
        let existing = Dictionary(uniqueKeysWithValues: stationRows.map { ($0.key, $0) })
        for entry in stationRows {
            for item in entry.items where item.menu === menu { menu.removeItem(item) }
        }
        stationRows = stations.map { existing[$0.key] ?? makeStationEntry(key: $0.key) }
        let anchor = menu.index(of: emptyRefreshItem)
        guard anchor >= 0 else { return }
        var position = anchor + 1
        for (index, entry) in stationRows.enumerated() {
            for item in entry.items where index > 0 || item !== entry.divider {
                menu.insertItem(item, at: position)
                position += 1
            }
        }
        if mainMenuIsOpen { panelChanged?() }
    }

    private func makeStationEntry(key: String) -> StationMenuEntry {
        let entry = StationMenuEntry(key: key)
        let card = entry.details.card
        card.onToggle = { [weak self] field in
            guard let self, let station = self.stationDirectory.stations.first(where: { $0.key == key }) else { return }
            let alreadyPinned = BarSelection.shared.current == .bluetti && self.pinnedStationKey == key
            self.pinnedStationKey = key
            BarSelection.shared.pin(.bluetti)
            if self.selectedKnownStation?.key != key {
                self.switchStation(to: station.selector)
                guard self.selectedKnownStation?.key == key else { return }
                if self.visibleMenuBarFields.contains(field) {
                    var choices = self.visibility
                    choices.remember(field, defaults: self.defaults)
                    self.render()
                    return
                }
            }
            if !alreadyPinned && self.visibleMenuBarFields.contains(field) { self.render() }
            else { self.toggleMenuBarField(field) }
        }
        let actions: [(NSButton, Selector)] = [
            (card.selectButton, #selector(selectStationRow(_:))),
            (card.renameButton, #selector(renameStationRow(_:))),
            (card.refreshButton, #selector(refreshStationRow(_:))),
            (entry.details.statusButton, #selector(refreshStationRow(_:)))
        ]
        for (button, action) in actions {
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.target = self
            button.action = action
        }
        return entry
    }

    func rebuildStationMenu(now: Date = Date()) {
        guard mainMenuIsOpen else { return }
        let stations = stationDirectory.stations
        syncStationEntries(stations)
        let active = selectedKnownStation?.key
        let fields = StatusVisibility(defaults: defaults, reading: pinnedReading, station: pinnedStationKey).visibleFields(for: pinnedReading)
        let available = Dictionary(uniqueKeysWithValues: stations.map { ($0.key, $0) })
        for entry in stationRows {
            guard let station = available[entry.key] else { continue }
            let selected = station.key == active
            let current = lastGood.flatMap { $0.matchesStation(id: station.deviceID, name: station.bluetoothName) ? $0 : nil }
            let connected = selected && !demo && !sleeping && !awaitingFirstRead && !hasConnectionFailure
                && (refreshState == .refreshed || refreshState == .connected)
                && current.map { now.timeIntervalSince($0.measuredAt) < maximumAge } == true
            let watts = current?.outputWatts ?? readingStore.lastOutputWatts(for: station, knownStations: stations)
            let title = StationRowTitle(name: station.displayName, watts: watts, connectedPercent: connected ? current?.percent : nil)
            let card = entry.details.card
            card.expanded = selected && BarSelection.shared.expanded == .bluetti && !BarSelection.shared.detailsCollapsed
            card.updateHeader(title: title, checked: card.expanded, enabled: !demo && !quitting, canRename: !quitting)
            card.selectButton.toolTip = station.deviceID ?? station.bluetoothName
            card.renameButton.setAccessibilityLabel("Rename " + station.displayName)
            card.refreshButton.setAccessibilityLabel("Refresh " + station.displayName)
            card.refreshButton.update(status: selected ? refreshState.rawValue : "", loading: selected && isLoadingReading,
                                      enabled: !sleeping && !quitting)
            card.setFields(BarSelection.shared.current == .bluetti && pinnedStationKey == entry.key ? fields : [], brand: brandBadge)
            updateDetails(entry.details, for: station, active: selected, now: now)
        }
    }

    func stopStationSpinners() {
        for entry in stationRows { entry.details.card.refreshButton.update(status: "", loading: false, enabled: false) }
    }

    @objc private func selectStationRow(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let station = stationDirectory.stations.first(where: { $0.key == key }) else { return }
        let sameDevice = selectedKnownStation?.key == key
        if selectedKnownStation?.key != key { switchStation(to: station.selector) }
        else { render() }
        BarSelection.shared.select(.bluetti, sameDevice: sameDevice)
    }

    @objc private func refreshStationRow(_ sender: NSButton) {
        guard !sleeping, !quitting, let key = sender.identifier?.rawValue,
              let station = stationDirectory.stations.first(where: { $0.key == key }) else { return }
        if selectedKnownStation?.key == key { refreshClicked() }
        else { switchStation(to: station.selector) }
    }

    @objc private func renameStationRow(_ sender: NSButton) {
        guard !quitting, let key = sender.identifier?.rawValue,
              let entry = stationRows.first(where: { $0.key == key }),
              let station = stationDirectory.stations.first(where: { $0.key == key }) else { return }
        cancelStationRename()
        let card = entry.details.card
        card.editName(with: aliasField)
        aliasField.begin(alias: station.alias ?? "", placeholder: station.bluetoothName) { [weak self, weak card] alias in
            card?.endEditingName()
            guard let self else { return }
            if let alias, !self.quitting {
                self.stationDirectory.setAlias(alias, deviceID: station.deviceID, bluetoothName: station.bluetoothName, model: station.model)
            }
            self.render()
        }
    }

    func cancelStationRename() { aliasField.cancel() }
}

final class StationDetails {
    let card = BatteryCard(frame: NSRect(x: 0, y: 0, width: 264, height: 86))
    private let cardItem = NSMenuItem()
    let statusButton = RefreshRowButton(frame: NSRect(x: 0, y: 0, width: 264, height: 20), style: .textOnly)

    private var measuredAt: Date?
    private var loading = false

    var items: [NSMenuItem] { [cardItem] }

    init() {
        card.autoresizingMask = [.width]
        cardItem.view = card
        statusButton.autoresizingMask = [.width]
        card.addSubview(statusButton)
    }

    func update(reading: Reading?, asOf: Date, power: MenuPowerRow, status: String,
                loading: Bool, enabled: Bool, shortDate: (Date) -> String) {
        let chargeTime = reading?.compactChargeTime(at: asOf) ?? ""
        let batteryTime = reading?.outputWatts == 0 ? "" : reading?.compactRuntime(at: asOf) ?? ""
        measuredAt = reading?.measuredAt
        self.loading = loading
        card.update(readingPercent: reading?.percent, power: power, chargeTime: chargeTime, batteryTime: batteryTime)
        statusButton.update(status: loading ? "Refreshing…" : reading.map { ReadingAge.label($0.measuredAt) } ?? status, loading: loading, enabled: enabled)
        statusButton.toolTip = reading.map { shortDate($0.measuredAt) }
    }

    func updateAge(now: Date) {
        if !loading, let measuredAt {
            statusButton.update(status:ReadingAge.label(measuredAt,now:now),loading:false,enabled:statusButton.isEnabled)
        }
    }

}

extension BlueBarDelegate {
    /// The selected station alone owns the Bluetooth connection. Cached readings
    /// keep their original age and frozen runtime when another station is selected.
    func updateDetails(_ details: StationDetails, for station: BlueBarKnownStation, active: Bool, now: Date) {
        var reading = active ? lastGood : nil
        var frozenAt = active ? runtimeFrozenAt : nil
        if let sample = reading, !sample.matchesStation(id: station.deviceID, name: station.bluetoothName),
           stationDirectory.station(deviceID: sample.deviceID, bluetoothName: sample.device)?.key != station.key {
            reading = nil
        }
        if reading == nil,
           let saved = readingStore.savedSnapshot(for: station, knownStations: stationDirectory.stations),
           var retained = try? Reading.decode(saved, previous: nil, now: now, maximumAge: nil) {
            frozenAt = restoreDisplayMetadata(saved["_bluebar_display"], into: &retained) ?? retained.runtimeMeasuredAt
            reading = retained
        }
        let asOf = frozenAt ?? reading.map { min(now, $0.measuredAt.addingTimeInterval(maximumAge)) } ?? now
        let power = MenuPresentation.power(for: reading, shortDate: shortDate)
        let loading = active && isLoadingReading
        var status = "Not connected"
        if active {
            let stale = reading.map { now.timeIntervalSince($0.measuredAt) >= maximumAge } ?? true
            if loading || refreshState == .connectFailed || refreshState == .readFailed {
                status = refreshState.rawValue
            } else if !sleeping && !hasConnectionFailure && !awaitingFirstRead && !stale {
                status = refreshState == .idle ? "Refresh" : refreshState.rawValue
            }
        }
        details.update(reading: reading, asOf: asOf, power: power, status: status,
                       loading: loading, enabled: !sleeping && !quitting, shortDate: shortDate)
        details.updateAge(now: now)
    }
}

final class BlueBarAliasEditor: NSTextField, NSTextFieldDelegate {
    private var completion: ((String?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        font = .systemFont(ofSize: 12)
        isHidden = true
        setAccessibilityLabel("Station name")
    }

    required init?(coder: NSCoder) { nil }

    func begin(alias: String, placeholder: String, completion: @escaping (String?) -> Void) {
        stringValue = alias
        placeholderString = placeholder
        self.completion = completion
        isHidden = false
        guard window?.makeFirstResponder(self) == true else { cancel(); return }
        // selectText(_:) ends the existing field editor session before starting another.
        // Keep this session active so its end-editing callback cannot cancel the rename.
        currentEditor()?.selectAll(nil)
    }

    func cancel() { finish(nil) }

    private func finish(_ alias: String?) {
        guard let callback = completion else { return }
        completion = nil
        abortEditing()
        isHidden = true
        callback(alias)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            finish(textView.string)
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { cancel() }
}
