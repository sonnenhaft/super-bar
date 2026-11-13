import Foundation
import CryptoKit
import Darwin
import CoreFoundation

enum DeyeError: LocalizedError {
    case signIn, unauthorized, message(String)
    var errorDescription: String? {
        switch self {
        case .signIn: return "Connect your Deye Cloud account."
        case .unauthorized: return "Deye rejected the saved login. Sign in again."
        case .message(let text): return text
        }
    }
    var needsSignIn: Bool {
        switch self { case .signIn, .unauthorized: return true; default: return false }
    }
}

// All authentication and station requests are serialized in this actor. Credentials
// stay on the validated Deye origin and never appear in errors or logs.
actor DeyeCloud {
    struct Session: Codable {
        var base: String
        var token: String
        var refresh_token: String?
        var expires_at: Double?
        var email: String?
        var password_sha256: String?
    }
    private let credentials: CloudCredentialStore
    private let importFile: URL?
    private let network: URLSession
    private let ownsSession: Bool
    private var account: Session?
    private var recoveryFailed = false

    init(file: URL, importFile: URL? = nil, network: URLSession? = nil, vault: any CredentialVault = CloudCredentialStore.defaultVault) {
        self.credentials = CloudCredentialStore(file: file, key: "deye-session", vault: vault)
        self.importFile = importFile
        self.ownsSession = network == nil
        self.network = network ?? CloudRedirects.session()
    }
    deinit { if ownsSession { network.invalidateAndCancel() } }

    static func checkedBase(_ value: String) throws -> String {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              ["deyecloud.com", "www.deyecloud.com", "eu1.deyecloud.com", "us1.deyecloud.com", "india.deyecloud.com"].contains(host)
        else { throw DeyeError.message("Invalid Deye Cloud server.") }
        return "https://" + host
    }
    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    private func load() throws {
        guard account == nil else { return }
        guard let saved = try credentials.load(Session.self, importFile: importFile, validate: { saved in
            var saved = saved
            guard !saved.token.isEmpty else { throw DeyeError.signIn }
            saved.base = try Self.checkedBase(saved.base)
            saved.token = saved.token.replacingOccurrences(of: "Bearer ", with: "")
            return saved
        }) else { throw DeyeError.signIn }
        account = saved
    }
    private func save() throws {
        guard let account else { throw DeyeError.signIn }
        try credentials.save(account)
    }
    private func unwrap(_ value: Any) -> Any { (value as? [String: Any])?["data"] as? [String: Any] ?? value }
    private func request(_ path: String, body: [String: Any]? = nil, query: [String: String] = [:], authenticated: Bool = true) async throws -> Any {
        guard let account else { throw DeyeError.signIn }
        var parts = URLComponents(string: try Self.checkedBase(account.base) + path)!
        parts.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = body != nil || !authenticated ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if authenticated { request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await CloudResponse.data(for: request, using: network) }
        catch { if Task.isCancelled { throw CancellationError() }; throw DeyeError.message("Could not connect to Deye Cloud.") }
        guard let http = response as? HTTPURLResponse else { throw DeyeError.message("Invalid Deye response.") }
        if http.statusCode == 401 || (!authenticated && [400,403].contains(http.statusCode)) { throw DeyeError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw DeyeError.message("Deye HTTP \(http.statusCode).") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw DeyeError.message("Deye returned invalid JSON.") }
        if let object = json as? [String: Any], object["success"] as? Bool == false || !(object["error"] as? String ?? "").isEmpty {
            let code = String(describing: object["code"] ?? "")
            if !authenticated || code == "401" || ["invalid_token", "expired_token", "token_expired"].contains(object["error"] as? String ?? "") { throw DeyeError.unauthorized }
            throw DeyeError.message("Deye rejected the request.")
        }
        return unwrap(json)
    }
    private func acceptTokens(_ value: Any, refreshing: Bool) throws {
        guard let value = value as? [String: Any], let token = value["access_token"] as? String, !token.isEmpty else { throw DeyeError.unauthorized }
        account?.token = token.replacingOccurrences(of: "Bearer ", with: "")
        if let refresh = value["refresh_token"] as? String, !refresh.isEmpty { account?.refresh_token = refresh }
        else if !refreshing { account?.refresh_token = nil }
        account?.expires_at = Self.number(value["expires_in"]).map { Date().timeIntervalSince1970 + $0 }
        recoveryFailed = false
        try save()
    }
    private func passwordGrant() async throws {
        guard let email = account?.email, let hash = account?.password_sha256, !email.isEmpty, !hash.isEmpty else { throw DeyeError.signIn }
        let data = try await request("/oauth-s/oauth/token", query: [
            "grant_type":"password", "identity_type":"2", "username":email, "password":hash,
            "client_id":"test", "org_id":"0", "record_flag":"0", "system":"Deye"
        ], authenticated: false)
        try acceptTokens(data, refreshing: false)
    }
    private func recover() async throws {
        guard !recoveryFailed else { throw DeyeError.unauthorized }
        if let token = account?.refresh_token, !token.isEmpty {
            do {
                let data = try await request("/oauth-s/oauth/token", query: ["grant_type":"refresh_token", "refresh_token":token, "client_id":"test", "system":"Deye"], authenticated: false)
                try acceptTokens(data, refreshing: true)
                return
            } catch DeyeError.unauthorized { /* Try the saved password hash once. */ }
        }
        do { try await passwordGrant() }
        catch DeyeError.unauthorized { recoveryFailed = true; throw DeyeError.unauthorized }
        catch DeyeError.signIn { recoveryFailed = true; throw DeyeError.signIn }
    }
    private func call(_ path: String, body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> Any {
        try load()
        guard !recoveryFailed else { throw DeyeError.unauthorized }
        if let expiry = account?.expires_at, expiry <= Date().timeIntervalSince1970 + 60 { try await recover() }
        do { return try await request(path, body: body, query: query) }
        catch DeyeError.unauthorized {
            try await recover()
            do { return try await request(path, body: body, query: query) }
            catch DeyeError.unauthorized { recoveryFailed = true; throw DeyeError.unauthorized }
        }
    }
    func signIn(email: String, password: String, base: String) async throws {
        var base = try Self.checkedBase(base)
        // Resolve public regional redirects before credentials are attached.
        for _ in 0..<5 {
            var request = URLRequest(url: URL(string: base + "/")!)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let response: URLResponse
            do { (_, response) = try await CloudResponse.data(for: request, using: network) }
            catch { throw DeyeError.message("Could not connect to Deye Cloud.") }
            guard let http = response as? HTTPURLResponse else { throw DeyeError.message("Invalid Deye response.") }
            if (300..<400).contains(http.statusCode), let target = http.value(forHTTPHeaderField: "Location"),
               let url = URL(string: target, relativeTo: request.url)?.absoluteURL {
                let next = try Self.checkedBase(url.absoluteString)
                if next == base { break }
                base = next
            } else if (200..<300).contains(http.statusCode) { break }
            else { throw DeyeError.message("Deye HTTP \(http.statusCode).") }
        }
        let previous = account
        account = Session(base: base, token: "", email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                          password_sha256: SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined())
        recoveryFailed = false
        do { try await passwordGrant() }
        catch { account = previous; throw error }
    }
    func snapshot(previous: DeyeReading?, includeHistory: Bool) async throws -> DeyeReading {
        var stationID = previous?.id
        var name = previous?.name ?? "Deye"
        if stationID == nil {
            let data = try await call("/maintain-s/operating/station/search", body: [:], query: ["order.direction":"DESC", "order.property":"id", "page":"1", "size":"100"])
            let object = data as? [String: Any]
            let rows = (object?["data"] ?? object?["records"] ?? data) as? [[String: Any]]
            guard let station = rows?.first, let raw = Self.number(station["id"] ?? station["stationId"]), raw > 0, raw.rounded() == raw, raw < Double(Int.max) else { throw DeyeError.message("No Deye station found.") }
            stationID = Int(raw)
            name = station["name"] as? String ?? "Deye"
        }
        guard let id = stationID, let current = try await call("/maintain-s/operating/system/\(id)") as? [String: Any] else { throw DeyeError.message("Invalid Deye readings.") }
        var stamp = Self.number(current["lastUpdateTime"] ?? current["collectionTime"])
        if let raw = stamp, raw > 1e12 { stamp = raw / 1000 }
        var days = previous?.days ?? []
        var curve = previous?.curve
        if includeHistory {
            days = []
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            for ago in -(ChartHistory.accountingDayCount(calendar: calendar) - 1)...0 {
                try Task.checkCancellation()
                let day = calendar.date(byAdding: .day, value: ago, to: Date())!
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                let key = formatter.string(from: day)
                if ago < -1, let lastHistoryDay = previous?.historyDay, lastHistoryDay != key,
                   let cached = previous?.days.first(where: { $0.day == key }), cached.kwh != nil {
                    days.append(cached)
                    continue
                }
                var value: Double?
                do {
                    let data = try await call("/maintain-s/history/batteryPower/\(id)/stats/daily", query: ["year":String(components.year!), "month":String(components.month!), "day":String(components.day!)]) as? [String: Any]
                    value = Self.number((data?["statistics"] as? [String: Any])?["generationValue"])
                    if ago >= -1, let rows = data?["records"] as? [[String: Any]] {
                        let fetched: [PowerPoint] = rows.compactMap { row in
                            guard let time = CloudValue.date(row["dateTime"]), calendar.isDate(time, inSameDayAs: day),
                                  let watts = Self.number(row["generationPower"]) else { return nil }
                            return PowerPoint(time: time, watts: watts)
                        }.sorted { $0.time < $1.time }
                        curve = (curve ?? []).filter { !calendar.isDate($0.time, inSameDayAs: day) } + fetched
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { value = nil }
                days.append(DeyeDay(day: formatter.string(from: day), kwh: value))
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        if let value = Self.number(current["generationValue"]) {
            days.removeAll { $0.day == today }
            days.append(DeyeDay(day: today, kwh: value))
        }
        curve = curve?.filter { $0.time >= Date().addingTimeInterval(-90000) && $0.time <= Date() }.sorted { $0.time < $1.time }
        return DeyeReading(id: stationID!, name: String(name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(160)),
                           power_w: Self.number(current["generationPower"]), today_kwh: Self.number(current["generationValue"]),
                           status: current["networkStatus"] as? String ?? "UNKNOWN", measured_at: stamp, days: days, curve: curve,
                           historyDay: includeHistory ? today : previous?.historyDay)
    }
}
