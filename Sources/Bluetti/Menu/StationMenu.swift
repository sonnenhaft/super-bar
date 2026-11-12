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
