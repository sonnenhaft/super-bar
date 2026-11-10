import AppKit

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
            self.toggleMenuBarField(field)
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

    func nextStationAgeUpdate(now: Date) -> Date? {
        stationRows.compactMap { $0.details.updateAge(now: now) }.min()
    }

    @discardableResult
    func rebuildStationMenu(now: Date = Date()) -> Date? {
        guard mainMenuIsOpen else { return nil }
        let stations = stationDirectory.stations
        syncStationEntries(stations)
        let active = selectedKnownStation?.key
        let fields = visibleMenuBarFields
        let available = Dictionary(uniqueKeysWithValues: stations.map { ($0.key, $0) })
        var nextAge: Date?
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
            card.updateHeader(title: title, checked: selected, enabled: !demo && !quitting, canRename: !quitting)
            card.selectButton.toolTip = station.deviceID ?? station.bluetoothName
            card.renameButton.setAccessibilityLabel("Rename " + station.displayName)
            card.refreshButton.setAccessibilityLabel("Refresh " + station.displayName)
            card.refreshButton.update(status: selected ? refreshState.rawValue : "", loading: selected && isLoadingReading,
                                      enabled: !sleeping && !quitting)
            card.setFields(selected ? fields : [], brand: brandBadge)
            entry.details.statusItem.target = selected ? self : nil
            entry.details.statusItem.action = selected ? #selector(refreshClicked) : nil
            entry.details.statusItem.keyEquivalent = selected ? "r" : ""
            if let next = updateDetails(entry.details, for: station, active: selected, now: now) {
                nextAge = min(nextAge ?? next, next)
            }
        }
        return nextAge
    }

    func stopStationSpinners() {
        for entry in stationRows { entry.details.card.refreshButton.update(status: "", loading: false, enabled: false) }
    }

    @objc private func selectStationRow(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let station = stationDirectory.stations.first(where: { $0.key == key }) else { return }
        if selectedKnownStation?.key != key { switchStation(to: station.selector) }
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
