import AppKit
import SwiftUI

struct MenuReadout: View {
    var size: CGFloat = 12
    var textColor: NSColor? = nil
    let ac: Aircon?
    let visible: Set<ReadoutField>
    let energyText: String?
    var cacheKey: [String] {
        var values = [String(Double(size)), textColor?.description ?? "", String(ac?.power == false), String(ac?.code("ECO") ?? -1)]
        if ac?.power == false { return values + [tempText(ac?.indoor)] + visible.map(\.rawValue).sorted() }
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
            if let ac, ac.power == false {
                if visible.contains(.target) { Text("⏻").fontWeight(.semibold).foregroundStyle(.red).accessibilityLabel("Off") }
                if visible.contains(.indoor), let room = ac.indoor {
                    if visible.contains(.target) { Text("/").foregroundStyle(.white) }
                    TemperatureText(value:tempText(room),menuBar:true).fontWeight(.semibold)
                }
            } else if let ac {
                if visible.contains(.target) {
                    if ac.code("ECO") == 1 { Image(systemName: "leaf.fill").font(.system(size: max(7, size - 2))).foregroundStyle(.green) }
                    TemperatureText(value:ac.acTemperature, menuBar:true).fontWeight(ac.acTemperature == "OFF" ? .bold : .semibold)
                }
                if visible.contains(.target) && visible.contains(.indoor) { Text("/").foregroundStyle(.white) }
                if visible.contains(.indoor) { TemperatureText(value:tempText(ac.indoor), menuBar:true).fontWeight(.semibold) }
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
                if visible.contains(.energy), let energyText {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").foregroundStyle(Color(nsColor: BarTheme.energy))
                        Text(energyText).monospacedDigit()
                    }.font(.system(size: max(7, size - 2), weight: .medium))
                }
            }
        }.font(.system(size: size)).monospacedDigit().foregroundStyle(Color(nsColor: textColor ?? .white)).frame(height: 22).fixedSize()
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

enum TCLAirflowArtwork {
    private static let images: [String: NSImage] = {
        var images = [String: NSImage]()
        for axis in ["vertical", "horizontal"] {
            let codes = Array(9...13) + Array(1...(axis == "vertical" ? 3 : 4))
            for code in codes {
                let name = "TCL-" + axis + "-" + String(code)
                if let url = Bundle.main.url(forResource: name, withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    image.size = NSSize(width: 30, height: 30)
                    images[name] = image
                }
            }
        }
        return images
    }()

    static func image(_ name: String) -> NSImage? { images[name] }
}

private struct VaneIndicator: View {
    let vertical: Bool
    let direction: Int?
    let motor: Int?
    var body: some View {
        if let code = direction, (9...13).contains(code) || (motor != 0 && (1...(vertical ? 3 : 4)).contains(code)),
           let image = TCLAirflowArtwork.image("TCL-" + (vertical ? "vertical" : "horizontal") + "-" + String(code)) {
            Image(nsImage: image)
                .renderingMode(.template).resizable().scaledToFit().frame(width: 17, height: 17)
        }
    }
}

enum ReadoutField: String, CaseIterable {
    case icon, indoor, target, power, fan, vertical, horizontal, eco, energy

    var symbol: String {
        switch self {
        case .icon: return "app"
        case .indoor: return "thermometer.medium"
        case .target: return "scope"
        case .power: return "power"
        case .fan: return "fanblades"
        case .vertical: return "arrow.up.and.down"
        case .horizontal: return "arrow.left.and.right"
        case .eco: return "leaf.fill"
        case .energy: return "bolt.fill"
        }
    }
}

final class ReadoutPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published private var overrides: [String: [String]]
    private let initial: [String]
    private var pinnedID: String? {
        get { defaults.string(forKey: "tcl.pinnedDevice") }
        set { defaults.set(newValue, forKey: "tcl.pinnedDevice") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        initial = (defaults.stringArray(forKey: "readoutFields") ?? ["target", "indoor"]) + ["icon"]
        let legacy = defaults.dictionary(forKey: "tcl.deviceFields") as? [String: [String]] ?? [:]
        overrides = defaults.dictionary(forKey: "tcl.deviceFields.v2") as? [String: [String]]
            ?? legacy.mapValues { $0.isEmpty ? [] : $0 + ["icon"] }
    }
    func ordered(_ id: String) -> [ReadoutField] {
        (overrides[id] ?? initial).compactMap(ReadoutField.init(rawValue:))
    }
    func set(_ field: ReadoutField, for id: String, visible: Bool) {
        pinnedID = id
        BarSelection.shared.pin(.tcl)
        var values = ordered(id).filter { $0 != field }
        if visible { values.insert(field, at: 0) }
        overrides[id] = values.map(\.rawValue)
        defaults.set(overrides, forKey: "tcl.deviceFields.v2")
    }
    func pinDevice(_ id: String) {
        objectWillChange.send()
        pinnedID = id
    }
    func device(in store: ClimateStore) -> Aircon? {
        if let id = pinnedID { return store.devices.first { $0.id == id } }
        if let ac = store.selected ?? store.devices.first { pinnedID = ac.id; return ac }
        return nil
    }

}
