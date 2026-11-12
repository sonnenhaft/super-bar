import Foundation

struct EnergyDayPoint: Codable, Identifiable {
    let key: String
    let label: String
    let wattHours: Double?
    var id: String { key }
}
struct PowerPoint: Codable, Identifiable {
    let time: Date
    let watts: Double
    var id: Date { time }
}
struct PowerInterval: Codable, Identifiable {
    let start: Date, end: Date
    let watts: Double
    var id: Date { start }
}

enum DisplayUnits {
    static func powerAxis(_ value: Double) -> String { axis(value,small:"W",large:"kW") }
    static func energyAxis(_ value: Double) -> String { axis(value,small:"Wh",large:"kWh") }
    private static func axis(_ value: Double, small: String, large: String) -> String {
        format(value,small:small,large:large)
    }
    static func power(_ watts: Double) -> String { format(watts, small: "W", large: "kW") }
    static func energy(_ wattHours: Double) -> String { format(wattHours, small: "Wh", large: "kWh") }
    private static func format(_ value: Double, small: String, large: String) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 800 {
            return String(format:"%.1f %@", locale:Locale(identifier:"en_US_POSIX"), value / 1000, large).replacingOccurrences(of: ".", with: ",")
        }
        return String(format:"%.0f %@", locale:Locale(identifier:"en_US_POSIX"), value, small)
    }
}


enum PowerPolling { static let interval = 15 }
enum ChartHistory { static let dayCount = 30 }

// Independent of the live-readout slider. History requests must never inherit
// the 1–15 second status polling cadence.
enum HistoryPolling {
    static let recent: TimeInterval = 300
    static let tclSummary: TimeInterval = 900 // TCL only exposes whole summary responses.
    static let archiveRetry: TimeInterval = 3600
    static func due(since previous: Date?, now: Date = Date(), calendar: Calendar) -> Bool {
        guard let previous else { return true }
        return now < previous || !calendar.isDate(previous, inSameDayAs: now)
            || now.timeIntervalSince(previous) >= recent
    }
}
