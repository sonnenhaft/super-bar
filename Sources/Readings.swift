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

enum RollingEnergy {
    struct Total {
        let wattHours: Double
        let coverage: TimeInterval
        func label(in range: ClosedRange<Date>) -> String {
            guard coverage > 0 else { return "—" }
            return "≈ " + DisplayUnits.energy(wattHours)
                + (coverage < range.upperBound.timeIntervalSince(range.lowerBound) - 600 ? "*" : "")
        }
    }
    static func clipped(_ intervals: [PowerInterval], to range: ClosedRange<Date>) -> [PowerInterval] {
        intervals.compactMap {
            let start = max($0.start, range.lowerBound), end = min($0.end, range.upperBound)
            guard end > start, $0.watts.isFinite, $0.watts >= 0 else { return nil }
            return PowerInterval(start: start, end: end, watts: $0.watts)
        }.sorted { $0.start < $1.start }
    }
    // Integrate only observed intervals; never turn missing hours into zero energy.
    static func total(points: [PowerPoint] = [], intervals: [PowerInterval] = [],
                      in range: ClosedRange<Date>, maximumGap: TimeInterval = 600) -> Total {
        let ordered = Dictionary(points.filter { $0.watts.isFinite && $0.watts >= 0 }
            .map { ($0.time, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.time < $1.time }
        var segments = clipped(intervals, to: range)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let duration = b.time.timeIntervalSince(a.time)
            let start = max(a.time, range.lowerBound), end = min(b.time, range.upperBound)
            guard duration > 0, duration <= maximumGap, end > start else { continue }
            var uncovered = [start...end]
            for known in segments {
                uncovered = uncovered.flatMap { span -> [ClosedRange<Date>] in
                    guard known.start < span.upperBound, known.end > span.lowerBound else { return [span] }
                    var rest: [ClosedRange<Date>] = []
                    if known.start > span.lowerBound { rest.append(span.lowerBound...known.start) }
                    if known.end < span.upperBound { rest.append(known.end...span.upperBound) }
                    return rest
                }
            }
            for span in uncovered {
                func watts(_ time: Date) -> Double { a.watts + (b.watts - a.watts) * time.timeIntervalSince(a.time) / duration }
                segments.append(PowerInterval(start: span.lowerBound, end: span.upperBound,
                                              watts: (watts(span.lowerBound) + watts(span.upperBound)) / 2))
            }
        }
        var energy = 0.0, coverage = 0.0
        var previousEnd = range.lowerBound
        for interval in segments.sorted(by: { $0.start < $1.start }) {
            let start = max(previousEnd, interval.start)
            guard interval.end > start else { continue }
            let seconds = interval.end.timeIntervalSince(start)
            energy += interval.watts * seconds / 3600; coverage += seconds
            previousEnd = interval.end
        }
        return Total(wattHours: energy, coverage: coverage)
    }
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
enum ChartHistory {
    static let dayCount = 30
    static func accountingDayCount(now: Date = Date(), calendar: Calendar) -> Int {
        max(dayCount, calendar.component(.day, from: now))
    }
}

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
