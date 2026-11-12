import AppKit

@main struct StatusStability {
    @MainActor static func main() {
        _ = NSApplication.shared
        let tariff = EnergyTariff()
        precondition(abs(tariff.bill(generationKWh: 1, consumptionKWh: 1)!.netCost - 4.55) < 0.000001)
        precondition(tariff.bill(generationKWh: nil, consumptionKWh: 1) == nil)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: nil) == nil)
        precondition(tariff.bill(generationKWh: -1, consumptionKWh: 1) == nil)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: .nan) == nil)
        precondition(tariff.bill(generationKWh: 0, consumptionKWh: 1)!.netCost == 13)
        let sold = tariff.bill(generationKWh: 1, consumptionKWh: 0)!
        precondition(sold.importCost == 0 && sold.netCost == -6.5 && sold.label == "Credit")
        let begin = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 600)
        let solarSamples = [PowerPoint(time: begin, watts: 6000), PowerPoint(time: end, watts: 6000)]
        let load = PowerInterval(start: begin, end: end, watts: 3000)
        let interval = DateInterval(start: begin, end: end)
        let matched = EnergyTariff.matched(generation: solarSamples, consumption: [load, load], live: [], range: interval)
        precondition(matched.generationKWh == 1 && matched.selfUseKWh == 0.5 && matched.exportKWh == 0.5 && matched.seconds == 600)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: 0.5, matched: matched)!.netCost == -3.25)
        let mixedBill = tariff.bill(generationKWh: 2, consumptionKWh: 2, matched: matched)!
        precondition(abs(mixedBill.importCost - 15.6) < 0.000001 && abs(mixedBill.exportRevenue - 7.8) < 0.000001)
        let missing = EnergyTariff.matched(generation: solarSamples, consumption: [], live: [], range: interval)
        precondition(missing.seconds == 0 && abs(tariff.bill(generationKWh: 1, consumptionKWh: 1, matched: missing)!.netCost - 4.55) < 0.000001)
        let importOnly = EnergyTariff.matched(generation: solarSamples, consumption: [PowerInterval(start: begin, end: end, watts: 12000)], live: [], range: interval)
        precondition(importOnly.importKWh == 1 && importOnly.exportKWh == 0 && tariff.bill(generationKWh: 1, consumptionKWh: 2, matched: importOnly)!.netCost == 13)
        let gap = EnergyTariff.matched(generation: [solarSamples[0], PowerPoint(time: end.addingTimeInterval(1), watts: 6000)], consumption: [load], live: [], range: interval)
        precondition(gap.seconds == 0)
        precondition(EnergyTariff(purchasePerKWh: 13, exportRatio: 0.5, selfUseRatio: 1).bill(generationKWh: 1, consumptionKWh: 1)!.netCost == 0)
        precondition(EnergyTariff(purchasePerKWh: 13, exportRatio: 0.5, selfUseRatio: 0).bill(generationKWh: 1, consumptionKWh: 1)!.netCost == 6.5)
        precondition(EnergyTariff(purchasePerKWh: 13, exportRatio: 0.5, selfUseRatio: 1).bill(generationKWh: 10, consumptionKWh: 1)!.netCost == -58.5)
        precondition(DeyeReading.power(3314) == "3,3 kW")
        precondition(DeyeReading.power(800) == "0,8 kW")
        precondition(DeyeReading.power(799) == "799 W")
        precondition(DeyeReading.power(735) == "735 W")
        precondition(DeyeReading.power(0) == "0 W")
        precondition(DeyeReading.power(nil) == "—" && DeyeReading.power(.nan) == "—")
        precondition(DisplayUnits.power(999) == "1,0 kW")
        precondition(DisplayUnits.power(1000) == "1,0 kW")
        precondition(DisplayUnits.power(1490) == "1,5 kW")
        precondition(DisplayUnits.energy(1490) == "1,5 kWh")
        precondition(DisplayUnits.energy(990) == "1,0 kWh")
        precondition(MenuPresentation.watts(400) == "400 W")
        precondition(MenuPresentation.watts(399.7) == "400 W")
        precondition(formatEnergy(400) == "400 Wh")
        precondition(liveWatts(["currentPowerConsumption": ["value": 0.4, "unit": "kW"]]) == 400)
        let energy = EnergyPeriod.Reading(lower: 0.4, upper: 0.4, at: 0, source: "fixture")
        precondition(energy.text == "400 Wh")
        precondition(EnergyPeriod.Reading(lower: 0.2, upper: 0.6, at: 0, source: "fixture").text == "400 Wh")
        precondition(EnergyPeriod.Reading(lower: 1.2, upper: 1.78, at: 0, source: "fixture").text == "1,5 kWh")
        precondition(EnergyPeriod.Reading(lower: 0, upper: 0.6, at: 0, source: "fixture").text == "300 Wh")
        precondition(EnergyPeriod.Reading(lower: 1.2, upper: .infinity, at: 0, source: "fixture").text == "≥1,2 kWh")
        precondition(DisplayUnits.energyAxis(10000) == "10,0 kWh")
        precondition(DisplayUnits.energyAxis(1490) == "1,5 kWh")
        precondition(DeviceDisplayName.clean("Bedroom Aircon") == "Bedroom")
        precondition(DeviceDisplayName.clean("A/C Living Room") == "Living Room")
        let chartDay = ISO8601DateFormatter().date(from:"2026-11-10T12:00:00Z")!
        let days = EnergyCharts.normalizedDays([EnergyDayPoint(key:"2026-11-09",label:"?",wattHours:400)],now:chartDay)
        precondition(days.count == 30 && days.first?.key == "20261012" && days.last?.key == "20261110" && days.last?.label == "Today")
        precondition(days[28].wattHours == 400 && days[29].wattHours == nil)
        let march = ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
        let shortMonth = EnergyCharts.normalizedDays([], now: march)
        precondition(shortMonth.first?.key == "20260131" && shortMonth.last?.key == "20260301")
        precondition(Set(shortMonth.map(\.key)).count == 30, "Repeated day-of-month labels must remain separate bars")
        func at(_ seconds: Double) -> Date { chartDay.addingTimeInterval(seconds) }
        let joined = EnergyCharts.consumptionSegments(hours: [
            PowerInterval(start: at(0), end: at(3600), watts: 500),
            PowerInterval(start: at(3600), end: at(7200), watts: 700),
            PowerInterval(start: at(10800), end: at(14400), watts: 900)
        ], live: [PowerPoint(time: at(14415), watts: 950),
                  PowerPoint(time: at(16215), watts: 1000),
                  PowerPoint(time: at(18016), watts: 1100)])
        precondition(joined.map(\.segment) == [0, 0, 0, 0, 1, 1, 1, 1, 2],
                     "Join adjacent hours and live samples; break only for uncovered gaps over 30 minutes")
        precondition(joined[1].point.time == joined[2].point.time && joined[1].point.watts != joined[2].point.watts,
                     "Hourly averages form steps without inventing a slope inside the measured hour")
        precondition(Set(joined.map(\.id)).count == joined.count, "Shared hour boundaries need distinct vertex IDs")
        let chartCalendar = TuyaHistory.calendar
        precondition(!HistoryPolling.due(since: chartDay, now: chartDay.addingTimeInterval(15), calendar: chartCalendar))
        precondition(HistoryPolling.due(since: chartDay, now: chartDay.addingTimeInterval(300), calendar: chartCalendar))
        let midnight = ISO8601DateFormatter().date(from:"2026-11-10T16:00:00Z")!
        precondition(HistoryPolling.due(since: midnight.addingTimeInterval(-15), now: midnight, calendar: chartCalendar))
        var archived = WeekHistory()
        archived.lastAttempt = chartDay
        archived.completedThrough = WeekHistory.dayKey(chartCalendar.date(byAdding: .day, value: -1, to: chartDay)!, chartCalendar)
        precondition(archived.due(at: chartDay.addingTimeInterval(7200), calendar: chartCalendar), "Expand older caches to 30 days")
        archived.days = WeekChart.series(response: [:], end: chartDay, calendar: chartCalendar)
        precondition(archived.days.count == 30)
        precondition(!archived.due(at: chartDay.addingTimeInterval(7200), calendar: chartCalendar), "Completed LG archive must not refresh hourly")
        precondition(archived.due(at: chartDay.addingTimeInterval(86400), calendar: chartCalendar), "New completed day needs a fetch")
        let energyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: energyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: energyDir) }
        var historyRequests = 0
        let tclDevice: [[String: Any]] = [["deviceId": "history-meter", "name": "AC"]]
        func syncTCL(_ now: Date) {
            EnergySync.refresh(devices: tclDevice, directory: energyDir, now: now) { _, path in
                historyRequests += 1
                if path.contains("timeType=1") { return ["code": 0, "data": [:]] }
                return ["code": 0, "data": ["ecoDetails": [["dataList": [["time": "2026-11-10", "totalElectricity": 1.2]]]]]]
            }
        }
        syncTCL(chartDay)
        precondition(historyRequests == 2)
        syncTCL(chartDay.addingTimeInterval(15))
        precondition(historyRequests == 2, "Fast TCL status polling must not request history")
        syncTCL(chartDay.addingTimeInterval(900))
        precondition(historyRequests == 3, "TCL summary refreshes at 15 minutes; hourly history stays cached")
        let presetAC = Aircon(["id":"preset","name":"Test","reported":[
            "powerSwitch":1,"workMode":1,"targetTemperature":22,"windSpeed":2,
            "verticalDirection":9,"horizontalDirection":9,"verticalSwitch":1,"horizontalSwitch":1
        ]])!
        let high = try! DeviceService.desired(CoolingPreset.high.fields(for:presetAC)!,report:presetAC.report)
        precondition(high["verticalDirection"] == 13 && high["horizontalDirection"] == 11 && high["verticalSwitch"] == 0 && high["horizontalSwitch"] == 0)
        let low = try! DeviceService.desired(CoolingPreset.low.fields(for:presetAC)!,report:presetAC.report)
        precondition(low["verticalDirection"] == 2 && low["horizontalDirection"] == 1 && low["verticalSwitch"] == 1 && low["horizontalSwitch"] == 1)
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
        let solar = DeyeStore(defaults: prefs)
        let expandedBeforePin = BarSelection.shared.expanded
        let readoutBeforePin = BarSelection.shared.current
        solar.pinned = true
        precondition(BarSelection.shared.expanded == expandedBeforePin && BarSelection.shared.current == readoutBeforePin)
        precondition(DeyeStore(defaults: prefs).pinned, "Deye visibility was not persisted")
        solar.pinned = false
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
        precondition(fields.device(in: climate)?.id == "b" && climate.selected?.id == "b")
        climate.select(climate.devices[0])
        precondition(fields.device(in: climate)?.id == "b", "Browsing another device changed pinned readings")
        fields.set(.target, for: "a", visible: true)
        precondition(fields.device(in: climate)?.id == "a", "Explicit Show did not choose the readout device")
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
        print("Cards: distinct device IDs, explicit pinning and per-device preferences verified.")
        let oldPinnedLG = defaults.string(forKey: "lg.pinnedDevice")
        let oldPinnedBlue = UserDefaults.standard.string(forKey: "bluetti.pinnedStation")
        defaults.removeObject(forKey: "lg.pinnedDevice")
        UserDefaults.standard.removeObject(forKey: "bluetti.pinnedStation")
        defer {
            defaults.set(oldPinnedLG, forKey: "lg.pinnedDevice")
            UserDefaults.standard.set(oldPinnedBlue, forKey: "bluetti.pinnedStation")
        }
        let card = BatteryCard(frame: NSRect(x: 0, y: 0, width: 374, height: 140))
        card.expanded = false
        card.update(readingPercent: 73, power: MenuPowerRow(input: "0 W", output: "135 W", toolTip: nil), chargeTime: "", batteryTime: "2h")
        precondition(card.contentHeight == 26 && card.refreshButton.isHidden && card.renameButton.isHidden)
        card.expanded = true
        precondition(card.contentHeight >= 112 && !card.refreshButton.isHidden && !card.renameButton.isHidden)
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
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "⏻ / 28°")
        precondition(lg.readout.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
        lg.toggleVisibility("icon")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "⏻ / 28°")
        lg.toggleVisibility("sensor")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "⏻")
        lg.toggleVisibility("current")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string.isEmpty)
        precondition(lg.sample(for: testID)?.value("sensor") == "28°")
        lg.state["operation"] = ["airConOperationMode": "POWER_ON"]
        lg.toggleVisibility("current")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "22°")
        let pinnedTitle = lg.readout.attributedTitle.string
        lg.samples[testID] = LGSample(lg.state)
        lg.selected = "another-device"
        lg.state = ["operation": ["airConOperationMode": "POWER_ON"],
                    "temperature": ["currentTemperature": 31, "targetTemperature": 18]]
        lg.updateStatus()
        precondition(lg.readout.attributedTitle.string == pinnedTitle, "Browsing LG changed the pinned device")
        print("Status readout: stable on repeated updates, changes still propagate; LG pins survive device selection.")
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
