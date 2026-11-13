import Foundation

@main struct LGSharedStateCheck {
    static func main() {
        for region in ["kic", "eic", "aic"] {
            let url = try! API.checkedURL(region: region, path: "devices")
            precondition(url.scheme == "https" && url.host == "api-" + region + ".lgthinq.com")
        }
        for region in ["attacker.example/?", "kic@attacker.example/", "kic.lgthinq.com.attacker.example", "", "KIC"] {
            do { _ = try API.checkedURL(region: region, path: "devices"); fatalError("Untrusted LG origin accepted") }
            catch { }
        }
        for path in ["https://attacker.example/devices", "//attacker.example/devices", "devices/../control", "devices/%2e%2e/control", "devices#fragment"] {
            do { _ = try API.checkedURL(region: "kic", path: path); fatalError("Untrusted LG request path accepted") }
            catch { }
        }
        let component = try! API.deviceComponent("unit/with?query#fragment%")
        let pathURL = try! API.checkedURL(region: "kic", path: "devices/" + component + "/state")
        precondition(pathURL.query == nil && pathURL.fragment == nil && pathURL.host == "api-kic.lgthinq.com")
        precondition(pathURL.absoluteString.contains("unit%2Fwith%3Fquery%23fragment%25/state"))
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
        precondition(sample.value("current") == "OFF" && sample.value("sensor") == "25°")
        precondition(LGSample([:]).powerOn == nil)
        precondition(LGSample(["temperature": ["unit": "F", "currentTemperature": 77]]).room == nil)
        precondition(LGDeviceValues.value("temperature", "currentTemperature", in: state) == nil)
        let bounds = LGDeviceValues.temperatureBounds(temperatures: ["minTargetTemperature": 18], capability: temperature.details)
        precondition(bounds.0 == 18 && bounds.1 == 30)
        print("LG shared state: Celsius selection, read-only controls, enum/range/step validation and missing readings verified.")
    }
}
