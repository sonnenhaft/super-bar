import Foundation

@main struct WidgetSnapshotCheck {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metric = WidgetMetric(id: "battery", name: "AC50P", value: "64%", detail: "120 W",
                                  symbol: "battery.100percent", updatedAt: now)
        precondition(!metric.isStale(at: now.addingTimeInterval(299)))
        precondition(metric.isStale(at: now.addingTimeInterval(301)), "Old widget readings must be marked saved even without a new network response")
        precondition(metric.isStale(at: now.addingTimeInterval(-61)), "A clock change must not make future timestamps look live")
        var unknown = metric
        unknown.updatedAt = nil
        precondition(unknown.isStale(at: now), "Missing measurement times cannot be labeled live")
        let encoded = try JSONEncoder().encode(WidgetSnapshot(energy: [], climate: [unknown], batteries: [metric]))
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
        precondition(restored.energy.isEmpty)
        precondition(restored.climate.first?.updatedAt == nil)
        precondition(restored.batteries.first?.value == "64%")
        precondition(restored.batteries.first?.updatedAt == now)

        // Existing installed widgets can still read snapshots written before controls.
        let oldJSON = Data(#"{"energy":[],"climate":[{"id":"old","name":"Old unit","value":"24°","detail":"Off","symbol":"air.conditioner.horizontal"}],"batteries":[]}"#.utf8)
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: oldJSON)
        precondition(old.climate.first?.control == nil)

        var control = WidgetClimateControl(target: 23, temperatures: [26, 22, 24, 22],
            powerOn: false, canSetPower: true, checkedAt: now)
        precondition(control.enabled(at: now), "Known off state can still offer controls")
        precondition(control.enabled(at: now.addingTimeInterval(300)))
        precondition(!control.enabled(at: now.addingTimeInterval(301)))
        precondition(control.enabled(at: now.addingTimeInterval(-60)))
        precondition(!control.enabled(at: now.addingTimeInterval(-61)))
        precondition(control.adjacent(delta: -1) == 22 && control.adjacent(delta: 1) == 24,
                     "Stepping uses the nearest supported value, including noncontiguous ranges")
        precondition(control.adjacent(delta: 0) == nil)
        precondition(control.validTemperature(24) && !control.validTemperature(23))
        control.target = 22
        precondition(control.adjacent(delta: -1) == nil && control.adjacent(delta: 1) == 24)
        control.target = 26
        precondition(control.adjacent(delta: 1) == nil)
        control.target = nil
        precondition(control.adjacent(delta: 1) == nil)
        control.target = .nan
        precondition(control.adjacent(delta: -1) == nil)
        control.target = 24
        control.powerOn = nil
        precondition(!control.enabled(at: now))
        control.powerOn = true

        // Brand and device ID identify a unit together; device IDs can collide.
        var tcl = metric
        tcl.id = "shared-id"; tcl.brand = "TCL"; tcl.control = control
        var lg = tcl
        lg.brand = "LG"
        let snapshot = WidgetSnapshot(climate: [unknown, tcl, lg])
        precondition(WidgetClimateSelection().selected(in: snapshot)?.brand == "TCL")
        let selection = WidgetClimateSelection(brand: "LG", deviceID: "shared-id", pickingTemperature: true, message: "Confirmed")
        precondition(selection.selected(in: snapshot)?.brand == "LG")
        precondition(WidgetClimateSelection(brand: "LG", deviceID: "missing").selected(in: snapshot)?.brand == "TCL")
        precondition(selection.selected(in: .empty) == nil)
        precondition(WidgetClimateSelection().selected(in: WidgetSnapshot(climate: [unknown])) == nil)
        let controlledRoundTrip = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(controlledRoundTrip.climate.last?.control?.target == 24)
        precondition(controlledRoundTrip.climate.last?.control?.temperatures == [26, 22, 24, 22])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superbar-widget-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("selection.json")
        precondition(WidgetClimateSelection.read(from: file) == WidgetClimateSelection())
        try WidgetClimateSelection.write(selection, to: file)
        precondition(WidgetClimateSelection.read(from: file) == selection)
        // Replacing the independent snapshot cannot alter UI selection.
        try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent("widget-readings.json"))
        precondition(WidgetClimateSelection.read(from: file).pickingTemperature)
        try Data("invalid".utf8).write(to: file)
        precondition(WidgetClimateSelection.read(from: file) == WidgetClimateSelection())
        print("Widget snapshots: legacy decode, freshness, supported setpoints, stepping and independent selection persistence verified.")
    }
}
