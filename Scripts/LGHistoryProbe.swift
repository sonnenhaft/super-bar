import Foundation
import Security

// Read-only history check. Uses only Super Bar's LG Keychain records. The
// mobile session and the official ThinQ Connect PAT have separate audiences.
#if !HISTORY_PROBE_SUITE
@main
#endif
enum LGHistoryProbe {
    static let day = ChartHistory.formatter("yyyyMMdd")
    static let stamp = ChartHistory.formatter("yyyy-MM-dd HH:mm")

    static func failure(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecItemNotFound) {
            return "Super Bar Keychain item not found (\(ns.code))"
        }
        if error is CredentialStorageError { return "Super Bar Keychain permission unavailable" }
        if let lg = error as? LGError {
            if let range = lg.message.range(of: #"\bHTTP [1-5][0-9]{2}\b"#, options: .regularExpression) {
                return "LG request rejected (" + String(lg.message[range]) + ")"
            }
            if lg.message == "No supported ThinQ2 air conditioners in this account." { return lg.message }
            return "LG request failed or the response format is unavailable."
        }
        if ns.domain == NSURLErrorDomain { return "Network error \(ns.code)" }
        if ns.domain == NSOSStatusErrorDomain { return "Keychain error \(ns.code)" }
        return "Invalid response or unavailable credentials."
    }

    static func calendarDays(from start: Date, through end: Date) -> [Date] {
        let calendar = ChartHistory.calendar
        var date = calendar.startOfDay(for: start)
        var days: [Date] = []
        while date < end {
            days.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return days
    }

    private static let stampFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH",
                                       "yyyyMMddHHmmss", "yyyyMMddHHmm", "yyyyMMddHH"].map { ChartHistory.formatter($0) }
    static func timestamp(_ value: Any?) -> Date? {
        guard let text = (value as? String) ?? (value as? NSNumber)?.stringValue, (10...40).contains(text.count) else { return nil }
        if text.contains("T") {
            if let zoned = try? Date(text, strategy: .iso8601) { return zoned }
            if let zoned = try? Date(text, strategy: .iso8601.time(includingFractionalSeconds: true)) { return zoned }
        }
        let local = text.replacingOccurrences(of: "T", with: " ")
        for format in stampFormats {
            if let parsed = format.date(from: local), format.string(from: parsed) == local { return parsed }
        }
        return nil
    }

    private static func intradayTime(_ row: [String: Any]) -> Date? {
        for key in ["usedDate", "dateTime", "usageDate", "startDate", "date"] {
            if let stamp = timestamp(row[key]) { return stamp }
            guard let date = (row[key] as? String) ?? (row[key] as? NSNumber)?.stringValue,
                  let rawHour = CloudValue.number(row["hour"]), let hour = Int(exactly: rawHour), (0...23).contains(hour) else { continue }
            let minuteField = row["minute"] ?? row["min"]
            let secondField = row["second"]
            guard let minute = Int(exactly: CloudValue.number(minuteField ?? 0) ?? -1), (0...59).contains(minute),
                  let second = Int(exactly: CloudValue.number(secondField ?? 0) ?? -1), (0...59).contains(second) else { continue }
            if date.count == 8, let stamp = timestamp(date + String(format: "%02d%02d%02d", hour, minute, second)) { return stamp }
            if date.count == 10, let stamp = timestamp(date + String(format: " %02d:%02d:%02d", hour, minute, second)) { return stamp }
        }
        return nil
    }

    // The ThinQ2 mobile API requires type=period and one date per hourly request.
    // See ioBroker.lg-thinq/lib/helper.js, sendStaticRequest for device type 'air'.
    static func mobileRows(_ response: [String: Any]) -> [[String: Any]]? {
        if let rows = response["result"] as? [[String: Any]] { return rows }
        return object(response["result"] ?? [:])["item"] as? [[String: Any]]
    }

    static func officialEnergyProperty(_ profile: Any) -> Bool? {
        let root = object(profile), result = object(root["result"] ?? [:])
        // The official SDK exposes energy capabilities as result.property strings.
        guard let properties = (result["property"] ?? root["property"]) as? [String] else { return nil }
        return properties.contains("energyUsage")
    }

    static func describeMobileMetadata(_ response: [String: Any], rows: [[String: Any]]) {
        let containers = [response, object(response["result"] ?? [:])] + rows
        let units = Set(containers.flatMap { row in
            ["energyDataUnit", "unit"].compactMap { row[$0] as? String }
        }.map { value -> String in
            let unit = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["wh", "kwh"].contains(unit) ? unit : "other"
        })
        let operation = rows.compactMap { CloudValue.number($0["operationTime"]) }
        print("    Unit fields:", units.isEmpty ? "absent" : units.sorted().joined(separator: ", "),
              "· operationTime rows:", operation.count, "· positive:", operation.filter { $0 > 0 }.count)
    }

    static func dailyValues(_ rows: [[String: Any]], official: Bool, inheritedUnit: String?) -> [Date: (Double, String)] {
        let iso = ChartHistory.formatter("yyyy-MM-dd")
        var values: [Date: (Double, String)] = [:]
        for row in rows {
            guard let energy = CloudValue.number(row[official ? "energyUsage" : "energyData"]), energy >= 0 else { continue }
            let date = ["usedDate", "date", "usageDate", "startDate"].compactMap { key -> Date? in
                guard let text = (row[key] as? String) ?? (row[key] as? NSNumber)?.stringValue else { return nil }
                for formatter in [day, iso] {
                    if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
                }
                return nil
            }.first
            guard let date else { continue }
            let unit = (row["energyDataUnit"] as? String ?? row["unit"] as? String ?? inheritedUnit)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch unit {
            case "wh": values[date] = (energy, "Wh")
            case "kwh" where (energy * 1000).isFinite: values[date] = (energy * 1000, "Wh")
            case nil where official: values[date] = (energy, "Wh")
            default: values[date] = (energy, "raw")
            }
        }
        return values
    }

    static func reportDays(_ label: String, rows: [[String: Any]], official: Bool, inheritedUnit: String?, now: Date) {
        let calendar = ChartHistory.calendar, today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -29, to: today)!
        let expected = calendarDays(from: first, through: today.addingTimeInterval(1))
        let values = dailyValues(rows, official: official, inheritedUnit: inheritedUnit).filter { expected.contains($0.key) }
        let iso = ChartHistory.formatter("yyyy-MM-dd")
        for unit in ["Wh", "raw"] {
            for (partial, interval) in [(false, "day"), (true, "day_partial")] {
                let samples = values.filter { $0.value.1 == unit && ($0.key == today) == partial }.map { ($0.key, $0.value.0) }
                HistoryProbeWindow.export(label, samples: samples, unit: unit, interval: interval)
            }
        }
        print("  \(label): \(rows.count) provider rows, \(values.count)/30 dated days, missing \(30 - values.count).")
        for date in expected {
            let status = date == today ? " · current incomplete day" : ""
            if let (value, unit) = values[date] { print("    \(iso.string(from: date)): \(value) \(unit)\(status)") }
            else { print("    \(iso.string(from: date)): —\(status)") }
        }
        let complete = values.filter { $0.key < today && $0.value.1 == "Wh" }
        if !complete.isEmpty {
            print("    Known-unit sum for \(complete.count) completed days: \(complete.values.reduce(0) { $0 + $1.0 }) Wh.")
        }
        if values.values.contains(where: { $0.1 == "raw" }) {
            print("    Raw values retain the provider's unspecified unit.")
        }
    }

    struct HourlyResponse {
        var scaled = [(Date, Double)]()
        var unspecified = [(Date, Double)]()
        var invalid = 0
        mutating func collect(_ rows: [[String: Any]], sourceDay: Date, official: Bool, inheritedUnit: String?) {
            for row in rows {
                let key = official ? "energyUsage" : "energyData"
                let usage = row[key]
                guard let energy = CloudValue.number(usage), energy >= 0,
                      let date = intradayTime(row),
                      ChartHistory.calendar.isDate(date, inSameDayAs: sourceDay) else { invalid += 1; continue }
                let unit = (row["energyDataUnit"] as? String ?? row["unit"] as? String ?? inheritedUnit)?.lowercased()
                switch unit {
                case "wh": scaled.append((date, energy))
                case "kwh" where (energy * 1000).isFinite: scaled.append((date, energy * 1000))
                case nil where official: scaled.append((date, energy)) // LG SDK measures energyUsage in Wh.
                default: unspecified.append((date, energy))
                }
            }
        }
        static func closelySpaced(_ samples: [(Date, Double)]) -> [(Date, Double)] {
            let sorted = Dictionary(samples, uniquingKeysWith: { _, last in last }).sorted { $0.key < $1.key }
            var found: [Date: Double] = [:]
            for (left, right) in zip(sorted, sorted.dropFirst()) where right.key.timeIntervalSince(left.key) < 3600 {
                found[left.key] = left.value
                found[right.key] = right.value
            }
            return found.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        func report(_ label: String) {
            for (points, unit, suffix) in [(scaled, "Wh", ""), (unspecified, "raw", " (provider units unspecified)")] {
                guard !points.isEmpty || (unit == "Wh" && unspecified.isEmpty) else { continue }
                let completed = points.filter { $0.0.addingTimeInterval(3600) <= HistoryProbeWindow.end }
                HistoryProbeWindow.report(label + suffix, samples: completed, unit: unit, hourly: true)
                let current = points.filter { $0.0 < HistoryProbeWindow.end && $0.0.addingTimeInterval(3600) > HistoryProbeWindow.end }
                HistoryProbeWindow.export(label + suffix, samples: current, unit: unit, interval: "hour_partial")
                for (date, value) in current {
                    print("    Current incomplete hour \(stamp.string(from: date)): provider reports \(value) \(unit), provisional.")
                }
                let withinWindow = points.filter { HistoryProbeWindow.start <= $0.0 && $0.0 < HistoryProbeWindow.end }
                let fine = Self.closelySpaced(withinWindow)
                if !fine.isEmpty {
                    HistoryProbeWindow.report(label + " — метки из почасового запроса с шагом меньше часа; длительность замера не указана",
                                              samples: fine, unit: unit, hourly: false)
                }
            }
            if invalid > 0 { print("  Rows without a numeric value and a verified intraday timestamp on the requested date:", invalid) }
        }
    }

    static func mobile(network: URLSession, now: Date, check48h: Bool = false, check30d: Bool = false) async throws -> Bool {
        let vault = try HistoryProbeSession(key: "lg-session")
        let client = LGMobileClient(network: network, vault: vault)
        guard let devices = try await client.requestIfConfigured("devices", payload: nil) as? [[String: Any]] else {
            throw LGError(message: "Mobile ThinQ AC list unavailable.")
        }
        print("Mobile ThinQ: \(devices.count) supported air conditioners")
        if check48h || check30d {
            guard let session = try LGMobileCredentials.read(vault: vault) else { throw LGError(message: "Mobile session unavailable") }
            var headers = LGMobileHTTP.headers(country: session.country, client: session.client)
            headers["x-emp-token"] = session.accessToken
            headers["x-user-no"] = session.userNumber
            let isoDay = ChartHistory.formatter("yyyy-MM-dd")
            let dates = calendarDays(from: HistoryProbeWindow.start, through: now)
            var complete = true
            for (index, device) in devices.enumerated() {
                guard let id = device["deviceId"] as? String else { continue }
                let route = "service/aircon/\(try API.deviceComponent(id))/energy-history"
                let base = try LGMobileHTTP.endpoint(session.apiURL, route)
                if check30d {
                    let today = ChartHistory.calendar.startOfDay(for: now)
                    let first = ChartHistory.calendar.date(byAdding: .day, value: -29, to: today)!
                    var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    url.queryItems = [.init(name: "type", value: "period"), .init(name: "period", value: "day"),
                                      .init(name: "startDate", value: isoDay.string(from: first)), .init(name: "endDate", value: isoDay.string(from: today))]
                    do {
                        let raw = try await LGMobileHTTP(network: network).json(url.url!, headers: headers, stage: "daily energy history")
                        guard let rows = mobileRows(raw) else { throw LGError(message: "Missing daily list") }
                        describeMobileMetadata(raw, rows: rows)
                        reportDays("ThinQ2 AC \(index + 1) daily energy", rows: rows, official: false,
                                   inheritedUnit: raw["energyDataUnit"] as? String, now: now)
                    } catch { print("  ThinQ2 AC \(index + 1), daily:", failure(error)); complete = false }
                    continue
                }
                var series = HourlyResponse(), pages = 0
                for date in dates {
                    let key = isoDay.string(from: date)
                    var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    url.queryItems = [.init(name: "type", value: "period"), .init(name: "period", value: "hour"),
                                      .init(name: "startDate", value: key), .init(name: "endDate", value: key)]
                    do {
                        let raw = try await LGMobileHTTP(network: network).json(url.url!, headers: headers, stage: "energy history")
                        guard let rows = mobileRows(raw) else { throw LGError(message: "Missing hourly list") }
                        print("  ThinQ2 AC \(index + 1), \(key): \(rows.count) hourly response rows")
                        describeMobileMetadata(raw, rows: rows)
                        series.collect(rows, sourceDay: date, official: false, inheritedUnit: raw["energyDataUnit"] as? String)
                        pages += 1
                    } catch { print("  ThinQ2 AC \(index + 1), \(key):", failure(error)) }
                }
                if pages > 0 { series.report("ThinQ2 AC \(index + 1) hourly energy") }
                if pages != dates.count {
                    print("  Incomplete ThinQ2 AC \(index + 1) check: \(pages)/\(dates.count) calendar dates returned a history list.")
                    complete = false
                }
            }
            return complete
        }
        for (i, device) in devices.enumerated() {
            guard let id = device["deviceId"] as? String else { continue }
            let hour = RollingEnergy.lastHour(endingAt: now)
            for query in LGHistoryQuery.chartQueries(at: now) {
                let label = "AC \(i+1), \(query.period.rawValue), \(day.string(from: query.first))…\(day.string(from: query.last))"
                do {
                    let page = try await client.energyHistory(id, query: query)
                    let rows = page.records.filter {
                        query.period == .day || ($0.start <= now && $0.start.addingTimeInterval(3600) > hour.lowerBound)
                    }.sorted { $0.start < $1.start }
                    let bounds = [rows.first, rows.last].compactMap { $0.map { stamp.string(from: $0.start) } }
                    print("\(label): \(page.rowCount) provider rows, \(rows.count) dated energy rows in requested period (\(bounds.joined(separator: " … "))), \(rows.filter { $0.wattHours == nil }.count) unscaled. Hourly values cover calendar-hour buckets.")
                } catch { print(label, failure(error)) }
            }
        }
        return true
    }

    static func official(network: URLSession, now: Date, check48h: Bool = false, check30d: Bool = false) async throws -> Bool {
        let vault = try HistoryProbeSession(key: "lg-token")
        guard let data = try vault.read("lg-token"), let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LGError(message: "Invalid ThinQ Connect PAT.")
        }
        let apiKey = try API.connectHistoryAPIKey(vault: vault)
        let preferences = UserDefaults(suiteName: "local.SuperBar")!
        let region = preferences.string(forKey: "region") ?? "kic"
        let country = preferences.string(forKey: "country") ?? "PH"
        guard ["aic", "eic", "kic"].contains(region), country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw LGError(message: "Invalid ThinQ Connect region or country.")
        }
        let client = preferences.string(forKey: "client") ?? UUID().uuidString
        func get(_ path: String, params: [URLQueryItem] = []) async throws -> Any {
            let base = try LGMobileHTTP.endpoint("https://api-" + region + ".lgthinq.com", path)
            var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            if !params.isEmpty { url.queryItems = params }
            var message = UUID().uuid
            let messageID = withUnsafeBytes(of: &message) { Data($0).base64EncodedString() }
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let headers = ["Authorization": "Bearer " + token, "x-country": country, "x-client-id": client,
                           "x-message-id": messageID, "x-service-phase": "OP", "x-api-key": apiKey]
            let result = try await LGMobileHTTP(network: network).json(url.url!, headers: headers, stage: "ThinQ Connect")
            guard let response = result["response"] else { throw LGError(message: "Missing ThinQ Connect response.") }
            return response
        }
        guard let list = try await get("devices") as? [[String: Any]] else { throw LGError(message: "Missing official device list.") }
        let devices = list.filter { object($0["deviceInfo"] ?? [:])["deviceType"] as? String == "DEVICE_AIR_CONDITIONER" }
        print("ThinQ Connect: \(devices.count) air conditioners")
        var complete = true
        for (i, device) in devices.enumerated() {
            guard let id = device["deviceId"] as? String else { continue }
            let path = "devices/energy/\(try API.deviceComponent(id))/"
            do {
                let profile = try await get(path + "profile")
                let advertised = officialEnergyProperty(profile).map { $0 ? "yes" : "no" } ?? "unrecognized property list"
                print("AC \(i+1) official energy profile received, energyUsage advertised: \(advertised)")
            } catch { print("AC \(i+1) energy profile:", failure(error)) }
            if check30d {
                let today = ChartHistory.calendar.startOfDay(for: now)
                let first = ChartHistory.calendar.date(byAdding: .day, value: -29, to: today)!
                do {
                    let response = try await get(path + "usage", params: [.init(name: "property", value: "energyUsage"),
                        .init(name: "period", value: "DAILY"), .init(name: "startDate", value: day.string(from: first)),
                        .init(name: "endDate", value: day.string(from: today))])
                    guard let rows = find("dataList", in: response) as? [[String: Any]] else { throw LGError(message: "Missing daily list") }
                    reportDays("ThinQ Connect AC \(i + 1) daily energy", rows: rows, official: true, inheritedUnit: nil, now: now)
                } catch { print("  ThinQ Connect AC \(i + 1), DAILY:", failure(error)); complete = false }
                continue
            }
            if check48h {
                var series = HourlyResponse(), pages = 0
                // DAILY and MONTHLY are documented by LG's SDK. Check HOURLY
                // empirically and only accept rows with genuine time-of-day data.
                let dates = calendarDays(from: HistoryProbeWindow.start, through: now)
                for date in dates {
                    let key = day.string(from: date)
                    do {
                        let response = try await get(path + "usage", params: [.init(name: "property", value: "energyUsage"),
                            .init(name: "period", value: "HOURLY"), .init(name: "startDate", value: key), .init(name: "endDate", value: key)])
                        guard let rows = find("dataList", in: response) as? [[String: Any]] else { throw LGError(message: "Missing dataList") }
                        print("  ThinQ Connect AC \(i + 1), \(key), HOURLY capability probe: \(rows.count) response rows")
                        series.collect(rows, sourceDay: date, official: true, inheritedUnit: nil)
                        pages += 1
                    } catch { print("  ThinQ Connect AC \(i + 1), \(key), HOURLY capability probe:", failure(error)) }
                }
                if pages > 0 { series.report("ThinQ Connect AC \(i + 1) HOURLY capability probe") }
                if pages != dates.count {
                    print("  Incomplete ThinQ Connect AC \(i + 1) check: \(pages)/\(dates.count) calendar dates returned a history list.")
                    complete = false
                }
                continue
            }
            for query in LGHistoryQuery.chartQueries(at: now) {
                if query.period == .hour && query.last < ChartHistory.calendar.startOfDay(for: now.addingTimeInterval(-3600)) { continue }
                // HOURLY is a capability probe. DAILY and MONTHLY are used by the official SDK integration.
                let period = query.period == .hour ? "HOURLY" : "DAILY"
                let first = day.string(from: query.first), last = day.string(from: query.last)
                do {
                    let response = try await get(path + "usage", params: [.init(name: "property", value: "energyUsage"),
                        .init(name: "period", value: period), .init(name: "startDate", value: first), .init(name: "endDate", value: last)])
                    guard let rows = find("dataList", in: response) as? [[String: Any]] else { throw LGError(message: "Missing energy dataList.") }
                    let dated = rows.compactMap { row -> String? in
                        guard CloudValue.number(row["energyUsage"]) != nil else { return nil }
                        for key in ["date", "usedDate", "startDate", "dateTime", "usageDate"] {
                            if let date = row[key].map(String.init(describing:)), date.range(of: "^[0-9T:+. -]{6,30}$", options: .regularExpression) != nil { return date }
                        }
                        return nil
                    }.sorted()
                    print("AC \(i+1) \(period) \(first)…\(last): \(rows.count) rows, \(dated.count) dated energyUsage (Wh), \(dated.first ?? "—") … \(dated.last ?? "—")")
                } catch { print("AC \(i+1) \(period) \(first)…\(last):", failure(error)) }
            }
        }
        return check48h || check30d ? complete : true
    }

    static func run30d() async -> Bool {
        let network = CloudRedirects.session(), now = HistoryProbeWindow.end
        defer { network.invalidateAndCancel() }
        print("LG · 30 calendar days including today · Asia/Manila")
        var mobileRead = false, officialRead = false
        do { mobileRead = try await mobile(network: network, now: now, check30d: true) } catch { print("Mobile ThinQ:", failure(error)) }
        do { officialRead = try await official(network: network, now: now, check30d: true) } catch { print("ThinQ Connect:", failure(error)) }
        return mobileRead || officialRead
    }

    // Legacy read-only history protocol implemented in ioBroker.lg-thinq:
    // https://github.com/TA2k/ioBroker.lg-thinq/blob/master/lib/helper.js#L895-L997
    // Its middle field is operating minutes, not a minute-resolution timestamp.
    static func legacyPowerRows(_ value: Any?) -> [(slot: String, minutes: Double, energy: Double)] {
        guard let text = value as? String, text.utf8.count <= 100_000 else { return [] }
        return text.split(separator: "/").prefix(1000).compactMap { entry in
            let fields = entry.split(separator: "_", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0].range(of: "^[0-9]{1,14}$", options: .regularExpression) != nil,
                  let minutes = Double(fields[1]), minutes.isFinite, minutes >= 0,
                  let energy = Double(fields[2]), energy.isFinite, energy >= 0 else { return nil }
            return (String(fields[0]), minutes, energy)
        }
    }

    static func legacyPeriod(hourly: Bool, first: Date, last: Date) -> String {
        // Hour_ uses an exclusive next-midnight end; Day_ takes the last date.
        let end = hourly ? ChartHistory.calendar.date(byAdding: .day, value: 1, to: first)! : last
        return (hourly ? "Hour_" : "Day_") + day.string(from: first) + "T000000Z/" + day.string(from: end) + "T000000Z"
    }

    static func runExplore() async -> Bool {
        print("LG alternate API: legacy aircon/inquiryPowerData. ThinQ2 device compatibility is unverified.")
        print("Only known read-only Hour_/Day_ requests are tested; operating minutes are not minute-by-minute history.")
        let network = CloudRedirects.session()
        defer { network.invalidateAndCancel() }
        do {
            let vault = try HistoryProbeSession(key: "lg-session")
            let client = LGMobileClient(network: network, vault: vault)
            guard let devices = try await client.requestIfConfigured("devices", payload: nil) as? [[String: Any]],
                  let session = try LGMobileCredentials.read(vault: vault) else {
                throw LGError(message: "Mobile session unavailable")
            }
            let http = LGMobileHTTP(network: network)
            var headers = LGMobileHTTP.headers(country: session.country, client: session.client)
            let gateway = try await http.json(LGMobileHTTP.url("https://route.lgthinq.com:46030/v1/service/application/gateway-uri"),
                                              headers: headers, stage: "legacy gateway")
            guard let base = object(gateway["result"] ?? [:])["thinq1Uri"] as? String else {
                print("  Legacy gateway not advertised; no alternate requests sent.")
                return false
            }
            let endpoint = try LGMobileHTTP.endpoint(base, "aircon/inquiryPowerData")
            headers["x-emp-token"] = session.accessToken
            headers["x-user-no"] = session.userNumber
            let now = HistoryProbeWindow.end, calendar = ChartHistory.calendar
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let first = calendar.date(byAdding: .day, value: -29, to: today)!
            let iso = ChartHistory.formatter("yyyy-MM-dd")
            var received = false
            for (index, device) in devices.enumerated() {
                guard let id = device["deviceId"] as? String else { continue }
                func probe(hourly: Bool, first: Date, last: Date) async -> Bool {
                    let label = "Legacy AC \(index + 1) \(hourly ? "Hour_" : "Day_") \(iso.string(from: first))…\(iso.string(from: last))"
                    do {
                        let response = try await http.json(endpoint, headers: headers,
                            payload: ["lgedmRoot": ["deviceId": id, "period": legacyPeriod(hourly: hourly, first: first, last: last)]],
                            stage: "legacy energy history")
                        let result = object(response["lgedmRoot"] ?? [:])
                        guard result["returnCd"] as? String == "0000" else {
                            let code = (result["returnCd"] as? String).flatMap {
                                $0.range(of: "^[0-9]{4}$", options: .regularExpression) != nil ? $0 : nil
                            } ?? "unrecognized"
                            print("  \(label): return code \(code), no verified energy rows.")
                            return false
                        }
                        let rows = legacyPowerRows(result["powerData"])
                        print("  \(label): \(rows.count) numeric rows; energy unit not supplied by this response.")
                        for row in rows {
                            let slot: String
                            if hourly, let hour = Int(row.slot), (0...23).contains(hour) {
                                slot = iso.string(from: first) + String(format: " %02d:00", hour)
                            } else { slot = "provider slot " + row.slot }
                            print("    \(slot): energy \(row.energy) raw · operation \(row.minutes) minutes")
                        }
                        if !hourly { print("    Day_ slots are retained as returned; no missing dates or totals are inferred.") }
                        return !rows.isEmpty
                    } catch { print("  \(label):", failure(error)); return false }
                }
                let hasHour = await probe(hourly: true, first: yesterday, last: yesterday)
                let hasDays = await probe(hourly: false, first: first, last: today)
                received = received || hasHour || hasDays
                guard hasHour else {
                    print("  Legacy AC \(index + 1): remaining hourly dates skipped after the first hourly probe returned no usable data.")
                    continue
                }
                for date in calendarDays(from: HistoryProbeWindow.start, through: now) where date != yesterday {
                    _ = await probe(hourly: true, first: date, last: date)
                }
            }
            return received
        } catch { print("LG alternate API:", failure(error)); return false }
    }

    static func run48h() async -> Bool {
        let network = CloudRedirects.session(), now = HistoryProbeWindow.end
        defer { network.invalidateAndCancel() }
        print("LG 48 h, Manila. ThinQ2 requests one calendar day at a time. No verified minute-level energy archive route for either LG API.")
        var mobileRead = false, officialRead = false
        do { mobileRead = try await mobile(network: network, now: now, check48h: true) } catch { print("Mobile ThinQ:", failure(error)) }
        do { officialRead = try await official(network: network, now: now, check48h: true) } catch { print("ThinQ Connect:", failure(error)) }
        return mobileRead || officialRead
    }

    static func main() async {
        if CommandLine.arguments.contains("--explore") { if !(await runExplore()) { exit(1) }; return }
        if CommandLine.arguments.contains("--30d") { if !(await run30d()) { exit(1) }; return }
        if CommandLine.arguments.contains("--48h") { if !(await run48h()) { exit(1) }; return }
        let network = CloudRedirects.session(), date = Date()
        defer { network.invalidateAndCancel() }
        var connected = false
        print("LG provider history at \(stamp.string(from: date)) Asia/Manila")
        do { _ = try await mobile(network: network, now: date); connected = true } catch { print("Mobile ThinQ:", failure(error)) }
        do { _ = try await official(network: network, now: date); connected = true } catch { print("ThinQ Connect:", failure(error)) }
        if !connected { exit(1) }
    }
}
