import Foundation

// LG uses its advertised HIGH/LOW speeds; TCL's Turbo/Quiet are separate modes.
enum LGCoolingPreset: CaseIterable, Hashable {
    case high, low
    var degrees: Int { self == .high ? 16 : 22 }
    var speed: String { self == .high ? "HIGH" : "LOW" }
    var label: String { "\(degrees)° " + speed.capitalized }
}

// Provider semantics are shared; polling, UI selection and credential storage
// stay in each platform's owner.
enum LGDeviceValues {
    static func value(_ group: String, _ key: String, in state: [String: Any]) -> Any? {
        let source = find(group, in: state) ?? [:]
        return find(key, in: group == "temperature" ? celsius(source) : source)
    }
    static func windKey(in profile: [String: Any]) -> String {
        find("windStrengthDetail", in: profile) != nil ? "windStrengthDetail" : "windStrength"
    }
    static func temperatureBounds(temperatures: [String: Any], capability: [String: Any]) -> (Double, Double) {
        (lgNumber(temperatures["minTargetTemperature"]) ?? lgNumber(capability["min"]) ?? 16,
         lgNumber(temperatures["maxTargetTemperature"]) ?? lgNumber(capability["max"]) ?? 30)
    }
}

struct LGCapability {
    let details: [String: Any]
    init(details: [String: Any]) { self.details = details }
    init(profile: [String: Any], group: String, key: String) {
        let source = find(group, in: profile) ?? [:]
        var decoded = object(find(key, in: group == "temperature" ? celsius(source) : source) ?? [:])
        if let writes = object(decoded["value"] ?? [:])["w"] {
            decoded["writeValues"] = writes
            if let range = writes as? [String: Any] { decoded.merge(range) { _, new in new } }
        }
        details = decoded
    }
    var writable: Bool {
        if details["mode"] == nil && details["writable"] == nil { return details["writeValues"] != nil }
        return details["writable"] as? Bool == true || (details["mode"] as? [String])?.contains("w") == true
            || (details["mode"] as? String)?.contains("w") == true
    }
    func allows(_ value: Any) -> Bool {
        guard writable else { return false }
        if let options = details["writeValues"] as? [Any], !options.contains(where: { equal($0, value) }) {
            return false
        }
        let number = lgNumber(value)
        let hasNumericConstraint = ["min", "max", "step"].contains { details[$0] != nil }
        if hasNumericConstraint && number == nil { return false }
        if let number {
            guard number.isFinite else { return false }
            let low = lgNumber(details["min"])
            let high = lgNumber(details["max"])
            if details["min"] != nil {
                guard let low, low.isFinite, number >= low else { return false }
            }
            if details["max"] != nil {
                guard let high, high.isFinite, number <= high else { return false }
            }
            if details["step"] != nil {
                guard let step = lgNumber(details["step"]), step.isFinite, step > 0 else { return false }
                let index = (number - (low ?? 0)) / step
                // Decimal provider steps can accumulate small floating-point error.
                guard index.isFinite, abs(index - index.rounded()) <= 1e-8 else { return false }
            }
        }
        return true
    }
    var options: [String] { writable ? details["writeValues"] as? [String] ?? [] : [] }
}

// Passive summaries never replace the selected device's control state.
struct LGSample {
    var room: Double?
    var target: Double?
    var eco: Bool?
    var fan: String?
    var power: String?
    var online: Bool?
    init(_ snapshot: [String: Any]) {
        let temperature = celsius(find("temperature", in: snapshot) ?? [:])
        room = lgNumber(temperature["currentTemperature"] ?? temperature["currentTemperatureC"])
        target = lgNumber(temperature["targetTemperature"] ?? temperature["targetTemperatureC"])
        eco = find("powerSaveEnabled", in: snapshot) as? Bool
        let flow = find("airFlow", in: snapshot) ?? [:]
        fan = ((find("windStrengthDetail", in: flow) ?? find("windStrength", in: flow)) as? String)?.capitalized
        power = find("airConOperationMode", in: find("operation", in: snapshot) ?? [:]) as? String
        online = snapshot["online"] as? Bool
        // A powered-off LG can keep returning its last sensor value from the cloud.
        if power != "POWER_ON" || online == false { room = nil }
    }
    var powerOn: Bool? {
        switch power {
        case "POWER_ON": return true
        case "POWER_OFF": return false
        default: return nil
        }
    }
    var status: String { online == false ? "Offline" : power == "POWER_OFF" ? "OFF" : power == "POWER_ON" ? "ON" : "Connected" }
    func value(_ key: String) -> String {
        key == "sensor" ? degree(room) : power == "POWER_OFF" ? "OFF" : degree(target)
    }
}
