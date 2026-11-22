import Foundation
import Combine

// LG uses its advertised HIGH/LOW speeds; TCL's Turbo/Quiet are separate modes.
enum LGCoolingPreset: CaseIterable, Hashable {
    case high, low
    var degrees: Int { self == .high ? 16 : 22 }
    var speed: String { self == .high ? "HIGH" : "LOW" }
    var label: String { "\(degrees)° " + speed.capitalized }
    var fanLevel: Int { self == .high ? 3 : 1 }
    func changes(windKey: String) -> [ControlChange] {
        [("operation", "airConOperationMode", "POWER_ON"), ("airConJobMode", "currentJobMode", "COOL"),
         ("temperature", "targetTemperature", Double(degrees)), ("airFlow", windKey, speed)]
    }
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
        (lgNumber(capability["min"]) ?? 16,
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
        // The user's LG window units cool down to 16°C. Their generic mobile
        // model can report 18°C; normalize once for UI and wire validation.
        if group == "temperature", key == "targetTemperature", lgNumber(decoded["min"]) == 18 {
            decoded["min"] = 16
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
        let mode = find("currentJobMode", in: snapshot) as? String
        eco = EcoChoice.decodeFlag(find("powerSaveEnabled", in: snapshot)) ?? mode.map { EcoChoice.ecoModes.contains($0) }
        let flow = find("airFlow", in: snapshot) ?? [:]
        fan = ((find("windStrengthDetail", in: flow) ?? find("windStrength", in: flow)) as? String)?.capitalized
        power = find("airConOperationMode", in: find("operation", in: snapshot) ?? [:]) as? String
        online = snapshot["online"] as? Bool
        // A powered-off LG can keep returning its last sensor value from the cloud.
        if powerOn == nil || online == false { room = nil }
    }
    var powerOn: Bool? {
        switch power {
        case "POWER_ON": return true
        case "POWER_OFF": return false
        default: return nil
        }
    }
    var status: String { online == false ? "Offline" : power == "POWER_OFF" ? "OFF" : power == "POWER_ON" ? "ON" : "Connected" }
    var roomReading: String { degree(room) }
    func value(_ key: String) -> String {
        key == "sensor" ? roomReading : power == "POWER_OFF" ? "OFF" : degree(target)
    }
}

// Shared control semantics for Mac and iPhone.
typealias ControlChange = (String, String, Any)

/// Some ACs expose Eco as a switch, others as an operating mode.
struct EcoChoice {
  let enabled: Bool?
  let change: ControlChange?
  static let ecoModes: Set<String> = ["ENERGY_SAVING", "ENERGY_SAVER", "ENERGY_SAVE", "ECO"]
  static func decodeFlag(_ v: Any?) -> Bool? {
      if let b = v as? Bool { return b }
      switch (v as? String)?.uppercased() {
      case "ON", "TRUE", "ENABLE", "ENABLED": return true
      case "OFF", "FALSE", "DISABLE", "DISABLED": return false
      default: return nil
      }
  }
  init(
    flag: Any?, flagWrites: [Any]?, writableFlag: Bool, mode: String?, modes: [String],
    returnMode: String?
  ) {
    let switchState = Self.decodeFlag(flag)
    if writableFlag, let switchState {
      let next = !switchState
      let wire: Any? = flagWrites.map { $0.first { Self.decodeFlag($0) == next } } ?? next
      if let wire {
        enabled = switchState
        change = ("powerSave", "powerSaveEnabled", wire)
        return
      }
    }
    if let eco = modes.first(where: Self.ecoModes.contains),
      let mode
    {
      enabled = mode == eco
      let next =
        mode == eco
        ? [returnMode, "COOL"].compactMap { $0 }.first { modes.contains($0) && $0 != eco } : eco
      change = next.map { ("airConJobMode", "currentJobMode", $0) }
    } else {
      enabled = switchState
      change = nil
    }
  }
}
