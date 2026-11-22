import Foundation
import Combine

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
    static func lastHour(endingAt now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-3600)...now
    }

    static func last24Hours(endingAt now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-86_400)...now
    }

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
        let measured = clipped(intervals, to: range)
        var segments = measured
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let duration = b.time.timeIntervalSince(a.time)
            let start = max(a.time, range.lowerBound), end = min(b.time, range.upperBound)
            guard duration > 0, duration <= maximumGap, end > start else { continue }
            var uncovered = [start...end]
            // Adjacent sample pairs cannot overlap each other.
            for known in measured where known.start < end && known.end > start {
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
    static func voltage(_ volts: Double) -> String {
        guard volts.isFinite, volts >= 0 else { return "—" }
        return volts.formatted(.number.precision(.fractionLength(0...1))) + " V"
    }
    static func powerUnit(_ watts: Double) -> String {
        if abs(watts) > 800_000 { return "MW" }
        return abs(watts) >= 800 ? "kW" : "W"
    }
    static func powerAxis(_ watts: Double) -> String {
        guard watts.isFinite else { return "—" }
        if powerUnit(watts) == "MW" {
            return String(format: "%.1f MW", locale: Locale(identifier: "en_US_POSIX"), watts / 1_000_000)
                .replacingOccurrences(of: ".", with: ",")
        }
        return format(watts, small: "W", large: "kW")
    }
    static func energyAxis(_ value: Double) -> String { format(value, small: "Wh", large: "kWh") }
    static func power(_ watts: Double) -> String { watts.isFinite ? powerAxis(watts) + " ⚡️" : "—" }
    static func energy(_ wattHours: Double) -> String { format(wattHours, small: "Wh ⚡️", large: "kWh ⚡️") }
    private static func format(_ value: Double, small: String, large: String) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 800 {
            return String(format:"%.1f %@", locale:Locale(identifier:"en_US_POSIX"), value / 1000, large).replacingOccurrences(of: ".", with: ",")
        }
        return String(format:"%.0f %@", locale:Locale(identifier:"en_US_POSIX"), value, small)
    }
}


enum PowerPolling { static let interval = 15 }

enum RefreshProvider: String, CaseIterable {
    case tcl = "TCL", lg = "LG", bluetti = "BLUETTI", deye = "Deye", tuya = "Tuya"
    var key: String {
        switch self {
        case .tcl: return "tcl.refreshInterval"
        case .lg: return "interval"
        case .bluetti: return "refreshIntervalSeconds"
        case .deye: return "deye.refreshInterval"
        case .tuya: return "tuya.refreshInterval"
        }
    }
    var choices: [Int] {
        switch self {
        case .tcl, .lg: return [1, 5, 15, 30, 60, 300, 600]
        case .bluetti: return [1, 3, 5, 15, 20, 30, 60, 120]
        case .deye, .tuya: return [15, 30, 60]
        }
    }
    var defaultSeconds: Int {
        switch self {
        case .tcl, .lg: return 60
        case .bluetti:
            #if os(iOS)
            return 15
            #else
            return 30
            #endif
        case .deye, .tuya:
            #if os(iOS)
            return 30
            #else
            return PowerPolling.interval
            #endif
        }
    }
    static func label(_ seconds: Int) -> String { seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m" }
}

/// Shared preferences only reschedule existing readers; changing a slider does
/// not issue a provider request or alter the independent history schedule.
final class RefreshPreferences: ObservableObject {
    static let shared = RefreshPreferences()
    let objectWillChange = ObservableObjectPublisher()
    let changes = PassthroughSubject<RefreshProvider, Never>()
    static func seconds(_ provider: RefreshProvider, preferences: UserDefaults = .standard) -> Int {
        let saved = preferences.integer(forKey: provider.key)
        return provider.choices.contains(saved) ? saved : provider.defaultSeconds
    }
    func set(_ provider: RefreshProvider, seconds: Int, preferences: UserDefaults = .standard) {
        guard provider.choices.contains(seconds), seconds != Self.seconds(provider, preferences: preferences) else { return }
        objectWillChange.send()
        preferences.set(seconds, forKey: provider.key)
        changes.send(provider)
    }
    static func wait(_ provider: RefreshProvider, since start: TimeInterval) async throws {
        // Recheck the preference while asleep so a shorter interval takes effect
        // without cancelling an in-flight request or adding a second reader.
        while true {
            try Task.checkCancellation()
            let remaining = Double(seconds(provider)) - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(1, remaining) * 1_000_000_000))
        }
    }
}

struct AutomaticPollSchedule {
    private var started: [RefreshProvider: TimeInterval] = [:]
    mutating func mark(_ provider: RefreshProvider, at time: TimeInterval) { started[provider] = time }
    mutating func due(_ provider: RefreshProvider, at time: TimeInterval, preferences: UserDefaults = .standard) -> Bool {
        if let previous = started[provider], time >= previous,
           time - previous < Double(RefreshPreferences.seconds(provider, preferences: preferences)) { return false }
        started[provider] = time
        return true
    }
}
enum ChartHistory {
    static let dayCount = 30
    // All providers use the same local day boundary for energy history and billing.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        return calendar
    }()

    static func formatter(_ format: String, zone: TimeZone = calendar.timeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    static func accountingDayCount(now: Date = Date()) -> Int {
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

// Bounded local readings shared by the Mac and iPhone clients. Daily values are
// estimates over observed intervals only, never a substitute for missing cloud history.
@MainActor final class DevicePowerHistory: ObservableObject {
    static let lg = DevicePowerHistory(provider: "lg")
    @Published private(set) var power: [String: [PowerPoint]]
    @Published private(set) var days: [String: [EnergyDayPoint]]
    private let preferences: UserDefaults?
    private let powerKey: String
    private let daysKey: String
    let maximumGap: TimeInterval
    private let writes = DispatchQueue(label: "superbar.observed-power", qos: .utility)
    init(provider: String, preferences: UserDefaults? = .standard, maximumGap: TimeInterval = 600) {
        self.maximumGap = maximumGap
        powerKey = provider + ".powerHistory"
        daysKey = provider + ".observedEnergyDays"
        self.preferences = preferences
        power = preferences?.data(forKey: powerKey).flatMap { try? JSONDecoder().decode([String: [PowerPoint]].self, from: $0) } ?? [:]
        days = preferences?.data(forKey: daysKey).flatMap { try? JSONDecoder().decode([String: [EnergyDayPoint]].self, from: $0) } ?? [:]
    }
    func record(_ watts: Double?, for id: String, at now: Date = Date()) {
        guard let watts, watts.isFinite, watts >= 0, now.timeIntervalSince1970.isFinite else { return }
        let saved = power[id] ?? []
        if let last = saved.last, now.timeIntervalSince(last.time) < 60 { return }
        var points = saved.filter { now.timeIntervalSince($0.time) <= 86_400 }
        let point = PowerPoint(time: now, watts: watts)
        var totals = Dictionary((days[id] ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let calendar = ChartHistory.calendar
        let formatter = ChartHistory.formatter("yyyyMMdd")
        // Seed the first daily estimate from the existing one-day cache.
        let integrationPoints = totals.isEmpty ? points + [point] : Array(points.suffix(1)) + [point]
        if let first = integrationPoints.first {
            var start = calendar.startOfDay(for: first.time)
            while start <= now {
                let end = calendar.date(byAdding: .day, value: 1, to: start)!
                let total = RollingEnergy.total(points: integrationPoints, in: start...min(end, now), maximumGap: maximumGap)
                if total.coverage > 0 {
                    let key = formatter.string(from: start)
                    totals[key] = EnergyDayPoint(key: key, label: String(key.suffix(2)),
                        wattHours: (totals[key]?.wattHours ?? 0) + total.wattHours)
                }
                start = end
            }
        }
        let earliest = formatter.string(from: calendar.date(byAdding: .day, value: -29, to: now)!)
        days[id] = totals.values.filter { $0.key >= earliest }.sorted { $0.key < $1.key }
        points.append(point)
        power[id] = Array(points.suffix(1441))
        guard let preferences else { return }
        let powerSnapshot = power, daySnapshot = days, powerKey = powerKey, daysKey = daysKey
        writes.async {
            if let data = try? JSONEncoder().encode(powerSnapshot) { preferences.set(data, forKey: powerKey) }
            if let data = try? JSONEncoder().encode(daySnapshot) { preferences.set(data, forKey: daysKey) }
        }
    }
}
