import AppKit

@main struct StatusStability {
    @MainActor static func main() {
        _ = NSApplication.shared
        verifyTelevisionLinks()
        let tariff = EnergyTariff()
        precondition(tariff.pesosPerHour(netWatts: 1000) == 6.5)
        precondition(tariff.pesosPerHour(netWatts: -1000) == -13)
        precondition(tariff.pesosPerHour(netWatts: 0) == 0)
        precondition(tariff.pesosPerHour(netWatts: nil) == nil)
        precondition(tariff.hourlyReadout(netWatts: 1000).hasSuffix("/h"))
        precondition(tariff.hourlyReadout(netWatts: nil) == "₱0.0/h")
        precondition(tariff.hourlyReadout(netWatts: DeyeReading.netForBilling(production: nil, load: 1000)) == "-₱13.0/h")
        let now = Date()
        let nightLoad = PowerInterval(start: now.addingTimeInterval(-3600), end: now, watts: 1000)
        let withoutSolar = tariff.last24Hours(generation: [], load: [], intervals: [nightLoad], now: now)
        precondition(withoutSolar.bill?.netCost == 13 && withoutSolar.partial)
        precondition(tariff.last24Hours(generation: [], load: [], intervals: [], now: now).dailyReadout == "₱0.0/d")
        precondition(EnergyTariff.money(13.289) == "₱13.3")
        precondition(EnergyTariff.money(-1250) == "-₱1.25k")
        precondition(DisplayUnits.powerAxis(800_000) == "800,0 kW")
        precondition(DisplayUnits.powerAxis(890_000) == "0,89 MW")
        precondition(DisplayUnits.powerAxis(-900_000) == "-0,90 MW")
        precondition(abs(tariff.roi(revenue: 7000)! - 1.75) < 0.000001)
        precondition(tariff.roi(revenue: 0) == 0 && tariff.roi(revenue: .nan) == nil)
        precondition(EnergyTariff(panelCost: 0).roi(revenue: 100) == nil)
        precondition(abs(tariff.revenue(generationKWh: 100)! - 910) < 0.000001)
        precondition(tariff.revenue(generationKWh: 100, today: true) == 650)
        precondition(tariff.bill(generationKWh: 100, consumptionKWh: 100)!.withoutSolarCost == 1300)
        precondition(abs(tariff.bill(generationKWh: 100, consumptionKWh: 100)!.netCost - 390) < 0.000001)
        precondition(tariff.bill(generationKWh: 100, consumptionKWh: 100, today: true)!.netCost == 650)
        precondition(tariff.bill(generationKWh: nil, consumptionKWh: 1)?.netCost == 13)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: nil) == nil)
        precondition(tariff.bill(generationKWh: -1, consumptionKWh: 1) == nil)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: .nan) == nil)
        precondition(tariff.bill(generationKWh: 0, consumptionKWh: 1)!.netCost == 13)
        precondition(tariff.bill(generationKWh: 1, consumptionKWh: 0, today: true)!.netCost == -6.5)
        let legacy = try! JSONDecoder().decode(EnergyTariff.self, from: Data(#"{"purchasePerKWh":15,"exportRatio":0.6,"selfUseRatio":0.25}"#.utf8))
        precondition(legacy.purchasePerKWh == 15 && legacy.exportRatio == 0.6 && legacy.todayExportRatio == 0.5 && legacy.panelCost == 400_000)
        let pricingDomain = "EnergyTariff.test." + UUID().uuidString
        let pricingDefaults = UserDefaults(suiteName: pricingDomain)!
        defer { pricingDefaults.removePersistentDomain(forName: pricingDomain) }
        pricingDefaults.set(try! JSONEncoder().encode(legacy), forKey: "energy.tariff")
        let pricing = EnergyPricing(defaults: pricingDefaults)
        precondition(pricing.tariff.purchasePerKWh == 15 && pricing.tariff.exportRatio == 0.7)
        pricing.tariff.exportRatio = 0.65
        precondition(EnergyPricing(defaults: pricingDefaults).tariff.exportRatio == 0.65, "Migration must run only once")
        let generation = [EnergyDayPoint(key: "20261111", label: "", wattHours: 100000), EnergyDayPoint(key: "20261112", label: "", wattHours: 100000)]
        let summary = tariff.summary(generation: generation, consumption: generation, todayKey: "20261112")
        precondition(abs(summary.revenue! - 1560) < 0.000001 && abs(summary.bill!.netCost - 1040) < 0.000001)
        precondition(abs(tariff.roi(revenue: summary.revenue!)! - 0.39) < 0.000001)
        let missingLoads = tariff.summary(generation: generation, consumption: [], todayKey: "20261112")
        precondition(missingLoads.revenue == summary.revenue && missingLoads.bill == nil && missingLoads.generationDays == 2 && missingLoads.billDays == 0)
        let monthEnd = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let monthCount = ChartHistory.accountingDayCount(now: monthEnd)
        precondition(monthCount == 31 && TuyaHistory.keys(now: monthEnd).first == "20261001")
        precondition(EnergyCharts.normalizedDays([], now: monthEnd, count: monthCount).first?.key == "20261001")
        for fan in ["windSpeed", "windSpeed7Gear"] {
            let ecoAC = Aircon(["id": "eco", "name": "Test", "reported": ["ECO": 0, "targetTemperature": 22, fan: 6, "silenceSwitch": 0, "turbo": 1, "windSpeedAutoSwitch": 1]])!
            let edits = try! DeviceService.desired(ecoAC.ecoChanges!, report: ecoAC.report)
            precondition(edits["ECO"] == 1 && edits["targetTemperature"] == 26 && edits["silenceSwitch"] == 1 && edits["turbo"] == 0)
            if fan == "windSpeed7Gear" { precondition(edits["windSpeedAutoSwitch"] == 0) }
        }
        let ecoOff = Aircon(["id": "eco", "name": "Test", "reported": ["ECO": 1, "targetTemperature": 26]])!
        precondition(ecoOff.ecoChanges?.count == 1 && ecoOff.ecoChanges?.first?.1 == 0)
        for enabled in [0, 1] {
            let otherMode = Aircon(["id": "eco-cool", "name": "Test", "reported": ["ECO": enabled, "workMode": 2, "targetTemperature": 26, "windSpeed7Gear": 1, "silenceSwitch": 1]])!
            let edits = try! DeviceService.desired(otherMode.ecoChanges!, report: otherMode.report)
            precondition(edits["workMode"] == 1 && edits["ECO"] == 1 - enabled, "Eco toggle must select cooling, never retain Dry or Heat")
            if enabled == 1 { precondition(edits["targetTemperature"] == nil, "Leaving Eco must preserve the selected temperature") }
        }
        func fanUnit(_ report: JSONObject) -> Aircon {
            Aircon(["id": "fan", "name": "Test", "reported": report])!
        }
        let classicFan = fanUnit(["windSpeed": 4, "turbo": 0, "silenceSwitch": 0])
        let compactTCL = Aircon(["name": "Synthetic", "online": true, "power": true,
                                "reported": ["turbo": 1, "ECO": 1, "windSpeed": 6]])!
        precondition(compactTCL.indicators == ClimateIndicators(eco: true, tcl: .turbo))
        for (speed, level) in [("LOW", 1), ("MID", 2), ("HIGH", 3)] {
            var state: [String: Any] = ["operation": ["airConOperationMode": "POWER_ON"],
                                        "airConJobMode": ["currentJobMode": "ENERGY_SAVING"], "airFlow": ["windStrength": speed]]
            let marks = LGSample(state).indicators
            precondition(marks.eco && marks.fan == .lg(level), "The actual LG fan speed and mode-based Eco appear together")
            state["online"] = false
            precondition(LGSample(state).indicators == ClimateIndicators(), "An offline AC has no active mode badges")
        }
        precondition(classicFan.fanSpeedOptions.map(\.id) == [7, 6, 5, 4, 3, 2, 1, 0])
        precondition(classicFan.fanSpeedOptions.map(\.symbol) == [.turbo, .high, .mediumHigh, .medium, .mediumLow, .low, .quiet, .automatic],
                     "Each available TCL speed gets the matching reference icon in descending order")
        precondition(classicFan.currentFanLevel == 4 && classicFan.currentFanSymbol == .medium && classicFan.fan == "Medium")
        precondition(classicFan.fanSymbol(-1) == .unknown && classicFan.fanSymbol(8) == .unknown)
        let limitedFan = fanUnit(["windSpeed": 6])
        precondition(limitedFan.fanSpeedOptions.map(\.id) == [6, 5, 4, 3, 2, 0],
                     "Unsupported Turbo and Quiet controls must not appear")
        precondition(limitedFan.currentFanSymbol == .high && limitedFan.fan == "High")
        let sevenMinimum = fanUnit(["windSpeed7Gear": 1])
        precondition(sevenMinimum.fanSpeedOptions.map(\.id) == [7, 6, 5, 4, 3, 2, 1, 0])
        precondition(sevenMinimum.fanSymbol(1) == .minimum && sevenMinimum.currentFanSymbol == .minimum && sevenMinimum.fan == "Minimum")
        precondition(sevenMinimum.selectedFanOption == 1)
        let quietAvailable = fanUnit(["windSpeed7Gear": 1, "silenceSwitch": 0])
        precondition(quietAvailable.fanSymbol(1) == .quiet && quietAvailable.fanLabel(1) == "Quiet")
        precondition(quietAvailable.currentFanLevel == 1 && quietAvailable.currentFanSymbol == .minimum && quietAvailable.fan == "Minimum")
        precondition(quietAvailable.selectedFanOption == nil,
                     "Minimum fan must not highlight Quiet before its mode flag is enabled")
        let quietActive = fanUnit(["windSpeed7Gear": 1, "silenceSwitch": 1, "windSpeedAutoSwitch": 1])
        precondition(quietActive.currentFanSymbol == .quiet && quietActive.fan == "Quiet" && quietActive.selectedFanOption == 1,
                     "An active Quiet flag takes precedence over the underlying automatic flag")
        let turboActive = fanUnit(["windSpeed7Gear": 1, "silenceSwitch": 1, "turbo": 1, "windSpeedAutoSwitch": 1])
        precondition(turboActive.currentFanSymbol == .turbo && turboActive.fan == "Turbo" && turboActive.selectedFanOption == 7,
                     "Turbo mode retains precedence if a transitional report contains conflicting flags")
        for report: JSONObject in [["windSpeed": 0], ["windSpeed7Gear": 6, "windSpeedAutoSwitch": 1]] {
            let automatic = fanUnit(report)
            precondition(automatic.currentFanLevel == 0 && automatic.currentFanSymbol == .automatic && automatic.fan == "Auto")
        }
        for report: JSONObject in [[:], ["windSpeed": -1], ["windSpeed": 99], ["windSpeed7Gear": 99]] {
            let unknown = fanUnit(report)
            precondition(unknown.currentFanLevel == nil && unknown.currentFanSymbol == .unknown && unknown.selectedFanOption == nil,
                         "Missing or unknown readings must not display a remembered/default fan speed")
        }
        precondition(fanUnit([:]).fanSpeedOptions.isEmpty && fanUnit(["windSpeed": -1]).fanSpeedOptions.isEmpty)
        precondition(TCLCoolingPreset.turbo.fanSymbol == .turbo && TCLCoolingPreset.quiet.fanSymbol == .quiet)
        precondition(DeyeReading.power(3314) == "3,3 kW ⚡️")
        precondition(DeyeReading.power(800) == "0,8 kW ⚡️")
        precondition(DeyeReading.power(799) == "799 W ⚡️")
        precondition(DeyeReading.power(735) == "735 W ⚡️")
        precondition(DeyeReading.power(0) == "0 W ⚡️")
        precondition(DeyeReading.power(nil) == "—" && DeyeReading.power(.nan) == "—")
        precondition(DisplayUnits.power(999) == "1,0 kW ⚡️")
        precondition(DisplayUnits.power(1000) == "1,0 kW ⚡️")
        precondition(DisplayUnits.power(1490) == "1,5 kW ⚡️")
        precondition(DisplayUnits.energy(1490) == "1,5 kWh ⚡️")
        precondition(DisplayUnits.energy(990) == "1,0 kWh ⚡️")
        precondition(MenuPresentation.watts(400) == "400 W ⚡️")
        precondition(MenuPresentation.watts(399.7) == "400 W ⚡️")
        precondition(DisplayUnits.energy(400) == "400 Wh ⚡️")
        precondition(liveWatts(["currentPowerConsumption": ["value": 0.4, "unit": "kW"]]) == 400)
        precondition(DisplayUnits.energyAxis(10000) == "10,0 kWh")
        precondition(DisplayUnits.energyAxis(1490) == "1,5 kWh")
        precondition(DisplayUnits.powerAxis(1000) == "1,0 kW")
        precondition(DeviceDisplayName.clean("Bedroom Aircon") == "Bedroom")
        precondition(DeviceDisplayName.clean("A/C Living Room") == "Living Room")
        let chartDay = ISO8601DateFormatter().date(from:"2026-11-10T12:00:00Z")!
        let meterDayStart = ChartHistory.calendar.startOfDay(for: chartDay).timeIntervalSince1970
        let legacyEnergy = """
        {"devices":[{"id":"ac","name":"Test","state":"ok","updated":\(meterDayStart),
         "days":[{"day":"2026-11-10","kwh":1.2}],
         "meters":[{"at":\(meterDayStart),"today":0},{"at":\(meterDayStart + 900),"today":0.1}]}]}
        """
        let legacyCache = try! JSONDecoder().decode(EnergyCache.self, from: Data(legacyEnergy.utf8))
        var intervalReport = legacyCache.devices[0]
        precondition(intervalReport.days == [EnergyDay(day: "2026-11-10", kwh: 1.2)])
        let averages = EnergyPeriod.powerIntervals(intervalReport, now: chartDay)
        precondition(averages.isEmpty, "Daily report changes are not hourly API readings")
        intervalReport.hours = [MeterHour(start: meterDayStart, kwh: 0.3), MeterHour(start: chartDay.timeIntervalSince1970, kwh: 0.4)]
        let confirmed = EnergyPeriod.powerIntervals(intervalReport, now: chartDay)
        precondition(confirmed.count == 1 && confirmed[0].watts == 300,
                     "Only completed hourly API readings appear on the chart")
        let counterStart = TCLCounterWindow(kwh: 1, at: chartDay.addingTimeInterval(-1800), previous: nil)
        let counterEnd = TCLCounterWindow(kwh: 1.1, at: chartDay.addingTimeInterval(-900), previous: counterStart)
        var estimatedReport = legacyCache.devices[0]
        estimatedReport.counter = counterEnd
        estimatedReport.counterHistory = [counterEnd]
        let estimated = EnergyPeriod.powerIntervals(estimatedReport, now: chartDay)
        precondition(estimated.count == 1 && abs(estimated[0].watts - 400) < 0.001,
                     "Render the measured daily-counter delta once, over its actual observation interval")
        let unchangedCounter = TCLCounterWindow(kwh: 1, at: chartDay.addingTimeInterval(-900), previous: counterStart)
        precondition(unchangedCounter.interval == nil, "An unchanged cloud counter is not a confirmed zero-power interval")
        let days = EnergyCharts.normalizedDays([EnergyDayPoint(key:"2026-11-09",label:"?",wattHours:400)],now:chartDay)
        precondition(days.count == 30 && days.first?.key == "20261012" && days.last?.key == "20261110" && days.last?.label == "Today")
        precondition(days[28].wattHours == 400 && days[29].wattHours == nil)
        let march = ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
        let shortMonth = EnergyCharts.normalizedDays([], now: march)
        precondition(shortMonth.first?.key == "20260131" && shortMonth.last?.key == "20260301")
        precondition(Set(shortMonth.map(\.key)).count == 30, "Repeated day-of-month labels must remain separate bars")
        func at(_ seconds: Double) -> Date { chartDay.addingTimeInterval(seconds) }
        let lastHour = RollingEnergy.lastHour(endingAt: at(900))
        precondition(lastHour == at(-2700)...at(900), "The one-hour chart crosses the clock-hour boundary")
        let clippedHour = RollingEnergy.clipped([PowerInterval(start: at(-3600), end: at(0), watts: 140),
                                                 PowerInterval(start: at(1800), end: at(5400), watts: 150)], to: lastHour)
        precondition(clippedHour.count == 1 && clippedHour[0].start == lastHour.lowerBound && clippedHour[0].end == at(0))
        let rollingRange = RollingEnergy.last24Hours(endingAt: chartDay)
        precondition(rollingRange == at(-86400)...at(0))
        intervalReport.hours = [MeterHour(start: at(-88200).timeIntervalSince1970, kwh: 0.6)]
        let boundary = EnergyPeriod.powerIntervals(intervalReport, now: chartDay).first!
        precondition(boundary.start == rollingRange.lowerBound && boundary.end == at(-84600) && boundary.watts == 600)
        let nightReading = DeyeReading(id: 1, name: "", power_w: 0, today_kwh: nil, status: "NORMAL",
                                       measured_at: chartDay.timeIntervalSince1970, days: [])
        precondition(DeyeReading.netForBilling(production: nightReading, load: 1000, now: chartDay) == -1000)
        precondition(DeyeReading.netForBilling(production: nightReading, load: nil, now: chartDay) == nil)
        precondition(DeyeReading.netForBilling(production: nightReading, load: 1000, now: at(600)) == -1000)
        let rolling = RollingEnergy.total(points: [PowerPoint(time: at(-90000), watts: 1000),
                                                   PowerPoint(time: at(0), watts: 1000)],
                                          in: rollingRange, maximumGap: 90000)
        precondition(abs(rolling.wattHours - 24000) < 0.001 && rolling.coverage == 86400,
                     "Clip to exactly 24 hours, including the previous calendar day")
        let gapTotal = RollingEnergy.total(points: [PowerPoint(time: at(-86400), watts: 1000),
                                                    PowerPoint(time: at(0), watts: 1000)], in: rollingRange)
        precondition(gapTotal.coverage == 0 && gapTotal.label(in: rollingRange) == "—", "Never interpolate through missing history")
        let mixedTotal = RollingEnergy.total(points: [PowerPoint(time: at(-3600), watts: 1000), PowerPoint(time: at(0), watts: 1000)],
                                             intervals: [PowerInterval(start: at(-5400), end: at(-1800), watts: 2000)],
                                             in: at(-3600)...at(0), maximumGap: 3600)
        precondition(abs(mixedTotal.wattHours - 1500) < 0.001 && mixedTotal.coverage == 3600,
                     "Clip boundary hours and give meter intervals priority over overlapping live samples")
        let partialMeter = TuyaHistory(meterID: "test", timeZoneID: "Asia/Manila",
            days: [EnergyDayPoint(key: ChartHistory.formatter("yyyyMMdd").string(from: at(0)), label: "", wattHours: 100)],
            hours: [], fetchedAt: ChartHistory.calendar.startOfDay(for: at(0)).addingTimeInterval(1800))
        precondition(partialMeter.energyIntervals.count == 1 && partialMeter.energyIntervals[0].watts == 200,
                     "Include current partial-hour energy from the daily meter, without treating it as a full hour")
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
        let detailed = EnergyCharts.consumptionSegments(hours: [PowerInterval(start: at(-3600), end: at(0), watts: 500)],
            live: [PowerPoint(time: at(-2700), watts: 120), PowerPoint(time: at(-2640), watts: 1500)])
        precondition(detailed.contains { $0.point.watts == 120 } && detailed.contains { $0.point.watts == 1500 } &&
                     detailed.first?.point.time == at(-3600) && detailed.last?.point.time == at(0),
                     "Keep detailed power reports inside archived hours and use the average on either side")
        let reports = [PowerPoint(time: at(0), watts: 0), PowerPoint(time: at(600), watts: 900),
                       PowerPoint(time: at(1800), watts: 100)]
        let fallbackHour = [PowerInterval(start: at(-60), end: at(1500), watts: 300)]
        func inspected(_ seconds: Double) -> Double? {
            EnergyCharts.powerValue(at: at(seconds), points: reports, intervals: fallbackHour, maximumGap: 600)
        }
        precondition(inspected(0) == 0 && inspected(200) == 300 && inspected(400) == 600 && inspected(600) == 900,
                     "Inspect reported values and interpolate only along a continuous measured line")
        precondition(inspected(601) == 300 && inspected(1200) == 300 && inspected(1600) == nil,
                     "After a line ends, inspect the available hourly average or leave the gap empty")
        let continuous = stride(from: 0.0, through: 86400, by: 15).map { PowerPoint(time: at($0), watts: 45) }
        let plotted = EnergyCharts.plotPoints(continuous, in: at(0)...at(86400), maximumGap: 180)
        precondition(plotted.count < continuous.count && zip(plotted, plotted.dropFirst()).allSatisfy {
            $1.time.timeIntervalSince($0.time) <= 180
        }, "Downsampling one day must keep a continuous station-power line connected")
        let chartCalendar = ChartHistory.calendar
        precondition(!HistoryPolling.due(since: chartDay, now: chartDay.addingTimeInterval(15), calendar: chartCalendar))
        precondition(HistoryPolling.due(since: chartDay, now: chartDay.addingTimeInterval(300), calendar: chartCalendar))
        let midnight = ISO8601DateFormatter().date(from:"2026-11-10T16:00:00Z")!
        precondition(HistoryPolling.due(since: midnight.addingTimeInterval(-15), now: midnight, calendar: chartCalendar))
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
        let hourOnly = [["deviceId": "hour-only", "name": "Hour-only meter"]]
        let replyWithHours: [String: Any] = ["code": 0, "data": ["ecoDetails": [
            ["date": "2026-11-10", "unit": "Wh", "dataList": [
                ["time": "17:00", "electricity": 500], ["time": "18:15", "electricity": 700],
                ["time": "21:00", "electricity": 900]]],
            ["dataList": [["date": "2026-11-10", "time": "19:00:00", "consumption": 0.35],
                          ["date": "2026-11-10", "time": "20:00", "electricity": 1],
                          ["date": "2026-11-10", "hour": 18, "unit": "W", "electricity": 77],
                          ["date": "2026-11-10", "totalElectricity": 100]]]]]]
        EnergySync.refresh(devices: hourOnly, directory: energyDir, now: chartDay) { _, path in
            path.contains("timeType=1") ? replyWithHours : ["code": 0, "data": [:]]
        }
        let hourlyReport = EnergyCache.read(from: energyDir.appendingPathComponent("tcl-energy.json"))!.devices[0]
        precondition(hourlyReport.days.isEmpty && hourlyReport.hours?.map(\.kwh) == [0.5, 0.35],
                     "Retain completed hourly kWh without daily totals, rejecting W, sub-hour rows and the open hour")
        let comparableDay = chartDay.addingTimeInterval(86400)
        precondition(EnergyPeriod.confirmedHours(replyWithHours, calendarTotals: ["2026-11-10": 4], now: comparableDay).count == 4)
        precondition(EnergyPeriod.confirmedHours(replyWithHours, calendarTotals: ["2026-11-10": 1], now: comparableDay).isEmpty)
        let historyDay = ChartHistory.formatter("yyyy-MM-dd")
        let daysToArchive = (-29...0).map { offset in
            ["date": historyDay.string(from: ChartHistory.calendar.date(byAdding: .day, value: offset, to: chartDay)!), "electricity": 500] as [String: Any]
        }
        EnergySync.refresh(devices: tclDevice, directory: energyDir, now: chartDay) { _, path in
            if path.contains("timeType=2") { return ["code": 0, "data": ["unit": "Wh", "dataList": daysToArchive]] }
            return ["code": 0, "data": [:]]
        }
        let monthReport = EnergyCache.read(from: energyDir.appendingPathComponent("tcl-energy.json"))!.devices[0]
        let monthSeries = monthReport.days.map { EnergyDayPoint(key: $0.day, label: "", wattHours: $0.kwh * 1000) }
        precondition(EnergyCharts.normalizedDays(monthSeries, now: chartDay).compactMap(\.wattHours) == Array(repeating: 500, count: 30))
        let baselineCounter = TCLCounterWindow(kwh: 1.20, at: chartDay, previous: nil)
        let flat = TCLCounterWindow(kwh: 1.20, at: at(900), previous: baselineCounter)
        precondition(flat.average(at: at(900)) == nil)
        let changed = TCLCounterWindow(kwh: 1.40, at: at(1800), previous: flat)
        let average = changed.average(at: at(1815))!
        precondition(abs(average.watts - 400) < 0.01 && average.minutes == 30)
        precondition(changed.average(at: at(2800)) == nil)
        precondition(TCLCounterWindow(kwh: 0.8, at: at(2700), previous: changed).last == nil)
        precondition(TCLCounterWindow(kwh: 2, at: at(4500), previous: changed).last == nil)
        let beforeMidnight = TCLCounterWindow(kwh: 0, at: midnight.addingTimeInterval(-900), previous: nil)
        precondition(TCLCounterWindow(kwh: 0.5, at: midnight, previous: beforeMidnight).last == nil)
        precondition(EnergyPeriod.dayLabel("2026-11-11", now: midnight) == "Today")
        precondition(EnergyPeriod.dayLabel("2026-11-10", now: midnight) == "Yesterday")
        let snapshot = DeviceService.normalize(["deviceId": "one", "isOnline": 1], shadow: [
            "state": ["reported": ["electricPowerW": 450, "powerW": 781, "powerSwitch": 1]],
            "metadata": ["reported": ["electricPowerW": ["timestamp": at(-600).timeIntervalSince1970],
                                      "powerW": ["timestamp": chartDay.timeIntervalSince1970]]]])
        let metered = Aircon(snapshot.merging(["name": "test"]) { _, new in new })!
        precondition(metered.measuredWatts(at: chartDay) == 781 && metered.measuredWatts(at: at(301)) == nil)
        func presetUnit(_ report: JSONObject) -> Aircon {
            Aircon(["id":"preset","name":"Test","reported":report])!
        }
        let classicReport: JSONObject = [
            "powerSwitch":0,"workMode":0,"targetTemperature":26,"windSpeed":2,
            "turbo":0,"silenceSwitch":1,"ECO":1,"highTemperatureWind":1,
            "verticalDirection":9,"horizontalDirection":9,"verticalSwitch":1,"horizontalSwitch":1
        ]
        let presetAC = presetUnit(classicReport)
        precondition(Aircon.setpoints(in: [:]) == Array(16...26))
        precondition(Aircon.setpoints(in: ["lowerTemperatureLimit": 18, "upperTemperatureLimit": 30]) == Array(18...26))
        precondition(Aircon.setpoints(in: ["lowerTemperatureLimit": 16, "upperTemperatureLimit": 24]) == Array(16...24))
        let turbo = try! DeviceService.desired(TCLCoolingPreset.turbo.fields(for:presetAC)!,report:classicReport)
        precondition(turbo["targetTemperature"] == 16 && turbo["powerSwitch"] == 1 && turbo["workMode"] == 1)
        precondition(turbo["windSpeed"] == 6 && turbo["turbo"] == 1 && turbo["silenceSwitch"] == 0,
                     "16° Turbo must enable the turbo flag, not merely select ordinary High speed")
        precondition(turbo["ECO"] == 0 && turbo["highTemperatureWind"] == 0)
        precondition(turbo["verticalDirection"] == 13 && turbo["horizontalDirection"] == 11 && turbo["verticalSwitch"] == 0 && turbo["horizontalSwitch"] == 0)
        let turboReport = classicReport.merging(turbo.mapValues { $0 as Any }) { _, new in new }
        precondition(TCLCoolingPreset.turbo.isSelected(on: presetUnit(turboReport)))
        var ordinaryHigh = turboReport
        ordinaryHigh["turbo"] = 0
        precondition(!TCLCoolingPreset.turbo.isSelected(on: presetUnit(ordinaryHigh)),
                     "An ordinary High reading must not highlight the Turbo preset")

        let quiet = try! DeviceService.desired(TCLCoolingPreset.quiet.fields(for:presetUnit(turboReport))!,report:turboReport)
        precondition(quiet["targetTemperature"] == 22 && quiet["powerSwitch"] == 1 && quiet["workMode"] == 1)
        precondition(quiet["windSpeed"] == 2 && quiet["silenceSwitch"] == 1 && quiet["turbo"] == 0,
                     "22° Quiet must enable silence and clear a previously active Turbo mode")
        precondition(quiet["ECO"] == 0 && quiet["highTemperatureWind"] == 0)
        precondition(quiet["verticalDirection"] == 2 && quiet["horizontalDirection"] == 1 && quiet["verticalSwitch"] == 1 && quiet["horizontalSwitch"] == 1)
        let quietReport = turboReport.merging(quiet.mapValues { $0 as Any }) { _, new in new }
        precondition(TCLCoolingPreset.quiet.isSelected(on: presetUnit(quietReport)))
        var ordinaryLow = quietReport
        ordinaryLow["silenceSwitch"] = 0
        precondition(!TCLCoolingPreset.quiet.isSelected(on: presetUnit(ordinaryLow)),
                     "An ordinary Low reading must not highlight the Quiet preset")

        var sevenGearReport = classicReport
        sevenGearReport["windSpeed7Gear"] = 0
        sevenGearReport["windSpeedAutoSwitch"] = 1
        for (preset, level) in [(TCLCoolingPreset.turbo, 7), (.quiet, 1)] {
            let fields = try! DeviceService.desired(preset.fields(for:presetUnit(sevenGearReport))!,report:sevenGearReport)
            precondition(fields["windSpeed7Gear"] == level && fields["windSpeedAutoSwitch"] == 0,
                         "Seven-gear presets must select the actual Turbo/Quiet gear and leave automatic fan mode")
            precondition(fields["turbo"] == (level == 7 ? 1 : 0) && fields["silenceSwitch"] == (level == 1 ? 1 : 0))
            let confirmed = sevenGearReport.merging(fields.mapValues { $0 as Any }) { _, new in new }
            precondition(preset.isSelected(on: presetUnit(confirmed)))
            sevenGearReport = confirmed
        }
        sevenGearReport.removeValue(forKey: "turbo")
        sevenGearReport.removeValue(forKey: "silenceSwitch")
        precondition(TCLCoolingPreset.turbo.fields(for:presetUnit(sevenGearReport)) != nil,
                     "Seven-gear devices encode Turbo directly and need no legacy turbo flag")
        precondition(TCLCoolingPreset.quiet.fields(for:presetUnit(sevenGearReport)) == nil,
                     "Minimum gear alone must not promise Quiet when the silence flag is unsupported")
        var unsupported = classicReport
        unsupported.removeValue(forKey: "turbo")
        precondition(TCLCoolingPreset.turbo.fields(for:presetUnit(unsupported)) == nil && TCLCoolingPreset.quiet.fields(for:presetUnit(unsupported)) != nil)
        unsupported = classicReport
        unsupported.removeValue(forKey: "silenceSwitch")
        precondition(TCLCoolingPreset.quiet.fields(for:presetUnit(unsupported)) == nil && TCLCoolingPreset.turbo.fields(for:presetUnit(unsupported)) != nil)
        var limitedRange = classicReport
        limitedRange["lowerTemperatureLimit"] = 17
        limitedRange["upperTemperatureLimit"] = 21
        precondition(TCLCoolingPreset.turbo.fields(for:presetUnit(limitedRange)) == nil && TCLCoolingPreset.quiet.fields(for:presetUnit(limitedRange)) == nil)
        precondition(TCLCoolingPreset.turbo.label == "16° Turbo" && TCLCoolingPreset.quiet.label == "22° Quiet")
        precondition(LGCoolingPreset.high.label == "16° High" && LGCoolingPreset.low.label == "22° Low",
                     "TCL's protocol-specific presets must not change LG fan modes")
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
        precondition(!climate.needsSignIn, "File absence must not imply missing Keychain credentials")
        inventory = .failure(TCLCloudError.signInRequired)
        fetchInventory()
        precondition(climate.needsSignIn, "A missing secure session must reveal sign-in")
        inventory = .success([])
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
        precondition(card.subviews.isEmpty, "The direct SwiftUI panel must not allocate a second, hidden hosting tree")
        card.update(readingPercent: 0, power: MenuPowerRow(input: "", output: "", toolTip: nil), chargeTime: "", batteryTime: "")
        precondition(card.hasReading && card.summaryPercent == "0%", "An empty battery must remain a known reading")
        card.update(readingPercent: nil, power: MenuPowerRow(input: "", output: "", toolTip: nil), chargeTime: "", batteryTime: "")
        precondition(!card.hasReading && card.summaryPercent == "—", "A missing reading must not become an empty battery")
        precondition(BatteryDetailContent.power("out", dc: 15, ac: 120) == "out DC|AC: 15 W ⚡️|120 W ⚡️")
        precondition(BatteryDetailContent.power("out", dc: nil, ac: 120) == "out AC: 120 W ⚡️",
                     "A missing channel must not hide the available channel or imply a known total")
        precondition(BatteryDetailContent.power("out", dc: .nan, ac: .infinity).isEmpty)
        let blue = BlueBarDelegate()
        // Before the user opens BLUETTI, no timer or queued refresh may start a helper.
        blue.restartPollTimer()
        blue.refresh()
        blue.pendingRefresh = true
        blue.runQueuedWork()
        precondition(!blue.bluetoothActivated && blue.job == nil && blue.pollTimer == nil,
                     "Bluetooth started before the user needed BLUETTI")
        blue.pendingRefresh = false
        blue.stationDirectory = BlueBarStationDirectory(defaults: nil)
        blue.readingStore = BlueBarReadingStore(defaults: nil)
        blue.outputHistory = DevicePowerHistory(provider: "bluetti-test", preferences: nil, maximumGap: 360)
        let pair = ["first", "second"].map { ["id": $0, "name": "AC50P" + $0, "model": "AC50P"] }
        precondition(blue.stationDirectory.observeNearby(pair))
        precondition(!blue.stationDirectory.observeNearby([]))
        precondition(blue.stationDirectory.stations.map(\.key) == ["id:first", "id:second"])
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let primary = try BluettiBluetoothLock(directory: locks, filename: "bluetooth-first.lock")
            let other = try BluettiBluetoothLock(directory: locks, filename: "bluetooth-second.lock")
            defer { primary.release(); other.release() }
            precondition((try? BluettiBluetoothLock(directory: locks, filename: "bluetooth-first.lock")) == nil)
        } catch { preconditionFailure("Distinct batteries must have independent Bluetooth locks") }
        try? FileManager.default.removeItem(at: locks)
        precondition(blue.stationReachability("id:second") == nil)
        let previewTime = Date().addingTimeInterval(-1)
        let sample: [String: Any] = ["ok": true, "model": "AC50P", "device": "AC50Psecond",
            "device_id": "second", "battery_percent": 0, "ac_output_w": 0, "dc_output_w": 0,
            "observed_at": previewTime.timeIntervalSince1970]
        precondition(blue.saveStationPreview(sample, deviceID: "second") && blue.lastGood == nil)
        precondition(blue.stationReachability("id:second") == true)
        precondition(blue.stationReachability("id:second", now: previewTime.addingTimeInterval(3 * blue.previewInterval + 1)) == false)
        precondition(!blue.saveStationPreview(sample, deviceID: "first") && blue.stationReachability("id:first") == nil)
        blue.stationContacts["id:second"] = .failed
        precondition(blue.stationReachability("id:second") == false)
        // Opening and closing the panel only renders the current station data.
        blue.bluetoothActivated = true
        let activeRead = CLIJob()
        blue.job = activeRead
        blue.mainMenuWillOpen()
        blue.mainMenuDidClose()
        precondition(blue.job === activeRead && !blue.pendingRefresh && !blue.streaming && blue.generation == 0)
        blue.streaming = true
        blue.connectedStationKey = "id:connected"
        blue.stationContacts["id:connected"] = .sample(Date())
        blue.mainMenuWillOpen()
        blue.mainMenuDidClose()
        precondition(blue.job === activeRead && !blue.pendingRefresh && blue.streaming && blue.generation == 0)
        precondition(!blue.stationIsOffline("id:connected") && blue.stationIsOffline("id:seen"))
        blue.pendingRefresh = false
        blue.refreshState = .reading
        blue.finishManualRead(error: "Automatic poll")
        precondition(!blue.isManuallyRefreshing && blue.lastManualRefreshError == nil)
        blue.refreshClicked()
        precondition(!blue.pendingRefresh && blue.isManuallyRefreshing, "A click during a read must show progress while joining that read")
        blue.finishManualRead(error: "Station disconnected")
        precondition(!blue.isManuallyRefreshing && blue.lastManualRefreshError == "Station disconnected")
        blue.refreshState = .refreshed
        blue.refreshClicked()
        precondition(blue.pendingRefresh && blue.isManuallyRefreshing && blue.lastManualRefreshError == nil,
                     "A helper that cannot accept the wake-up must be retried")
        blue.finishManualRead(error: nil)
        precondition(blue.isManuallyRefreshing, "A previous helper's sample cannot complete a queued click")
        blue.stopPollingSession()
        precondition(!blue.stationIsOffline("id:connected") && blue.pendingRefresh && blue.isManuallyRefreshing)
        blue.pendingRefresh = false
        blue.manualRead = nil
        blue.bluetoothActivated = false
        blue.restartPollTimer()
        blue.job = nil
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

        let lg = LGStore()
        defaults.register(defaults: ["font": 13.0, "icon": true, "sensor": true, "current": true, "locationWeather": false])
        var lgUpdates = 0
        lg.didRender = { lgUpdates += 1 }
        lg.connected = true
        lg.state = ["operation": ["airConOperationMode": "POWER_ON"], "temperature":["currentTemperature":21,"targetTemperature":22]]
        lg.updateStatus()
        lgUpdates = 0
        for _ in 0..<30 { lg.updateStatus() }
        precondition(lgUpdates == 0, "unchanged LG rendered repeatedly")
        lg.state = ["operation": ["airConOperationMode": "POWER_ON"], "temperature":["currentTemperature":22,"targetTemperature":23]]
        lg.updateStatus()
        precondition(lgUpdates > 0, "changed LG did not update")
        lgUpdates = 0
        for _ in 0..<10 {
            lg.panelOpened()
            lg.panelClosed()
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
        precondition(lg.sample(for: testID)?.room == 28 && lg.sample(for: testID)?.value("sensor") == "28°", "Keep the reported room temperature while LG is off")
        lg.state["operation"] = ["airConOperationMode": "POWER_ON"]
        lg.toggleVisibility("current")
        precondition(lg.readout.image == nil && lg.readout.attributedTitle.string == "22°")
        precondition(lg.sample(for: testID)?.value("sensor") == "28°", "Powered-on LG must expose its room reading again")
        let pinnedTitle = lg.readout.attributedTitle.string
        lg.samples[testID] = LGSample(lg.state)
        lg.selected = "another-device"
        lg.state = ["operation": ["airConOperationMode": "POWER_ON"],
                    "temperature": ["currentTemperature": 31, "targetTemperature": 18]]
        lg.updateStatus()
        precondition(lg.readout.attributedTitle.string == pinnedTitle, "Browsing LG changed the pinned device")
        lg.connected = false
        lg.polling = true
        var requestedPreset = false
        lg.useCard(lg.selected) { requestedPreset = true }
        precondition(!requestedPreset,
                     "A preset pressed during selection must wait for the device read, not be disabled or dropped")
        lg.connected = true
        lg.applyDeferredControls()
        precondition(requestedPreset)
        lg.polling = false
        requestedPreset = false
        lg.sending = true
        lg.useCard(lg.selected) { requestedPreset = true }
        precondition(requestedPreset, "An in-flight command must not block another preset")
        lg.sending = false
        print("Status readout: stable on repeated updates, changes still propagate; LG pins survive device selection.")
    }

    @MainActor private static func verifyTelevisionLinks() {
        let domain = "TVLink.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LGTelevisionStore(defaults: defaults)
        let first = LGAccountTelevision(id: "a", name: "Living room", macAddress: "10:00:00:00:00:01", online: false)
        let second = LGAccountTelevision(id: "b", name: "Living room", macAddress: nil, online: nil)
        let account = [first, second]
        let a = LGTelevisionStore.accountID(first), b = LGTelevisionStore.accountID(second)
        precondition(store.items(account).map(\.id) == [a, b])
        let firstLAN = WebOSTVEndpoint(id: "one", host: "192.168.1.31", name: first.name, macAddress: first.macAddress)
        precondition(store.linkedID(firstLAN, accounts: account) == a)
        func configure(_ id: String?, _ endpoint: WebOSTVEndpoint) -> String? {
            store.configure(id: id, name: endpoint.name, host: endpoint.host, mac: endpoint.macAddress, endpoint: endpoint, accounts: account)
        }
        precondition(configure(a, firstLAN) == nil)
        precondition(configure(b, firstLAN) != nil)
        precondition(store.items(account).first?.canWake == true)
        let secondLAN = WebOSTVEndpoint(id: "two", host: "192.168.1.32", name: second.name, macAddress: nil)
        precondition(configure(nil, secondLAN) == nil)
        let localID = store.selectedID!
        let pairingID = store.links[localID]!.pairingID
        precondition(configure(b, secondLAN) == nil && store.links[localID] == nil)
        precondition(store.links[b]?.pairingID == pairingID && store.selectedID == b)
        precondition(store.items(account).allSatisfy { $0.volume == nil && !$0.connected })
        precondition(LGTelevisionStore(defaults: defaults).links == store.links)
        let airPlayID = "72:00:00:00:00:03"
        let old = TelevisionLink(id: "local.test", name: "LG TV", host: "192.168.1.33",
                                 mac: airPlayID, discoveryID: airPlayID, pairingID: "existing-pair")
        defaults.set(try! JSONEncoder().encode([old.id: old]), forKey: "lg.tv.localLinks.v1")
        let migrated = LGTelevisionStore(defaults: defaults)
        precondition(migrated.links[old.id]?.mac == nil && migrated.links[old.id]?.pairingID == old.pairingID)
        precondition(migrated.items([]).first?.canWake == false)
        let actualMAC = "10:00:00:00:00:03"
        precondition(migrated.configure(id: old.id, name: old.name, host: old.host, mac: actualMAC,
                                        endpoint: nil, accounts: []) == nil)
        let reopened = LGTelevisionStore(defaults: defaults)
        precondition(reopened.links[old.id]?.mac == actualMAC && reopened.items([]).first?.canWake == true)
        print("TV: distinct namesakes, wake address, unique endpoint bindings and pairing continuity verified.")
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
