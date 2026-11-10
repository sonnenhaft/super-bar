import AppKit
import SwiftUI

struct MenuReadout: View {
    var size: CGFloat = 12
    var textColor: NSColor? = nil
    let ac: Aircon?
    let visible: Set<ReadoutField>
    let energyText: String?
    var cacheKey: [String] {
        var values = [String(Double(size)), textColor?.description ?? "", String(ac?.power == false)]
        if ac?.power == false { return values }
        for field in ReadoutField.allCases where visible.contains(field) {
            values.append(field.rawValue)
            guard let ac else { continue }
            switch field {
            case .target: values.append(ac.acTemperature)
            case .indoor: values.append(tempText(ac.indoor))
            case .power: values.append(ac.status)
            case .fan: values.append(Self.speed(ac))
            case .eco: values.append(String(ac.code("ECO") ?? -1))
            case .vertical, .horizontal:
                let prefix = field == .vertical ? "vertical" : "horizontal"
                values.append(String(ac.code(prefix + "Direction") ?? -1))
                values.append(String(ac.code(prefix + "Switch") ?? -1))
            case .energy: values.append(energyText ?? "")
            case .icon: break
            }
        }
        return values
    }
    var body: some View {
        HStack(spacing: 4) {
            if visible.contains(.icon) || ac?.power == false {
                TCLLogo().frame(width: 30, height: 15)
            }
            if let ac, ac.power != false {
                if visible.contains(.target) {
                    Text(ac.acTemperature).fontWeight(ac.acTemperature == "OFF" ? .bold : .semibold)
                }
                if visible.contains(.target) && visible.contains(.indoor) { Text("/") }
                if visible.contains(.indoor) { Text(tempText(ac.indoor)).fontWeight(.semibold) }
                if visible.contains(.power), let on = ac.power {
                    Image(systemName: on ? "power.circle.fill" : "power.circle").font(.system(size: max(7, size - 2)))
                }
                if visible.contains(.fan) {
                    HStack(spacing: 2) {
                        Image(systemName: "fanblades").font(.system(size: max(7, size - 2), weight: .medium))
                        Text(Self.speed(ac)).font(.system(size: max(7, size - 2), weight: .semibold)).monospacedDigit()
                    }
                }
                if visible.contains(.vertical) {
                    VaneIndicator(vertical: true, direction: ac.code("verticalDirection"), motor: ac.code("verticalSwitch"))
                }
                if visible.contains(.horizontal) {
                    VaneIndicator(vertical: false, direction: ac.code("horizontalDirection"), motor: ac.code("horizontalSwitch"))
                }
                if visible.contains(.eco), ac.code("ECO") == 1 {
                    Image(systemName: "leaf.fill").font(.system(size: max(7, size - 2))).foregroundStyle(.green)
                }
                if visible.contains(.energy), let energyText {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                        Text(energyText).monospacedDigit()
                    }.font(.system(size: max(7, size - 2), weight: .medium))
                }
            }
        }.font(.system(size: size)).monospacedDigit().foregroundStyle(Color(nsColor: textColor ?? .labelColor)).frame(height: 22).fixedSize()
    }
    private static func speed(_ ac: Aircon) -> String {
        guard ac.has(ac.fanField) else { return "–" }
        if ac.code("turbo") == 1 { return "T" }
        if ac.code("silenceSwitch") == 1 { return "S" }
        let speed = ac.code(ac.fanField)
        if ac.fanField == "windSpeed7Gear" {
            if speed == 0 || ac.code("windSpeedAutoSwitch") == 1 { return "A" }
            if speed == 7 { return "T" }
            return speed.map(String.init) ?? "–"
        }
        return [0:"A", 2:"Lo", 3:"M−", 4:"M", 5:"M+", 6:"Hi"][speed ?? -1] ?? "–"
    }
}

private struct VaneIndicator: View {
    let vertical: Bool
    let direction: Int?
    let motor: Int?
    var body: some View {
        if let code = direction, (9...13).contains(code) || (motor != 0 && (1...(vertical ? 3 : 4)).contains(code)) {
            Image("TCL-" + (vertical ? "vertical" : "horizontal") + "-" + String(code))
                .renderingMode(.template).resizable().scaledToFit().frame(width: 17, height: 17)
        } else { Text("–") }
    }
}
