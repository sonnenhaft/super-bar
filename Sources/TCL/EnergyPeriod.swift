import Foundation

// Counter observations use calendar-day totals from a single TCL response.
// Yesterday is needed across midnight, when the calendar-day counter resets.
struct MeterObservation: Codable, Equatable {
    let at: TimeInterval
    let today: Double
    let yesterday: Double?
}

struct MeterHour: Codable, Equatable {
    let start: TimeInterval
    let kwh: Double
}

enum EnergyPeriod {
    static let zone = TimeZone(identifier: "Asia/Manila")!
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = zone
        f.dateFormat = format
        f.isLenient = false
        return f
    }
    static func start(at date: Date) -> TimeInterval {
        let midnight = calendar.startOfDay(for: date).timeIntervalSince1970
        let nine = midnight + 9 * 3600
        return date.timeIntervalSince1970 < nine ? nine - 86400 : nine
    }
    static func pretty(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2)))
    }
    struct Reading {
        let lower: Double
        let upper: Double
        let at: TimeInterval
        let source: String
        var text: String {
            if upper == .infinity { return "≥" + EnergyPeriod.pretty(floor((lower + 1e-9) * 100) / 100) + " kWh" }
            if upper - lower < 0.00001 { return EnergyPeriod.pretty(lower) + " kWh" }
            // Round interval endpoints outwards so rounding never narrows the true range.
            let low = floor((lower + 1e-9) * 100) / 100
            let high = ceil((upper - 1e-9) * 100) / 100
            return (low == 0 ? "≤" + EnergyPeriod.pretty(high) : EnergyPeriod.pretty(low) + "–" + EnergyPeriod.pretty(high)) + " kWh"
        }
        var detail: String {
            "From 09:00 Manila time to " + EnergyPeriod.formatter("dd.MM HH:mm").string(from: Date(timeIntervalSince1970: at)) + ". " + source
        }
    }

    static func reading(_ report: DailyEnergyReport, now: Date) -> Reading? {
        let boundary = start(at: now), end = now.timeIntervalSince1970
        if end == boundary { return Reading(lower: 0, upper: 0, at: end, source: "Start of the day.") }
        let firstMidnight = boundary - 9 * 3600
        let nextMidnight = firstMidnight + 86400
        let meters = (report.meters ?? []).filter { $0.at >= firstMidnight && $0.at <= end }.sorted { $0.at < $1.at }
        let buckets = (report.hours ?? []).filter { $0.start >= firstMidnight && $0.start < end }
        let hours = Dictionary(buckets.map { ($0.start, $0.kwh) }, uniquingKeysWith: { _, latest in latest })
        let pre = (0..<9).compactMap { hours[firstMidnight + Double($0)*3600] }
        var lowerAtNine = meters.last { $0.at <= boundary }?.today ?? 0
        var upperAtNine = meters.first { $0.at >= boundary && $0.at < nextMidnight }?.today
        if pre.count == 9 {
            lowerAtNine = pre.reduce(0, +)
            upperAtNine = lowerAtNine
        }
        // Compare exact readings with measured intervals. On each refresh, use
        // the latest exact result if one is available in the latest report.
        var results: [Reading] = []
        if let meter = meters.last, meter.at >= boundary {
            let afterMidnight = meter.at >= nextMidnight
            if !afterMidnight || meter.yesterday != nil {
                let finished = afterMidnight ? meter.yesterday! : meter.today
                let endTotal = finished + (afterMidnight ? meter.today : 0)
                let upper = min(upperAtNine ?? finished, finished)
                if lowerAtNine <= upper + 0.00001 {
                    let lo = max(0, endTotal - upper), hi = max(lo, endTotal - lowerAtNine)
                    results.append(Reading(lower: lo, upper: hi, at: meter.at,
                                           source: hi - lo < 0.00001 ? "From TCL readings." :
                                              "Estimate from the daily meter. No reading at 09:00."))
                }
            }
        }
        var hour = boundary, sum = 0.0
        // Only completed hours have an unambiguous end. A missing bucket breaks
        // coverage; the server may omit empty or unknown hours.
        while hour + 3600 <= end, let value = hours[hour] { sum += value; hour += 3600 }
        if hour > boundary {
            results.append(Reading(lower: sum, upper: sum, at: hour, source: "From TCL hourly readings."))
        }
        let freshExact = results.filter { $0.upper - $0.lower < 0.00001 && end - $0.at < 3700 }
        guard let latest = (freshExact.isEmpty ? results : freshExact).max(by: { $0.at < $1.at }) else { return nil }
        if end - latest.at > 3700 {
            guard latest.lower > 0 else { return nil }
            return Reading(lower: latest.lower, upper: .infinity, at: latest.at,
                           source: "Lower bound from the latest TCL report.")
        }
        return latest
    }

    // Accept explicit local dates and hours only. A date without an hour
    // denotes a daily total and must never become a midnight hourly interval.
    static func parseHours(_ reply: [String: Any], now: Date) -> [MeterHour] {
        guard EnergyHistory.number(reply["code"]) == 0, let data = reply["data"] as? [String: Any] else { return [] }
        let dateOnly = formatter("yyyy-MM-dd")
        let full = formatter("yyyy-MM-dd HH:mm")
        var values: [TimeInterval: Double] = [:]
        func visit(_ row: [String: Any], parentDay: String? = nil) {
            let time = (row["time"] as? String) ?? (row["date"] as? String) ?? ""
            var day = parentDay
            if time.count >= 10 {
                let prefix = String(time.prefix(10))
                if let d = dateOnly.date(from: prefix), dateOnly.string(from: d) == prefix { day = prefix }
            }
            for key in ["dataList","ecoDetails","consumptionDetails"] {
                if let entries = row[key] as? [[String: Any]] { for entry in entries { visit(entry, parentDay: day) } }
            }
            guard let day else { return }
            let hourText: String
            if time.count > 10 && ["T"," "].contains(String(time.dropFirst(10).prefix(1))) {
                hourText = String(time.dropFirst(11))
            } else if let hour = row["hour"] {
                hourText = String(describing: hour)
            } else if time.count < 10 {
                hourText = time
            } else { return }
            let parts = hourText.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts[0].count <= 2, let hour = Int(parts[0]), (0...23).contains(hour),
                  parts.dropFirst().allSatisfy({ $0 == "00" }),
                  let date = full.date(from: day + String(format: " %02d:00", hour)),
                  date <= now && date >= now.addingTimeInterval(-3 * 86400),
                  let kwh = EnergyHistory.number(row["totalElectricity"]) ?? EnergyHistory.number(row["electricity"]) ?? EnergyHistory.number(row["consumption"]),
                  kwh >= 0 else { return }
            values[date.timeIntervalSince1970] = kwh
        }
        visit(data)
        return values.sorted { $0.key < $1.key }.map { MeterHour(start: $0.key, kwh: $0.value) }
    }

    static func confirmedHours(_ reply: [String: Any], calendarTotals: [String: Double], now: Date) -> [MeterHour] {
        let dateOnly = formatter("yyyy-MM-dd")
        let groups = Dictionary(grouping: parseHours(reply, now: now)) {
            dateOnly.string(from: Date(timeIntervalSince1970: $0.start))
        }
        var checked: [MeterHour] = []
        for (day, entries) in groups {
            // Some products use timeType=1 for a different granularity or
            // counter. Only use explicit hour values that reconcile with the
            // independently retrieved calendar total at TCL's 0.01 kWh precision.
            guard let total = calendarTotals[day],
                  entries.contains(where: { calendar.component(.hour, from: Date(timeIntervalSince1970: $0.start)) == 0 }),
                  abs(total - entries.reduce(0.0, { $0 + $1.kwh })) < 0.0051 else { continue }
            checked.append(contentsOf: entries.filter { $0.start + 3600 <= now.timeIntervalSince1970 })
        }
        return checked
    }
}
