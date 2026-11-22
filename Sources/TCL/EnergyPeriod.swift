import Foundation

struct MeterHour: Codable, Equatable {
    let start: TimeInterval
    let kwh: Double
}

// Receipt times bound the interval between TCL daily-counter observations.
// An unchanged counter can mean the cloud has not published its next batch.
struct TCLCounterWindow: Codable, Equatable {
    struct Reading: Codable, Equatable {
        let at: TimeInterval
        let kwh: Double
    }
    let first: Reading
    let last: Reading?
    private static let maximumSpan = 2 * HistoryPolling.tclSummary + 120

    init(kwh: Double, at date: Date, previous: Self?) {
        let next = Reading(at: date.timeIntervalSince1970, kwh: kwh)
        let anchor = previous.flatMap { $0.last ?? $0.first }
        if let anchor, next.at >= anchor.at, kwh >= anchor.kwh,
           ChartHistory.calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: anchor.at)) {
            if kwh == anchor.kwh, let previous {
                self = previous
                return
            }
            let span = next.at - anchor.at
            if (HistoryPolling.tclSummary...Self.maximumSpan).contains(span) {
                first = anchor
                last = next
                return
            }
        }
        first = next
        last = nil
    }

    func average(at now: Date) -> (watts: Double, minutes: Int)? {
        guard let last, first.kwh >= 0, last.kwh > first.kwh,
              (0...HistoryPolling.tclSummary + 60).contains(now.timeIntervalSince1970 - last.at),
              ChartHistory.calendar.isDate(now, inSameDayAs: Date(timeIntervalSince1970: first.at)) else { return nil }
        let span = last.at - first.at
        guard (HistoryPolling.tclSummary...Self.maximumSpan).contains(span) else { return nil }
        let watts = (last.kwh - first.kwh) * 3_600_000 / span
        guard watts.isFinite else { return nil }
        return (watts, Int((span / 60).rounded()))
    }

    var interval: PowerInterval? {
        guard let last, first.at.isFinite, last.at.isFinite, first.kwh.isFinite, last.kwh.isFinite,
              first.kwh >= 0, last.kwh > first.kwh,
              ChartHistory.calendar.isDate(Date(timeIntervalSince1970: first.at), inSameDayAs: Date(timeIntervalSince1970: last.at)) else { return nil }
        let span = last.at - first.at
        guard (HistoryPolling.tclSummary...Self.maximumSpan).contains(span) else { return nil }
        let watts = (last.kwh - first.kwh) * 3_600_000 / span
        guard watts.isFinite else { return nil }
        return PowerInterval(start: Date(timeIntervalSince1970: first.at), end: Date(timeIntervalSince1970: last.at), watts: watts)
    }
}

enum EnergyPeriod {
    static func dayLabel(_ key: String, now: Date) -> String {
        let calendar = ChartHistory.calendar
        let iso = ChartHistory.formatter("yyyy-MM-dd")
        guard let date = iso.date(from: key),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day else { return "—" }
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days)d ago"
        }
    }

    // TCL's electricity fields default to kWh. Honor an explicit energy unit
    // and ignore other quantities (for example W or a percentage).
    static func kilowattHours(_ row: [String: Any], unit: String?) -> Double? {
        guard let amount = CloudValue.number(row["totalElectricity"]) ?? CloudValue.number(row["electricity"]) ?? CloudValue.number(row["consumption"]),
              amount >= 0 else { return nil }
        switch unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "kwh": return amount
        case "wh": return amount / 1000
        default: return nil
        }
    }

    // Only hour-stamped leaf readings are meter intervals. Daily/monthly group
    // totals may appear in the same response.
    static func parseHours(_ reply: [String: Any], now: Date) -> [MeterHour] {
        guard CloudValue.number(reply["code"]) == 0, let data = reply["data"] as? [String: Any] else { return [] }
        let dateOnly = ChartHistory.formatter("yyyy-MM-dd")
        let full = ChartHistory.formatter("yyyy-MM-dd HH:mm")
        var values: [TimeInterval: Double] = [:]
        func visit(_ row: [String: Any], parentDay: String? = nil, parentUnit: String? = nil) {
            let date = row["date"] as? String ?? ""
            let time = row["time"] as? String ?? ""
            let stamp = [time, date].first { $0.count >= 10 }
            var day = parentDay
            if let stamp {
                let prefix = String(stamp.prefix(10))
                day = dateOnly.date(from: prefix).flatMap { dateOnly.string(from: $0) == prefix ? prefix : nil }
            }
            let unit = row["unit"] as? String ?? parentUnit
            let groups = ["dataList", "ecoDetails", "consumptionDetails"].compactMap { row[$0] as? [[String: Any]] }
            if !groups.isEmpty {
                for entry in groups.joined() { visit(entry, parentDay: day, parentUnit: unit) }
                return
            }
            guard let day, let kwh = kilowattHours(row, unit: unit) else { return }
            let hourText: String
            if let stamp, stamp.count > 10, ["T", " "].contains(String(stamp.dropFirst(10).prefix(1))) {
                hourText = String(stamp.dropFirst(11))
            } else if let hour = row["hour"] {
                hourText = String(describing: hour)
            } else {
                hourText = time
            }
            let parts = hourText.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), (1...2).contains(parts[0].count),
                  parts[0].allSatisfy(\.isNumber), let hour = Int(parts[0]), (0...23).contains(hour),
                  parts.dropFirst().allSatisfy({ $0 == "00" }),
                  let start = full.date(from: day + String(format: " %02d:00", hour)),
                  start >= now.addingTimeInterval(-3 * 86400), start.addingTimeInterval(3600) <= now else { return }
            values[start.timeIntervalSince1970] = kwh
        }
        visit(data)
        return values.sorted { $0.key < $1.key }.map { MeterHour(start: $0.key, kwh: $0.value) }
    }

    static func confirmedHours(_ reply: [String: Any], calendarTotals: [String: Double], now: Date) -> [MeterHour] {
        let formatter = ChartHistory.formatter("yyyy-MM-dd")
        let today = formatter.string(from: now)
        let groups = Dictionary(grouping: parseHours(reply, now: now)) {
            formatter.string(from: Date(timeIntervalSince1970: $0.start))
        }
        return groups.flatMap { day, rows -> [MeterHour] in
            // Only a finished day with all 24 Manila clock hours can be compared
            // for equality. Each meter reading can round to the nearest 0.01 kWh.
            if day < today, let dayTotal = calendarTotals[day] {
                let sum = rows.reduce(0) { $0 + $1.kwh }
                let rounding = 0.005 * Double(rows.count + 1) + 1e-9
                if sum > dayTotal + rounding || (rows.count == 24 && abs(sum - dayTotal) > rounding) { return [] }
            }
            return rows
        }.sorted { $0.start < $1.start }
    }

    static func powerIntervals(_ report: DailyEnergyReport, now: Date) -> [PowerInterval] {
        let end = now.timeIntervalSince1970
        let hours = (report.hours ?? []).filter {
            $0.start + 3600 > end - 86400 && $0.start + 3600 <= end && $0.kwh.isFinite && $0.kwh >= 0
        }.map {
            PowerInterval(start: Date(timeIntervalSince1970: $0.start),
                          end: Date(timeIntervalSince1970: $0.start + 3600), watts: $0.kwh * 1000)
        }
        var estimates = (report.counterHistory ?? []).compactMap(\.interval)
        if let latest = report.counter?.interval, !estimates.contains(where: { $0.start == latest.start }) { estimates.append(latest) }
        estimates = estimates.filter { estimate in
            estimate.end <= now && !hours.contains { $0.start < estimate.end && $0.end > estimate.start }
        }
        return RollingEnergy.clipped((hours + estimates).sorted { $0.start < $1.start }, to: RollingEnergy.last24Hours(endingAt: now))
    }
}
