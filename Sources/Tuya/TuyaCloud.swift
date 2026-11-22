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
        var password: String?
        var meter_id: String?
    }
    static let powerLogAction = "tuya.m.smart.operate.all.log"
    static let allowed: Set<String> = ["thing.m.user.username.token.get", "thing.m.user.email.password.login", "tuya.m.location.list", "tuya.m.my.group.device.list", "tuya.m.device.ref.info.my.list", "tuya.m.dp.rang.stat.day.list", "tuya.m.dp.rang.stat.hour.list", powerLogAction]
    #if HISTORY_PROBE_SUITE
    // Official Tuya panel SDK read APIs, enabled only for the diagnostic build.
    static let probeHistoryActions: Set<String> = ["m.smart.operate.log", "tuya.m.device.query.device.log"]
    #endif
    private let credentials: CloudCredentialStore
    private let source: URL?
    private let network: URLSession
    private let ownsSession: Bool
    private var account: Session?
    private var failedLogin = false
    private var renewal: Task<Void, Error>?
    private var homes: [String] = []
    private var schemas: [String: [String: Any]] = [:]
    private var discoveryAt: Date?
    init(file: URL = PrivateJSONFile.appFile("Tuya/session.json"), source: URL? = PrivateJSONFile.importFile("tuya"), network: URLSession? = nil, vault: any CredentialVault = CloudCredentialStore.defaultVault) {
        self.credentials = CloudCredentialStore(file: file, key: "tuya-session", vault: vault); self.source = source
        self.ownsSession = network == nil; self.network = network ?? CloudRedirects.session()
    }
    deinit { if ownsSession { network.invalidateAndCancel() } }
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
        guard let saved = try credentials.load(Session.self, importFile: source, validate: { saved in
            guard saved.app == "smartlife", saved.mode == "mobile", !saved.email.isEmpty else { throw TuyaError.signIn }
            _ = try Self.endpoint(saved.endpoint)
            return saved
        }) else { throw TuyaError.signIn }
        account = saved
    }
    private func save() throws { if let account { try credentials.save(account) } }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    func request(_ action: String, data: [String: Any]? = nil, version: String = "2.0", gid: String? = nil, authenticated: Bool = true) async throws -> Any {
        #if HISTORY_PROBE_SUITE
        guard Self.allowed.contains(action) || Self.probeHistoryActions.contains(action) else { throw TuyaError.message("Tuya only permits authentication and reading.") }
        #else
        guard Self.allowed.contains(action) else { throw TuyaError.message("Tuya only permits authentication and reading.") }
        #endif
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
        do { (bytes, response) = try await CloudResponse.data(for: request, using: network, history: action.hasPrefix("tuya.m.dp.rang.stat.") || action == Self.powerLogAction, provider: .tuya) }
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
    private func renewSession() async throws {
        if let renewal { return try await renewal.value }
        let task = Task { try await login() }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }
    private func read(_ action: String, data: [String: Any]? = nil, version: String = "2.0", gid: String? = nil) async throws -> Any {
        try load()
        guard !failedLogin else { throw TuyaError.signIn }
        if account?.sid.isEmpty == true { try await renewSession() }
        let sid = account?.sid
        do { return try await request(action, data: data, version: version, gid: gid) }
        catch TuyaError.expired {
            do {
                if account?.sid == sid { try await renewSession() }
                return try await request(action, data: data, version: version, gid: gid)
            }
            catch { failedLogin = true; throw error }
        }
    }
    func signIn(email: String, password: String) async throws {
        try? load()
        let previous = account, previousFailure = failedLogin
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameAccount = previous?.email.caseInsensitiveCompare(email) == .orderedSame
        var next = sameAccount ? previous! : Session()
        next.email = email
        guard sameAccount || !password.isEmpty else { throw TuyaError.message("Enter the password when connecting a different Smart Life account.") }
        if !password.isEmpty { next.password_md5 = TuyaCrypto.md5(password); next.password = password }
        next.sid = ""
        account = next
        failedLogin = true // A concurrent read must not reuse the previous account's SID.
        do { try await login() }
        catch { account = previous; failedLogin = previousFailure; throw error }
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
        guard device.powerDP != nil || device.historyDP != nil else { throw TuyaError.message("Tuya history is unavailable for this meter.") }
        let saved = previous.flatMap { $0.meterID == device.id ? $0 : nil }
        var result = TuyaHistory(meterID: device.id, timeZoneID: device.timeZoneID ?? "", days: [], hours: [], fetchedAt: now)
        if let dp = device.historyDP {
            do {
                result = try await statistics(for: device, dp: dp, previous: saved, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // UTC power reports remain usable when the meter's local calendar is unknown.
                guard device.powerDP != nil else { throw error }
                result.problem = (error as? TuyaError)?.errorDescription ?? "Tuya statistics unavailable"
            }
        } else if let saved, saved.timeZoneID == device.timeZoneID {
            // Keep the statistics timestamp used to derive the partial-hour interval.
            result = saved
            result.problem = nil
        }
        let cutoff = now.addingTimeInterval(-86400)
        var points = (saved?.power ?? []).filter { $0.time >= cutoff && $0.time <= now }
        result.logsFetchedAt = saved?.logsFetchedAt
        result.logsCoveredFrom = saved?.logsCoveredFrom
        guard let dp = device.powerDP else {
            if saved?.power != nil { result.power = points }
            return result
        }
        do {
            let since = max(cutoff, min(saved?.logsFetchedAt?.addingTimeInterval(-60) ?? cutoff, now))
            // Small batches avoid the account's frequency limit. Older gaps are
            // resumed on the next refresh; the hourly archive is already usable.
            var remainingPages = 12
            let recent = try await powerLogs(device.id, dp: dp, from: since, to: now, pages: &remainingPages)
            points += recent.points
            var incomplete = recent.incomplete
            var coveredFrom = recent.start
            if recent.start <= since, let earlier = saved?.logsCoveredFrom, earlier <= since {
                coveredFrom = max(cutoff, earlier)
                if coveredFrom > cutoff, remainingPages > 0 {
                    let earlierLogs = try await powerLogs(device.id, dp: dp, from: cutoff, to: coveredFrom, pages: &remainingPages)
                    points += earlierLogs.points
                    coveredFrom = earlierLogs.start
                    incomplete = incomplete || earlierLogs.incomplete
                }
            }
            result.logsCoveredFrom = coveredFrom
            result.logsFetchedAt = now
            if incomplete {
                result.problem = [result.problem, "Detailed history is partial; hourly totals are shown in gaps"].compactMap { $0 }.joined(separator: " · ")
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.problem = [result.problem, "Tuya power log unavailable"].compactMap { $0 }.joined(separator: " · ")
        }
        result.power = Array(Dictionary(points.map { ($0.time, $0) }, uniquingKeysWith: { _, new in new })
            .values.sorted { $0.time < $1.time }.suffix(86_400))
        return result
    }

    private func powerLogs(_ id: String, dp: TuyaPowerDP, from start: Date, to end: Date, pages: inout Int) async throws -> (points: [PowerPoint], start: Date, incomplete: Bool) {
        let lower = Int64(floor(start.timeIntervalSince1970)) * 1000
        let upper = Int64((end.timeIntervalSince1970 * 1000).rounded(.down))
        var points: [PowerPoint] = []
        var pending = [(lower, upper)]
        var coveredFrom = end
        while pages > 0, let (from, through) = pending.popLast() {
            try Task.checkCancellation()
            let body: [String: Any] = ["devId": id, "dpIds": String(dp.id), "offset": 0, "limit": 100,
                                       "startTime": String(from), "endTime": String(through), "sortType": "DESC"]
            let page: [String: Any]
            do {
                // Preserve all successful pages if a later request fails.
                page = CloudValue.object(try await read(Self.powerLogAction, data: body, version: "1.0"))
            } catch is CancellationError { throw CancellationError() }
            catch { return (points, coveredFrom, true) }
            pages -= 1
            guard let rows = page["dps"] as? [[String: Any]], rows.count <= 100 else { return (points, coveredFrom, true) }
            var invalid = false
            for row in rows {
                guard let time = CloudValue.date(row["timeStamp"]),
                      let ms = Int64(exactly: (time.timeIntervalSince1970 * 1000).rounded()) else { continue }
                guard ms >= from && ms <= through else { invalid = true; continue }
                guard time >= start && time <= end else { continue }
                if CloudValue.number(row["dpId"]) == Double(dp.id), let watts = dp.watts(row["value"]) {
                    points.append(PowerPoint(time: time, watts: watts))
                }
            }
            guard !invalid else { return (points, coveredFrom, true) }
            let more = page["hasNext"] as? Bool == true || (CloudValue.number(page["total"]).map { $0 > Double(rows.count) } ?? (page["hasNext"] == nil && rows.count == 100))
            if more {
                // Real accounts ignore offset and sometimes ignore sort order.
                // Disjoint second-aligned windows cannot skip tied timestamps.
                guard !rows.isEmpty, from / 1000 < through / 1000 else { return (points, coveredFrom, true) }
                let middle = (from / 1000 + (through / 1000 - from / 1000 + 1) / 2) * 1000
                pending.append((from, middle - 1))
                pending.append((middle, through))
            } else {
                coveredFrom = max(start, Date(timeIntervalSince1970: Double(from) / 1000))
            }
            if pages > 0 && !pending.isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        return (points, coveredFrom, !pending.isEmpty)
    }

    private func statistics(for device: TuyaDevice, dp: Int, previous: TuyaHistory?, now: Date) async throws -> TuyaHistory {
        guard let zoneID = device.timeZoneID, let zone = TimeZone(identifier: zoneID) else {
            throw TuyaError.message("Tuya meter timezone is unavailable.")
        }
        let keys = TuyaHistory.keys(now: now)
        let dayFormatter = ChartHistory.formatter("yyyyMMdd")
        guard keys.allSatisfy({ key in
            let date = dayFormatter.date(from: key)!
            return zone.secondsFromGMT(for: date) == ChartHistory.calendar.timeZone.secondsFromGMT(for: date)
        }) else { throw TuyaError.message("Tuya and Deye use different timezones.") }
        let saved = previous.flatMap { $0.meterID == device.id && $0.timeZoneID == zoneID ? $0 : nil }
        var days = saved?.days.filter { keys.contains($0.key) } ?? []
        var hours = saved?.hours.filter { $0.end > now.addingTimeInterval(-86400) } ?? []
        var firstMissing = keys.dropLast().first { key in !days.contains { $0.key == key && $0.wattHours != nil } } ?? keys.last!
        // A cached "today" total was partial. Fetch it once more after midnight.
        if let saved {
            let lastFetchedDay = dayFormatter.string(from: saved.fetchedAt)
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
        let meterDayFormatter = ChartHistory.formatter("yyyyMMdd", zone: zone)
        for key in keys.suffix(2) {
          do {
            let data = base.merging(["date": key]) { _, new in new }
            let raw = try await read("tuya.m.dp.rang.stat.hour.list", data: data, version: "1.0")
            let fetched = TuyaHistory.hourly(raw, zone: zone, now: now).filter {
                meterDayFormatter.string(from: $0.start) == key
            }
            let incoming = Set(fetched.map(\.start))
            hours.removeAll { incoming.contains($0.start) }
            hours += fetched
        } catch is CancellationError { throw CancellationError() }
        catch { errors.append("Tuya hourly history unavailable") }
        }
        return TuyaHistory(meterID: device.id, timeZoneID: zoneID, days: days.sorted { $0.key < $1.key },
                           hours: hours.sorted { $0.start < $1.start }, fetchedAt: now, problem: errors.isEmpty ? nil : errors.joined(separator: " · "))
    }
    func savedEmail() -> String { try? load(); return account?.email ?? "" }
}
