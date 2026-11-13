import Foundation

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
            detail: reachable ? (power == false ? "Off" : "Set " + tempText(target)) : "Unavailable",
            symbol: "air.conditioner.horizontal", updatedAt: checkedAt, brand: "TCL", control: control)
    }
}

extension PhoneLGDevice {
    var widgetMetric: WidgetMetric {
        let control = problem == nil ? checked.map {
            WidgetClimateControl(target: target,
                temperatures: (16...30).filter {
                    bounds.contains(Double($0)) && allowed("temperature", "targetTemperature", Double($0))
                }, powerOn: power,
                canSetPower: power.map { allowed("operation", "airConOperationMode", $0 ? "POWER_OFF" : "POWER_ON") } ?? false,
                checkedAt: $0)
        } : nil
        return WidgetMetric(id: id, name: name, value: degree(room),
            detail: problem != nil ? "Unavailable" : power.map { $0 ? "Set " + degree(target) : "Off" } ?? "Unknown",
            symbol: "air.conditioner.horizontal", updatedAt: checked, brand: "LG", control: control)
    }
}
