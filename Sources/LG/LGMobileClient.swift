import Foundation
import Combine

struct LGHistoryQuery: Hashable {
    enum Period: String { case hour, day }
    let period: Period
    let first: Date
    let last: Date

    // ThinQ2 accepts exactly one calendar date per hourly request.
    static func chartQueries(at now: Date) -> [Self] {
        let calendar = ChartHistory.calendar, today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let monthStart = calendar.date(byAdding: .day, value: 1 - ChartHistory.dayCount, to: today)!
        return [Self(period: .day, first: monthStart, last: today),
                Self(period: .hour, first: today, last: today),
                Self(period: .hour, first: yesterday, last: yesterday)]
    }
}

struct LGHistoryRecord {
    let start: Date
    let wattHours: Double?
    var unscaled: Double? = nil
}

struct LGHistoryPage {
    let rowCount: Int
    let records: [LGHistoryRecord]

    // ThinQ2 aircon energy-history returns result[].usedDate and energyData.
    // Some models omit the energy unit. Keep those rows available to diagnostics
    // without applying an undocumented scale to a nonzero value.
    init(response: [String: Any], query: LGHistoryQuery) throws {
        guard let rows = response["result"] as? [[String: Any]] ?? object(response["result"] ?? [:])["item"] as? [[String: Any]] else {
            throw LGError(message: "LG energy history: missing result list.")
        }
        rowCount = rows.count
        let date = ChartHistory.formatter(query.period == .hour ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        let end = ChartHistory.calendar.date(byAdding: .day, value: 1, to: query.last)!
        records = rows.compactMap { row in
            guard let stamp = row["usedDate"] as? String, let start = date.date(from: stamp),
                  date.string(from: start) == stamp, start >= query.first, start < end,
                  let n = CloudValue.number(row["energyData"]), n >= 0 else { return nil }
            let unit = (row["energyDataUnit"] ?? row["unit"] ?? response["energyDataUnit"]) as? String
            let wh: Double?
            switch unit?.lowercased() {
            case "wh": wh = n
            case "kwh": wh = n * 1000
            case nil where n == 0: wh = 0
            default: wh = nil
            }
            return LGHistoryRecord(start: start, wattHours: wh?.isFinite == true ? wh : nil,
                                   unscaled: unit == nil ? n : nil)
        }
    }

    init(records: [LGHistoryRecord], rowCount: Int? = nil) { self.records = records; self.rowCount = rowCount ?? records.count }

    // Match the SAME device's finished dates against ThinQ Connect's Wh values.
    // Never infer a scale from zeros, a single date, or another device's alias.
    func confirmedScale(against official: LGHistoryPage, before today: Date) -> Double? {
        let known = Dictionary(official.records.map { ($0.start, $0.wattHours) }, uniquingKeysWith: { _, b in b })
        let pairs = records.compactMap { row -> (Double, Double)? in
            guard row.start < today, let raw = row.unscaled,
                  let wh = known[row.start] ?? nil else { return nil }
            return (raw, wh)
        }
        guard pairs.filter({ $0.0 > 0 && $0.1 > 0 }).count >= 3 else { return nil }
        return [1.0, 1000.0, 0.001].first { scale in
            pairs.allSatisfy { abs($0.0 * scale - $0.1) <= max(1, $0.1 * 0.001) }
        }
    }

    func scaled(_ scale: Double?) -> Self {
        Self(records: records.map { row in
            let value = row.wattHours ?? scale.flatMap { s in row.unscaled.map { $0 * s } }
            return LGHistoryRecord(start: row.start, wattHours: value?.isFinite == true ? value : nil, unscaled: row.unscaled)
        }, rowCount: rowCount)
    }
}

@MainActor final class LGCloudHistory: ObservableObject {
    struct Series {
        var days = [String: EnergyDayPoint]()
        var hours = [Date: PowerInterval]()
        var hasUnspecifiedUnit = false
    }
    @Published private(set) var devices = [String: Series]()
    private var attempted = [String: Date]()
    private var loading = Set<String>()

    func refresh(_ id: String, now: Date = Date(), load: (LGHistoryQuery) async throws -> LGHistoryPage) async {
        guard !id.isEmpty, !loading.contains(id),
              HistoryPolling.due(since: attempted[id], now: now, calendar: ChartHistory.calendar) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let queries = LGHistoryQuery.chartQueries(at: now)
        let key = ChartHistory.formatter("yyyyMMdd")
        var series = devices[id] ?? Series()
        series.days = series.days.filter { $0.key >= key.string(from: queries[0].first) }
        series.hours = series.hours.filter { $0.value.end > now.addingTimeInterval(-86_400) }
        var hasUnspecifiedUnit = false
        var receivedPage = false
        for query in queries {
            guard !Task.isCancelled else { return }
            // An unsupported hourly or daily route must not suppress the other period.
            guard let page = try? await load(query) else { continue }
            receivedPage = true
            for record in page.records where record.start <= now {
                guard let wh = record.wattHours else { hasUnspecifiedUnit = true; continue }
                if query.period == .hour {
                    let end = record.start.addingTimeInterval(3600)
                    // A partial current-hour total has no confirmed end time.
                    guard end <= now, end > now.addingTimeInterval(-86_400) else { continue }
                    series.hours[record.start] = PowerInterval(start: record.start, end: end, watts: wh)
                } else {
                    let day = key.string(from: record.start)
                    series.days[day] = EnergyDayPoint(key: day, label: String(day.suffix(2)), wattHours: wh)
                }
            }
        }
        guard !Task.isCancelled else { return }
        if receivedPage { series.hasUnspecifiedUnit = hasUnspecifiedUnit }
        attempted[id] = now
        devices[id] = series
    }
}

// Adapts mobile ThinQ snapshots/model capabilities to the existing shared LG UI.
// Only capabilities advertised by the device model are exposed as controls.
struct LGMobileModel {
    let data: [String: Any]
    struct Field {
        let group: String, key: String, mobile: String, prefix: String
        var control: String { mobile.contains(".wDir.") ? "wDirCtrl" : "basicCtrl" }
    }
    static let fields = [
        Field(group: "operation", key: "airConOperationMode", mobile: "airState.operation", prefix: "@AC_MAIN_OPERATION_"),
        Field(group: "airConJobMode", key: "currentJobMode", mobile: "airState.opMode", prefix: "@AC_MAIN_OPERATION_MODE_"),
        Field(group: "airFlow", key: "windStrength", mobile: "airState.windStrength", prefix: "@AC_MAIN_WIND_STRENGTH_"),
        Field(group: "temperature", key: "targetTemperature", mobile: "airState.tempState.target", prefix: "")
    ]
    func definition(_ key: String) -> [String: Any] {
        if let value = object(data["MonitoringValue"] ?? [:])[key] { return object(value) }
        let values = object(data["Value"] ?? [:])
        if let value = values[key] { return object(value) }
        let protocolValue = object(data["Monitoring"] ?? [:])["protocol"]
        let alias = object(protocolValue ?? [:])[key] as? String
            ?? (protocolValue as? [[String: Any]])?.first { $0["superSet"] as? String == key }?["value"] as? String
        return object(alias.flatMap { values[$0] } ?? [:])
    }
    func options(_ field: Field) -> [String: String] {
        let definition = definition(field.mobile)
        let raw = object(definition["valueMapping"] ?? definition["value_mapping"] ?? definition["option"] ?? [:])
        var values: [String: String] = [:]
        for (code, entry) in raw {
            guard var label = (entry as? String) ?? object(entry)["label"] as? String,
                  !field.prefix.isEmpty, label.hasPrefix(field.prefix) else { continue }
            label.removeFirst(field.prefix.count)
            if label.hasSuffix("_W") { label.removeLast(2) }
            if field.key == "airConOperationMode" {
                if label == "OFF" { label = "POWER_OFF" }
                else if ["ON", "ALL_ON"].contains(label) { label = "POWER_ON" }
                else { continue }
            }
            if field.key == "currentJobMode", ["ACO", "AI"].contains(label) { label = "AUTO" }
            values[code] = label
        }
        return values
    }
    func range(_ field: Field) -> [String: Any] {
        let definition = definition(field.mobile)
        let range = object(definition["valueMapping"] ?? definition["value_validation"] ?? definition["option"] ?? [:])
        guard let min = CloudValue.number(range["min"]), let max = CloudValue.number(range["max"]), min <= max,
              let step = CloudValue.number(range["step"] ?? 1), step > 0 else { return [:] }
        return ["min": min, "max": max, "step": step]
    }
    var profile: [String: Any] {
        var profile: [String: Any] = [:]
        for field in Self.fields {
            var group = object(profile[field.group] ?? [:])
            if field.group == "temperature" {
                let limits = range(field)
                if !limits.isEmpty { group[field.key] = limits.merging(["writable": true]) { _, new in new }; group["unit"] = "C" }
            } else {
                let values = Array(Set(options(field).values)).sorted()
                if !values.isEmpty { group[field.key] = ["writable": true, "writeValues": values] }
            }
            profile[field.group] = group
        }
        return profile
    }
    static func value(_ path: String, in snapshot: [String: Any]) -> Any? {
        if let direct = snapshot[path] { return direct }
        if let direct = object(snapshot["airState"] ?? [:])[path] { return direct }
        var value: Any = snapshot
        for key in path.split(separator: ".") {
            guard let next = object(value)[String(key)] else { return nil }; value = next
        }
        return value
    }
    func state(_ snapshot: [String: Any]) -> [String: Any] {
        var state: [String: Any] = [:]
        for field in Self.fields {
            guard let raw = Self.value(field.mobile, in: snapshot) else { continue }
            var group = object(state[field.group] ?? [:])
            if field.group == "temperature" { group[field.key] = CloudValue.number(raw); group["unit"] = "C" }
            else { group[field.key] = options(field)[String(describing: raw)] }
            state[field.group] = group
        }
        var temperature = object(state["temperature"] ?? [:]); temperature["unit"] = "C"
        temperature["currentTemperature"] = CloudValue.number(Self.value("airState.tempState.current", in: snapshot))
        state["temperature"] = temperature
        if let watts = CloudValue.number(Self.value("airState.energy.onCurrent", in: snapshot)), watts >= 0 { state["currentPower"] = watts }
        return state
    }
    func command(_ payload: [String: Any]) throws -> [String: Any] {
        guard payload.count == 1, let (group, raw) = payload.first else { throw LGError(message: "Unsupported LG control.") }
        let values = object(raw).filter { $0.key != "unit" }
        guard values.count == 1, let (key, value) = values.first,
              let field = Self.fields.first(where: { $0.group == group && $0.key == key }) else { throw LGError(message: "Unsupported LG control.") }
        let capability = LGCapability(profile: profile, group: group, key: key)
        guard capability.allows(value) else { throw LGError(message: "This LG setting is not supported.") }
        let encoded: Any
        if group == "temperature" { encoded = value }
        else {
            guard let label = value as? String, let code = options(field).sorted(by: { $0.key < $1.key }).first(where: { $0.value == label })?.key else { throw LGError(message: "Unsupported LG setting.") }
            encoded = code
        }
        return ["ctrlKey": field.control, "command": "Set", "dataKey": field.mobile, "dataValue": encoded]
    }
}

actor LGMobileClient {
    private let http: LGMobileHTTP
    private let vault: any CredentialVault
    private var models: [String: LGMobileModel] = [:]
    private var devices: [String: [String: Any]] = [:]
    private var account: String?
    private var refreshing: Task<LGMobileSession, Error>?
    private var historyScales: [String: Double] = [:]
    init(network: URLSession, vault: any CredentialVault = CredentialAccess.shared) { http = LGMobileHTTP(network: network); self.vault = vault }

    static func connect(email: String, password: String, country: String, vault: any CredentialVault = CredentialAccess.shared, network: URLSession? = nil) async throws {
        let ownsSession = network == nil
        let network = network ?? CloudRedirects.session()
        defer { if ownsSession { network.invalidateAndCancel() } }
        // The candidate has no persistence side effects until account and device discovery succeed.
        let session = try await LGMobileAuth.login(email: email, password: password, country: country, network: network)
        let client = LGMobileClient(network: network, vault: vault)
        _ = try await client.discover(session)
        try Task.checkCancellation()
        try LGMobileCredentials.save(session, vault: vault)
    }
    private func session() async throws -> LGMobileSession? {
        guard var saved = try LGMobileCredentials.read(vault: vault) else { return nil }
        if saved.expiresAt.timeIntervalSinceNow > 90 { return saved }
        if let refreshing { return try await refreshing.value }
        let original = saved, http = http, vault = vault
        let task = Task<LGMobileSession, Error> {
            let token = try await http.oauth(original.oauthURL, fields: [("grant_type", "refresh_token"), ("refresh_token", original.refreshToken)])
            var updated = original
            updated.accessToken = try LGMobileHTTP.required("access_token", in: token, stage: "refresh")
            if let rotated = token["refresh_token"] as? String, !rotated.isEmpty { updated.refreshToken = rotated }
            updated.expiresAt = LGMobileHTTP.expiry(token)
            // An old in-flight refresh must not overwrite a newly connected account.
            guard let current = try LGMobileCredentials.read(vault: vault), current.refreshToken == original.refreshToken,
                  current.accessToken == original.accessToken else { throw CancellationError() }
            try LGMobileCredentials.save(updated, vault: vault)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        saved = try await task.value
        return saved
    }
    private func request(_ path: String, session: LGMobileSession, payload: [String: Any]? = nil) async throws -> [String: Any] {
        var headers = LGMobileHTTP.headers(country: session.country, client: session.client)
        headers["x-emp-token"] = session.accessToken; headers["x-user-no"] = session.userNumber
        if payload != nil { headers["x-thinq-security-key"] = "nuts_securitykey" }
        let result = try await http.json(LGMobileHTTP.endpoint(session.apiURL, path), headers: headers, payload: payload, stage: "devices")
        guard let value = result["result"] as? [String: Any] else { throw LGError(message: "LG devices: invalid response.") }
        return value
    }
    func energyHistory(_ id: String, query: LGHistoryQuery) async throws -> LGHistoryPage {
        guard let session = try await session() else { throw LGError(message: "LG mobile session missing.") }
        let route = "service/aircon/\(try API.deviceComponent(id))/energy-history"
        let base = try LGMobileHTTP.endpoint(session.apiURL, route)
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let day = ChartHistory.formatter("yyyy-MM-dd")
        url.queryItems = [URLQueryItem(name: "type", value: "period"),
                          URLQueryItem(name: "period", value: query.period.rawValue),
                          URLQueryItem(name: "startDate", value: day.string(from: query.first)),
                          URLQueryItem(name: "endDate", value: day.string(from: query.last))]
        var headers = LGMobileHTTP.headers(country: session.country, client: session.client)
        headers["x-emp-token"] = session.accessToken
        headers["x-user-no"] = session.userNumber
        let scaleKey = session.userNumber + ":" + id
        var mobile: [String: Any]?
        var mobileError: Error?
        do { mobile = try await http.json(url.url!, headers: headers, stage: "energy history") }
        catch is CancellationError { throw CancellationError() }
        catch { mobileError = error }
        let page = try mobile.map { try LGHistoryPage(response: $0, query: query) }
        try Task.checkCancellation()
        if query.period == .day, let official = try? await officialDailyHistory(id, query: query, session: session) {
            historyScales[scaleKey] = page?.confirmedScale(against: official,
                before: ChartHistory.calendar.startOfDay(for: Date()))
            var merged = Dictionary((page?.scaled(historyScales[scaleKey]).records ?? []).map { ($0.start, $0) }, uniquingKeysWith: { _, b in b })
            // The mobile endpoint is fresher for the partial current day.
            let today = ChartHistory.calendar.startOfDay(for: Date())
            for row in official.records where row.start < today || merged[row.start]?.wattHours == nil { merged[row.start] = row }
            return LGHistoryPage(records: merged.values.sorted { $0.start < $1.start })
        }
        guard let page else { throw mobileError ?? LGError(message: "LG energy history unavailable.") }
        return page.scaled(historyScales[scaleKey])
    }

    // Optional, read-only archive using the separately stored Connect credential.
    // Device control continues to use the mobile account exclusively.
    private func officialDailyHistory(_ id: String, query: LGHistoryQuery, session: LGMobileSession) async throws -> LGHistoryPage {
        let apiKey = try API.connectHistoryAPIKey(vault: vault)
        var credential = try vault.read("lg-token")
        // Earlier Super Bar versions kept the optional archive token in its own
        // Keychain item. Import that exact item after application access is granted.
        // Never touch the real Keychain when a test/custom vault was supplied.
        if credential == nil, CredentialAccess.usesKeychain,
           let shared = vault as? SessionCredentialVault, shared === CredentialAccess.shared,
           let legacy = try? KeychainCredentialVault().read("lg-token"),
           let token = String(data: legacy, encoding: .utf8), !token.isEmpty {
            try vault.write(legacy, key: "lg-token")
            credential = legacy
        }
        guard let data = credential, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LGError(message: "LG Connect history credential unavailable.")
        }
        let region = defaults.string(forKey: "region") ?? "kic"
        guard ["aic", "eic", "kic"].contains(region) else { throw LGError(message: "Invalid LG region.") }
        let base = try LGMobileHTTP.endpoint("https://api-" + region + ".lgthinq.com", "devices/energy/\(try API.deviceComponent(id))/usage")
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let format = ChartHistory.formatter("yyyyMMdd")
        url.queryItems = [.init(name: "property", value: "energyUsage"), .init(name: "period", value: "DAILY"),
                          .init(name: "startDate", value: format.string(from: query.first)), .init(name: "endDate", value: format.string(from: query.last))]
        let headers = ["Authorization": "Bearer " + token, "x-country": session.country, "x-client-id": session.client,
                       "x-message-id": UUID().uuidString.replacingOccurrences(of: "-", with: ""), "x-service-phase": "OP",
                       "x-api-key": apiKey]
        let response = try await http.json(url.url!, headers: headers, stage: "energy history")
        guard let rows = find("dataList", in: response["response"] ?? [:]) as? [[String: Any]] else {
            throw LGError(message: "LG daily history: missing data list.")
        }
        let iso = ChartHistory.formatter("yyyy-MM-dd")
        let records = rows.compactMap { row -> LGHistoryRecord? in
            guard let amount = CloudValue.number(row["energyUsage"]), amount >= 0 else { return nil }
            let wh: Double
            switch (row["unit"] as? String)?.lowercased() {
            case nil, "wh": wh = amount
            case "kwh": wh = amount * 1000
            default: return nil
            }
            guard wh.isFinite else { return nil }
            let date = ["date", "usedDate", "usageDate", "startDate"].compactMap { key -> Date? in
                guard let text = (row[key] as? String) ?? (row[key] as? NSNumber)?.stringValue else { return nil }
                return [format, iso].compactMap { f in f.date(from: text).flatMap { f.string(from: $0) == text ? $0 : nil } }.first
            }.first
            guard let date, date >= query.first, date <= query.last else { return nil }
            return LGHistoryRecord(start: date, wattHours: wh)
        }
        return LGHistoryPage(records: records)
    }
    func dashboardEntriesIfConfigured() async throws -> [[String: Any]]? {
        guard let session = try await deviceSession() else { return nil }
        return try await dashboardEntries(session)
    }
    func televisionOnlineIfConfigured(id: String) async throws -> Bool? {
        guard let session = try await deviceSession() else { return nil }
        let detail = try await request("service/devices/\(try API.deviceComponent(id))", session: session)
        return LGAccountTelevision.cloudOnline(detail["online"])
    }
    private func dashboardEntries(_ session: LGMobileSession) async throws -> [[String: Any]] {
        let result = try await request("service/application/dashboard", session: session)
        guard let list = result["item"] as? [[String: Any]] else { throw LGError(message: "LG device list is missing.") }
        return list
    }
    private func discover(_ session: LGMobileSession) async throws -> LGAccountDirectory {
        let list = try await dashboardEntries(session)
        var tvIDs = Set<String>()
        let televisions: [LGAccountTelevision] = list.compactMap { item in
            guard CloudValue.number(item["deviceType"]) == 701,
                  let id = try? LGMobileHTTP.required("deviceId", in: item, stage: "devices"),
                  (try? API.deviceComponent(id)) != nil, tvIDs.insert(id).inserted else { return nil }
            let alias = (item["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LGAccountTelevision(id: id, name: alias.flatMap { $0.isEmpty ? nil : $0 } ?? "LG TV",
                                       macAddress: item["macAddress"] as? String, online: LGAccountTelevision.cloudOnline(item["online"]))
        }
        let conditioners = list.filter { CloudValue.number($0["deviceType"]) == 401 }
        let supported = conditioners.filter { ($0["platformType"] as? String)?.lowercased() == "thinq2" }
        if televisions.isEmpty && !conditioners.isEmpty && supported.isEmpty {
            throw LGError(message: "No supported ThinQ2 air conditioners in this account.")
        }
        var discovered: [String: [String: Any]] = [:]
        let rooms: [Device] = supported.compactMap { item in
            guard let id = try? LGMobileHTTP.required("deviceId", in: item, stage: "devices"),
                  (try? API.deviceComponent(id)) != nil, discovered[id] == nil else { return nil }
            discovered[id] = item
            return Device(id: id, name: item["alias"] as? String ?? "LG")
        }
        guard !televisions.isEmpty || supported.isEmpty || !rooms.isEmpty else { throw LGError(message: "LG devices: missing device identifier.") }
        models = models.filter { id, _ in
            guard let item = discovered[id] else { return false }
            return (item["modelJsonUri"] as? String) == (devices[id]?["modelJsonUri"] as? String)
        }
        devices = discovered
        return LGAccountDirectory(airConditioners: rooms, televisions: televisions)
    }
    private func model(_ id: String, session: LGMobileSession) async throws -> LGMobileModel {
        if let cached = models[id] { return cached }
        if devices[id] == nil { _ = try await discover(session) }
        guard let item = devices[id], let source = item["modelJsonUri"] as? String else { throw LGError(message: "LG model capabilities are missing.") }
        // Model downloads never receive account headers; URLs are still restricted to LG hosts.
        let model = LGMobileModel(data: try await http.json(LGMobileHTTP.url(source), stage: "model"))
        guard !model.profile.values.allSatisfy({ object($0).isEmpty }) else { throw LGError(message: "This LG model format is not supported yet.") }
        models[id] = model
        return model
    }
    private func deviceSession() async throws -> LGMobileSession? {
        guard let session = try await session() else { return nil }
        let identity = session.country + ":" + session.userNumber
        if account != identity { account = identity; devices.removeAll(); models.removeAll() }
        return session
    }
    func accountDirectoryIfConfigured() async throws -> LGAccountDirectory? {
        guard let session = try await deviceSession() else { return nil }
        return try await discover(session)
    }
    func requestIfConfigured(_ path: String, payload: [String: Any]?) async throws -> Any? {
        guard let session = try await deviceSession() else { return nil }
        if path == "devices" {
            // The history probe reads only ACs and must never query a television's energy as an AC.
            return try await discover(session).airConditioners.map {
                ["deviceId": $0.id, "deviceInfo": ["deviceType": "DEVICE_AIR_CONDITIONER", "alias": $0.name]]
            }
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "devices", let id = parts[1].removingPercentEncoding,
              ["profile", "state", "control"].contains(parts[2]) else {
            throw LGError(message: "Unsupported LG device request.")
        }
        let model = try await model(id, session: session)
        switch parts[2] {
        case "profile": return model.profile
        case "control":
            guard let payload else { throw LGError(message: "Missing LG control.") }
            return try await request("service/devices/\(try API.deviceComponent(id))/control-sync", session: session, payload: model.command(payload))
        default:
            let result = try await request("service/devices/\(try API.deviceComponent(id))", session: session)
            let online = result["online"] as? Bool
            if online == false { return ["online": false] }
            guard let snapshot = result["snapshot"] as? [String: Any] else { throw LGError(message: "LG device snapshot is missing.") }
            var state = model.state(snapshot)
            if let online { state["online"] = online }
            return state
        }
    }
}
