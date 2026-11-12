import Foundation

struct TuyaDevice: Codable, Identifiable {
    let id: String, name: String, category: String
    let online: Bool?
    let watts: Double?
    let voltage: Double?, current: Double?, energyKWh: Double?, leakageMA: Double?, temperature: Double?
    let measuredAt: Date?
    var timeZoneID: String? = nil
    var historyDP: Int? = nil
    var isMeter: Bool { ["zndb", "dlq"].contains(category) || watts != nil || voltage != nil }
    static func decode(_ row: [String: Any], schema info: [String: Any]) -> TuyaDevice? {
        guard let id = row["devId"] as? String, !id.isEmpty else { return nil }
        let schema: [[String: Any]]
        if let rows = info["schema"] as? [[String: Any]] { schema = rows }
        else if let raw = info["schema"] as? String, let data = raw.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { schema = rows }
        else { schema = [] }
        let dps = CloudValue.object(CloudValue.object(row["dataPointInfo"])["dps"] ?? row["dps"])
        var values: [String: (raw: Any, spec: [String: Any])] = [:]
        for field in schema {
            guard let code = field["code"] as? String, let dp = field["id"], let raw = dps[String(describing: dp)] else { continue }
            values[code] = (raw, CloudValue.object(field["property"]))
        }
        func scaled(_ code: String, units: [String: Double]) -> Double? {
            guard let value = values[code], let raw = CloudValue.number(value.raw), let unit = value.spec["unit"] as? String,
                  let factor = units[unit], let scale = CloudValue.number(value.spec["scale"]), (0...12).contains(scale), scale.rounded() == scale else { return nil }
            return raw / pow(10, scale) * factor
        }
        var phases: [String: (Double, Double, Double)] = [:]
        let phaseCodes = schema.compactMap { $0["code"] as? String }.filter { ["phase_a", "phase_b", "phase_c"].contains($0) }
        if row["productId"] as? String == "i5mqmxkho1vahdt2" {
            for code in phaseCodes {
                guard let raw = values[code]?.raw as? String, let data = Data(base64Encoded: raw), data.count == 8 else { continue }
                let b = Array(data)
                func number(_ range: Range<Int>) -> Double { Double(range.reduce(0) { $0 * 256 + Int(b[$1]) }) }
                phases[code] = (number(0..<2) / 10, number(2..<5) / 1000, number(5..<8))
            }
        }
        let powerUnits = ["W": 1.0, "w": 1, "kW": 1000, "kw": 1000, "KW": 1000, "MW": 1_000_000, "mW": 0.001]
        var watts = ["total_power", "total_active_power", "power_total", "cur_power", "active_power", "power"].compactMap { scaled($0, units: powerUnits) }.first
        if watts == nil {
            let powers = ["a", "b", "c"].compactMap { phases["phase_" + $0]?.2 ?? scaled("power_" + $0, units: powerUnits) }
            if powers.count == 3 || (phaseCodes == ["phase_a"] && powers.count == 1) { watts = powers.reduce(0, +) }
        }
        func flag(_ value: Any?) -> Bool? {
            if let text = value as? String { return text.lowercased() == "true" ? true : text.lowercased() == "false" ? false : nil }
            if let n = value as? NSNumber, [0,1].contains(n.intValue) { return n.boolValue }
            return nil
        }
        var online = flag(row["isOnline"]) ?? flag(row["online"]) ?? flag(row["cloudOnline"])
        if online == nil {
            let flags = CloudValue.object(row["moduleMap"]).values.compactMap { flag(CloudValue.object($0)["isOnline"]) }
            if !flags.isEmpty { online = flags.contains(true) }
        }
        return TuyaDevice(id: id, name: row["name"] as? String ?? "Meter", category: row["category"] as? String ?? "",
                          online: online, watts: watts, voltage: phases["phase_a"]?.0 ?? scaled("cur_voltage", units: ["V": 1]),
                          current: phases["phase_a"]?.1 ?? scaled("cur_current", units: ["mA": 0.001, "A": 1]),
                          energyKWh: scaled("total_forward_energy", units: ["kWh": 1, "kW·h": 1]),
                          leakageMA: scaled("leakage_current", units: ["mA": 1]), temperature: scaled("temp_current", units: ["℃": 1, "°C": 1]),
                          measuredAt: CloudValue.date(row["dpMaxTime"]),
                          timeZoneID: row["timezoneId"] as? String,
                          historyDP: row["productId"] as? String == "i5mqmxkho1vahdt2" ? schema.first(where: {
                              $0["code"] as? String == "total_forward_energy"
                          }).flatMap { field in
                              guard let value = CloudValue.number(field["id"]), value > 0, value < 10000,
                                    value.rounded() == value else { return nil }
                              return Int(value)
                          } : nil)
    }
}

struct TuyaHistory: Codable {
    let meterID: String, timeZoneID: String
    var days: [EnergyDayPoint]
    var hours: [PowerInterval]
    let fetchedAt: Date
    var problem: String? = nil

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Manila")!
        return value
    }
    static func formatter(_ format: String, zone: TimeZone = calendar.timeZone) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = calendar; value.timeZone = zone
        value.dateFormat = format; value.isLenient = false
        return value
    }
    static func keys(now: Date) -> [String] {
        let format = formatter("yyyyMMdd")
        return (-(ChartHistory.accountingDayCount(now: now, calendar: calendar) - 1)...0).map { format.string(from: calendar.date(byAdding: .day, value: $0, to: now)!) }
    }
    static func daily(_ raw: Any, keys: [String]) -> [EnergyDayPoint] {
        let outer = CloudValue.object(raw)
        let values = outer["result"].map(CloudValue.object) ?? outer
        return keys.map { key in
            let value = CloudValue.number(values[key]).flatMap { $0 >= 0 ? $0 * 1000 : nil }
            return EnergyDayPoint(key: key, label: String(key.suffix(2)), wattHours: value)
        }
    }
    static func hourly(_ raw: Any, zone: TimeZone, now: Date) -> [PowerInterval] {
        let format = formatter("yyyyMMddHH", zone: zone)
        return CloudValue.object(raw).compactMap { key, raw in
            guard key.count == 10, let start = format.date(from: key),
                  format.string(from: start) == key, let kwh = CloudValue.number(raw), kwh >= 0 else { return nil }
            let end = start.addingTimeInterval(3600)
            // Current-hour energy is partial, so it must not be drawn as a full-hour average.
            guard end <= now, end > now.addingTimeInterval(-86400) else { return nil }
            return PowerInterval(start: start, end: end, watts: kwh * 1000)
        }.sorted { $0.start < $1.start }
    }
    var energyIntervals: [PowerInterval] {
        let start = Self.calendar.startOfDay(for: fetchedAt)
        let hourStart = Self.calendar.dateInterval(of: .hour, for: fetchedAt)!.start
        let completed = hours.filter { $0.start >= start && $0.end <= hourStart }
        let expected = Int(hourStart.timeIntervalSince(start) / 3600)
        let key = Self.formatter("yyyyMMdd").string(from: fetchedAt)
        guard completed.count == expected, fetchedAt > hourStart,
              let total = days.first(where: { $0.key == key })?.wattHours else { return hours }
        let remaining = total - completed.reduce(0) { $0 + $1.watts * $1.end.timeIntervalSince($1.start) / 3600 }
        guard remaining >= 0 else { return hours }
        return hours + [PowerInterval(start: hourStart, end: fetchedAt,
                                     watts: remaining * 3600 / fetchedAt.timeIntervalSince(hourStart))]
    }
}
struct TuyaSnapshot: Codable {
    let devices: [TuyaDevice]
    var meterID: String?
    let fetchedAt: Date
    var meter: TuyaDevice? { meterID.flatMap { id in devices.first { $0.id == id } } }
    func consumption(now: Date = Date()) -> Double? {
        guard now.timeIntervalSince(fetchedAt) < 90, let meter, meter.online == true, let watts = meter.watts else { return nil }
        if let measured = meter.measuredAt, now.timeIntervalSince(measured) > 600 { return nil }
        return watts
    }
}
