import Foundation

private extension TuyaCloud {
    // snapshot() loads the Keychain session and handles its normal renewal.
    // If a long paginated read outlives that session, refresh it once.
    func readHistoryPage(_ action: String, data: [String: Any], version: String = "1.0") async throws -> Any {
        do { return try await request(action, data: data, version: version) }
        catch TuyaError.expired {
            _ = try await snapshot()
            return try await request(action, data: data, version: version)
        }
    }
}

#if !HISTORY_PROBE_SUITE
@main
#endif
enum TuyaHistoryProbe {
    private enum LogError: String, Error {
        case response = "Unexpected log format."
        case duplicate = "The provider repeated the previous page."
        case timestamp = "Invalid timestamp or data point ID in a log row."
        case incomplete = "The provider indicated another page but returned no rows."
        case cursor = "More than 1000 records share one second; complete pagination could not be verified."
        case offsetLimit = "Reached the documented 4000-record offset limit. Older reports remain unverified."
        case window = "The provider returned records outside the requested time window. Older history remains unverified."
    }
    private static func failure(_ error: Error) -> String {
        if let error = error as? LogError { return error.rawValue }
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain { return "Keychain lookup failed (\(ns.code))" }
        if error is CredentialStorageError { return "Could not access the Super Bar credentials in Keychain." }
        if let error = error as? TuyaError {
            switch error {
            case .signIn, .expired: return "Smart Life sign-in required."
            case .message(let message) where message == "Could not connect to Tuya.": return message
            case .message(let message) where message.range(of: "^Tuya rejected the request \\([A-Za-z0-9_-]{1,64}\\)\\.$", options: .regularExpression) != nil: return message
            default: return "Tuya rejected the request or returned an unreadable response."
            }
        }
        return "Request failed (\(ns.code))."
    }

    static func hourly(_ cloud: TuyaCloud, meter: TuyaDevice, from start: Date, to end: Date) async -> Bool {
        guard let dp = meter.historyDP, let zone = meter.timeZoneID.flatMap(TimeZone.init(identifier:)) else {
            print("Hourly energy unavailable: meter has no supported energy DP or reported timezone.")
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = ChartHistory.formatter("yyyyMMdd", zone: zone)
        let hour = ChartHistory.formatter("yyyyMMddHH", zone: zone)
        var date = calendar.startOfDay(for: start)
        var values: [(Date, Double)] = []
        var failed = false
        while date < end {
            let key = day.string(from: date)
            do {
                let raw = try await cloud.readHistoryPage("tuya.m.dp.rang.stat.hour.list",
                    data: ["devId": meter.id, "dpId": dp, "date": key, "type": "minux", "auto": 2])
                guard let outer = raw as? [String: Any] else { throw TuyaError.message("Invalid hourly payload.") }
                let result = outer["result"] as? [String: Any] ?? outer
                guard result.isEmpty || result.keys.contains(where: { $0.count == 10 && $0.allSatisfy(\.isNumber) }) else {
                    throw TuyaError.message("Invalid hourly payload.")
                }
                for (timeKey, rawValue) in result {
                    guard timeKey.count == 10, timeKey.hasPrefix(key), let time = hour.date(from: timeKey),
                          hour.string(from: time) == timeKey, let kWh = CloudValue.number(rawValue), kWh >= 0,
                          time < end, time.addingTimeInterval(3600) > start else { continue }
                    if time.addingTimeInterval(3600) <= end { values.append((time, kWh)) }
                    else { print("  Partial current calendar hour (\(key), meter time): \(kWh) kWh so far") }
                }
            } catch {
                print("  Hourly API \(key):", failure(error))
                failed = true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { return false }
            date = next
        }
        HistoryProbeWindow.report(failed ? "Hourly energy (partial query)" : "Hourly energy",
                                  samples: values, unit: "kWh", hourly: true)
        return !failed
    }

    struct Report {
        let millis: Int64
        let dp: Int
        let value: Any?
    }

    private struct ReportID: Hashable {
        let millis: Int64
        let dp: Int
        let value: Data
        init(_ report: Report) throws {
            millis = report.millis
            dp = report.dp
            value = try JSONSerialization.data(withJSONObject: report.value ?? NSNull(),
                                               options: [.fragmentsAllowed, .sortedKeys])
        }
    }

    // Some accounts repeat offset=0 at every offset and return a different
    // ordering from sortType. Split full windows into disjoint time ranges
    // until each fits one response, keeping all same-second records together.
    // Only a saturated single second needs offset pagination (up to 1000).
    static func powerLog(from start: Date, to end: Date, fetch: (Int64, Int64, Int, Int) async throws -> Any,
                         receive: ([Report]) -> Void) async throws -> Int {
        guard let firstMillis = Int64(exactly: ceil(start.timeIntervalSince1970 * 1000)),
              let upper = Int64(exactly: ceil(end.timeIntervalSince1970 * 1000)),
              firstMillis >= 0, firstMillis < upper else { throw LogError.timestamp }
        // The API response can have second precision even for a millisecond
        // query. Include that first second, then filter to the original range.
        let lower = firstMillis - firstMillis % 1000
        var pending = [(lower, upper - 1)]
        var observed = Set<ReportID>()
        var pages = 0
        while let (from, through) = pending.popLast() {
            var offset = 0
            var previousPage: Set<ReportID>?
            while true {
                let limit = min(100, 1000 - offset)
                let result = try await fetch(from, through, offset, limit)
                guard let page = result as? [String: Any], let rows = page["dps"] as? [[String: Any]], rows.count <= limit else {
                    throw LogError.response
                }
                pages += 1
                let reports = try rows.map { row -> Report in
                    guard let time = CloudValue.date(row["timeStamp"]),
                          let millis = Int64(exactly: (time.timeIntervalSince1970 * 1000).rounded()),
                          let id = CloudValue.number(row["dpId"]).flatMap(Int.init(exactly:)) else {
                        throw LogError.timestamp
                    }
                    guard from <= millis, millis <= through else { throw LogError.window }
                    return Report(millis: millis, dp: id, value: row["value"])
                }
                let identities = try reports.map(ReportID.init)
                let pageSet = Set(identities)
                guard previousPage != pageSet || rows.isEmpty else { throw LogError.duplicate }
                previousPage = pageSet
                let fresh = zip(reports, identities).compactMap { report, identity -> Report? in
                    guard firstMillis <= report.millis, report.millis < upper,
                          observed.insert(identity).inserted else { return nil }
                    return report
                }
                receive(fresh)
                offset += rows.count
                let total = CloudValue.number(page["total"]).flatMap(Int.init(exactly:))
                let next = page["hasNext"] as? Bool
                let more = next == true || (total.map { $0 > offset } ?? (next == nil && rows.count == limit))
                if !more { break }
                guard !rows.isEmpty else { throw LogError.incomplete }
                let firstSecond = from / 1000
                let lastSecond = through / 1000
                if firstSecond < lastSecond {
                    let middle = (firstSecond + (lastSecond - firstSecond + 1) / 2) * 1000
                    pending.append((from, middle - 1))
                    pending.append((middle, through))
                    break
                }
                guard offset < 1000 else { throw LogError.cursor }
            }
        }
        return pages
    }

    // Official APIs and schemas:
    // https://github.com/tuya/tuya-panel-sdk/blob/main/packages/tuya-panel-api/src/common/statistic.ts
    // https://github.com/tuya/tuya-panel-sdk/blob/main/packages/tuya-panel-api/src/common/interface.ts
    // The device-query example uses timeStamp=0 and a numeric millisecond timeStr:
    // https://airtake-public-data-1254153901.cos.ap-shanghai.myqcloud.com/goat/pdf/1614322332100/Data%20Statistics_Tuya%20Smart_Documentation.pdf
    static func deviceLog(from start: Date, to end: Date,
                          fetch: (Int64, Int64, Int, String?, String?) async throws -> Any,
                          receive: ([Report]) -> Void) async throws -> Int {
        var firstKey: String?, lastKey: String?
        return try await powerLog(from: start, to: end) { lower, upper, offset, limit in
            if offset == 0 { firstKey = nil; lastKey = nil }
            else if firstKey == nil || lastKey == nil { throw LogError.cursor }
            let raw = try await fetch(lower, upper, limit, firstKey, lastKey)
            guard let rows = raw as? [[String: Any]], rows.count <= limit else { throw LogError.response }
            firstKey = (rows.first?["rowkey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            lastKey = (rows.last?["rowkey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let normalized = rows.map { row -> [String: Any] in
                var result = row
                if CloudValue.date(row["timeStamp"]) == nil, CloudValue.date(row["timeStr"]) != nil {
                    result["timeStamp"] = row["timeStr"]
                }
                return result
            }
            return ["dps": normalized, "hasNext": rows.count == limit]
        } receive: { receive($0) }
    }

    // This older API has no time-bound parameters. Keep the full returned page
    // for duplicate detection, then retain only observations in our 48h window.
    static func reportedLog(from start: Date, to end: Date,
                            fetch: (Int, Int) async throws -> Any,
                            receive: ([Report]) -> Void) async throws -> Int {
        var offset = 0, pages = 0
        var observed = Set<ReportID>()
        while offset < 4000 {
            let limit = min(100, 4000 - offset)
            let raw = try await fetch(offset, limit)
            guard let result = raw as? [String: Any], let rows = result["dps"] as? [[String: Any]],
                  rows.count <= limit else { throw LogError.response }
            pages += 1
            var fresh = [Report]()
            for row in rows {
                guard let date = CloudValue.date(row["timeStamp"]),
                      let millis = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()),
                      let dp = CloudValue.number(row["dpId"]).flatMap(Int.init(exactly:)) else { throw LogError.timestamp }
                let report = Report(millis: millis, dp: dp, value: row["value"])
                if try observed.insert(ReportID(report)).inserted { fresh.append(report) }
            }
            guard rows.isEmpty || !fresh.isEmpty else { throw LogError.duplicate }
            receive(fresh.filter {
                let date = Date(timeIntervalSince1970: Double($0.millis) / 1000)
                return start <= date && date < end
            })
            offset += rows.count
            let total = CloudValue.number(result["total"]).flatMap(Int.init(exactly:))
            let next = result["hasNext"] as? Bool
            let more = next == true || (total.map { $0 > offset } ?? (next == nil && rows.count == limit))
            if !more { return pages }
            guard !rows.isEmpty else { throw LogError.incomplete }
        }
        throw LogError.offsetLimit
    }

    enum DetailAPI: String {
        case current = "tuya.m.smart.operate.all.log"
        case reported = "m.smart.operate.log"
        case device = "tuya.m.device.query.device.log"
    }

    static func detail(_ cloud: TuyaCloud, meter: TuyaDevice, from start: Date, to end: Date,
                       api: DetailAPI = .current) async -> Bool {
        let ids = Set([meter.powerDP?.id, meter.historyDP].compactMap { $0 })
        guard !ids.isEmpty else { print("No supported power or energy DP in the meter schema."); return false }
        var power: [(Date, Double)] = [], counter: [(Date, Double)] = []
        var invalid = 0, complete = true, requests = 0
        print("Reading timestamped power and energy DP logs: \(api.rawValue)…")
        let dpIDs = ids.sorted().map(String.init).joined(separator: ",")
        let receive: ([Report]) -> Void = { rows in
            for row in rows {
                let time = Date(timeIntervalSince1970: Double(row.millis) / 1000)
                if let dp = meter.powerDP, row.dp == dp.id, let watts = dp.watts(row.value) { power.append((time, watts)) }
                else if row.dp == meter.historyDP, let value = CloudValue.number(row.value), value >= 0 { counter.append((time, value)) }
                else { invalid += 1 }
            }
        }
        func progress() {
            requests += 1
            if requests.isMultiple(of: 50) { print("  Reading page \(requests)…") }
        }
        do {
            let pages: Int
            switch api {
            case .current:
                pages = try await powerLog(from: start, to: end) { lower, upper, offset, limit in
                    progress()
                    return try await cloud.readHistoryPage(api.rawValue, data: ["devId": meter.id,
                    "dpIds": dpIDs, "sortType": "DESC",
                    "startTime": String(lower), "endTime": String(upper), "offset": offset, "limit": limit])
                } receive: { receive($0) }
            case .reported:
                pages = try await reportedLog(from: start, to: end) { offset, limit in
                    progress()
                    return try await cloud.readHistoryPage(api.rawValue, data: ["devId": meter.id,
                        "dpIds": dpIDs, "sortType": "DESC", "offset": offset, "limit": limit], version: "2.0")
                } receive: { receive($0) }
            case .device:
                print("  Probing the documented device-query method with millisecond time bounds.")
                pages = try await deviceLog(from: start, to: end) { lower, upper, limit, firstKey, lastKey in
                    progress()
                    var data: [String: Any] = ["devId": meter.id, "dpIds": dpIDs, "size": limit,
                        "startTime": String(lower), "endTime": String(upper), "reverse": 2, "rowType": 1]
                    if let firstKey, let lastKey { data["startRowKey"] = firstKey; data["endRowKey"] = lastKey }
                    return try await cloud.readHistoryPage(api.rawValue, data: data)
                } receive: { receive($0) }
            }
            print("Tuya DP requests finished (\(pages) pages). Returned coverage is shown below.")
            if power.isEmpty && counter.isEmpty {
                print("No DP measurements returned; retention of the requested history is unconfirmed.")
            }
        } catch {
            complete = false
            print("Tuya DP log incomplete:", failure(error))
        }
        if meter.powerDP != nil { HistoryProbeWindow.report("\(api.rawValue): power", samples: power, unit: "W", hourly: false) }
        else { print("No supported power DP in the meter schema.") }
        if meter.historyDP != nil {
            HistoryProbeWindow.report("\(api.rawValue): energy counter", samples: counter, unit: "raw counter units", hourly: false)
        }
        if invalid > 0 { print("  Additional rows without a usable numeric reading:", invalid) }
        return complete
    }

    static func runExplore() async -> Bool {
        do {
            let cloud = TuyaCloud(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                  source: nil, vault: try HistoryProbeSession(key: "tuya-session"))
            guard let meter = try await cloud.snapshot().meter else {
                print("No main consumption meter selected in Super Bar."); return false
            }
            print("Alternative mobile APIs from Tuya's official panel SDK; using the saved Smart Life session.")
            let device = await detail(cloud, meter: meter, from: HistoryProbeWindow.start, to: HistoryProbeWindow.end, api: .device)
            let reported = await detail(cloud, meter: meter, from: HistoryProbeWindow.start, to: HistoryProbeWindow.end, api: .reported)
            print("Tuya also documents 15-minute statistics in ThingSmartBusinessRequest. Its HTTP action is not published in that SDK guide, so no guessed action was sent.")
            return device || reported
        } catch { print("Tuya alternative API check:", failure(error)); return false }
    }

    static func run48h() async -> Bool {
        do {
            let cloud = TuyaCloud(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                  source: nil, vault: try HistoryProbeSession(key: "tuya-session"))
            guard let meter = try await cloud.snapshot().meter else {
                print("No main consumption meter selected in Super Bar."); return false
            }
            let hours = await hourly(cloud, meter: meter, from: HistoryProbeWindow.start, to: HistoryProbeWindow.end)
            let logs = await detail(cloud, meter: meter, from: HistoryProbeWindow.start, to: HistoryProbeWindow.end)
            return hours && logs
        } catch { print("Tuya live check:", failure(error)); return false }
    }

    static func daily(_ cloud: TuyaCloud, meter: TuyaDevice) async -> Bool {
        guard let dp = meter.historyDP, let zone = meter.timeZoneID.flatMap(TimeZone.init(identifier:)) else {
            print("Daily energy unavailable: meter has no supported energy DP or reported timezone.")
            return false
        }
        let format = ChartHistory.formatter("yyyyMMdd")
        let dates = (0..<30).compactMap {
            ChartHistory.calendar.date(byAdding: .day, value: $0, to: HistoryProbeWindow.dayStart)
        }
        guard dates.allSatisfy({
            zone.secondsFromGMT(for: $0) == ChartHistory.calendar.timeZone.secondsFromGMT(for: $0)
        }) else {
            print("Meter calendar days differ from Manila; a matching 30-day total could not be verified.")
            return false
        }
        do {
            let raw = try await cloud.readHistoryPage("tuya.m.dp.rang.stat.day.list", data: [
                "devId": meter.id, "dpId": dp, "type": "minux", "auto": 2,
                "startDay": format.string(from: HistoryProbeWindow.dayStart),
                "endDay": format.string(from: HistoryProbeWindow.today)
            ], version: "2.0")
            guard let outer = raw as? [String: Any] else { throw TuyaError.message("Invalid daily payload.") }
            let result = outer["result"] as? [String: Any] ?? outer
            guard result.isEmpty || result.keys.contains(where: { $0.count == 8 && $0.allSatisfy(\.isNumber) }) else {
                throw TuyaError.message("Invalid daily payload.")
            }
            let values = dates.compactMap { date -> (Date, Double)? in
                guard let kWh = CloudValue.number(result[format.string(from: date)]), kWh >= 0 else { return nil }
                return (date, kWh)
            }
            HistoryProbeWindow.reportDays("Tuya daily energy", samples: values, unit: "kWh")
            return true
        } catch {
            print("Tuya daily history:", failure(error))
            return false
        }
    }

    static func run30d() async -> Bool {
        do {
            let cloud = TuyaCloud(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                  source: nil, vault: try HistoryProbeSession(key: "tuya-session"))
            guard let meter = try await cloud.snapshot().meter else {
                print("No main consumption meter selected in Super Bar."); return false
            }
            return await daily(cloud, meter: meter)
        } catch { print("Tuya 30-day check:", failure(error)); return false }
    }
    private static func cachedMeter() -> TuyaSnapshot? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/local.SuperBar.plist")
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bytes = values["tuya.readings"] as? Data else { return nil }
        return try? JSONDecoder().decode(TuyaSnapshot.self, from: bytes)
    }

    private static func observeMeter() async {
        let began = Date()
        guard let saved = cachedMeter(), let meter = saved.meter,
              (0...90).contains(began.timeIntervalSince(saved.fetchedAt)) else { return }
        var lastFetch = saved.fetchedAt
        var lastDeviceTime = meter.measuredAt
        let format = ChartHistory.formatter("yyyy-MM-dd HH:mm:ss")
        var count = 0
        while Date().timeIntervalSince(began) < 50 && count < 2 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let snapshot = cachedMeter(), snapshot.meter?.id == meter.id,
                  snapshot.fetchedAt > lastFetch, snapshot.fetchedAt >= began,
                  let watts = snapshot.consumption() else { continue }
            lastFetch = snapshot.fetchedAt
            let stamp = snapshot.meter?.measuredAt
            let deviceTime = stamp.map { format.string(from: $0) } ?? "unavailable"
            print("NEW reading received by the running Super Bar at \(format.string(from: lastFetch)): \(watts) W, device timestamp \(deviceTime), advanced: \(stamp != nil && stamp != lastDeviceTime)")
            lastDeviceTime = stamp
            count += 1
        }
        if count == 0 { print("No new meter snapshot observed during this check.") }
    }

    private static func report(_ history: TuyaHistory, asOf date: Date) {
        let format = ChartHistory.formatter("yyyy-MM-dd HH:mm:ss")
        print("Archive read at", format.string(from: history.fetchedAt), "Asia/Manila")
        for seconds in [3600, 86400] {
            let range = date.addingTimeInterval(-Double(seconds))...date
            let points = (history.power ?? []).filter { range.contains($0.time) }.sorted { $0.time < $1.time }
            let bounds = [points.first, points.last].compactMap { $0.map { format.string(from: $0.time) } }
            print(seconds / 3600, "h:", points.count, "timestamped W reports", bounds.joined(separator: " … "),
                  "and", RollingEnergy.clipped(history.hours, to: range).count, "hourly averages")
        }
        print("Daily observations:", history.days.filter { $0.wattHours != nil }.count)
        if let problem = history.problem { print(problem) }
    }

    static func main() async {
        if CommandLine.arguments.contains("--30d") {
            if !(await run30d()) { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--48h") {
            if await !run48h() { exit(1) }
            return
        }
        let now = Date(), prefs = UserDefaults(suiteName: "local.SuperBar")!
        do {
            let cloud = TuyaCloud(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), source: nil, vault: try HistoryProbeSession(key: "tuya-session"))
            guard let meter = try await cloud.snapshot().meter else { throw TuyaError.message("Select the main consumption meter in Super Bar.") }
            print("Live Tuya API, selected meter")
            report(try await cloud.history(for: meter, previous: nil, now: now), asOf: now)
        } catch {
            print("Live probe stopped:", error.localizedDescription)
            if let bytes = prefs.data(forKey: "tuya.history"), let cached = try? JSONDecoder().decode(TuyaHistory.self, from: bytes) {
                print("Previously cached provider response, evaluated at its fetch time:")
                report(cached, asOf: cached.fetchedAt)
            }
            await observeMeter()
            exit(1)
        }
    }
}
