import AppKit

@main struct StatusStability {
    @MainActor static func main() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try! DeviceService.ensure(directory)
        var inventory: Result<[JSONObject], Error> = .success([])
        let climate = ClimateStore(directory: directory, fetch: { try inventory.get() })
        func fetchInventory() {
            climate.refresh()
            let cutoff = Date().addingTimeInterval(4)
            while climate.refreshing && Date() < cutoff { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(!climate.refreshing)
        }
        precondition(climate.needsSignIn)
        fetchInventory()
        precondition(climate.selected == nil && !climate.needsSignIn, "Authenticated empty inventory reopened login")
        inventory = .failure(ACError("Connection interrupted"))
        fetchInventory()
        precondition(!climate.needsSignIn, "Network failure reopened login")
        inventory = .failure(TCLCloudError.credentialsRejected)
        fetchInventory()
        precondition(climate.needsSignIn, "Rejected credentials must reveal the sign-in form")
        let domain = "SuperBar.cards." + UUID().uuidString
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        prefs.set(["indoor"], forKey: "readoutFields")
        let fields = ReadoutPreferences(defaults: prefs)
        inventory = .success([["id":"a","name":"Same"], ["id":"b","name":"Same"], ["id":"c","name":"Third"]])
        fetchInventory()
        climate.select(climate.devices[1])
        fields.set(.fan, for: "b", visible: true)
        precondition(fields.device(in: climate)?.id == "b" && fields.ordered("b").first == .fan)
        fields.set(.fan, for: "b", visible: false)
        precondition(fields.ordered("b") == [.indoor, .icon])
        fields.set(.indoor, for: "b", visible: false)
        precondition(fields.device(in: climate)?.id == "b" && fields.ordered("b") == [.icon])
        fields.set(.icon, for: "b", visible: false)
        precondition(!ReadoutPreferences(defaults: prefs).ordered("b").contains(.icon))
        precondition(fields.device(in: climate)?.id == "a" && climate.selected?.id == "b")
        for (power, expected) in [(false, "OFF"), (true, "22°")] {
            let unit = Aircon(["name": "Test", "online": true, "power": power, "target": 22, "indoor": 28])!
            precondition(unit.acTemperature == expected && tempText(unit.indoor) == "28°")
        }
        let battery = Reading.fromFixture()!
        var first = StatusVisibility(defaults: prefs, reading: battery, station: "one")
        first.toggle(.percentage, reading: battery, defaults: prefs)
        let second = StatusVisibility(defaults: prefs, reading: battery, station: "two")
        precondition(first.selected != second.selected)
        first.remember(.output, defaults: prefs)
        precondition(first.summary(for: battery, at: Date()) == battery.outputText)
        print("Cards: distinct device IDs, last visible reading, per-device preferences and fallback verified.")
        let blue = BlueBarDelegate()
        // Before the user opens BLUETTI, no timer or queued refresh may start a helper.
        blue.restartPollTimer()
        blue.refresh()
        blue.pendingRefresh = true
        blue.runQueuedWork()
        precondition(!blue.bluetoothActivated && blue.job == nil && blue.pollTimer == nil,
                     "Bluetooth started before the user needed BLUETTI")
        blue.pendingRefresh = false
        var blueUpdates = 0
        blue.didRender = { blueUpdates += 1 }
        blue.render()
        blueUpdates = 0
        for _ in 0..<30 { blue.render() }
        precondition(blueUpdates == 0, "unchanged BLUETTI rendered repeatedly")
        blue.lastGood = Reading.fromFixture()
        blue.render()
        precondition(blueUpdates > 0, "changed BLUETTI did not update")
        blueUpdates = 0
        blue.makeMenu()
        for _ in 0..<10 {
            blue.mainMenuWillOpen()
            blue.mainMenuDidClose()
        }
        precondition(blueUpdates == 0, "opening BLUETTI menu changed the readout")

        let lg = App()
        defaults.register(defaults: ["font": 13.0, "icon": true, "sensor": true, "current": true, "locationWeather": false])
        var lgUpdates = 0
        lg.didRender = { lgUpdates += 1 }
        lg.connected = true
        lg.state = ["temperature":["currentTemperature":21,"targetTemperature":22]]
        lg.updateStatus()
        lgUpdates = 0
        for _ in 0..<30 { lg.updateStatus() }
        precondition(lgUpdates == 0, "unchanged LG rendered repeatedly")
        lg.state = ["temperature":["currentTemperature":22,"targetTemperature":23]]
        lg.updateStatus()
        precondition(lgUpdates > 0, "changed LG did not update")
        lg.buildMenu()
        lgUpdates = 0
        for _ in 0..<10 {
            lg.menuWillOpen(lg.menu)
            lg.menuDidClose(lg.menu)
        }
        precondition(lgUpdates == 0, "opening LG menu changed the readout")
        let testID = UUID().uuidString
        let oldSelected = defaults.string(forKey: "selected")
        defer {
            defaults.set(oldSelected, forKey: "selected")
            for key in ["current", "sensor", "icon"] {
                defaults.removeObject(forKey: "lg.fields." + testID + "." + key)
            }
            defaults.removeObject(forKey: "lg.lastField." + testID)
        }
        lg.selected = testID
        lg.state = ["operation": ["airConOperationMode": "POWER_OFF"],
                    "temperature": ["currentTemperature": 28, "targetTemperature": 22]]
        lg.updateStatus()
        for key in ["icon", "sensor", "current"] {
            precondition(lg.readout.image != nil && lg.readout.attributedTitle.string.isEmpty)
            lg.toggleVisibility(key)
        }
        precondition(lg.sample(for: testID)?.value("sensor") == "28°")
        lg.state["operation"] = ["airConOperationMode": "POWER_ON"]
        lg.toggleVisibility("current")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "22°")
        print("Status readout: stable on repeated updates, changes still propagate.")
    }
}

private extension Reading {
    static func fromFixture() -> Reading? {
        let sample: [String: Any] = [
            "ok": true, "model": "AC50P", "device": "DEMO",
            "battery_percent": 73, "observed_at": Date().timeIntervalSince1970,
            "ac_input_w": 0, "dc_input_w": 0, "ac_output_w": 120, "dc_output_w": 15
        ]
        return try? Reading.decode(sample, previous: nil, now: Date(), maximumAge: nil)
    }
}
