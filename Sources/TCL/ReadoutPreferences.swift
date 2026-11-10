import SwiftUI

enum ReadoutField: String, CaseIterable {
    case icon, indoor, target, power, fan, vertical, horizontal, eco, energy

    var label: String {
        switch self {
        case .icon: return "TCL icon"
        case .indoor: return "Room temperature"
        case .target: return "AC temperature or OFF"
        case .power: return "Power"
        case .fan: return "Fan speed"
        case .vertical: return "Vertical vanes"
        case .horizontal: return "Horizontal vanes"
        case .eco: return "Eco indicator"
        case .energy: return "Energy"
        }
    }
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
        var values = ordered(id).filter { $0 != field }
        if visible { values.insert(field, at: 0) }
        overrides[id] = values.map(\.rawValue)
        defaults.set(overrides, forKey: "tcl.deviceFields.v2")
    }
    func device(in store: ClimateStore) -> Aircon? {
        if let ac = store.selected, !ordered(ac.id).isEmpty { return ac }
        return store.devices.first { !ordered($0.id).isEmpty }
    }

}

struct ReadoutSettings: View {
    @ObservedObject var preferences: ReadoutPreferences
    let id: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Show in menu bar").font(.headline).padding(.bottom, 10)
            ForEach([ReadoutField.power, .vertical, .horizontal, .eco], id: \.self) { field in
                Toggle(isOn: Binding(get: { preferences.ordered(id).contains(field) },
                                     set: { preferences.set(field, for: id, visible: $0) })) {
                    Label(field.label, systemImage: field.symbol)
                }
                .toggleStyle(.checkbox).padding(.vertical, 5)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}
