import Foundation

enum TuyaError: LocalizedError {
    case signIn, expired, message(String)
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to Smart Life."
        case .expired: return "Tuya session expired. Sign in again."
        case .message(let text): return text
        }
    }
}

actor TuyaCloud {
    struct Session: Codable {
        var mode = "mobile", app = "smartlife", region = "EU", country_code = "63"
        var endpoint = "https://a1.tuyaeu.com/api.json"
        var sid = "", device_id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var email = "", password_md5: String?
        var meter_id: String?
    }
    static let allowed: Set<String> = ["thing.m.user.username.token.get", "thing.m.user.email.password.login", "tuya.m.location.list", "tuya.m.my.group.device.list", "tuya.m.device.ref.info.my.list", "tuya.m.dp.rang.stat.day.list", "tuya.m.dp.rang.stat.hour.list"]
    private let file: URL, source: URL?
    private let network: URLSession
    private var account: Session?
    private var failedLogin = false
    private var homes: [String] = []
    private var schemas: [String: [String: Any]] = [:]
    private var discoveryAt: Date?
    init(file: URL = PrivateJSONFile.appFile("Tuya/session.json"), source: URL? = PrivateJSONFile.importFile("tuya"), network: URLSession? = nil) {
        self.file = file; self.source = source; self.network = network ?? CloudRedirects.session()
    }
    static func endpoint(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.query == nil, c.fragment == nil,
              ["", "/", "/api.json"].contains(c.path), let host = c.host?.lowercased(),
              ["tuyaeu.com", "tuyaus.com", "tuyacn.com", "tuyain.com", "iotbing.com", "lifeaiot.com"].contains(where: { host.hasSuffix("." + $0) }),
              let url = URL(string: "https://" + host + "/api.json") else { throw TuyaError.message("Invalid Tuya server.") }
        return url
    }
    private func load() throws {
        guard account == nil else { return }
        let origin = FileManager.default.fileExists(atPath: file.path) ? file : source
        guard let origin, let saved = try? PrivateJSONFile.read(Session.self, from: origin), saved.app == "smartlife", saved.mode == "mobile", !saved.email.isEmpty else { throw TuyaError.signIn }
        _ = try Self.endpoint(saved.endpoint)
        account = saved
        if origin != file { try save() }
    }
    private func save() throws { if let account { try PrivateJSONFile.write(account, to: file) } }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    func request(_ action: String, data: [String: Any]? = nil, version: String = "2.0", gid: String? = nil, authenticated: Bool = true) async throws -> Any {
        guard Self.allowed.contains(action) else { throw TuyaError.message("Tuya only permits authentication and reading.") }
        guard let account else { throw TuyaError.signIn }
        var fields = ["a": action, "v": version, "deviceId": account.device_id, "os": "Android", "lang": "en", "clientId": "ekmnwp9f5pnh3trdtpgy", "time": String(Int(Date().timeIntervalSince1970)), "et": "0.0.1", "ttid": "smart_life", "appVersion": "3.8.5", "appRnVersion": "5.11", "platform": "Android", "requestId": UUID().uuidString.lowercased()]
        if let data { fields["postData"] = String(data: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)! }
        fields["gid"] = gid
        if authenticated { fields["sid"] = account.sid }
        fields["sign"] = TuyaCrypto.signature(fields)
        var request = URLRequest(url: try Self.endpoint(account.endpoint))
        request.httpMethod = "POST"; request.httpBody = Self.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bytes: Data, response: URLResponse
        do { (bytes, response) = try await network.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw TuyaError.message("Could not connect to Tuya.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw TuyaError.message("Invalid Tuya response.") }
        guard json["success"] as? Bool == true else {
            let code = json["errorCode"] as? String ?? "unknown"
            if ["USER_SESSION_INVALID", "USER_SESSION_EXPIRED"].contains(code) { throw TuyaError.expired }
            if code.contains("CAPTCHA") || code.contains("VERIFY") || code.contains("MFA") { throw TuyaError.message("Confirm the login in Smart Life, then try again.") }
            let safe = code.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil ? code : "unknown"
            throw TuyaError.message("Tuya rejected the request (\(safe)).")
        }
        return json["result"] ?? NSNull()
    }
    private func login() async throws {
        guard let saved = account, let digest = saved.password_md5 else { throw TuyaError.signIn }
        let token = CloudValue.object(try await request("thing.m.user.username.token.get", data: ["countryCode": saved.country_code, "username": saved.email, "isUid": false], authenticated: false))
        guard let value = token["token"] as? String, !value.isEmpty else { throw TuyaError.signIn }
        let encrypted = try TuyaCrypto.password(digest, token: token)
        let result = CloudValue.object(try await request("thing.m.user.email.password.login", data: ["countryCode": saved.country_code, "email": saved.email, "passwd": encrypted, "ifencrypt": 1, "options": "{\"group\":1,\"mfaCode\":\"\"}", "token": value], version: "3.0", authenticated: false))
        guard let sid = result["sid"] as? String, !sid.isEmpty else { throw TuyaError.signIn }
        let origin = CloudValue.object(result["domain"])["mobileApiUrl"] as? String ?? saved.endpoint
        account?.endpoint = try Self.endpoint(origin).absoluteString
        account?.sid = sid; failedLogin = false
        try save()
    }
    private func read(_ action: String, data: [String: Any]? = nil, version: String = "2.0", gid: String? = nil) async throws -> Any {
        try load()
        guard !failedLogin else { throw TuyaError.signIn }
        if account?.sid.isEmpty == true { try await login() }
        do { return try await request(action, data: data, version: version, gid: gid) }
        catch TuyaError.expired {
            do { try await login(); return try await request(action, data: data, version: version, gid: gid) }
            catch { failedLogin = true; throw error }
        }
    }
    func signIn(email: String, password: String) async throws {
        try? load()
        var next = account ?? Session()
        next.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty { next.password_md5 = TuyaCrypto.md5(password) }
        account = next
        try save() // Remember input even if authentication fails.
        failedLogin = false
        try await login()
        homes = []; schemas = [:]; discoveryAt = nil
    }
    func snapshot() async throws -> TuyaSnapshot {
        try load()
        if homes.isEmpty || discoveryAt.map({ Date().timeIntervalSince($0) > 3600 }) != false {
            guard let rows = try await read("tuya.m.location.list", version: "2.1") as? [[String: Any]] else { throw TuyaError.message("Invalid Tuya homes.") }
            homes = rows.compactMap { row in (row["groupId"] ?? row["id"]).map { String(describing: $0) } }
            discoveryAt = Date(); schemas = [:]
        }
        var devices: [String: TuyaDevice] = [:]
        for home in homes {
            guard let rows = try await read("tuya.m.my.group.device.list", gid: home) as? [[String: Any]] else { throw TuyaError.message("Invalid Tuya devices.") }
            if rows.contains(where: { schemas[$0["productId"] as? String ?? ""] == nil }) {
                guard let refs = try await read("tuya.m.device.ref.info.my.list", gid: home) as? [[String: Any]] else { throw TuyaError.message("Invalid Tuya schemas.") }
                for ref in refs { if let id = ref["id"] { schemas[String(describing: id)] = CloudValue.object(ref["schemaInfo"]) } }
            }
            for row in rows {
                if let device = TuyaDevice.decode(row, schema: schemas[row["productId"] as? String ?? ""] ?? [:]) { devices[device.id] = device }
            }
        }
        let sorted = devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return TuyaSnapshot(devices: sorted, meterID: account?.meter_id, fetchedAt: Date())
    }
    func selectMeter(_ id: String) throws { try load(); account?.meter_id = id; try save() }
    func history(for device: TuyaDevice, previous: TuyaHistory?, now: Date = Date()) async throws -> TuyaHistory {
        guard let dp = device.historyDP else { throw TuyaError.message("Tuya history is unavailable for this meter.") }
        guard let zoneID = device.timeZoneID, let zone = TimeZone(identifier: zoneID) else {
            throw TuyaError.message("Tuya meter timezone is unavailable.")
        }
        let keys = TuyaHistory.keys(now: now)
        guard keys.allSatisfy({ key in
            let date = TuyaHistory.formatter("yyyyMMdd").date(from: key)!
            return zone.secondsFromGMT(for: date) == TuyaHistory.calendar.timeZone.secondsFromGMT(for: date)
        }) else { throw TuyaError.message("Tuya and Deye use different timezones.") }
        let saved = previous.flatMap { $0.meterID == device.id && $0.timeZoneID == zoneID ? $0 : nil }
        var days = saved?.days.filter { keys.contains($0.key) } ?? []
        var hours = saved?.hours.filter { TuyaHistory.calendar.isDate($0.start, inSameDayAs: now) } ?? []
        var firstMissing = keys.dropLast().first { key in !days.contains { $0.key == key && $0.wattHours != nil } } ?? keys.last!
        // A cached "today" total was partial. Fetch it once more after midnight.
        if let saved {
            let lastFetchedDay = TuyaHistory.formatter("yyyyMMdd").string(from: saved.fetchedAt)
            if keys.contains(lastFetchedDay) { firstMissing = min(firstMissing, lastFetchedDay) }
        }
        let base: [String: Any] = ["devId": device.id, "dpId": dp, "type": "minux", "auto": 2]
        var errors: [String] = []
        do {
            let data = base.merging(["startDay": firstMissing, "endDay": keys.last!]) { _, new in new }
            let raw = try await read("tuya.m.dp.rang.stat.day.list", data: data)
            let requested = keys.filter { $0 >= firstMissing }
            let fetched = TuyaHistory.daily(raw, keys: requested)
            days.removeAll { requested.contains($0.key) }
            days += fetched
        } catch is CancellationError { throw CancellationError() }
        catch { errors.append("Tuya daily history unavailable") }
        do {
            let data = base.merging(["date": keys.last!]) { _, new in new }
            let raw = try await read("tuya.m.dp.rang.stat.hour.list", data: data, version: "1.0")
            hours = TuyaHistory.hourly(raw, zone: zone, now: now)
        } catch is CancellationError { throw CancellationError() }
        catch { errors.append("Tuya hourly history unavailable") }
        return TuyaHistory(meterID: device.id, timeZoneID: zoneID, days: days.sorted { $0.key < $1.key },
                           hours: hours, fetchedAt: now, problem: errors.isEmpty ? nil : errors.joined(separator: " · "))
    }
    func savedEmail() -> String { try? load(); return account?.email ?? "" }
}
