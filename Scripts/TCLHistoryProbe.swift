import Foundation
import Security

// Build with Readings.swift, CloudSupport.swift, CredentialStore.swift, TCLCloud.swift and HistoryProbeSession.swift.
// Only the existing Super Bar Keychain account is used. Renewals stay in memory.
#if !HISTORY_PROBE_SUITE
@main
#endif
enum TCLHistoryProbe {
    private static let day = ChartHistory.formatter("yyyy-MM-dd")
    private static let second = ChartHistory.formatter("yyyy-MM-dd HH:mm:ss")
    struct Records {
        var days: [Date: Double] = [:]
        var timed: [Date: Double] = [:]
        var explicitHours: Set<Date> = []
        var unidentified = 0
        var unsupportedUnit = 0
        private static func timestamp(_ text: String, on day: String) -> Date? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts.allSatisfy({ (1...2).contains($0.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
            let minutes = parts.count > 1 ? Int(parts[1])! : 0
            let seconds = parts.count > 2 ? Int(parts[2])! : 0
            guard (0...59).contains(minutes), (0...59).contains(seconds) else { return nil }
            let stamp = day + String(format: " %02d:%02d:%02d", hour, minutes, seconds)
            return second.date(from: stamp).flatMap { second.string(from: $0) == stamp ? $0 : nil }
        }
        mutating func collect(_ row: [String: Any], parentDay: String? = nil, parentUnit: String? = nil) {
            let timeField = row["time"] as? String ?? ""
            let stamp = (timeField.count >= 10 ? timeField : row["date"] as? String ?? "").replacingOccurrences(of: "T", with: " ")
            let prefix = String(stamp.prefix(10))
            let dated = day.date(from: prefix).flatMap { day.string(from: $0) == prefix ? $0 : nil }
            let context = stamp.isEmpty ? parentDay : dated.map(day.string)
            let unit = (row["unit"] as? String ?? parentUnit)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let groups = ["ecoDetails", "dataList", "consumptionDetails", "consumption_details"].compactMap { row[$0] as? [[String: Any]] }
            if !groups.isEmpty {
                for child in groups.joined() { collect(child, parentDay: context, parentUnit: unit) }
                return
            }
            guard let value = CloudValue.number(row["totalElectricity"]) ?? CloudValue.number(row["total_electricity"]) ??
                    CloudValue.number(row["electricity"]) ?? CloudValue.number(row["consumption"]),
                  value >= 0 else { return }
            guard unit == nil || unit == "kwh" || unit == "wh" else { unsupportedUnit += 1; return }
            let kWh = unit == "wh" ? value / 1000 : value
            let clock = timeField.count < 10 && !timeField.isEmpty ? timeField : String(stamp.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            let hour = row["hour"].map { String(describing: $0) }
            let time = clock.isEmpty ? (hour ?? "") : clock
            let absolute = timeField.count > 10 ? timeField : (row["date"] as? String ?? "")
            let hasZone = absolute.contains("T") && absolute.dropFirst(10).contains(where: { "Z+-".contains($0) })
            let isoTime = hasZone ? (try? Date(absolute, strategy: .iso8601.time(includingFractionalSeconds: true))) ?? (try? Date(absolute, strategy: .iso8601)) : nil
            if let date = isoTime ?? context.flatMap({ Self.timestamp(time, on: $0) }) {
                timed[date] = kWh
                if hour != nil { explicitHours.insert(date) }
            } else if let dated, time.isEmpty { days[dated] = kWh }
            else { unidentified += 1 }
        }

        func resolutions(from start: Date, through end: Date) -> (hours: [(Date, Double)], finer: [(Date, Double)], unclassified: [(Date, Double)]) {
            let calendar = ChartHistory.calendar
            var hours = [(Date, Double)](), finer = [(Date, Double)](), unclassified = [(Date, Double)]()
            let requested = timed.keys.filter { $0 >= start && $0 < end }.sorted()
            var closePairs = Set<Date>()
            // An offset such as :30 says nothing about report frequency. Use the
            // measured gap, which also works for a pair spanning midnight or an hour.
            for (first, second) in zip(requested, requested.dropFirst()) where second.timeIntervalSince(first) < 3600 {
                closePairs.insert(first)
                closePairs.insert(second)
            }
            for (date, value) in timed where date < end && date.addingTimeInterval(3600) > start {
                let aligned = calendar.dateInterval(of: .hour, for: date)?.start == date
                let hourlyNeighbor = timed[date.addingTimeInterval(-3600)] != nil || timed[date.addingTimeInterval(3600)] != nil
                if closePairs.contains(date) { finer.append((date, value)) }
                else if aligned && (explicitHours.contains(date) || hourlyNeighbor) { hours.append((date, value)) }
                else if date >= start { unclassified.append((date, value)) }
            }
            return (hours, finer, unclassified)
        }
    }
    private static func describe(_ dates: [Date]) -> String {
        let ordered = dates.sorted()
        guard let first = ordered.first, let last = ordered.last else { return "0 samples" }
        let gaps = Set(zip(ordered, ordered.dropFirst()).map { Int($1.timeIntervalSince($0)) }).sorted()
        return "\(ordered.count) samples, \(second.string(from: first)) … \(second.string(from: last)), spacing(s) \(gaps)"
    }
    private static func room(_ name: String?, index: Int) -> String {
        // Only these verified room aliases appear in the report. Unknown names
        // may be a serial number, an account identifier or another private label.
        let alias = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["living aircon", "bedroom aircon", "office aircon"].contains(alias) ? alias : "AC \(index + 1)"
    }
    private static func reportSavedArchive(now: Date) {
        struct Cache: Decodable {
            struct Day: Decodable { let day: String, kwh: Double }
            struct Hour: Decodable { let start: TimeInterval, kwh: Double }
            struct Counter: Decodable {
                struct Reading: Decodable { let at: TimeInterval, kwh: Double }
                let first: Reading, last: Reading?
            }
            struct Report: Decodable {
                let name: String?, updated: TimeInterval, days: [Day]
                let hours: [Hour]?, lastHourlyRequest: TimeInterval?, counter: Counter?
            }
            let devices: [Report]
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let override = ProcessInfo.processInfo.environment["TCL_DATA_DIR"] ?? ""
        let directory = override.isEmpty ? appSupport.appendingPathComponent("TCLBar") : URL(fileURLWithPath: override)
        let file = directory.appendingPathComponent("tcl-energy.json")
        guard let saved = try? PrivateJSONFile.read(Cache.self, from: file) else {
            print("Saved TCL provider archive (tcl-energy.json): unavailable")
            return
        }
        print("Saved TCL provider archive (tcl-energy.json), Asia/Manila. No fresh API response.")
        let firstDay = ChartHistory.calendar.date(byAdding: .day, value: -29, to: ChartHistory.calendar.startOfDay(for: now))!
        let hour = RollingEnergy.lastHour(endingAt: now)
        var counters = [String]()
        for (index, report) in saved.devices.enumerated() {
            let name = room(report.name, index: index)
            let dates = Set(report.days.compactMap { record -> Date? in
                guard record.kwh.isFinite, record.kwh >= 0, let date = day.date(from: record.day),
                      day.string(from: date) == record.day, date >= firstDay, date <= now else { return nil }
                return date
            })
            let availableHours = (report.hours ?? []).filter { $0.start.isFinite && $0.kwh.isFinite && $0.kwh >= 0 }
            let recent = availableHours.filter {
                let start = Date(timeIntervalSince1970: $0.start)
                return start < now && start.addingTimeInterval(3600) > hour.lowerBound
            }.sorted { $0.start < $1.start }
            print(name)
            if report.updated > 0 { print("  Daily archive fetched:", second.string(from: Date(timeIntervalSince1970: report.updated))) }
            print("  Daily provider kWh for the last 30 calendar days:", describe(Array(dates)))
            if let last = report.lastHourlyRequest { print("  Last hourly archive request:", second.string(from: Date(timeIntervalSince1970: last))) }
            print("  Provider hourly buckets: \(availableHours.count) saved, \(recent.count) overlapping the last 60 minutes")
            for value in recent { print("   ", second.string(from: Date(timeIntervalSince1970: value.start)), value.kwh, "kWh in the calendar hour") }
            if let first = report.counter?.first, let last = report.counter?.last,
               first.at < last.at, last.kwh > first.kwh, last.at <= now.timeIntervalSince1970 {
                let range = [first.at, last.at].map { second.string(from: Date(timeIntervalSince1970: $0)) }
                counters.append("  \(name): 2 receipt times, " + range.joined(separator: " … "))
            }
        }
        print("Separate local daily-counter changes (receipt times, outside the provider archive): \(counters.count)")
        for summary in counters { print(summary) }
    }
    private static func errorLabel(_ error: Error) -> String {
        if let cloud = error as? TCLCloudError {
            switch cloud {
            case .http(_, let code): return "HTTP \(code)"
            case .message(let message) where message.contains("Cannot reach") || message.hasSuffix("timed out."):
                return "Network request failed"
            case .signInRequired: return "TCL account missing from Super Bar Keychain"
            case .credentialsRejected, .expired: return "TCL rejected the Keychain session or sign-in"
            default: return "Invalid TCL response"
            }
        }
        if error is CredentialStorageError { return "Super Bar Keychain access unavailable" }
        let issue = error as NSError
        if issue.domain == NSOSStatusErrorDomain {
            if issue.code == Int(errSecItemNotFound) { return "TCL account missing from the Super Bar Keychain available to this process" }
            return "Super Bar Keychain lookup failed (\(issue.code))"
        }
        return "Request failed (\(issue.code))"
    }
    static func run30d() -> Bool {
        unsetenv("TCL_SSO_ID")
        unsetenv("TCL_SSO_TOKEN")
        do {
            let cloud = TCLCloud(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 vault: try HistoryProbeSession(key: "tcl-session"))
            let devices = try cloud.connect()
            guard !devices.isEmpty else { print("TCL: в аккаунте нет доступных кондиционеров."); return false }
            var complete = true
            for (index, device) in devices.enumerated() {
                let name = room((device["nickName"] ?? device["nick_name"]) as? String, index: index)
                do {
                    let result = try cloud.statistics(device: device, path: "/v1/ac/statistics/electricity/summary?timeType=2")
                    guard CloudValue.number(result["code"]) == 0, let data = result["data"] as? [String: Any] else {
                        let code = CloudValue.number(result["code"]).map(String.init(describing:)) ?? "без кода"
                        print("  \(name): суточная история недоступна, код TCL \(code)")
                        complete = false
                        continue
                    }
                    var records = Records()
                    records.collect(data)
                    HistoryProbeWindow.reportDays(name, samples: records.days.map { ($0.key, $0.value) }, unit: "kWh")
                    if records.unidentified > 0 || records.unsupportedUnit > 0 {
                        print("    Строк без распознанной даты: \(records.unidentified), с неподдерживаемой единицей: \(records.unsupportedUnit).")
                    }
                } catch { print("  \(name):", errorLabel(error)); complete = false }
            }
            return complete
        } catch { print("TCL: запрос истории не выполнен —", errorLabel(error)); return false }
    }

    static func run48h() -> Bool {
        unsetenv("TCL_SSO_ID")
        unsetenv("TCL_SSO_TOKEN")
        let start = HistoryProbeWindow.start, end = HistoryProbeWindow.end
        let week = ChartHistory.formatter("yyyyMMdd")
        let first = ChartHistory.calendar.date(byAdding: .day, value: -6, to: end)!
        print("TCL Home · история из облака, окно 48 ч, время Манилы.")
        do {
            let cloud = TCLCloud(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 vault: try HistoryProbeSession(key: "tcl-session"))
            let devices = try cloud.connect()
            guard !devices.isEmpty else { print("TCL: в аккаунте нет доступных кондиционеров."); return false }
            var allRead = true
            for (index, device) in devices.enumerated() {
                print(room((device["nickName"] ?? device["nick_name"]) as? String, index: index))
                var routes = [1, 0, 2].map { ("summary timeType=\($0)", "/v1/ac/statistics/electricity/summary?timeType=\($0)") }
                if let id = ["deviceId", "device_id", "id"].compactMap({ device[$0] as? String }).first(where: { !$0.isEmpty }),
                   id != ".", id != ".." {
                    let encoded = TCLIoTSigner.escape(id)
                    let range = week.string(from: first) + "-" + week.string(from: end)
                    routes.append(("legacy weekly", "/v3/ac/\(encoded)/power/consumption/info/?week=\(range)"))
                }
                var succeeded = 0
                for (label, path) in routes {
                    do {
                        let reply = try cloud.statistics(device: device, path: path)
                        guard let code = CloudValue.number(reply["code"]), code == 0, let data = reply["data"] as? [String: Any] else {
                            let status = CloudValue.number(reply["code"]).map(String.init(describing:)) ?? "без кода"
                            print("  \(label): недоступно, код TCL \(status)")
                            continue
                        }
                        var records = Records()
                        records.collect(data)
                        succeeded += 1
                        let dailyDates = records.days.keys.filter { $0 >= ChartHistory.calendar.startOfDay(for: start) && $0 <= end }
                        let series = records.resolutions(from: start, through: end)
                        print("  \(label): суточных значений за затронутые даты \(dailyDates.count), строк без распознанного времени \(records.unidentified), с неподдерживаемой единицей \(records.unsupportedUnit).")
                        if records.days.isEmpty && records.timed.isEmpty {
                            print("  Ответ TCL получен, распознанных датированных записей энергии в нём нет.")
                            continue
                        }
                        HistoryProbeWindow.report("\(label) · часовое поле или метки с часовым шагом", samples: series.hours, unit: "kWh", hourly: true)
                        HistoryProbeWindow.report("\(label) · метки, у которых есть соседний замер ближе одного часа", samples: series.finer, unit: "kWh", hourly: false)
                        if !series.unclassified.isEmpty {
                            HistoryProbeWindow.report("\(label) · прочие датированные замеры, частота не подтверждена", samples: series.unclassified, unit: "kWh", hourly: false)
                        }
                    } catch { print("  \(label):", errorLabel(error)) }
                }
                if succeeded == 0 { allRead = false; print("  Ни один запрос TCL не вернул историю.") }
            }
            print("TCL summary возвращает собственный диапазон дат и не имеет подтверждённого параметра выбора дня. Отчёт учитывает только записи с датой в заданном окне. Для точки с временем суток без даты день не подставляется.")
            return allRead
        } catch { print("TCL: запрос истории не выполнен —", errorLabel(error)); return false }
    }

    // Captured original-client requests, including a same-day range:
    // https://github.com/nemesa/ha-tcl-home-unofficial-integration/blob/main/notes/power_and_worktime/power.txt
    // timeType 1/2/3 semantics from captured TCL+ traffic:
    // https://github.com/Tinnci/ha-tcl-udp-ac/blob/main/docs/tcl_cloud_api_notes.md
    static func explorationRoutes(deviceID: String, start: Date, end: Date) -> [(label: String, path: String)] {
        guard !deviceID.isEmpty, deviceID != ".", deviceID != "..",
              deviceID.rangeOfCharacter(from: .controlCharacters) == nil else { return [] }
        let root = "/v3/ac/" + TCLIoTSigner.escape(deviceID) + "/power/consumption/info/"
        let compact = ChartHistory.formatter("yyyyMMdd")
        let month = ChartHistory.formatter("yyyy/MM")
        let calendar = ChartHistory.calendar
        var routes: [(label: String, path: String)] = [
            ("summary timeType=3 · годовая группировка", "/v1/ac/statistics/electricity/summary?timeType=3")
        ]
        var date = calendar.startOfDay(for: start)
        var months: Set<String> = []
        // The 48-hour window intersects at most three Manila calendar dates.
        for _ in 0..<3 where date <= end {
            let value = compact.string(from: date)
            routes.append(("legacy один день \(day.string(from: date))", root + "?week=" + value + "-" + value))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        // Query each month intersecting the requested 30 calendar dates as well.
        // This makes the previous month available even when summary only returns the current month.
        let today = calendar.startOfDay(for: end)
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today)!
        for offset in 0..<30 {
            months.insert(month.string(from: calendar.date(byAdding: .day, value: offset, to: monthStart)!))
        }
        for value in months.sorted() { routes.append(("legacy месяц \(value)", root + value)) }
        return routes
    }

    private static func describeShape(_ data: [String: Any]) {
        let allowed = Set(["time", "date", "hour", "timestamp", "startTime", "endTime", "totalElectricity",
                           "total_electricity", "electricity", "consumption", "realElectricity",
                           "avgElectricity", "averageElectricity", "ecoDetails", "dataList",
                           "consumptionDetails", "consumption_details", "workModeDetails"])
        var counts: [String: Int] = [:]
        var sampled = 0
        func visit(_ value: Any, depth: Int) {
            guard depth <= 8, sampled < 5_000 else { return }
            sampled += 1
            if let row = value as? [String: Any] {
                for (key, child) in row {
                    if allowed.contains(key) { counts[key, default: 0] += 1 }
                    if child is [String: Any] || child is [Any] { visit(child, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for child in array.prefix(1000) { visit(child, depth: depth + 1) }
            }
        }
        visit(data, depth: 0)
        print("    Поля ответа (число вхождений): " + counts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    }

    static func runExplore() -> Bool {
        unsetenv("TCL_SSO_ID")
        unsetenv("TCL_SSO_TOKEN")
        print("TCL · дополнительные запросы из опубликованных записей трафика.")
        print("  В TCL+ summary: timeType=1 — неделя с днями, 2 — месяц с днями, 3 — год с месяцами. Детализация международного сервиса проверяется по фактическому ответу.")
        do {
            let cloud = TCLCloud(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 vault: try HistoryProbeSession(key: "tcl-session"))
            let devices = try cloud.connect()
            guard !devices.isEmpty else { print("TCL: в аккаунте нет доступных кондиционеров."); return false }
            var received = false
            for (index, device) in devices.enumerated() {
                let name = room((device["nickName"] ?? device["nick_name"]) as? String, index: index)
                guard let id = ["deviceId", "device_id", "id"].compactMap({ device[$0] as? String }).first(where: { !$0.isEmpty }) else { continue }
                print("  \(name)")
                for route in explorationRoutes(deviceID: id, start: HistoryProbeWindow.start, end: HistoryProbeWindow.end) {
                    do {
                        let reply = try cloud.statistics(device: device, path: route.path)
                        guard CloudValue.number(reply["code"]) == 0, let data = reply["data"] as? [String: Any] else {
                            let code = CloudValue.number(reply["code"]).map(String.init(describing:)) ?? "без кода"
                            print("    \(route.label): код TCL \(code), историю получить не удалось.")
                            continue
                        }
                        received = true
                        var records = Records()
                        records.collect(data)
                        print("    \(route.label): строк с датой дня \(records.days.count), с временем \(records.timed.count), без распознанной даты \(records.unidentified), неизвестная единица \(records.unsupportedUnit).")
                        describeShape(data)
                        HistoryProbeWindow.export(name + " · " + route.label, samples: records.days.map { ($0.key, $0.value) }, unit: "kWh", interval: "day")
                        for (date, value) in records.days.sorted(by: { $0.key < $1.key })
                            where date >= ChartHistory.calendar.startOfDay(for: HistoryProbeWindow.start) && date <= HistoryProbeWindow.end {
                            print("      \(day.string(from: date)) = \(value) kWh")
                        }
                        if !records.timed.isEmpty {
                            let series = records.resolutions(from: HistoryProbeWindow.start, through: HistoryProbeWindow.end)
                            HistoryProbeWindow.report(name + " · " + route.label + " · часовые отметки", samples: series.hours, unit: "kWh", hourly: true)
                            HistoryProbeWindow.report(name + " · " + route.label + " · пары с интервалом менее часа", samples: series.finer, unit: "kWh", hourly: false)
                            if !series.unclassified.isEmpty {
                                HistoryProbeWindow.report(name + " · " + route.label + " · частота не определена", samples: series.unclassified, unit: "kWh", hourly: false)
                            }
                        }
                    } catch { print("    \(route.label):", errorLabel(error)) }
                }
            }
            print("  Найден также TCL+ POST /v1/dashboard/energyStatistics/detail. Параметры запроса и привязка к конкретному AC в источнике не опубликованы, применимость к вашему международному аккаунту не подтверждена.")
            print("  Коды 10002 и 10003 сами по себе не подтверждают отсутствие истории.")
            return received
        } catch { print("TCL: дополнительные запросы не выполнены —", errorLabel(error)); return false }
    }

    static func main() {
        if CommandLine.arguments.contains("--explore") { exit(runExplore() ? 0 : 1) }
        if CommandLine.arguments.contains("--48h") { exit(run48h() ? 0 : 1) }
        unsetenv("TCL_SSO_ID")
        unsetenv("TCL_SSO_TOKEN")
        do {
            // An unused unique directory prevents the normal legacy-file migration.
            let cloud = TCLCloud(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 vault: try HistoryProbeSession(key: "tcl-session"))
            let devices = try cloud.connect()
            let now = Date(), hour = RollingEnergy.lastHour(endingAt: now)
            let firstDay = ChartHistory.calendar.date(byAdding: .day, value: -29, to: ChartHistory.calendar.startOfDay(for: now))!
            print("Live TCL AC inventory: \(devices.count). Asia/Manila. Provider data only.")
            for (index, device) in devices.enumerated() {
                print(room((device["nickName"] ?? device["nick_name"]) as? String, index: index))
                for type in [2, 1, 0] {
                    do {
                        let result = try cloud.statistics(device: device, path: "/v1/ac/statistics/electricity/summary?timeType=\(type)")
                        guard CloudValue.number(result["code"]) == 0, let data = result["data"] as? [String: Any] else {
                            print("  timeType=\(type) provider code \(CloudValue.number(result["code"]).map(String.init(describing:)) ?? "unknown")")
                            continue
                        }
                        var records = Records()
                        records.collect(data)
                        print("  timeType=\(type) daily kWh (30 calendar days): " + describe(records.days.keys.filter { $0 >= firstDay && $0 <= now }))
                        print("  timestamped kWh (last 60 min): " + describe(records.timed.keys.filter { hour.contains($0) }))
                        print("  all timestamped kWh: " + describe(Array(records.timed.keys)) + "; undated energy rows: \(records.unidentified)")
                    } catch { print("  timeType=\(type) " + errorLabel(error)) }
                }
            }
        } catch {
            print(errorLabel(error))
            reportSavedArchive(now: Date())
            exit(1)
        }
    }
}
