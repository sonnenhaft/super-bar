import Foundation

@main enum StationNamesCheck {
    static func main() {
        let suite = "station-names-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = BlueBarStationDirectory(defaults: defaults)
        directory.importAliases(["AC50P123456": "Office"])
        precondition(directory.stations.count == 1 && directory.stations[0].deviceID == nil)
        directory.observe(deviceID: "phone-id", bluetoothName: "AC50P123456")
        precondition(directory.stations.count == 1)
        precondition(directory.displayName(deviceID: "phone-id", bluetoothName: "AC50P123456") == "Office")
        directory.setAlias("  Bedroom\n ", deviceID: "phone-id", bluetoothName: "AC50P123456")
        let reloaded = BlueBarStationDirectory(defaults: defaults)
        precondition(reloaded.displayName(deviceID: "phone-id", bluetoothName: "AC50P123456") == "Bedroom")
        reloaded.observe(deviceID: "other-id", bluetoothName: "AC50P123456")
        reloaded.importAliases(["AC50P123456": "Wrong"])
        precondition(reloaded.displayName(deviceID: "phone-id", bluetoothName: "AC50P123456") == "Bedroom")
        precondition(reloaded.station(deviceID: "other-id", bluetoothName: "AC50P123456")?.alias == nil)
        reloaded.setAlias("", deviceID: "phone-id", bluetoothName: "AC50P123456")
        precondition(reloaded.station(deviceID: "phone-id", bluetoothName: "AC50P123456")?.alias == nil)
        // Existing phone readings are already bound to a UUID before import.
        reloaded.observe(deviceID: "known-phone-id", bluetoothName: "AC50P999999")
        reloaded.importAliases(["AC50P999999": "Living room", "": "Invalid"])
        precondition(reloaded.displayName(deviceID: "known-phone-id", bluetoothName: "AC50P999999") == "Living room")
        precondition(reloaded.stations.count == 3)
        let first = "00000000-0000-0000-0000-00000000000a"
        let second = "00000000-0000-0000-0000-00000000000b"
        let third = "00000000-0000-0000-0000-00000000000c"
        var retry = BluettiDiscoveryRetry()
        let known = [first.uppercased(), first, second, third, "not-a-peripheral-id"]
        precondition(retry.candidates(knownIDs: known, found: [], now: 100) == [first, second],
                     "Known stations missing advertisements get at most two direct attempts, with canonical unique IDs")
        precondition(retry.candidates(knownIDs: known, found: [], now: 115) == [third],
                     "Unavailable stations must not delay every polling pass or starve another saved station")
        precondition(retry.candidates(knownIDs: known, found: [], now: 159).isEmpty)
        precondition(retry.candidates(knownIDs: known, found: [first], now: 160) == [second],
                     "Keep the open/advertised link; only retry missing stations after the interval")
        precondition(retry.candidates(knownIDs: known, found: [], now: 10) == [first, third],
                     "A restarted uptime cannot suppress retries forever")
        print("Station names: transfer across hosts, rename persistence, reset and ambiguous names verified.")
    }
}
