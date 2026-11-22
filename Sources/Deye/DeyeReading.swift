import Foundation

struct DeyeDay: Codable, Identifiable {
    let day: String
    let kwh: Double?
    var id: String { day }
}
struct DeyeReading: Codable {
    let id: Int
    var name: String
    let power_w: Double?
    let today_kwh: Double?
    let status: String
    let measured_at: Double?
    var days: [DeyeDay]
    var curve: [PowerPoint]? = nil
    var historyDay: String? = nil
    var finalizedCurveDay: String? = nil
    var date: Date? { measured_at.map(Date.init(timeIntervalSince1970:)) }
    func currentPower(now: Date = Date()) -> Double? {
        guard status == "NORMAL", let date, (-60..<600).contains(now.timeIntervalSince(date)),
              let power_w, power_w.isFinite, power_w >= 0 else { return nil }
        return power_w
    }
    static func netForBilling(production: DeyeReading?, load: Double?, now: Date = Date()) -> Double? {
        guard let load, load.isFinite, load >= 0 else { return nil }
        return (production?.currentPower(now: now) ?? 0) - load
    }
    // Current power and history may finish in either order. Merge by measurement
    // time so a slow history response cannot replace a newer live observation.
    func withHistory(from history: DeyeReading?, now: Date = Date()) -> DeyeReading {
        var result = self
        if let history, history.id == id {
            result.days = history.days
            result.historyDay = history.historyDay
            result.finalizedCurveDay = history.finalizedCurveDay
        }
        if let date, let today_kwh, ChartHistory.calendar.isDate(date, inSameDayAs: now) {
            let key = ChartHistory.formatter("yyyy-MM-dd").string(from: date)
            result.days.removeAll { $0.day == key }
            result.days.append(DeyeDay(day: key, kwh: today_kwh))
        }
        var points = curve ?? []
        if let history, history.id == id { points += history.curve ?? [] }
        if let date, let watts = currentPower(now: now) { points.append(PowerPoint(time: date, watts: watts)) }
        let cutoff = now.addingTimeInterval(-90_000)
        let unique = Dictionary(points.filter { (cutoff...now).contains($0.time) }.map { ($0.time, $0) },
                                uniquingKeysWith: { _, last in last })
        result.curve = unique.values.sorted { $0.time < $1.time }
        return result
    }
    static func power(_ watts: Double?) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        return DisplayUnits.power(watts)
    }
}
