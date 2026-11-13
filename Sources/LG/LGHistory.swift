import Foundation

struct DayUsage: Codable, Equatable {
  var day: String
  var label: String
  var wh: Double?
  var seconds: Double?
  var observed: Bool? = nil
  var shifted: Bool? = nil
  var estimated: Bool? = nil

}

struct Boundary: Codable {
  let time: Date
  let wh: Double
  var seconds: Double?
}
struct Morning: Codable {
  var before: Boundary?
  var after: Boundary?
  func atNine(_ nine: Date) -> Boundary? {
    guard let a = before ?? after, let b = after ?? before else { return nil }
    if a.time == nine { return a }
    if b.time == nine { return b }
    guard a.time < nine, b.time > nine, b.wh >= a.wh else { return nil }
    let fraction = nine.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time)
    let seconds = a.seconds.flatMap { first in
      b.seconds.flatMap { $0 >= first ? first + ($0 - first) * fraction : nil }
    }
    return Boundary(time: nine, wh: a.wh + (b.wh - a.wh) * fraction, seconds: seconds)
  }
}

struct WeekHistory: Codable {
  var lastAttempt: Date?
  var days: [DayUsage] = []
  var month: String? = nil
  var monthWh: Double? = nil
  var mornings: [String: Morning]? = nil  // optional to read earlier caches
  var completedThrough: String? = nil
  func due(at date: Date, calendar: Calendar = .current) -> Bool {
    let offset = date < Self.nine(date, calendar) ? -2 : -1
    let end = Self.dayKey(calendar.date(byAdding: .day, value: offset, to: date)!, calendar)
    guard completedThrough != end || days.count < ChartHistory.dayCount else { return false }
    return lastAttempt.map { date < $0 || date.timeIntervalSince($0) >= HistoryPolling.archiveRetry } ?? true
  }
  static func load(_ key: String) -> Self {
    guard let data = defaults.data(forKey: key),
      let h = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return h
  }
  func save(_ key: String) {
    if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: key) }
  }
  static func dayKey(_ date: Date, _ cal: Calendar) -> String {
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
  }
  static func monthKey(_ date: Date, _ calendar: Calendar) -> String {
    String(dayKey(date, calendar).prefix(6))
  }
  static func nine(_ date: Date, _ cal: Calendar) -> Date {
    cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
  }
  mutating func record(_ point: Boundary, calendar cal: Calendar) {
    let nine = Self.nine(point.time, cal)
    let delta = point.time.timeIntervalSince(nine)
    guard abs(delta) <= 15 * 60 else { return }
    let key = Self.dayKey(point.time, cal)
    var all = mornings ?? [:]
    var day = all[key] ?? Morning()
    if delta <= 0, day.before.map({ $0.time < point.time }) ?? true { day.before = point }
    if delta >= 0, day.after.map({ $0.time > point.time }) ?? true { day.after = point }
    all[key] = day
    let cutoff = Self.dayKey(cal.date(byAdding: .day, value: -12, to: point.time)!, cal)
    mornings = all.filter { $0.key >= cutoff }
  }
}

/// On-time observed between consecutive successful polls. Long gaps and unknown states
/// contribute nothing. Stored totals are explicitly marked as observations in the UI.
struct ObservedUse: Codable {
  var civil: [String: Double] = [:], shifted: [String: Double] = [:]
  private enum CodingKeys: String, CodingKey { case civil, shifted }
  var previous: Date? = nil
  var previouslyOn: Bool? = nil
  var lastSave: Date? = nil
  mutating func sample(at now: Date, on: Bool?, interval: Double, calendar cal: Calendar) {
    defer {
      previous = now
      previouslyOn = on
    }
    guard let start = previous, let old = previouslyOn, let on, old == on,
      now > start, now.timeIntervalSince(start) <= min(630, max(15, 1.5 * interval))
    else { return }
    for hour in [0, 9] {
      let morning = cal.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
      let day = start < morning ? cal.date(byAdding: .day, value: -1, to: morning)! : morning
      let next = cal.date(byAdding: .day, value: 1, to: day)!
      let first = WeekHistory.dayKey(day, cal)
      let a = on ? min(now, next).timeIntervalSince(start) : 0
      if hour == 0 { civil[first, default: 0] += a } else { shifted[first, default: 0] += a }
      if now > next {
        let second = WeekHistory.dayKey(next, cal)
        let b = on ? now.timeIntervalSince(next) : 0
        if hour == 0 { civil[second, default: 0] += b } else { shifted[second, default: 0] += b }
      }
    }
  }
  mutating func save(_ key: String, at now: Date, force: Bool = false) {
    guard force || lastSave.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return }
    let cutoff = WeekHistory.dayKey(
      Calendar.current.date(byAdding: .day, value: -12, to: now)!, Calendar.current)
    civil = civil.filter { $0.key >= cutoff }
    shifted = shifted.filter { $0.key >= cutoff }
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key + ".run") }
    lastSave = now
  }
  static func load(_ key: String) -> Self {
    defaults.data(forKey: key + ".run").flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
      ?? Self()
  }
}

enum LGHistoryDecoder {
  static func runtime(_ row: [String: Any]) -> Double? {
    func num(_ v: Any?) -> Double? {
      let n = lgNumber(v) ?? (v as? String).flatMap(Double.init)
      return n.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    for base in ["operation", "operating", "usage", "run", "runtime", "operationTime", "usageTime"]
    {
      for (suffix, multiplier) in [("Seconds", 1.0), ("Minutes", 60.0), ("Hours", 3600.0)] {
        if let n = num(row[base + suffix]) { return n * multiplier }
      }
    }
    for key in ["operationTime", "usageTime", "runTime", "runtime", "operatingTime"] {
      let entry = object(row[key] ?? [:])
      let unit = (entry["unit"] ?? row[key + "Unit"]) as? String
      guard let n = num(entry["value"] ?? row[key]), let unit else { continue }
      switch unit.lowercased() {
      case "s", "sec", "seconds": return n
      case "m", "min", "minutes": return n * 60
      case "h", "hr", "hours": return n * 3600
      default: continue
      }
    }
    return nil
  }

  static func series(
    response: Any, end: Date, calendar cal: Calendar, mornings: [String: Morning] = [:],
    use: ObservedUse = ObservedUse()
  ) -> [DayUsage] {
    let rows = find("dataList", in: response) as? [[String: Any]] ?? []
    var totals: [String: Double] = [:]
    var durations: [String: Double] = [:]
    var incomplete = Set<String>()
    for row in rows {
      guard let wh = lgNumber(row["energyUsage"]), wh.isFinite, wh >= 0 else { continue }
      let raw = ["date", "usageDate", "usedDate", "useDate", "periodDate", "startDate", "dateTime"]
        .compactMap { row[$0] }.first
      guard let raw else { continue }
      let key = String(String(describing: raw).filter(\.isNumber).prefix(8))
      guard key.count == 8 else { continue }
      totals[key, default: 0] += wh
      if let t = runtime(row) { durations[key, default: 0] += t } else { incomplete.insert(key) }
    }
    return (-(ChartHistory.dayCount - 1)...0).map { offset in
      let d = cal.date(byAdding: .day, value: offset, to: end)!
      let next = cal.date(byAdding: .day, value: 1, to: d)!
      let key = WeekHistory.dayKey(d, cal)
      let nextKey = WeekHistory.dayKey(next, cal)
      var day = DayUsage(
        day: key, label: String(cal.component(.day, from: d)), wh: totals[key],
        seconds: incomplete.contains(key) ? nil : durations[key])
      if let total = day.wh, let a = mornings[key]?.atNine(WeekHistory.nine(d, cal)),
        let b = mornings[nextKey]?.atNine(WeekHistory.nine(next, cal)), a.wh <= total
      {
        day.wh = total - a.wh + b.wh
        day.shifted = true
        day.estimated =
          mornings[key]?.before?.time != a.time || mornings[nextKey]?.before?.time != b.time
        if let seconds = day.seconds, let m = a.seconds, let n = b.seconds, m <= seconds {
          day.seconds = seconds - m + n
        } else {
          day.seconds = nil
        }
      }
      if day.seconds == nil {
        day.seconds = (day.shifted == true ? use.shifted : use.civil)[key]
        day.observed = day.seconds != nil
      }
      return day
    }
  }
}
