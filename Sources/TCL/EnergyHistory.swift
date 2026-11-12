import Charts
import CoreFoundation
import Foundation
import SwiftUI

struct EnergyDay: Codable, Equatable {
    let day: String
    let kwh: Double
}

struct DailyEnergyReport: Codable, Equatable {
    let id: String
    let name: String
    let state: String
    let attempted: TimeInterval?
    let updated: TimeInterval
    let days: [EnergyDay]
    var meters: [MeterObservation]? = nil
    var hours: [MeterHour]? = nil
    var lastHourlyRequest: TimeInterval? = nil
}

struct EnergyCache: Codable, Equatable {
    let devices: [DailyEnergyReport]

    static func read(from file: URL) -> Self? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct WattSample: Codable, Identifiable {
    let timestamp: TimeInterval
    let watts: Double
    var id: TimeInterval { timestamp }
}

final class EnergyHistory: ObservableObject {
    private let directory: URL
    private let wattFile: URL
    private let files = DispatchQueue(label: "superbar.tcl.energy-files", qos: .utility)
    @Published private var cloud: [DailyEnergyReport] = []
    @Published private var samples: [String: [WattSample]] = [:]
    private var ids: [String: String] = [:]

    @Published private(set) var cardEnergy: [String: String] = [:]

    private func updateCardEnergy() {
        let names = Set(ids.keys).union(cloud.map(\.name)).union(samples.keys)
        let now = Date()
        let values = names.reduce(into: [String: String]()) { result, name in
            result[name] = barEnergy(for: name, now: now)?.text
        }
        if values != cardEnergy { cardEnergy = values }
    }

    private var restoring = true
    private var pendingIngest: [([[String: Any]], Date)] = []

    init(directory: URL) {
        self.directory = directory
        self.wattFile = directory.appendingPathComponent("watts.json")
        files.async { [wattFile] in
            let saved = (try? Data(contentsOf: wattFile)).flatMap { try? JSONDecoder().decode([String: [WattSample]].self, from: $0) }
            DispatchQueue.main.async {
                if let saved { self.samples = saved }
                self.restoring = false
                for (devices, now) in self.pendingIngest { self.ingest(devices, now: now) }
                self.pendingIngest.removeAll()
                self.updateCardEnergy()
            }
        }
        loadCloud()
    }

    private func loadCloud() {
        let file = directory.appendingPathComponent("tcl-energy.json")
        files.async {
            guard let cache = EnergyCache.read(from: file) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cloud != cache.devices else { return }
                self.cloud = cache.devices
                self.updateCardEnergy()
            }
        }
    }

    func report(for device: String) -> DailyEnergyReport? {
        if let id = ids[device] { return cloud.first { $0.id == id } }
        return cloud.first { $0.name == device }
    }

    func watts(for device: String, now: Date = Date()) -> [WattSample] {
        let key = ids[device] ?? report(for: device)?.id ?? device
        let cutoff = now.timeIntervalSince1970 - 86400
        return (samples[key] ?? []).filter { $0.timestamp >= cutoff && $0.timestamp <= now.timeIntervalSince1970 }
    }

    func barEnergy(for device: String, now: Date = Date()) -> (text: String, detail: String)? {
        let key = ids[device] ?? report(for: device)?.id ?? device
        if let latest = samples[key]?.last(where: { $0.timestamp <= now.timeIntervalSince1970 }), now.timeIntervalSince1970 - latest.timestamp <= 300 {
            let time = EnergyPeriod.formatter("HH:mm").string(from: Date(timeIntervalSince1970: latest.timestamp))
            return (DisplayUnits.power(latest.watts), "Power measured at " + time + ".")
        }
        guard let report = report(for: device), let result = EnergyPeriod.reading(report, now: now) else { return nil }
        return (result.text, result.detail)
    }

    // Keep a point only at the device's own measurement time. An unchanged
    // shadow can be read repeatedly, even while the air conditioner is offline.
    func ingest(_ devices: [[String: Any]], now: Date = Date()) {
        if restoring { pendingIngest.append((devices, now)); return }
        let cutoff = now.timeIntervalSince1970 - 86400
        var retained = samples.mapValues { $0.filter { $0.timestamp >= cutoff && $0.timestamp <= now.timeIntervalSince1970 } }
                              .filter { !$0.value.isEmpty }
        ids.removeAll(keepingCapacity: true)
        var changed = retained.values.reduce(0) { $0 + $1.count } != samples.values.reduce(0) { $0 + $1.count }
        for device in devices {
            guard let name = device["name"] as? String else { continue }
            if let id = device["id"] as? String { ids[name] = id }
            let key = ids[name] ?? report(for: name)?.id ?? name
            guard let reported = device["reported"] as? [String: Any],
                  let watts = Self.watts(in: reported),
                  let timestamp = Self.number(device["watts_reported_at"]),
                  timestamp >= cutoff, timestamp <= now.timeIntervalSince1970 else { continue }
            var points = retained[key] ?? []
            let sample = WattSample(timestamp: timestamp, watts: watts)
            if let index = points.lastIndex(where: { $0.timestamp == timestamp }) {
                guard points[index].watts != watts else { continue }
                points[index] = sample
            } else {
                points.append(sample)
                points.sort { $0.timestamp < $1.timestamp }
            }
            retained[key] = points
            changed = true
        }
        if changed {
            samples = retained
            files.async { [wattFile, retained] in
                guard let data = try? JSONEncoder().encode(retained) else { return }
                try? data.write(to: wattFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wattFile.path)
            }
        }
        updateCardEnergy()
        loadCloud()
    }

    static let wattFields = ["electricPowerW", "activePowerW", "instantaneousPowerW", "powerW"]
    static func watts(in report: [String: Any]) -> Double? {
        for key in wattFields {
            if let value = number(report[key]), value >= 0 { return value }
        }
        return nil
    }

    static func number(_ raw: Any?) -> Double? {
        let value: Double?
        if let numeric = raw as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() {
            value = numeric.doubleValue
        } else {
            value = (raw as? String).flatMap(Double.init)
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
}

struct EnergyChartView: View {
    @ObservedObject var history: EnergyHistory
    let device: String
    var body: some View {
        let now = Date()
        let report = history.report(for: device)
        let period = report.flatMap { EnergyPeriod.reading($0, now: now) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label { Text("Since 9am").foregroundStyle(.secondary) } icon: { Image(systemName:"bolt.fill").foregroundStyle(Color(nsColor:BarTheme.energy)) }
                Spacer()
                Text(period?.text ?? "—").fontWeight(.semibold).monospacedDigit()
            }.font(.callout).help(period?.detail ?? "Waiting for meter readings")
            EnergyCharts(days: days(report, now: now),
                         power: history.watts(for:device,now:now).map { PowerPoint(time:Date(timeIntervalSince1970:$0.timestamp),watts:$0.watts) },
                         currentDay: true, powerIntervals: report.map { EnergyPeriod.powerIntervals($0, now: now) } ?? [])
        }
    }
    private func days(_ report: DailyEnergyReport?, now: Date) -> [EnergyDayPoint] {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"Asia/Manila")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let values = Dictionary((report?.days ?? []).map { ($0.day,$0.kwh) },uniquingKeysWith:{ _,last in last })
        return (-(ChartHistory.dayCount - 1)...0).compactMap { offset in
            guard let date = calendar.date(byAdding:.day,value:offset,to:now) else { return nil }
            let key = formatter.string(from:date)
            return EnergyDayPoint(key:key,label:offset == 0 ? "Today" : String(calendar.component(.day,from:date)),
                                  wattHours:values[key].map { $0 * 1000 })
        }
    }
}
