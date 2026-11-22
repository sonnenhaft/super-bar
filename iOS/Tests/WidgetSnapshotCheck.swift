import Foundation

@main struct WidgetSnapshotCheck {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reported = AC50PAutonomy.runtimeLabel(percent: 64, reported: 5400, externalInput: false, acWatts: 120, dcWatts: 0)
        precondition(reported == "≈ 1h 30m left")
        let backup = AC50PAutonomy.runtimeLabel(percent: 64, reported: nil, externalInput: true, acWatts: 120, dcWatts: 0)
        precondition(backup == "Backup ≈ 1h 53m")
        precondition(AC50PAutonomy.runtimeLabel(percent: 64, reported: nil, externalInput: false, acWatts: 120, dcWatts: 0) == "≈ 1h 53m left")
        precondition(AC50PAutonomy.runtimeLabel(percent: 64, reported: nil, externalInput: false, acWatts: 0, dcWatts: 0) == "No output load")
        let metric = WidgetMetric(id: "battery", name: "AC50P", value: "64%", detail: "120 W",
                                  symbol: "battery.100percent", updatedAt: now, batteryRuntime: reported)
        precondition(!metric.isStale(at: now.addingTimeInterval(299)))
        precondition(metric.isStale(at: now.addingTimeInterval(301)), "Old widget readings must be marked saved even without a new network response")
        precondition(metric.isStale(at: now.addingTimeInterval(-61)), "A clock change must not make future timestamps look live")
        var unknown = metric
        unknown.batteryRuntime = "Runtime unavailable"
        precondition(unknown.displayedRuntime == nil && metric.displayedRuntime == reported)
        unknown.updatedAt = nil
        precondition(unknown.isStale(at: now), "Missing measurement times cannot be labeled live")
        let encoded = try JSONEncoder().encode(WidgetSnapshot(energy: [], climate: [unknown], batteries: [metric]))
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
        precondition(restored.energy.isEmpty)
        precondition(restored.climate.first?.updatedAt == nil)
        precondition(restored.batteries.first?.value == "64%")
        precondition(restored.batteries.first?.batteryRuntime == reported)
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
        // A formerly selected unit can disconnect while its old controls remain cached.
        var offline = lg
        offline.online = false
        tcl.online = true
        tcl.control?.powerOn = false
        let afterDisconnect = WidgetSnapshot(climate: [offline, tcl])
        precondition(afterDisconnect.visibleClimate.map(\.brand) == ["TCL"] && offline.isSaved(at: now),
                     "A reachable, powered-off AC stays visible; a disconnected AC's saved reading requires Show offline")
        var previousRoom = tcl
        previousRoom.value = "26.5°"; previousRoom.detail = "Set 24°"
        var settingsOnly = previousRoom
        settingsOnly.value = "—"; settingsOnly.detail = "Set 23°"; settingsOnly.updatedAt = now.addingTimeInterval(30)
        let fallback = settingsOnly.retainingReading(from: previousRoom)
        precondition(fallback.value == "26.5°" && fallback.updatedAt == now && fallback.isSaved(at: now))
        precondition(fallback.detail == "Set 23°", "Keep a newly reported setpoint even if the sensor reading is absent")
        precondition(settingsOnly.retainingReading(from: lg).value == "—", "Never borrow another provider's room reading")
        var roomOnly = previousRoom
        roomOnly.detail = "Set —"; roomOnly.value = "27°"
        let separate = roomOnly.retainingReading(from: previousRoom)
        precondition(separate.setting == "Set 24°" && separate.isSettingSaved(at: now) && !separate.isSaved(at: now),
                     "A missing target must not mark a current room temperature as old")
        let price = WidgetMetric(id: "cost-hour", name: "Net / hour", value: "-₱15.6/h", detail: "", symbol: "pesosign", updatedAt: now)
        var noMeter = price
        noMeter.value = "—"; noMeter.updatedAt = now.addingTimeInterval(30)
        let savedPrice = noMeter.retainingReading(from: price)
        precondition(savedPrice.value == price.value && savedPrice.updatedAt == now && savedPrice.isSaved(at: now))
        var connectedBattery = metric
        connectedBattery.id = "connected"; connectedBattery.online = true
        connectedBattery.value = "0%"
        var savedBattery = metric
        savedBattery.online = false
        var devices = WidgetSnapshot(climate: [offline, tcl], batteries: [savedBattery, connectedBattery],
                                     showOfflineDevices: false, bluetoothCheckedAt: now)
        var neverRead = savedBattery
        neverRead.id = "discovered"; neverRead.value = "—"; neverRead.updatedAt = nil; neverRead.online = true
        devices.batteries.append(neverRead)
        for invalid in ["", "—", "—%", "0 W", "101%", "-1%"] {
            var legacy = neverRead
            legacy.value = invalid
            precondition(!legacy.hasBatteryReading)
        }
        precondition(devices.forWidget(at: now).visibleBatteries.map(\.id) == ["connected"] && connectedBattery.hasBatteryReading,
                     "Keep measured zero charge and hide offline or never-read stations")
        devices.batteries[0].online = true
        precondition(devices.forWidget(at: now).visibleBatteries.map(\.id) == ["battery", "connected"],
                     "A recovered station returns in its directory position")
        devices.batteries[0].online = false
        precondition(devices.forWidget(at: now.addingTimeInterval(300)).visibleBatteries.isEmpty)
        var renewedSnapshot = devices
        renewedSnapshot.bluetoothCheckedAt = now.addingTimeInterval(301)
        precondition(renewedSnapshot.forWidget(at: now.addingTimeInterval(301)).visibleBatteries.isEmpty,
                     "An unrelated app refresh cannot renew an old individual battery measurement")
        devices.showOfflineDevices = true
        let shown = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(devices))
        precondition(shown.visibleClimate.count == 2 && shown.visibleBatteries.map(\.id) == ["battery", "connected", "discovered"],
                     "Showing offline devices must survive the trip from app to extension")
        let expired = shown.forWidget(at: now.addingTimeInterval(300)).visibleBatteries
        precondition(expired.map(\.value) == ["64%", "0%", "—"] && expired.allSatisfy { $0.online == false })
        precondition(expired.prefix(2).allSatisfy { $0.isSaved(at: now) && $0.batteryRuntime == reported },
                     "Showing expired stations preserves the measured charge and runtime")
        devices.showOfflineDevices = nil; devices.bluetoothCheckedAt = nil
        precondition(devices.forWidget(at: now).visibleBatteries.isEmpty, "Discovery cannot prove a connection")
        precondition(selection.selected(in: afterDisconnect) == nil)
        precondition(WidgetClimateSelection().selected(in: afterDisconnect)?.brand == "TCL")
        precondition(WidgetClimateSelection().selected(in: WidgetSnapshot(climate: [offline])) == nil)
        let controlledRoundTrip = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(controlledRoundTrip.climate.last?.control?.target == 24)
        precondition(controlledRoundTrip.climate.last?.control?.temperatures == [26, 22, 24, 22])

        let live = WidgetMetric(id: "confirmed", name: "Bedroom", value: "25°", detail: "Set 24°",
            symbol: "air.conditioner.horizontal", updatedAt: now, brand: "TCL",
            control: WidgetClimateControl(target: 24, temperatures: [22, 24, 26], powerOn: true,
                canSetPower: true, checkedAt: now), online: true, ecoEnabled: false)
        let displayed = WidgetSnapshot(climate: [live])
        var timestampOnly = displayed
        timestampOnly.climate[0].updatedAt = now.addingTimeInterval(1)
        timestampOnly.climate[0].control?.checkedAt = now.addingTimeInterval(1)
        precondition(displayed.hasSamePresentation(as: timestampOnly, at: now.addingTimeInterval(2)),
                     "Unchanged fresh polls must not use a timeline reload for each timestamp")
        precondition(!displayed.hasSamePresentation(as: timestampOnly, at: now.addingTimeInterval(301)),
                     "Refreshing a saved-reading clock must still reload the widget")
        var changed = timestampOnly
        changed.climate[0].control?.powerOn = false; changed.climate[0].detail = "Off"
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "Confirmed power changes must reload")
        changed = timestampOnly
        changed.climate[0].control?.target = 26; changed.climate[0].detail = "Set 26°"
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "Confirmed temperatures must reload")
        changed = timestampOnly; changed.climate[0].value = "26°"
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "Room readings must reload")
        changed = timestampOnly; changed.climate[0].ecoEnabled = true
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "Eco indicators must reload")
        changed = timestampOnly; changed.climate[0].fanSpeed = "turbo"
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "A confirmed fan change must reload the compact indicators")
        changed = timestampOnly; changed.climate[0].online = false
        precondition(!displayed.hasSamePresentation(as: changed, at: now), "Reachability changes must reload")

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
        print("Widget snapshots: room and AC-setting fallback, saved prices and battery runtime, freshness, legacy decode and control selection verified.")
    }
}
