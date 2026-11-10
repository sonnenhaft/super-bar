import Foundation

enum EnergySync {
    typealias Request = ([String: Any], String) throws -> [String: Any]

    static func refresh(devices: [[String: Any]], cloud: TCLCloud, directory: URL) {
        refresh(devices: devices, directory: directory, now: Date()) { device, path in
            try cloud.statistics(device: device, path: path)
        }
    }

    static func refresh(devices: [[String: Any]], directory: URL, now: Date, request: Request) {
        let file = directory.appendingPathComponent("tcl-energy.json")
        let stored = EnergyCache.read(from: file)
        let old = Dictionary((stored?.devices ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let stamp = now.timeIntervalSince1970
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.calendar = calendar
        iso.timeZone = calendar.timeZone
        iso.dateFormat = "yyyy-MM-dd"
        iso.isLenient = false
        let today = iso.string(from: now)
        let yesterday = iso.string(from: calendar.date(byAdding: .day, value: -1, to: now)!)
        let start = iso.string(from: calendar.date(byAdding: .day, value: -6, to: now)!)
        let cutoff = iso.string(from: calendar.date(byAdding: .day, value: -94, to: now)!)
        let legacyWeek = start.replacingOccurrences(of: "-", with: "") + "-" + today.replacingOccurrences(of: "-", with: "")
        var reports: [DailyEnergyReport] = []

        for device in devices {
            guard let id = string(device, ["deviceId", "device_id", "id"]) else { continue }
            let name = string(device, ["nickName", "nick_name", "name", "deviceName", "device_name"]) ?? id
            let previous = old[id]
            let timeOfDay = stamp - calendar.startOfDay(for: now).timeIntervalSince1970
            let nearCutoff = abs(timeOfDay - 9 * 3600) <= 180
            let retry: TimeInterval = nearCutoff ? 50 : 900
            let crossedNine = previous?.attempted.map { $0 < EnergyPeriod.start(at: now) } ?? false
            let crossedMidnight = previous?.attempted.map { $0 < calendar.startOfDay(for: now).timeIntervalSince1970 } ?? false
            if let previous, previous.name == name, previous.meters != nil, !crossedNine, !crossedMidnight,
               let attempted = previous.attempted, (0..<retry).contains(stamp - attempted) {
                reports.append(previous)
                continue
            }
            var readings: [String: Double]?
            do {
                // TCL Home 7 returns daily kWh in monthly groups. Some older
                // units only answer the week endpoint on the regional server.
                let reply = try request(device, "/v1/ac/statistics/electricity/summary?timeType=2")
                readings = parse(reply, legacy: false, formatter: iso, cutoff: cutoff, today: today)
            } catch let e as URLError where [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .timedOut, .cancelled].contains(e.code) {
                reports.append(DailyEnergyReport(id: id, name: name, state: "error", attempted: stamp,
                                                 updated: previous?.updated ?? 0, days: previous?.days ?? [],
                                                 meters: previous?.meters ?? [], hours: previous?.hours ?? [], lastHourlyRequest: previous?.lastHourlyRequest))
                continue
            } catch { /* Try the legacy route on service/HTTP errors. */ }
            if readings?.isEmpty != false {
                let pathChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                if let segment = id.addingPercentEncoding(withAllowedCharacters: pathChars),
                   let reply = try? request(device, "/v3/ac/\(segment)/power/consumption/info/?week=\(legacyWeek)"),
                   let fallback = parse(reply, legacy: true, formatter: iso, cutoff: cutoff, today: today) {
                    readings = fallback
                }
            }
            var totals = Dictionary((previous?.days ?? []).filter { $0.day >= cutoff && $0.day <= today }
                .map { ($0.day, $0.kwh) }, uniquingKeysWith: { _, last in last })
            totals.merge(readings ?? [:]) { _, newest in newest }
            let days = totals.sorted { $0.key < $1.key }.suffix(95).map { EnergyDay(day: $0.key, kwh: $0.value) }
            var meters = (previous?.meters ?? []).filter { $0.at >= stamp - 3 * 86400 && $0.at <= stamp }
            if let nowKWh = readings?[today] {
                meters.append(MeterObservation(at: stamp, today: nowKWh, yesterday: readings?[yesterday]))
            }
            var hours = Dictionary((previous?.hours ?? []).filter { $0.start >= stamp - 3 * 86400 }
                .map { ($0.start, $0) }, uniquingKeysWith: { _, last in last })
            var hourAttempt = previous?.lastHourlyRequest
            if let readings, !readings.isEmpty, hourAttempt == nil || stamp - hourAttempt! >= 3600 || stamp < hourAttempt! {
                hourAttempt = stamp
                if let reply = try? request(device, "/v1/ac/statistics/electricity/summary?timeType=1") {
                    for entry in EnergyPeriod.confirmedHours(reply, calendarTotals: readings, now: now) { hours[entry.start] = entry }
                }
            }
            reports.append(DailyEnergyReport(id: id, name: name, state: readings.map { $0.isEmpty ? "empty" : "ok" } ?? "error",
                                             attempted: stamp, updated: readings == nil ? (previous?.updated ?? 0) : stamp, days: days,
                                             meters: Array(meters.suffix(400)), hours: hours.values.sorted { $0.start < $1.start },
                                             lastHourlyRequest: hourAttempt))
        }
        let cache = EnergyCache(devices: reports)
        if cache != stored, let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private static func string(_ device: [String: Any], _ keys: [String]) -> String? {
        keys.compactMap { device[$0] as? String }.first { !$0.isEmpty }
    }

    private static func parse(_ reply: [String: Any], legacy: Bool, formatter: DateFormatter,
                              cutoff: String, today: String) -> [String: Double]? {
        guard EnergyHistory.number(reply["code"]) == 0, let data = reply["data"] as? [String: Any] else { return nil }
        let entries: [[String: Any]]
        if legacy {
            guard let rows = data["consumptionDetails"] as? [[String: Any]] else { return nil }
            entries = rows
        } else {
            let groups = data["ecoDetails"] as? [[String: Any]] ?? []
            entries = groups.flatMap { $0["dataList"] as? [[String: Any]] ?? [] }
        }
        var result: [String: Double] = [:]
        for entry in entries {
            guard let day = entry[legacy ? "date" : "time"] as? String, day.count == 10,
                  day >= cutoff, day <= today,
                  let date = formatter.date(from: day), formatter.string(from: date) == day else { continue }
            let value = legacy ? EnergyHistory.number(entry["consumption"]) :
                                 (EnergyHistory.number(entry["totalElectricity"]) ?? EnergyHistory.number(entry["electricity"]))
            if let value, value >= 0 { result[day] = value }
        }
        return result
    }
}
