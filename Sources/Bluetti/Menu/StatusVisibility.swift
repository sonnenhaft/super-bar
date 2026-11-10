import Foundation

extension Reading {
    var hasRuntime: Bool {
        runtime.remainingSeconds != nil
            && [.discharging, .empty].contains(runtime.state)
    }

    func remainingMinutes(_ seconds: Int, at date: Date, countDown: Bool) -> Int {
        let elapsed = countDown ? max(0, date.timeIntervalSince(runtimeMeasuredAt)) : 0
        return Int(ceil(max(0, Double(seconds) - elapsed) / 60))
    }

    func compactRuntime(at date: Date) -> String? {
        guard hasRuntime, let seconds = runtime.remainingSeconds else { return nil }
        let minutes = remainingMinutes(seconds, at: date, countDown: !runtime.backup)
        return MenuPresentation.duration(minutes: minutes)
    }

    func compactChargeTime(at date: Date) -> String? {
        guard let seconds = timeToFullSeconds else { return nil }
        let elapsed = max(0, date.timeIntervalSince(measuredAt))
        return MenuPresentation.duration(minutes: Int(ceil(max(0, Double(seconds) - elapsed) / 60)))
    }

    var inputWattsText: String? {
        let inputs = [acInput, dcInput].compactMap { $0 }
        guard !inputs.isEmpty else { return nil }
        let total = inputs.reduce(0, +)
        return total.isFinite && total > 0 ? MenuPresentation.watts(total) : nil
    }

    var percentText: String { "\(percent)%" }
    var outputText: String? { outputWatts.map(MenuPresentation.watts) }
}

enum MenuBarField: String, CaseIterable {
    case percentage, battery, brand, input, output, chargeTime, runtime
}

struct StatusVisibility {
    private static let preference = "pinnedMenuBarFields"
    private static let numericFields: Set<MenuBarField> = [.percentage, .input, .output, .chargeTime, .runtime]
    private let preference: String
    private(set) var preferred: MenuBarField?
    private(set) var selected: Set<MenuBarField>

    init(defaults: UserDefaults, reading: Reading?, station: String = "") {
        preference = station.isEmpty ? Self.preference : Self.preference + "." + station
        preferred = defaults.string(forKey: preference + ".last").flatMap(MenuBarField.init(rawValue:))
        if let saved = defaults.stringArray(forKey: preference) ?? defaults.stringArray(forKey: Self.preference) {
            selected = Set(saved.compactMap(MenuBarField.init(rawValue:)))
            return
        }
        // Keep the previous version's preferences until the first edit.
        selected = []
        if (defaults.object(forKey: "showBrandIcon") as? Bool) != false { selected.insert(.brand) }
        if !defaults.bool(forKey: "hideOutputWatts") { selected.insert(.output) }
        if !defaults.bool(forKey: "hideRuntime") { selected.insert(.runtime) }
        let hidePercent = (defaults.object(forKey: "hideBatteryPercent") as? Bool)
            ?? (selected.contains(.runtime) && reading?.hasRuntime == true)
        if !hidePercent { selected.insert(.percentage) }
    }

    func visibleFields(for reading: Reading?) -> Set<MenuBarField> {
        guard let reading else { return [.brand] }
        var result = selected
        if reading.inputWattsText == nil { result.remove(.input) }
        if reading.outputText == nil { result.remove(.output) }
        if reading.timeToFullSeconds == nil { result.remove(.chargeTime) }
        if !reading.hasRuntime { result.remove(.runtime) }
        if result.isDisjoint(with: Self.numericFields) {
            result.insert(reading.outputText == nil ? .percentage : .output)
        }
        return result
    }

    mutating func toggle(_ field: MenuBarField, reading: Reading?, defaults: UserDefaults) {
        if selected.contains(field) || visibleFields(for: reading).contains(field) {
            selected.remove(field)
        } else {
            selected.insert(field)
        }
        if selected.contains(field) { remember(field, defaults: defaults) }
        defaults.set(selected.map(\.rawValue).sorted(), forKey: preference)
    }

    mutating func remember(_ field: MenuBarField, defaults: UserDefaults) {
        preferred = field
        defaults.set(field.rawValue, forKey: preference + ".last")
    }

    func summary(for reading: Reading, at date: Date) -> String {
        let visible = visibleFields(for: reading)
        for field in [preferred].compactMap({ $0 }) + MenuBarField.allCases where visible.contains(field) {
            let value = Self.title(for: reading, fields: [field], at: date)
            if !value.isEmpty { return value }
        }
        return "—"
    }

    static func title(for reading: Reading, fields: Set<MenuBarField>, at date: Date) -> String {
        var text: [String] = []
        if fields.contains(.percentage) { text.append(reading.percentText) }
        if fields.contains(.runtime), let time = reading.compactRuntime(at: date) { text.append(time) }
        if fields.contains(.output), let watts = reading.outputText { text.append(watts) }
        if fields.contains(.input), let watts = reading.inputWattsText { text.append("in " + watts) }
        if fields.contains(.chargeTime), let time = reading.compactChargeTime(at: date) { text.append("↑" + time) }
        return text.joined(separator: " ")
    }
}
