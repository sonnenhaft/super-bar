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
        print("Station names: transfer across hosts, rename persistence, reset and ambiguous names verified.")
    }
}
