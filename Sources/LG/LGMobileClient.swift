import Foundation

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
    private func discover(_ session: LGMobileSession) async throws -> [[String: Any]] {
        let result = try await request("service/application/dashboard", session: session)
        guard let list = result["item"] as? [[String: Any]] else { throw LGError(message: "LG device list is missing.") }
        return try list.filter { CloudValue.number($0["deviceType"]) == 401 }.map { item in
            guard item["platformType"] as? String == "thinq2" else { throw LGError(message: "This LG air conditioner uses the older ThinQ1 protocol.") }
            let id = try LGMobileHTTP.required("deviceId", in: item, stage: "devices")
            devices[id] = item
            return ["deviceId": id, "deviceInfo": ["deviceType": "DEVICE_AIR_CONDITIONER", "alias": item["alias"] as? String ?? "LG"]]
        }
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
    func requestIfConfigured(_ path: String, payload: [String: Any]?) async throws -> Any? {
        guard let session = try await session() else { return nil }
        let identity = session.country + ":" + session.userNumber
        if account != identity { account = identity; devices.removeAll(); models.removeAll() }
        if path == "devices" { return try await discover(session) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "devices", let id = parts[1].removingPercentEncoding,
              ["profile", "state", "control"].contains(parts[2]) else {
            throw LGError(message: "LG mobile API does not expose this energy-history request.")
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
