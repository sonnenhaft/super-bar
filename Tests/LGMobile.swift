import Foundation
import CryptoKit

private final class MockMobileLG: URLProtocol {
    static var failure = "", tokenRequests = 0
    static var paths: [String] = []
    static var authorizePath = "", authorizeDate = ""
    static let model: [String: Any] = ["MonitoringValue": [
        "airState.operation": ["dataType": "Enum", "valueMapping": ["0": ["label": "@AC_MAIN_OPERATION_OFF_W"], "1": ["label": "@AC_MAIN_OPERATION_ALL_ON_W"]]],
        "airState.opMode": ["dataType": "Enum", "valueMapping": ["0": ["label": "@AC_MAIN_OPERATION_MODE_COOL_W"]]],
        "airState.windStrength": ["dataType": "Enum", "valueMapping": ["2": ["label": "@AC_MAIN_WIND_STRENGTH_LOW_W"], "4": ["label": "@AC_MAIN_WIND_STRENGTH_HIGH_W"]]],
        "airState.tempState.target": ["dataType": "Range", "valueMapping": ["min": 16, "max": 30, "step": 1]]
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
            precondition(field("user_auth2") == "encrypted+password")
            precondition(request.value(forHTTPHeaderField: "X-Signature") == "pre-signature")
            value = Self.failure == "password" ? ["error": ["code": "INVALID_PASSWORD", "message": "do not echo credentials"]] : ["account": ["userIDType": "LGE", "country": "PH", "userID": "test+lg@example.com", "loginSessionID": "test-session"]]
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
            value = ["resultCode": "0000", "result": ["item": [["deviceType": 401, "deviceId": "test-device", "alias": "Window AC", "platformType": "thinq2", "modelJsonUri": "https://objectcontent.lgthinq.com/model.json"]]]]
        case "/model.json":
            precondition(request.value(forHTTPHeaderField: "x-emp-token") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            value = Self.model
        case "/v1/service/devices/test-device":
            value = ["resultCode": "0000", "result": ["snapshot": ["airState": ["operation": 1, "opMode": 0, "windStrength": 4, "tempState": ["current": 27, "target": 22]]]]]
        case "/v1/service/devices/test-device/control-sync":
            let payload = try! JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            precondition(payload["dataKey"] as? String == "airState.windStrength" && payload["dataValue"] as? String == "4")
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
    static func main() async throws {
        for absent in [nil, "", "  ", NSNull(), "null", "kr.lgeapi.com", "https://attacker.invalid"] as [Any?] {
            let selected = try LGMobileHTTP.oauthBackend(absent, fallback: "https://kr.lgeapi.com/")
            precondition(selected == "https://kr.lgeapi.com/")
        }
        do { _ = try LGMobileHTTP.oauthBackend(nil, fallback: "https://attacker.invalid"); fatalError("Unsafe fallback accepted") } catch {}
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockMobileLG.self]
        let network = URLSession(configuration: config); defer { network.invalidateAndCancel() }
        let vault = MemoryCredentialVault()
        try await LGMobileClient.connect(email: "test+lg@example.com", password: " pass +& word ", country: "ph", vault: vault, network: network)
        let saved = try vault.read("lg-session")!
        var session = try LGMobileCredentials.read(vault: vault)!
        precondition(session.password == " pass +& word " && session.country == "PH")
        let client = LGMobileClient(network: network, vault: vault)
        let list = try await client.requestIfConfigured("devices", payload: nil) as! [[String: Any]]
        precondition(list.count == 1)
        let profile = try await client.requestIfConfigured("devices/test-device/profile", payload: nil) as! [String: Any]
        precondition(LGCapability(profile: profile, group: "airFlow", key: "windStrength").options == ["HIGH", "LOW"])
        let state = try await client.requestIfConfigured("devices/test-device/state", payload: nil) as! [String: Any]
        precondition(LGSample(state).target == 22 && LGSample(state).room == 27 && LGSample(state).powerOn == true)
        _ = try await client.requestIfConfigured("devices/test-device/control", payload: ["airFlow": ["windStrength": "HIGH"]])
        let before = MockMobileLG.paths.count
        do { _ = try await client.requestIfConfigured("devices/test-device/control", payload: ["temperature": ["targetTemperature": 99]]); fatalError("Out-of-range control accepted") } catch {}
        precondition(MockMobileLG.paths.count == before)
        for failure in ["password", "devices", "signature", "state", "host"] {
            MockMobileLG.failure = failure
            do { try await LGMobileClient.connect(email: "test+lg@example.com", password: " pass +& word ", country: "PH", vault: vault, network: network); fatalError("Bad login succeeded") }
            catch { precondition(!error.localizedDescription.contains("do not echo")) }
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
        print("LG mobile: password flow/signatures, device adapter, refresh, failed-login preservation and credential host isolation verified with synthetic fixtures.")
    }
}
