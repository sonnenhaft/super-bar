import Foundation

struct MenuPowerRow: Equatable {
    let input: String
    let output: String
    let toolTip: String?

    var isEmpty: Bool { input.isEmpty && output.isEmpty }
}

enum MenuPresentation {
    static func batterySymbol(percent: Int) -> String {
        let level = min(4, max(0, (percent + 12) / 25)) * 25
        return "battery.\(level)"
    }

    static func watts(_ value: Double) -> String { String(format: "%gw", value) }

    static func lastRead(_ date: Date, now: Date) -> (title: String, nextUpdate: Date) {
        let age = max(0, now.timeIntervalSince(date))
        if age < 1 {
            return ("Just now", date.addingTimeInterval(1))
        }
        let unit: (seconds: Int, name: String)
        switch age {
        case ..<60: unit = (1, "second")
        case ..<3600: unit = (60, "minute")
        case ..<86400: unit = (3600, "hour")
        default: unit = (86400, "day")
        }
        let count = Int(age) / unit.seconds
        let label = count == 1 ? unit.name : unit.name + "s"
        let next = date.addingTimeInterval(Double((count + 1) * unit.seconds))
        return ("\(count) \(label) ago", next)
    }

    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    static func power(for reading: Reading?, shortDate: (Date) -> String) -> MenuPowerRow {
        func powerText(_ direction: String, _ dc: Double?, _ ac: Double?) -> String? {
            var names: [String] = []
            var values: [String] = []
            for (name, value) in [("DC", dc), ("AC", ac)] {
                if let value = value, value.isFinite, value > 0 {
                    names.append(name)
                    values.append(watts(value))
                }
            }
            guard !names.isEmpty else { return nil }
            return direction + " " + names.joined(separator: "|") + ": " + values.joined(separator: "|")
        }
        let retainedAt = reading?.outputPowerRetainedAt.map { "out · " + shortDate($0) }
        return MenuPowerRow(input: powerText("in", reading?.dcInput, reading?.acInput) ?? "",
                            output: powerText("out", reading?.dcOutput, reading?.acOutput) ?? "",
                            toolTip: retainedAt)
    }

}
