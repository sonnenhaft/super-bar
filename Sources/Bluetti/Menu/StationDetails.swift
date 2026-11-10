import AppKit

final class StationDetails {
    let card = BatteryCard(frame: NSRect(x: 0, y: 0, width: 264, height: 86))
    private let cardItem = NSMenuItem()
    let statusItem = NSMenuItem()
    let statusButton = RefreshRowButton(frame: NSRect(x: 0, y: 0, width: 264, height: 20), style: .textOnly)
    private let ageLabel = NSTextField(labelWithString: "")
    private var measuredAt: Date?

    var items: [NSMenuItem] { [cardItem, statusItem] }

    init() {
        card.autoresizingMask = [.width]
        cardItem.view = card
        statusButton.autoresizingMask = [.width]
        ageLabel.font = .systemFont(ofSize: 10)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.alignment = .right
        ageLabel.frame = NSRect(x: 136, y: 3, width: 116, height: 14)
        ageLabel.autoresizingMask = [.minXMargin]
        statusButton.addSubview(ageLabel)
        statusItem.view = statusButton
    }

    func update(reading: Reading?, asOf: Date, power: MenuPowerRow, status: String,
                loading: Bool, enabled: Bool, shortDate: (Date) -> String) {
        let chargeTime = reading?.compactChargeTime(at: asOf) ?? ""
        let batteryTime = reading?.outputWatts == 0 ? "" : reading?.compactRuntime(at: asOf) ?? ""
        card.update(readingPercent: reading?.percent, power: power, chargeTime: chargeTime, batteryTime: batteryTime)
        statusButton.update(status: status, loading: loading, enabled: enabled)
        measuredAt = reading?.measuredAt
        ageLabel.toolTip = measuredAt.map(shortDate)
        ageLabel.isHidden = measuredAt == nil
    }

    func updateAge(now: Date) -> Date? {
        guard let measuredAt else { return nil }
        let age = MenuPresentation.lastRead(measuredAt, now: now)
        if ageLabel.stringValue != age.title { ageLabel.stringValue = age.title }
        return age.nextUpdate
    }
}

extension BlueBarDelegate {
    /// The selected station alone owns the Bluetooth connection. Cached readings
    /// keep their original age and frozen runtime when another station is selected.
    @discardableResult
    func updateDetails(_ details: StationDetails, for station: BlueBarKnownStation, active: Bool, now: Date) -> Date? {
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
        return details.updateAge(now: now)
    }
}
