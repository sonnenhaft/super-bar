import Foundation

private final class MockDeye: URLProtocol {
    static var mode = "valid"
    static var paths: [String] = []
    static var grants: [String] = []
    static var reads = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.paths.append(path)
        if Self.mode == "network" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var status = 200
        var body: [String: Any]
        if path == "/oauth-s/oauth/token" {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil, "Old bearer token leaked into renewal")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let grant = query.first { $0.name == "grant_type" }!.value!
            Self.grants.append(grant)
            if Self.mode == "login" {
                let hash = query.first { $0.name == "password" }?.value
                precondition(hash == "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8", "Native login did not hash the password")
            }
            if Self.mode == "badLogin" || (Self.mode == "fallback" && grant == "refresh_token") {
                status = 400
                body = ["error": "invalid_grant"]
            } else { body = ["access_token":"new-token", "refresh_token":"rotated", "expires_in":3600] }
        } else if path == "/" { body = [:]
        } else if path.contains("/operating/system/") {
            Self.reads += 1
            if Self.mode == "double401" || (Self.mode == "401" && Self.reads == 1) {
                status = 401
                body = ["error":"expired_token"]
            } else {
                body = ["data":["generationPower":3314, "generationValue":2.7, "networkStatus":"NORMAL", "lastUpdateTime":1794443261000], "error":NSNull()]
            }
        } else if path.contains("/stats/daily") {
            if Self.paths.filter({ $0.contains("/stats/daily") }).count == 2 { status = 500; body = [:] }
            else {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                func part(_ name: String) -> Int { Int(query.first { $0.name == name }!.value!)! }
                var components = calendar.dateComponents([.hour, .minute, .second], from: Date())
                components.year = part("year"); components.month = part("month"); components.day = part("day")
                let stamp = calendar.date(from: components)!.timeIntervalSince1970
                body = ["data":["statistics":["generationValue":29.7], "records": [["dateTime":stamp, "generationPower":1500]]]]
            }
        } else if path.contains("/station/search") {
            body = ["data":["data":[["id":61011710, "name":"Leela home solana4u"]]]]
        } else { fatalError("Unexpected Deye endpoint: " + path) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum DeyeSessionCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockDeye.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let previous = DeyeReading(id:61011710,name:"Leela home solana4u",power_w:nil,today_kwh:nil,status:"UNKNOWN",measured_at:nil,days:[])
        func fixture(_ mode: String, expired: Bool = false) throws -> (DeyeCloud, MemoryCredentialVault) {
            MockDeye.mode = mode; MockDeye.paths = []; MockDeye.grants = []; MockDeye.reads = 0
            let file = root.appendingPathComponent(UUID().uuidString + ".json")
            let account = DeyeCloud.Session(base:"https://eu1.deyecloud.com",token:"old-token",refresh_token:"old-refresh",
                                           expires_at:expired ? 1 : Date().timeIntervalSince1970 + 3600,
                                           email:"test@example.com",password_sha256:"fake-hash")
            try PrivateJSONFile.write(account, to: file)
            let vault = MemoryCredentialVault()
            return (DeyeCloud(file:file,network:network,vault:vault),vault)
        }
        let (login, loginVault) = try fixture("login")
        try await login.signIn(email:"test@example.com", password:"password", base:"https://eu1.deyecloud.com")
        precondition(MockDeye.grants == ["password"])
        let loginJSON = try JSONSerialization.jsonObject(with: loginVault.read("deye-session")!) as! [String:Any]
        precondition(loginJSON["password"] == nil && loginJSON["password_sha256"] != nil)
        precondition(loginJSON["token"] as? String == "new-token" && loginJSON["refresh_token"] as? String == "rotated")
        let (valid, _) = try fixture("valid")
        let reading = try await valid.snapshot(previous:nil,includeHistory:false)
        precondition(reading.id == 61011710 && reading.power_w == 3314 && reading.today_kwh == 2.7)
        precondition(reading.measured_at == 1794443261 && MockDeye.paths.count == 2 && MockDeye.grants.isEmpty)
        let (renew, renewedVault) = try fixture("valid",expired:true)
        _ = try await renew.snapshot(previous:previous,includeHistory:false)
        precondition(MockDeye.grants == ["refresh_token"])
        let saved = try renewedVault.saved(DeyeCloud.Session.self, key: "deye-session")
        precondition(saved.token == "new-token" && saved.refresh_token == "rotated" && saved.password_sha256 == "fake-hash")
        let (retry, _) = try fixture("401")
        _ = try await retry.snapshot(previous:previous,includeHistory:false)
        precondition(MockDeye.reads == 2 && MockDeye.grants == ["refresh_token"])
        let (fallback, _) = try fixture("fallback",expired:true)
        _ = try await fallback.snapshot(previous:previous,includeHistory:false)
        precondition(MockDeye.grants == ["refresh_token", "password"])
        for mode in ["badLogin", "double401"] {
            let (failed, _) = try fixture(mode,expired: mode == "badLogin")
            for _ in 0..<2 {
                do { _ = try await failed.snapshot(previous:previous,includeHistory:false); fatalError("Rejected login accepted") }
                catch DeyeError.unauthorized {}
            }
            precondition(MockDeye.grants.count == (mode == "badLogin" ? 2 : 1), "Infinite auth retries")
        }
        let (offline, _) = try fixture("network",expired:true)
        do { _ = try await offline.snapshot(previous:previous,includeHistory:false); fatalError("Offline request succeeded") }
        catch DeyeError.message(let text) { precondition(!text.contains("old-refresh") && !text.contains("fake-hash")) }
        precondition(MockDeye.grants.isEmpty, "Network failure triggered password login")
        let (partial, _) = try fixture("valid")
        let history = try await partial.snapshot(previous:previous,includeHistory:true)
        precondition(history.days.count == 30 && history.days[1].kwh == nil && history.power_w == 3314)
        precondition(Set(history.days.map(\.day)).count == 30)
        precondition(MockDeye.paths.filter { $0.contains("/stats/daily") }.count == 30)
        precondition(history.curve?.last?.watts == 1500 && history.days.last?.kwh == 2.7)
        precondition(history.curve?.count == 2, "Retain yesterday's curve for a rolling 24-hour window")
        _ = try await partial.snapshot(previous: history, includeHistory: true)
        precondition(MockDeye.paths.filter { $0.contains("/stats/daily") }.count == 33, "Reuse older totals; refresh both curve days and retry the missing day")
        MockDeye.mode = "valid"
        let source = root.appendingPathComponent("import.json")
        try PrivateJSONFile.write(DeyeCloud.Session(base: "https://eu1.deyecloud.com", token: "import-token"), to: source)
        let destination = root.appendingPathComponent("native/session.json")
        let importedVault = MemoryCredentialVault()
        let imported = DeyeCloud(file:destination,importFile:source,network:network,vault:importedVault)
        _ = try await imported.snapshot(previous:previous,includeHistory:false)
        precondition(!FileManager.default.fileExists(atPath:destination.path), "Import must save only to the credential vault")
        let importedSession = try importedVault.saved(DeyeCloud.Session.self, key: "deye-session")
        precondition(importedSession.token == "import-token")
        try FileManager.default.removeItem(at:source)
        let independent = DeyeCloud(file:destination,network:network,vault:importedVault)
        _ = try await independent.snapshot(previous:previous,includeHistory:false)
        precondition(DeyeCloud.number(true) == nil && DeyeCloud.number(-1) == nil && DeyeCloud.number(Double.nan) == nil && DeyeCloud.number(0) == 0)
        for invalid in ["http://eu1.deyecloud.com", "https://attacker.example", "https://user:password@eu1.deyecloud.com"] {
            do { _ = try DeyeCloud.checkedBase(invalid); fatalError("Unsafe Deye origin accepted") } catch {}
        }
        print("Deye Swift: session import/reuse, refresh/access tokens and password hashes in vault, bounded retries, partial history and no plaintext writes passed.")
    }
}
