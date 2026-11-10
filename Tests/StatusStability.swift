import AppKit

@main struct StatusStability {
    @MainActor static func main() {
        _ = NSApplication.shared
        precondition(DisplayUnits.power(999) == "999 W")
        precondition(DisplayUnits.power(1000) == "1.00 kW")
        precondition(DisplayUnits.power(1490) == "1.49 kW")
        precondition(DisplayUnits.energy(1490) == "1.49 kWh")
        precondition(DisplayUnits.energy(990) == "990 Wh")
        precondition(MenuPresentation.watts(400) == "400 W")
        precondition(MenuPresentation.watts(399.7) == "400 W")
        precondition(formatEnergy(400) == "400 Wh")
        precondition(liveWatts(["currentPowerConsumption": ["value": 0.4, "unit": "kW"]]) == 400)
        let energy = EnergyPeriod.Reading(lower: 0.4, upper: 0.4, at: 0, source: "fixture")
        precondition(energy.text == "400 Wh")
        precondition(EnergyPeriod.Reading(lower: 0.2, upper: 0.6, at: 0, source: "fixture").text == "400 Wh")
        precondition(EnergyPeriod.Reading(lower: 1.2, upper: 1.78, at: 0, source: "fixture").text == "1.49 kWh")
        precondition(EnergyPeriod.Reading(lower: 0, upper: 0.6, at: 0, source: "fixture").text == "300 Wh")
        precondition(EnergyPeriod.Reading(lower: 1.2, upper: .infinity, at: 0, source: "fixture").text == "≥1.20 kWh")
        precondition(DisplayUnits.energyAxis(10000) == "10 kWh")
        precondition(DisplayUnits.energyAxis(1490) == "1.49 kWh")
        precondition(DeviceDisplayName.clean("Bedroom Aircon") == "Bedroom")
        precondition(DeviceDisplayName.clean("A/C Living Room") == "Living Room")
        let chartDay = ISO8601DateFormatter().date(from:"2026-11-10T12:00:00Z")!
        let days = EnergyCharts.normalizedDays([EnergyDayPoint(key:"2026-11-09",label:"?",wattHours:400)],now:chartDay)
        precondition(days.count == 7 && days.first?.key == "20261104" && days.last?.key == "20261110" && days.last?.label == "Today")
        precondition(days[5].wattHours == 400 && days[6].wattHours == nil)
        let orderDomain = "SuperBar.order." + UUID().uuidString
        let orderDefaults = UserDefaults(suiteName:orderDomain)!
        defer { orderDefaults.removePersistentDomain(forName:orderDomain) }
        let order = CardOrder(defaults:orderDefaults)
        order.move("c",before:"a",group:"TCL",known:["a","b","c"])
        precondition(CardOrder(defaults:orderDefaults).sorted(["a","b","c"],group:"TCL",id:{$0}) == ["c","a","b"])
        let presetAC = Aircon(["id":"preset","name":"Test","reported":[
            "powerSwitch":1,"workMode":1,"targetTemperature":22,"windSpeed":2,
            "verticalDirection":9,"horizontalDirection":9,"verticalSwitch":1,"horizontalSwitch":1
        ]])!
        let high = try! DeviceService.desired(CoolingPreset.high.fields(for:presetAC)!,report:presetAC.report)
        precondition(high["verticalDirection"] == 13 && high["horizontalDirection"] == 11 && high["verticalSwitch"] == 0 && high["horizontalSwitch"] == 0)
        let low = try! DeviceService.desired(CoolingPreset.low.fields(for:presetAC)!,report:presetAC.report)
        precondition(low["verticalDirection"] == 2 && low["horizontalDirection"] == 1 && low["verticalSwitch"] == 1 && low["horizontalSwitch"] == 1)
        let selectionButton = CardSelectionButton.Control()
        var selections = 0
        selectionButton.selectDevice = {
            precondition(selectionButton.active, "Selection must be visible before model work")
            selections += 1
        }
        let press = NSEvent.mouseEvent(with:.leftMouseDown, location:.zero, modifierFlags:[], timestamp:0,
                                      windowNumber:0, context:nil, eventNumber:0, clickCount:1, pressure:1)!
        selectionButton.mouseDown(with:press)
        precondition(selections == 1, "Selection waited for mouse-up")
        precondition(selectionButton.accessibilityValue() as? String == "Selected")
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
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "\u{FFFC} / 28°")
        lg.toggleVisibility("icon")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "\u{FFFC} / 28°")
        lg.toggleVisibility("sensor")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "\u{FFFC}")
        lg.toggleVisibility("current")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string.isEmpty)
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
