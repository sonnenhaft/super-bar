import Foundation

@main struct LGSharedStateCheck {
    @MainActor static func main() {
        for path in ["https://attacker.example/devices", "//attacker.example/devices", "devices/../control", "devices/%2e%2e/control", "devices#fragment"] {
            do { _ = try API.validatePath(path); fatalError("Untrusted LG request path accepted") }
            catch { }
        }
        let component = try! API.deviceComponent("unit/with?query#fragment%")
        try! API.validatePath("devices/" + component + "/state")
        precondition(component == "unit%2Fwith%3Fquery%23fragment%25")
        for identifier in ["", ".", "..", String(repeating: "x", count: 513)] {
            do { _ = try API.deviceComponent(identifier); fatalError("Invalid LG ID accepted") } catch { }
        }
        let profile: [String: Any] = [
            "temperature": [
                ["unit": "F", "targetTemperature": ["mode": ["r", "w"], "value": ["w": ["min": 60, "max": 86]]]],
                ["unit": "C", "targetTemperature": ["mode": ["r", "w"], "value": ["w": ["min": 16, "max": 30]]]],
            ],
            "airFlow": ["windStrengthDetail": ["value": ["w": ["LOW", "MEDIUM", "HIGH"]]]],
            "operation": ["airConOperationMode": ["mode": "r", "value": ["w": ["POWER_ON", "POWER_OFF"]]]],
        ]
        let temperature = LGCapability(profile: profile, group: "temperature", key: "targetTemperature")
        precondition(temperature.writable && temperature.allows(16) && temperature.allows(30))
        precondition(!temperature.allows(15) && !temperature.allows(31), "Celsius bounds must not come from the Fahrenheit profile")
        let fan = LGCapability(profile: profile, group: "airFlow", key: "windStrengthDetail")
        precondition(fan.options == ["LOW", "MEDIUM", "HIGH"])
        precondition(fan.allows("LOW") && !fan.allows("TURBO"))
        precondition(LGDeviceValues.windKey(in: profile) == "windStrengthDetail")
        precondition(LGDeviceValues.windKey(in: [:]) == "windStrength")
        let power = LGCapability(profile: profile, group: "operation", key: "airConOperationMode")
        precondition(!power.writable && !power.allows("POWER_ON"), "Read-only metadata must override a list of values")
        precondition(!LGCapability(profile: profile, group: "unknown", key: "missing").writable)

        let stepped = LGCapability(details: ["writable": true, "min": 17, "max": 29, "step": 2])
        precondition(stepped.allows(17) && stepped.allows(19) && stepped.allows(29))
        precondition(!stepped.allows(18) && !stepped.allows(16) && !stepped.allows(30),
                     "A provider step is anchored at the declared minimum")
        let zeroAnchored = LGCapability(details: ["writable": true, "step": 2])
        precondition(zeroAnchored.allows(0) && zeroAnchored.allows(22) && !zeroAnchored.allows(21),
                     "Without a minimum, numeric steps are anchored at zero")
        let decimalStep = LGCapability(details: ["writable": true, "min": 16.1, "max": 17, "step": 0.1])
        precondition(decimalStep.allows(16.3) && !decimalStep.allows(16.35),
                     "Step validation must tolerate floating-point error without accepting partial steps")
        precondition(!temperature.allows(Double.nan) && !temperature.allows(Double.infinity)
                     && !temperature.allows(-Double.infinity) && !temperature.allows("22"),
                     "Numeric capabilities require finite numeric values")
        for invalidStep in [0.0, -1.0, Double.nan, Double.infinity] {
            precondition(!LGCapability(details: ["writable": true, "step": invalidStep]).allows(22),
                         "An invalid declared step cannot authorize a command")
        }
        precondition(!LGCapability(details: ["writable": true, "min": Double.nan]).allows(22))
        precondition(!LGCapability(details: ["writable": true, "max": "unknown"]).allows(22))

        let state: [String: Any] = [
            "temperature": [["unit": "F", "currentTemperature": 77, "targetTemperature": 72],
                            ["unit": "C", "currentTemperatureC": 25, "targetTemperatureC": 22]],
            "operation": ["airConOperationMode": "POWER_OFF"],
            "airFlow": ["windStrengthDetail": "LOW"],
        ]
        let sample = LGSample(state)
        precondition(sample.room == 25 && sample.target == 22 && sample.powerOn == false)
        precondition(LGSample(["online": false]).status == "Offline")
        precondition(sample.value("current") == "OFF" && sample.value("sensor") == "25°")
        precondition(LGSample([:]).powerOn == nil)
        precondition(LGSample(["temperature": ["unit": "F", "currentTemperature": 77]]).room == nil)
        precondition(LGDeviceValues.value("temperature", "currentTemperature", in: state) == nil)
        let bounds = LGDeviceValues.temperatureBounds(temperatures: ["minTargetTemperature": 18], capability: temperature.details)
        precondition(bounds.0 == 16 && bounds.1 == 30, "A stale snapshot minimum must not override cooling capabilities")
        let windowProfile: [String: Any] = ["temperature": ["targetTemperature": ["writable": true, "min": 18, "max": 30, "step": 1]]]
        let windowTemperature = LGCapability(profile: windowProfile, group: "temperature", key: "targetTemperature")
        precondition(windowTemperature.allows(16) && windowTemperature.allows(17) && !windowTemperature.allows(15))
        for preset in LGCoolingPreset.allCases {
            let fields = preset.changes(windKey: "windStrength")
            precondition(fields.count == 4 && fields[1].2 as? String == "COOL")
            precondition(fields[2].2 as? Double == Double(preset.degrees) && fields[3].2 as? String == preset.speed)
        }
        let testPreferences = UserDefaults(suiteName: "SuperBar.LGHistory." + UUID().uuidString)!
        let history = DevicePowerHistory(provider: "lg", preferences: testPreferences)
        let midnight = ISO8601DateFormatter().date(from: "2026-11-12T16:00:00Z")!
        history.record(600, for: "synthetic", at: midnight.addingTimeInterval(-30))
        history.record(600, for: "synthetic", at: midnight.addingTimeInterval(30))
        let observed = history.days["synthetic"]!
        precondition(observed.map(\.key) == ["20261112", "20261113"])
        precondition(observed.allSatisfy { abs(($0.wattHours ?? -1) - 5) < 0.001 })
        history.record(600, for: "synthetic", at: midnight.addingTimeInterval(7200))
        precondition(history.days["synthetic"]!.compactMap(\.wattHours).reduce(0, +) == 10,
                     "An unobserved gap must not become invented monthly consumption")
        let stations = DevicePowerHistory(provider: "bluetti", preferences: nil)
        stations.record(0, for: "first", at: midnight)
        stations.record(nil, for: "first", at: midnight.addingTimeInterval(60))
        stations.record(800, for: "second", at: midnight)
        precondition(stations.power["first"]?.map(\.watts) == [0] && stations.power["second"]?.map(\.watts) == [800],
                     "Keep each station's genuine readings, including zero output")
        let saver = EcoChoice(flag: nil, flagWrites: nil, writableFlag: false,
            mode: "COOL", modes: ["COOL", "ENERGY_SAVER"], returnMode: "COOL")
        precondition(saver.change?.2 as? String == "ENERGY_SAVER")
        print("LG shared state: Celsius selection, read-only controls, enum/range/step validation and missing readings verified.")
    }
}
