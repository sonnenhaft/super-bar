import Foundation
import CryptoKit
import Darwin

private typealias CloudObject = [String: Any]

enum TCLCloudError: LocalizedError {
    case message(String)
    case http(String, Int)
    case expired
    case signInRequired
    case credentialsRejected

    var needsSignIn: Bool {
        switch self {
        case .expired, .signInRequired, .credentialsRejected, .http(_, 401): return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to TCL Home."
        case .credentialsRejected: return "Check your TCL Home email and password."
        case .message(let text): return text
        case .http(let service, let code): return "\(service): HTTP \(code)."
        case .expired: return "Your TCL Home session expired."
        }
    }
}

private func cloudString(_ object: CloudObject, _ keys: String...) -> String? {
    for key in keys {
        if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
}
private func cloudHex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
private func cloudMD5(_ text: String) -> String {
    cloudHex(Insecure.MD5.hash(data: Data(text.utf8)))
}
private func cloudJSON(_ data: Data, service: String) throws -> CloudObject {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? CloudObject else {
        throw TCLCloudError.message("\(service) returned an unexpected response.")
    }
    return object
}

// Follow only the explicit, validated cloud endpoints. Never forward an SSO
// body or a signed request to an HTTP redirect chosen by another host.

private final class CloudReply: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

// AWS IoT's Publish endpoint expects a once-escaped MQTT topic on the wire.
// SigV4 separately URI-encodes that path, including its existing percent signs.
struct TCLIoTSigner {
    let region: String, accessKey: String, secretKey: String, token: String

    static func escape(_ value: String, preservingSlash: Bool = false) -> String {
        var text = ""
        for b in value.utf8 {
            switch b {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                text.unicodeScalars.append(UnicodeScalar(b))
            case 47 where preservingSlash: text += "/"
            default: text += String(format: "%%%02X", b)
            }
        }
        return text
    }

    func request(method: String, wirePath: String, query: String = "", body: Data? = nil, now: Date = Date()) throws -> URLRequest {
        let host = "data-ats.iot.\(region).amazonaws.com"
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.percentEncodedPath = wirePath
        if !query.isEmpty { parts.percentEncodedQuery = query }
        guard let url = parts.url else { throw TCLCloudError.message("Invalid AWS IoT endpoint.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now), day = String(timestamp.prefix(8))
        let scope = "\(day)/\(region)/iotdata/aws4_request"
        var headers = ["host":host, "x-amz-date":timestamp, "x-amz-security-token":token]
        if body != nil { headers["content-type"] = "application/json" }
        let names = headers.keys.sorted()
        let signed = names.joined(separator: ";")
        let headerBlock = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let canonical = [method, Self.escape(wirePath, preservingSlash: true), query, headerBlock, signed,
                         cloudHex(SHA256.hash(data: body ?? Data()))].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", timestamp, scope, cloudHex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = Data(("AWS4" + secretKey).utf8)
        for item in [day, region, "iotdata", "aws4_request"] {
            key = Data(HMAC<SHA256>.authenticationCode(for: Data(item.utf8), using: SymmetricKey(data: key)))
        }
        let signature = cloudHex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: key)))
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }
}

final class TCLCloud {
    private let credentials: CloudCredentialStore
    private let session: URLSession
    private let ownsSession: Bool
    private var deviceBase: URL?
    private var saas = "", sso = ""
    private var signer: TCLIoTSigner?
    private struct Account: Codable {
        var email: String?, digest: String?, id: String?, token: String?, saved: Double?
        var password: String?
    }

    // Synchronous facade for the serial cloud worker and the command-line tool.
    // URLSession delivers completions on its own queue.
    init(directory: URL, session: URLSession? = nil, vault: any CredentialVault = CloudCredentialStore.defaultVault) {
        credentials = CloudCredentialStore(file: directory.appendingPathComponent(".tcl-auth.json"), key: "tcl-session", vault: vault)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        ownsSession = session == nil
        self.session = session ?? URLSession(configuration: config, delegate: CloudRedirects(), delegateQueue: nil)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    private func send(_ req: URLRequest, service: String) throws -> Data {
        let reply = CloudReply()
        let task = Task { [session] in
            do {
                let (data, response) = try await CloudResponse.data(for: req, using: session)
                reply.data = data; reply.response = response
            } catch { reply.error = error }
            reply.ready.signal()
        }
        if reply.ready.wait(timeout: .now() + min(req.timeoutInterval, 22) + 3) == .timedOut {
            task.cancel(); throw TCLCloudError.message("\(service) timed out.")
        }
        if let error = reply.error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed: throw TCLCloudError.message("Cannot reach \(service): server not found.")
            case .timedOut: throw TCLCloudError.message("\(service) timed out.")
            default: throw TCLCloudError.message("Cannot reach \(service) (\(error.code.rawValue)).")
            }
        }
        guard reply.error == nil, let response = reply.response as? HTTPURLResponse else {
            throw TCLCloudError.message("No response from \(service).")
        }
        guard (200..<300).contains(response.statusCode) else { throw TCLCloudError.http(service, response.statusCode) }
        return reply.data ?? Data()
    }

    private func json(_ url: URL, service: String = "TCL Home", body: CloudObject? = nil,
                      headers: [String:String] = [:], timeout: Double = 15) throws -> CloudObject {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key,value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        return try cloudJSON(send(req, service: service), service: service)
    }

    private func writeAccount(_ account: Account) throws {
        try credentials.save(account)
    }

    private func login(email: String, digest: String, password: String? = nil) throws -> Account {
        let url = URL(string: "https://sg.account.tcl.com/account/login?clientId=54148614")!
        let response = try json(url, body: [
            "username":email, "password":digest, "equipment":2, "osType":1, "clientVersion":"4.8.1",
            "osVersion":"6.0", "deviceModel":"AndroidAndroid SDK built for x86", "captchaRule":2, "channel":"app"
        ], headers:["User-Agent":"Android", "th_platform":"android", "th_version":"4.8.1", "th_appbulid":"830"])
        guard String(describing: response["status"] ?? "") == "1", let token = cloudString(response,"token"),
              let user = response["user"] as? CloudObject, let id = cloudString(user,"username") else {
            throw TCLCloudError.credentialsRejected
        }
        let account = Account(email:email, digest:digest, id:id, token:token, saved:Date().timeIntervalSince1970, password:password)
        try writeAccount(account)
        return account
    }

    func storeLogin(email: String, password: String) throws {
        _ = try login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), digest: cloudMD5(password), password: password)
        resetSession()
    }

    private var reuseUntil: TimeInterval = 0

    func resetSession() {
        reuseUntil = 0
        deviceBase = nil
        signer = nil
        saas = ""
        sso = ""
    }

    private func approvedEndpoint(_ raw: String?) throws -> URL {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme == "https", let host = parts.host,
              host.hasSuffix(".tcljd.com") || host.hasSuffix(".tcl.com"), parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path == "/" || parts.path.isEmpty, let url = parts.url else {
            throw TCLCloudError.message("TCL Home returned an unknown cloud endpoint.")
        }
        return url
    }

    private func refreshSession(for account: Account) throws -> (devices: URL, region: String, cognito: String?) {
        guard let id = account.id, let token = account.token else { throw TCLCloudError.signInRequired }
        let discovery = try json(URL(string:"https://prod-center.aws.tcljd.com/v3/global/cloud_url_get")!,
                                 body:["ssoId":id, "ssoToken":token])
        guard let endpoints = discovery["data"] as? CloudObject,
              let region = cloudString(endpoints,"cloud_region"),
              region.range(of: "^[a-z]{2}-[a-z]+-[0-9]+$", options:.regularExpression) != nil else { throw TCLCloudError.expired }
        let auth = try approvedEndpoint(cloudString(endpoints,"cloud_url"))
        let devices = try approvedEndpoint(cloudString(endpoints,"device_url"))
        let result = try json(auth.appendingPathComponent("v3/auth/refresh_tokens"),
                              body:["userId":id, "ssoToken":token, "appId":"wx6e1af3fa84fbe523"])
        guard let session = result["data"] as? CloudObject, let access = cloudString(session,"saasToken","saas_token") else {
            throw TCLCloudError.expired
        }
        deviceBase = devices
        saas = access
        sso = token
        return (devices, region, cloudString(session,"cognitoToken","cognito_token"))
    }

    private func saasHeaders(_ client: [String:String]) -> [String:String] {
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.lowercased()
        return ["timestamp":stamp, "nonce":nonce, "sign":cloudMD5(stamp + nonce + saas), "accessToken":saas,
                "Accept-Language":"en"].merging(client) { _, new in new }
    }

    private func listDevices(at devices: URL) throws -> [CloudObject] {
        let headers = saasHeaders(["platform":"android", "appversion":"5.4.1", "thomeversion":"4.8.1"])
        let listing = try json(devices.appendingPathComponent("v3/user/get_things"), body:[:], headers:headers)
        guard let all = listing["data"] as? [CloudObject] else { throw TCLCloudError.message("TCL did not return a device list.") }
        return all.filter { row in
            let family = ["deviceName","device_name","deviceType","device_type","category"].compactMap { row[$0] as? String }
            if family.contains(where: { $0.range(of:"air.?conditioner|^(split|portable|window|duct|cylindrical) AC",
                                                  options:[.regularExpression,.caseInsensitive]) != nil }) { return true }
            return ["nickName","nick_name","deviceName","device_name"].compactMap { row[$0] as? String }
                .contains(where: { $0.range(of:#"\bair[ -]?con(?:ditioner)?$"#, options:[.regularExpression,.caseInsensitive]) != nil })
        }
    }

    func connect() throws -> [[String:Any]] {
        // Inventory stays fresh; only discovery, authentication and signing keys are reused.
        if let base = deviceBase, signer != nil, ProcessInfo.processInfo.systemUptime < reuseUntil {
            do { return try listDevices(at: base) }
            catch TCLCloudError.http(_, 401) {} catch TCLCloudError.http(_, 403) {}
            catch TCLCloudError.expired {} catch { resetSession(); throw error }
        }
        resetSession()
        let cached = try credentials.load(Account.self)
        let env = ProcessInfo.processInfo.environment
        func renewAccount() throws -> Account {
            guard let email = cached?.email, let digest = cached?.digest, !email.isEmpty, !digest.isEmpty else {
                throw TCLCloudError.signInRequired
            }
            return try login(email:email, digest:digest, password: cached?.password)
        }
        let account: Account
        let usingCachedSession: Bool
        let now = Date().timeIntervalSince1970
        if let id = env["TCL_SSO_ID"], !id.isEmpty, let token = env["TCL_SSO_TOKEN"], !token.isEmpty {
            account = Account(id: id, token: token)
            usingCachedSession = false
        } else if let cached, let saved = cached.saved, (0..<2700).contains(now - saved),
                  !(cached.id ?? "").isEmpty, !(cached.token ?? "").isEmpty {
            account = cached
            usingCachedSession = true
        } else {
            account = try renewAccount()
            usingCachedSession = false
        }
        let discovered: (devices: URL, region: String, cognito: String?)
        do {
            discovered = try refreshSession(for: account)
        } catch let error as TCLCloudError {
            let rejected: Bool
            switch error {
            case .expired, .http(_, 401), .http(_, 403): rejected = true
            default: rejected = false
            }
            guard usingCachedSession, rejected else { throw error }
            discovered = try refreshSession(for: renewAccount())
        }
        let (devices, region, cognito) = discovered
        let inventory = try listDevices(at: devices)
        guard !inventory.isEmpty else { return [] }
        guard let cognito else { throw TCLCloudError.expired }
        let pieces = cognito.components(separatedBy: ".")
        var encoded = pieces.count >= 2 ? pieces[1].replacingOccurrences(of:"-", with:"+").replacingOccurrences(of:"_", with:"/") : ""
        encoded += String(repeating:"=", count:(4 - encoded.utf8.count % 4) % 4)
        guard let claims = Data(base64Encoded:encoded), let object = try? cloudJSON(claims, service:"Cognito"),
              let identity = cloudString(object,"sub") else { throw TCLCloudError.message("TCL did not return a Cognito identity.") }
        let response = try json(URL(string:"https://cognito-identity.\(region).amazonaws.com/")!, service:"Cognito",
                                body:["IdentityId":identity, "Logins":["cognito-identity.amazonaws.com":cognito]],
                                headers:["Content-Type":"application/x-amz-json-1.1", "X-Amz-Target":"AWSCognitoIdentityService.GetCredentialsForIdentity"])
        guard let creds = response["Credentials"] as? CloudObject,
              let access = cloudString(creds,"AccessKeyId"), let secret = cloudString(creds,"SecretKey"),
              let keyToken = cloudString(creds,"SessionToken") else { throw TCLCloudError.message("Cognito did not grant access to the units.") }
        signer = TCLIoTSigner(region:region, accessKey:access, secretKey:secret, token:keyToken)
        let remaining = (creds["Expiration"] as? Double).map { $0 - Date().timeIntervalSince1970 - 30 } ?? 300
        reuseUntil = ProcessInfo.processInfo.systemUptime + max(0, min(300, remaining))
        return inventory
    }

    func shadow(id: String) throws -> [String:Any] {
        guard let signer else { throw TCLCloudError.expired }
        let req = try signer.request(method:"GET", wirePath:"/things/\(TCLIoTSigner.escape(id))/shadow")
        return try cloudJSON(send(req, service:"AWS IoT"), service:"AWS IoT")
    }

    func publish(id: String, desired: [String:Int]) throws {
        guard let signer else { throw TCLCloudError.expired }
        let payload: CloudObject = ["state":["desired":desired], "clientToken":"mobile_" + UUID().uuidString]
        let body = try JSONSerialization.data(withJSONObject:payload)
        let req = try signer.request(method:"POST", wirePath:"/topics/%24aws/things/\(TCLIoTSigner.escape(id))/shadow/update",
                                     query:"qos=1", body:body)
        _ = try send(req, service:"AWS IoT")
    }

    func statistics(device: [String:Any], path: String) throws -> [String:Any] {
        guard let base = deviceBase, !saas.isEmpty, !sso.isEmpty else { throw TCLCloudError.expired }
        guard path.hasPrefix("/v1/ac/") || path.hasPrefix("/v3/ac/"), let url = URL(string: path, relativeTo:base)?.absoluteURL,
              url.host == base.host else { throw TCLCloudError.message("Unknown TCL statistics endpoint.") }
        let id = cloudString(device,"deviceId","device_id","id") ?? ""
        let product = cloudString(device,"productKey","product_key") ?? ""
        guard ![id,product].contains(where:{ $0.rangeOfCharacter(from:.newlines) != nil }) else {
            throw TCLCloudError.message("Invalid device ID.")
        }
        let client: [String:String]
        if path.hasPrefix("/v3/ac/") {
            client = ["platform":"android", "appversion":"5.4.1", "User-Agent":"Android"]
        } else {
            client = ["platform":"ios", "appVersion":"7.4.5", "thomeversion":"7.0.5", "appId":"wx6e1af3fa84fbe523",
                           "appPackageName":"com.tcl.tclhome", "countryCode":"PH", "timeZone":"Asia/Manila",
                           "ssoToken":sso, "productKey":product, "deviceId":id]
        }
        return try json(url, headers:saasHeaders(client), timeout:8)
    }
}
