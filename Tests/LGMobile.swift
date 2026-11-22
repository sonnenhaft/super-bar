import Foundation
import CryptoKit

private final class MockMobileLG: URLProtocol {
    static var failure = "", tokenRequests = 0
    static var paths: [String] = []
    static var controls: [[String: Any]] = []
    static var authorizePath = "", authorizeDate = ""
    static let model: [String: Any] = ["MonitoringValue": [
        "airState.operation": ["dataType": "Enum", "valueMapping": ["0": ["label": "@AC_MAIN_OPERATION_OFF_W"], "1": ["label": "@AC_MAIN_OPERATION_ALL_ON_W"]]],
        "airState.opMode": ["dataType": "Enum", "valueMapping": ["0": ["label": "@AC_MAIN_OPERATION_MODE_COOL_W"]]],
        "airState.windStrength": ["dataType": "Enum", "valueMapping": ["2": ["label": "@AC_MAIN_WIND_STRENGTH_LOW_W"], "4": ["label": "@AC_MAIN_WIND_STRENGTH_HIGH_W"]]],
        "airState.tempState.target": ["dataType": "Range", "valueMapping": ["min": 18, "max": 30, "step": 1]]
    ]]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.paths.append(path)
        let bodyData = body(), bodyText = String(decoding: bodyData, as: UTF8.self)
        let fields = URLComponents(string: "https://fixture.invalid/?" + bodyText)?.queryItems ?? []
        func field(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        var value: [String: Any] = [:], raw: Data?
        var status = 200
        switch path {
        case "/v1/service/application/gateway-uri":
            value = ["resultCode": "0000", "result": ["empSpxUri": Self.failure == "host" ? "https://lgaccount.com.attacker.invalid/spx" : "https://ph.m.lgaccount.com/spx", "empTermsUri": "https://ph.emp.lgsmartplatform.com", "thinq2Uri": "https://kic.lgthinq.com:46030/v1"]]
        case "/spx/preLogin":
            precondition(request.url!.host == "ph.m.lgaccount.com", "Region must not silently become US")
            let expected = SHA512.hash(data: Data(" pass +& word ".utf8)).map { String(format: "%02x", $0) }.joined()
            precondition(field("user_auth2") == expected, "Password must preserve whitespace and be hashed")
            value = ["signature": "pre-signature", "tStamp": "123", "encrypted_pw": "encrypted+password"]
        case let p where p.hasPrefix("/emp/v2.0/account/session/"):
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath.hasSuffix("test%2Blg%40example.com"))
            precondition(field("user_auth2") == "encrypted+password")
            precondition(request.value(forHTTPHeaderField: "X-Signature") == "pre-signature")
            value = Self.failure == "password" ? ["error": ["code": "INVALID_PASSWORD", "message": "do not echo credentials"]] : ["account": ["userIDType": "LGE", "country": "PH", "userID": "test+lg@example.com", "loginSessionID": "test-session"]]
            if Self.failure == "wrong-email" { status = 406; value = ["error": ["code": "MS.001.01", "message": "do not echo credentials"]] }
        case "/spx/signature":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let signed = query.first { $0.name == "timestamp" }!.value!
            let lines = signed.split(separator: "\n", maxSplits: 1).map(String.init)
            Self.authorizePath = lines[0]; Self.authorizeDate = lines[1]
            raw = Data((Self.failure == "signature" ? "<html>404</html>" : Data(repeating: 1, count: 20).base64EncodedString()).utf8)
        case "/emp/oauth2/authorize/empsession":
            precondition(url.path + "?" + (url.query ?? "") == Self.authorizePath, "Signed query differs from sent request")
            precondition(request.value(forHTTPHeaderField: "lgemp-x-date") == Self.authorizeDate)
            precondition(request.value(forHTTPHeaderField: "lgemp-x-session-key") == "test-session")
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            let redirect = "lgaccount.lgsmartthinq:/?" + LGMobileHTTP.form([("code", "test-code"), ("state", Self.failure == "state" ? "incorrect" : state), ("oauth2_backend_url", "https://kr.lgeapi.com/")])
            value = ["status": 1, "redirect_uri": redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!]
        case "/oauth/1.0/oauth2/token":
            Self.tokenRequests += 1
            let date = request.value(forHTTPHeaderField: "x-lge-oauth-date")!
            precondition(request.value(forHTTPHeaderField: "x-lge-oauth-signature") == LGMobileHTTP.signature(path + "?" + bodyText + "\n" + date))
            if field("grant_type") == "authorization_code" { precondition(field("code") == "test-code") }
            else { precondition(field("refresh_token") == "test-refresh") }
            value = ["access_token": "test-access", "refresh_token": "test-refresh", "expires_in": "3600", "oauth2_backend_url": ""]
        case "/users/profile": value = ["status": 1, "account": ["userNo": "test-user"]]
        case "/v1/service/application/dashboard":
            precondition(request.value(forHTTPHeaderField: "x-emp-token") == "test-access")
            if Self.failure == "devices" { status = 503 }
            let legacy: [String: Any] = ["deviceType": 401, "deviceId": "legacy", "platformType": "thinq1"]
            let valid: [String: Any] = ["deviceType": 401, "deviceId": "test-device", "alias": "Window AC", "platformType": "thinq2", "modelJsonUri": "https://objectcontent.lgthinq.com/model.json"]
            let malformed: [String: Any] = ["deviceType": 401, "platformType": "thinq2"]
            let television: [String: Any] = ["deviceType": 701, "deviceId": "television", "alias": "Living TV",
                                              "macAddress": "02:00:00:00:00:01", "online": false]
            let second: [String: Any] = ["deviceType": "701", "deviceId": "other-tv", "alias": "Living TV", "online": true]
            let items: [[String: Any]]
            switch Self.failure {
            case "unsupported": items = [legacy]
            case "tv-only": items = [legacy, television, second, television]
            default: items = [legacy, malformed, valid, television, second, television]
            }
            value = ["resultCode": "0000", "result": ["item": items]]
        case "/model.json":
            precondition(request.value(forHTTPHeaderField: "x-emp-token") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            value = Self.model
        case "/v1/service/devices/test-device":
            value = ["resultCode": "0000", "result": ["online": true, "snapshot": ["airState": ["operation": Self.failure == "off" ? 0 : 1, "opMode": 0, "windStrength": 4, "tempState": ["current": 27, "target": 22]]]]]
        case "/v1/service/aircon/test-device/energy-history":
            precondition(request.httpMethod == "GET" && bodyData.isEmpty)
            precondition(request.value(forHTTPHeaderField: "x-emp-token") == "test-access" && request.value(forHTTPHeaderField: "Authorization") == nil)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let param = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
            precondition(param["type"] == "period", "The real ThinQ endpoint requires type=period")
            let hourly = param["period"] == "hour"
            precondition(hourly ? param["startDate"] == param["endDate"] : param["period"] == "day")
            if Self.failure == "history" { status = 503 }
            let rows: [[String: Any]] = hourly
                ? [["usedDate": param["endDate"]! + " 02:00:00", "energyData": 300, "unit": "Wh"],
                   ["usedDate": param["endDate"]! + " 03:00:00", "energyData": "0"],
                   ["usedDate": param["endDate"]! + " 04:00:00", "energyData": "100", "unit": "Wh"]]
                : [["usedDate": param["startDate"]!, "energyData": "1.5", "energyDataUnit": "kWh"],
                   ["usedDate": param["endDate"]!, "energyData": "10"],
                   ["usedDate": "2000-01-01", "energyData": 100, "unit": "Wh"],
                   ["usedDate": param["endDate"]!, "energyData": NSNull()]]
            value = ["resultCode": "0000", "result": Self.failure == "empty" ? [] : rows]
            if Self.failure == "archive" {
                value = ["resultCode": "0000", "result": hourly
                    ? [["usedDate": param["endDate"]! + " 02:00:00", "energyData": 372]]
                    : (1...3).map { ["usedDate": "2026-11-0\($0)", "energyData": $0 * 730] as [String: Any] }]
            }
        case "/devices/energy/test-device/usage":
            precondition(request.httpMethod == "GET" && bodyData.isEmpty && url.host == "api-kic.lgthinq.com")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-history-token"
                         && request.value(forHTTPHeaderField: "x-emp-token") == nil)
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            precondition(query["period"] == "DAILY" && query["property"] == "energyUsage")
            value = ["response": ["result": ["dataList": (1...3).map {
                ["date": "2026110\($0)", "energyUsage": $0 * 730] as [String: Any]
            }]]]
        case "/v1/service/devices/test-device/control-sync":
            let payload = try! JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            Self.controls.append(payload)
            value = ["resultCode": "0000", "result": [:]]
        default: fatalError("Unexpected mobile request: " + path)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: raw ?? (try! JSONSerialization.data(withJSONObject: value)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum LGMobileCheck {
    @MainActor static func checkHistory(_ client: LGMobileClient) async throws {
        let now = ChartHistory.formatter("yyyy-MM-dd HH:mm").date(from: "2026-11-05 04:15")!
        let queries = LGHistoryQuery.chartQueries(at: now)
        let day = try await client.energyHistory("test-device", query: queries[0])
        precondition(day.rowCount == 4 && day.records.count == 2 && day.records[0].wattHours == 1500
                     && day.records[1].wattHours == nil)
        let cloud = LGCloudHistory()
        func load(_ q: LGHistoryQuery) async throws -> LGHistoryPage { try await client.energyHistory("test-device", query: q) }
        await cloud.refresh("A", now: now, load: load)
        let series = cloud.devices["A"]!
        precondition(series.days.count == 1 && series.hasUnspecifiedUnit && series.hours.count == 3)
        precondition(series.hours.values.allSatisfy { $0.end <= now && $0.end > now.addingTimeInterval(-86400) })
        precondition(series.hours.values.contains { $0.watts == 0 } && series.hours.values.contains { $0.watts == 300 })
        let count = MockMobileLG.paths.count
        await cloud.refresh("A", now: now, load: load)
        precondition(count == MockMobileLG.paths.count, "Reopening the chart must reuse its cache")
        MockMobileLG.failure = "empty"
        await cloud.refresh("B", now: now, load: load)
        precondition(cloud.devices["B"]?.days.isEmpty == true && cloud.devices["B"]?.hours.isEmpty == true)
        MockMobileLG.failure = "history"
        do { _ = try await load(queries[0]); fatalError("Provider error treated as successful history") }
        catch { precondition(error.localizedDescription.contains("503")) }
        await cloud.refresh("A", now: now.addingTimeInterval(301), load: load)
        precondition(cloud.devices["A"]?.days.count == 1 && cloud.devices["A"]?.hasUnspecifiedUnit == true)
        MockMobileLG.failure = ""
        let dates = (1...4).map { ChartHistory.calendar.date(byAdding: .day, value: -$0, to: now)! }
        let raw = LGHistoryPage(records: dates.enumerated().map { LGHistoryRecord(start: $0.element, wattHours: nil, unscaled: Double($0.offset + 1) * 100) })
        let official = LGHistoryPage(records: dates.enumerated().map { LGHistoryRecord(start: $0.element, wattHours: Double($0.offset + 1) * 100) })
        precondition(raw.confirmedScale(against: official, before: now) == 1)
        precondition(raw.scaled(raw.confirmedScale(against: official, before: now)).records.map(\.wattHours) == [100, 200, 300, 400])
        let conflicting = LGHistoryPage(records: Array(official.records.prefix(3)) + [LGHistoryRecord(start: dates[3], wattHours: 900)])
        precondition(raw.confirmedScale(against: conflicting, before: now) == nil, "Conflicting dates must not produce a guessed energy unit")
        precondition(raw.confirmedScale(against: LGHistoryPage(records: Array(official.records.prefix(2))), before: now) == nil)
    }
    static func main() async throws {
        for absent in [nil, "", "  ", NSNull(), "null", "kr.lgeapi.com", "https://attacker.invalid", "https://kr.lgeapi.com/?unexpected=hint"] as [Any?] {
            let selected = try LGMobileHTTP.oauthBackend(absent, fallback: "https://kr.lgeapi.com/")
            precondition(selected == "https://kr.lgeapi.com/")
        }
        do { _ = try LGMobileHTTP.oauthBackend(nil, fallback: "https://attacker.invalid"); fatalError("Unsafe fallback accepted") } catch {}
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockMobileLG.self]
        let network = URLSession(configuration: config); defer { network.invalidateAndCancel() }
        let vault = MemoryCredentialVault()
        try vault.write(Data("fixture-connect-api-key".utf8), key: "lg-connect-api-key")
        try await LGMobileClient.connect(email: "test+lg@example.com", password: " pass +& word ", country: "ph", vault: vault, network: network)
        let saved = try vault.read("lg-session")!
        var session = try LGMobileCredentials.read(vault: vault)!
        precondition(session.password == " pass +& word " && session.country == "PH")
        let client = LGMobileClient(network: network, vault: vault)
        try await checkHistory(client)
        try vault.write(Data("test-history-token".utf8), key: "lg-token")
        MockMobileLG.failure = "archive"
        let historyQueries = LGHistoryQuery.chartQueries(at: ChartHistory.formatter("yyyy-MM-dd").date(from: "2026-11-05")!)
        let knownDays = try await client.energyHistory("test-device", query: historyQueries[0])
        let confirmedHours = try await client.energyHistory("test-device", query: historyQueries[1])
        precondition(knownDays.records.map(\.wattHours) == [730, 1460, 2190] && confirmedHours.records.first?.wattHours == 372,
                     "Real-shaped mobile history and separately authenticated DAILY usage must populate both charts")
        MockMobileLG.failure = ""
        let beforeDashboard = MockMobileLG.paths.count
        let api = API(network: network, vault: vault)
        let directory = try await api.accountDirectoryIfNeeded(hasDevices: false)!
        precondition(directory.airConditioners.map(\.id) == ["test-device"])
        precondition(directory.televisions == [
            LGAccountTelevision(id: "television", name: "Living TV", macAddress: "02:00:00:00:00:01", online: false),
            LGAccountTelevision(id: "other-tv", name: "Living TV", macAddress: nil, online: true)])
        let secondPass = try await api.accountDirectoryIfNeeded(hasDevices: true)
        precondition(secondPass == nil && MockMobileLG.paths.count == beforeDashboard + 1)
        MockMobileLG.failure = "tv-only"
        let tvOnly = try await client.accountDirectoryIfConfigured()!
        precondition(tvOnly.airConditioners.isEmpty && tvOnly.televisions.count == 2)
        MockMobileLG.failure = ""
        let list = try await client.requestIfConfigured("devices", payload: nil) as! [[String: Any]]
        precondition(list.compactMap { $0["deviceId"] as? String } == ["test-device"],
                     "Unsupported or incomplete devices must not suppress a supported AC in the same account")
        let profile = try await client.requestIfConfigured("devices/test-device/profile", payload: nil) as! [String: Any]
        precondition(LGCapability(profile: profile, group: "airFlow", key: "windStrength").options == ["HIGH", "LOW"])
        let state = try await client.requestIfConfigured("devices/test-device/state", payload: nil) as! [String: Any]
        precondition(LGSample(state).target == 22 && LGSample(state).room == 27 && LGSample(state).powerOn == true)
        MockMobileLG.failure = "off"
        let off = LGSample(try await client.requestIfConfigured("devices/test-device/state", payload: nil) as! [String: Any])
        precondition(off.online == true && off.powerOn == false)
        _ = try await client.requestIfConfigured("devices/test-device/control", payload: ["operation": ["airConOperationMode": "POWER_ON"]])
        precondition(MockMobileLG.controls.count == 1 && MockMobileLG.controls[0]["dataKey"] as? String == "airState.operation"
                     && MockMobileLG.controls[0]["dataValue"] as? String == "1", "Turning on an available LG sends only the power command")
        MockMobileLG.failure = ""
        _ = try await client.requestIfConfigured("devices/test-device/control", payload: ["airFlow": ["windStrength": "HIGH"]])
        precondition(MockMobileLG.controls.last?["dataValue"] as? String == "4")
        for preset in LGCoolingPreset.allCases {
            MockMobileLG.controls = []
            for (group, key, value) in preset.changes(windKey: "windStrength") {
                _ = try await client.requestIfConfigured("devices/test-device/control", payload: [group: [key: value]])
            }
            precondition(MockMobileLG.controls.map { $0["dataKey"] as! String } == ["airState.operation", "airState.opMode", "airState.tempState.target", "airState.windStrength"])
            precondition(MockMobileLG.controls[1]["dataValue"] as? String == "0")
            precondition(lgNumber(MockMobileLG.controls[2]["dataValue"]) == Double(preset.degrees))
            precondition(MockMobileLG.controls[3]["dataValue"] as? String == (preset == .high ? "4" : "2"))
        }
        let before = MockMobileLG.paths.count
        do { _ = try await client.requestIfConfigured("devices/test-device/control", payload: ["temperature": ["targetTemperature": 99]]); fatalError("Out-of-range control accepted") } catch {}
        precondition(MockMobileLG.paths.count == before)
        for failure in ["password", "wrong-email", "devices", "unsupported", "signature", "state", "host"] {
            MockMobileLG.failure = failure
            do { try await LGMobileClient.connect(email: "test+lg@example.com", password: " pass +& word ", country: "PH", vault: vault, network: network); fatalError("Bad login succeeded") }
            catch {
                precondition(!error.localizedDescription.contains("do not echo"))
                if failure == "wrong-email" { precondition(error.localizedDescription.contains("could not find this email")) }
            }
            let unchanged = try vault.read("lg-session")
            precondition(unchanged == saved, "Failed login replaced working credentials")
        }
        MockMobileLG.failure = ""
        session.expiresAt = .distantPast; try LGMobileCredentials.save(session, vault: vault)
        let tokens = MockMobileLG.tokenRequests
        _ = try await client.requestIfConfigured("devices", payload: nil)
        precondition(MockMobileLG.tokenRequests == tokens + 1)
        let refreshed = try LGMobileCredentials.read(vault: vault)!
        precondition(refreshed.expiresAt > Date())
        for url in ["http://ph.m.lgaccount.com/", "https://lgaccount.com.attacker.invalid/", "https://user:password@lgaccount.com/", "https://127.0.0.1/", "https://lgaccount.com:1234/"] {
            do { _ = try LGMobileHTTP.url(url); fatalError("Unsafe server accepted") } catch {}
        }
        print("LG mobile: chart history, units, zero, empty and failed responses, cache isolation, password login, refresh and device adapter verified with synthetic fixtures.")
    }
}
