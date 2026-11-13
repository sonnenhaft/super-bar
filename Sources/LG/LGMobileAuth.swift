import Foundation
import CryptoKit

// Native implementation of the ThinQ mobile account protocol. Protocol references:
// https://github.com/RobotPool/homebridge-lg-thinq/blob/master/src/lib/Auth.ts
// https://github.com/ollo69/ha-smartthinq-sensors/issues/1016
struct LGMobileSession: Codable {
    let email: String, password: String, country: String, client: String
    let apiURL: String, oauthURL: String, userNumber: String
    var accessToken: String, refreshToken: String, expiresAt: Date
}

enum LGMobileCredentials {
    static func read(vault: any CredentialVault = CredentialAccess.shared) throws -> LGMobileSession? {
        guard let data = try vault.read("lg-session") else { return nil }
        return try JSONDecoder().decode(LGMobileSession.self, from: data)
    }
    static func save(_ session: LGMobileSession, vault: any CredentialVault = CredentialAccess.shared) throws {
        try vault.write(JSONEncoder().encode(session), key: "lg-session")
    }
}

struct LGMobileHTTP {
    let network: URLSession
    static let clientID = "LGAO221A02"
    static let applicationKey = "6V1V8H2BN5P9ZQGOI5DAQ92YZBDO3EK9"
    // Public protocol signing constant, not an account credential.
    static let oauthKey = "c053c2a6ddeb7ad97cb0eed0dcb31cf8"
    static func url(_ value: String, stage: String = "server") throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
              ["lgthinq.com", "lgaccount.com", "lgsmartplatform.com", "lgecloud.com", "lgeapi.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 || url.port == 46030 else {
            let parts = URLComponents(string: value)
            let host = parts?.host ?? "unknown"
            let safeHost = host.range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) != nil ? host : "invalid host"
            let port = parts?.port.map { ":\($0)" } ?? ""
            throw LGError(message: "LG \(stage): unsupported server \(safeHost)\(port).")
        }
        return url
    }
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        let url = try url(base)
        guard url.query == nil else { throw LGError(message: "Invalid LG server address.") }
        return try Self.url(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)
    }
    static func form(_ values: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.map { $0.0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }
    static func date(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: now)
    }
    static func signature(_ input: String) -> String {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: Data(oauthKey.utf8)))).base64EncodedString()
    }
    static func headers(country: String, client: String) -> [String: String] {
        ["x-api-key": "VGhpblEyLjAgU0VSVklDRQ==", "x-client-id": client,
         "x-country-code": country, "x-language-code": "en-" + country,
         "x-message-id": UUID().uuidString, "x-service-code": "SVC202", "x-service-phase": "OP",
         "x-thinq-app-level": "PRD", "x-thinq-app-os": "ANDROID", "x-thinq-app-type": "NUTS", "x-thinq-app-ver": "5.0.1200"]
    }
    func data(_ url: URL, headers: [String: String] = [:], body: String? = nil, json: [String: Any]? = nil, stage: String) async throws -> Data {
        _ = try Self.url(url.absoluteString, stage: stage)
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.httpMethod = body == nil && json == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await CloudResponse.data(for: request, using: network)
        guard let response = response as? HTTPURLResponse else { throw LGError(message: "LG \(stage): no response.") }
        guard (200..<300).contains(response.statusCode) else { throw LGError(message: "LG \(stage): HTTP \(response.statusCode).") }
        return data
    }
    func json(_ url: URL, headers: [String: String] = [:], body: String? = nil, payload: [String: Any]? = nil, stage: String) async throws -> [String: Any] {
        let data = try await data(url, headers: headers, body: body, json: payload, stage: stage)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LGError(message: "LG \(stage): invalid response.") }
        if result["error"] != nil || result["lgoauth_error_code"] != nil || (result["status"] as? Int).map({ $0 != 1 }) == true || (result["resultCode"] as? String).map({ $0 != "0000" }) == true {
            // Provider messages may echo user input or tokens. Expose bounded codes only.
            let code = object(result["error"] ?? [:])["code"] ?? result["lgoauth_error_code"] ?? result["resultCode"] ?? "rejected"
            let raw = String(describing: code)
            let safe = raw.range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) != nil ? raw : "rejected"
            throw LGError(message: "LG \(stage): \(safe).")
        }
        return result
    }
    func oauth(_ base: String, fields: [(String, String)]) async throws -> [String: Any] {
        let date = Self.date(), body = Self.form(fields)
        let path = "/oauth/1.0/oauth2/token"
        return try await json(Self.endpoint(base, String(path.dropFirst())), headers: [
            "x-lge-appkey": Self.clientID, "x-lge-app-os": "ADR", "x-lge-oauth-date": date,
            "x-lge-oauth-signature": Self.signature(path + "?" + body + "\n" + date)
        ], body: body, stage: "token exchange")
    }
    static func required(_ key: String, in object: [String: Any], stage: String) throws -> String {
        if let value = object[key] as? String, !value.isEmpty { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
        throw LGError(message: "LG \(stage): missing \(key).")
    }
    static func expiry(_ token: [String: Any]) -> Date {
        let seconds = CloudValue.number(token["expires_in"]) ?? 3600
        return Date().addingTimeInterval(min(86400, max(60, seconds)))
    }
    static func oauthBackend(_ value: Any?, fallback: String) throws -> String {
        // This optional hint can be empty or malformed in a successful response.
        // Never send credentials to it unless it is a trusted HTTPS LG endpoint;
        // retain the already validated server that completed the token exchange.
        let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = !value.isEmpty && (try? url(value)) != nil ? value : fallback
        _ = try url(selected, stage: "token backend")
        return selected
    }
}

enum LGMobileAuth {
    static func login(email: String, password: String, country: String, network: URLSession) async throws -> LGMobileSession {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines), country = country.uppercased()
        guard !email.isEmpty, !password.isEmpty, country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { throw LGError(message: "Enter your LG email, password and two-letter country.") }
        let http = LGMobileHTTP(network: network), client = UUID().uuidString
        let gateway = try await http.json(LGMobileHTTP.url("https://route.lgthinq.com:46030/v1/service/application/gateway-uri"), headers: LGMobileHTTP.headers(country: country, client: client), stage: "gateway")
        let routes = object(gateway["result"] ?? [:])
        let loginBase = try LGMobileHTTP.required("empSpxUri", in: routes, stage: "gateway")
        let empBase = try LGMobileHTTP.required("empTermsUri", in: routes, stage: "gateway")
        let apiBase = try LGMobileHTTP.required("thinq2Uri", in: routes, stage: "gateway")
        _ = try LGMobileHTTP.url(apiBase, stage: "gateway thinq2Uri")
        _ = try LGMobileHTTP.url(loginBase, stage: "gateway empSpxUri")
        _ = try LGMobileHTTP.url(empBase, stage: "gateway empTermsUri")
        var headers = ["X-Application-Key": LGMobileHTTP.applicationKey, "X-Client-App-Key": LGMobileHTTP.clientID,
            "X-Lge-Svccode": "SVC709", "X-Device-Type": "M01", "X-Device-Platform": "ADR", "X-Device-Language-Type": "IETF",
            "X-Device-Publish-Flag": "Y", "X-Device-Country": country, "X-Device-Language": "en-" + country]
        let hash = SHA512.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        let pre = try await http.json(LGMobileHTTP.endpoint(loginBase, "preLogin"), headers: headers, body: LGMobileHTTP.form([
            ("user_auth2", hash), ("log_param", "login request / user_id : \(email) / third_party : null / svc_list : SVC202,SVC710 / 3rd_service : ")]), stage: "pre-login")
        headers["X-Signature"] = try LGMobileHTTP.required("signature", in: pre, stage: "pre-login")
        headers["X-Timestamp"] = try LGMobileHTTP.required("tStamp", in: pre, stage: "pre-login")
        let accountResult = try await http.json(LGMobileHTTP.endpoint(empBase, "emp/v2.0/account/session/" + API.deviceComponent(email)), headers: headers, body: LGMobileHTTP.form([
            ("user_auth2", try LGMobileHTTP.required("encrypted_pw", in: pre, stage: "pre-login")), ("password_hash_prameter_flag", "Y"), ("svc_list", "SVC202,SVC710")]), stage: "account login")
        let account = object(accountResult["account"] ?? [:])
        let state = UUID().uuidString, redirect = "lgaccount.lgsmartthinq:/"
        let query = LGMobileHTTP.form([
            ("account_type", try LGMobileHTTP.required("userIDType", in: account, stage: "account login")), ("client_id", LGMobileHTTP.clientID),
            ("country_code", try LGMobileHTTP.required("country", in: account, stage: "account login")), ("redirect_uri", redirect),
            ("response_type", "code"), ("state", state), ("username", try LGMobileHTTP.required("userID", in: account, stage: "account login"))])
        let date = LGMobileHTTP.date(), path = "/emp/oauth2/authorize/empsession?" + query
        let signatureURL = try LGMobileHTTP.endpoint(loginBase, "signature?" + LGMobileHTTP.form([
            ("kind", "oauth2"), ("timestamp", path + "\n" + date), ("key_name", "OAUTH_SECRETKEY"), ("sever_type", "OP")]))
        let signatureData = try await http.data(signatureURL, stage: "signature")
        let signature = String(decoding: signatureData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: signature)?.count == 20 else { throw LGError(message: "LG signature: invalid response.") }
        let authorization = try await http.json(LGMobileHTTP.url("https://emp-oauth.lgecloud.com" + path), headers: [
            "lgemp-x-app-key": "LGAO722A02", "lgemp-x-date": date, "lgemp-x-signature": signature,
            "lgemp-x-session-key": try LGMobileHTTP.required("loginSessionID", in: account, stage: "account login"),
            "X-Device-Type": "M01", "X-Device-Platform": "ADR"], stage: "authorization")
        let raw = try LGMobileHTTP.required("redirect_uri", in: authorization, stage: "authorization")
        let candidates = [raw, raw.removingPercentEncoding ?? raw]
        guard let parameters = candidates.compactMap({ URLComponents(string: $0)?.queryItems }).first(where: { $0.contains { $0.name == "code" } }),
              let code = parameters.first(where: { $0.name == "code" })?.value else { throw LGError(message: "LG authorization: no code returned.") }
        if let returnedState = parameters.first(where: { $0.name == "state" })?.value, returnedState != state { throw LGError(message: "LG authorization: state mismatch.") }
        let oauthBase = parameters.first(where: { $0.name == "oauth2_backend_url" })?.value
            ?? object(routes["uris"] ?? [:])["empOauthBaseUri"] as? String
            ?? "https://\(country.lowercased()).lgeapi.com/"
        _ = try LGMobileHTTP.url(oauthBase, stage: "authorization backend")
        let token = try await http.oauth(oauthBase, fields: [("code", code), ("grant_type", "authorization_code"), ("redirect_uri", redirect)])
        let access = try LGMobileHTTP.required("access_token", in: token, stage: "token exchange")
        let refresh = try LGMobileHTTP.required("refresh_token", in: token, stage: "token exchange")
        let sessionOAuthBase = try LGMobileHTTP.oauthBackend(token["oauth2_backend_url"], fallback: oauthBase)
        let profileDate = LGMobileHTTP.date()
        let profile = try await http.json(LGMobileHTTP.endpoint(sessionOAuthBase, "users/profile"), headers: [
            "Authorization": "Bearer " + access, "X-Lge-Svccode": "SVC202", "X-Application-Key": LGMobileHTTP.applicationKey,
            "lgemp-x-app-key": LGMobileHTTP.clientID, "X-Device-Type": "M01", "X-Device-Platform": "ADR",
            "x-lge-oauth-date": profileDate, "x-lge-oauth-signature": LGMobileHTTP.signature("/users/profile\n" + profileDate)], stage: "profile")
        return LGMobileSession(email: email, password: password, country: country, client: client, apiURL: apiBase, oauthURL: sessionOAuthBase,
            userNumber: try LGMobileHTTP.required("userNo", in: object(profile["account"] ?? [:]), stage: "profile"),
            accessToken: access, refreshToken: refresh, expiresAt: LGMobileHTTP.expiry(token))
    }
}
