import Foundation

private func climateSetting(power: Bool?, target: Double?, available: Bool) -> String {
    guard available else { return "Unavailable" }
    if power == false { return target.map { "Off · " + tempText($0) } ?? "Off" }
    if let target { return "Set " + tempText(target) }
    return power == true ? "Set —" : "Unknown"
}

// Used both by foreground refreshes and by confirmed widget commands.
extension Aircon {
    func widgetMetric(checkedAt: Date?, available: Bool = true) -> WidgetMetric {
        let reachable = available && online == true && !failed
        let control = reachable ? checkedAt.map {
            WidgetClimateControl(target: target,
                temperatures: has("targetTemperature") ? setpoints : [], powerOn: power,
                canSetPower: has("powerSwitch"), checkedAt: $0)
        } : nil
        return WidgetMetric(id: id, name: name, value: tempText(indoor),
            detail: climateSetting(power: power, target: target, available: reachable),
            symbol: "air.conditioner.horizontal", updatedAt: sensorTime ?? checkedAt, brand: "TCL", control: control,
            online: available && !failed ? online : false, ecoEnabled: ecoEnabled,
            fanSpeed: currentFanSymbol == .unknown ? nil : currentFanSymbol.rawValue)
    }
}

extension PhoneLGDevice {
    var indicators: ClimateIndicators {
        guard checked != nil, problem == nil else { return ClimateIndicators() }
        return LGSample(state).indicators
    }
    var widgetMetric: WidgetMetric {
        let reported = LGSample(state)
        let control = online != false && problem == nil ? checked.map {
            WidgetClimateControl(target: target,
                temperatures: (16...30).filter {
                    bounds.contains(Double($0)) && allowed("temperature", "targetTemperature", Double($0))
                }, powerOn: power,
                canSetPower: power.map { allowed("operation", "airConOperationMode", $0 ? "POWER_OFF" : "POWER_ON") } ?? false,
                checkedAt: $0)
        } : nil
        return WidgetMetric(id: id, name: name, value: roomReading,
            detail: climateSetting(power: power, target: target, available: online != false && problem == nil),
            symbol: "air.conditioner.horizontal", updatedAt: checked, brand: "LG", control: control,
            online: problem == nil ? online : false, ecoEnabled: reported.eco, fanSpeed: reported.fan)
    }
}
