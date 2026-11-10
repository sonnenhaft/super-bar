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
            return (EnergyPeriod.pretty(latest.watts) + " W", "Power measured at " + time + " Manila time.")
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
    @State private var tab = 0

    private struct DaySlot: Identifiable {
        let date: String
        let label: String
        let value: Double?
        var id: String { date }
    }
    // TCL groups readings by calendar day in the AC's Philippines time zone.
    private static let zone = TimeZone(identifier: "Asia/Manila")!
    private func week(_ report: DailyEnergyReport?, now: Date) -> [DaySlot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let iso = DateFormatter()
        iso.calendar = calendar
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = Self.zone
        iso.dateFormat = "yyyy-MM-dd"
        let values = Dictionary((report?.days ?? []).map { ($0.day, $0.kwh) }, uniquingKeysWith: { _, newest in newest })
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let key = iso.string(from: date)
            return DaySlot(date: key, label: offset == 0 ? "Today" : String(calendar.component(.day, from: date)), value: values[key])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Energy", systemImage: "bolt.fill").font(.headline)
                Spacer(minLength: 6)
                Picker("Period", selection: $tab) {
                    Text("7 days").tag(0)
                    Text("24 hours").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let now = Date()
            let period = history.report(for: device).flatMap { EnergyPeriod.reading($0, now: now) }
            HStack {
                Label("Since 09:00 Manila time", systemImage: "bolt.fill").foregroundStyle(.secondary)
                Spacer()
                Text(period?.text ?? "—").fontWeight(.semibold).monospacedDigit()
            }.font(.callout)
             .help(period?.detail ?? "Waiting for hourly readings or the TCL daily meter.")
            if let energy = history.barEnergy(for: device, now: now), energy.text.hasSuffix(" W") {
                Text("Now " + energy.text).font(.caption).help(energy.detail)
            }
            if tab == 0 { dailyBody }
            else { wattBody }
        }
    }

    private var dailyBody: some View {
        let report = history.report(for: device)
        let slots = week(report, now: Date())
        let values = slots.compactMap(\.value)
        return VStack(alignment: .leading, spacing: 6) {
            if !values.isEmpty {
                HStack(alignment: .lastTextBaseline) {
                    Text("Daily energy since midnight, kWh").foregroundStyle(.secondary)
                    Spacer()
                }.font(.caption)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(slots) { slot in
                        VStack(spacing: 3) {
                            Text(slot.value.map(Self.n) ?? "—")
                                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .foregroundStyle(slot.value == nil ? Color.secondary : Color.primary)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            if let value = slot.value {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(slot.date == slots.last?.date ? Color.accentColor : Color.accentColor.opacity(0.56))
                                    .frame(maxWidth: 23)
                                    .frame(height: max(2, 43 * CGFloat(value / max(0.01, values.max() ?? 0))))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .help("\(slot.date) · " + (slot.value.map { "\(Self.n($0)) kWh" } ?? "no data"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(slot.date), " + (slot.value.map { "\(Self.n($0)) kilowatt-hours" } ?? "no data"))
                    }
                }.frame(height: 59, alignment: .bottom)
                Divider()
                HStack(spacing: 4) {
                    ForEach(slots) { slot in
                        Text(slot.label).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }.accessibilityHidden(true)
            }
            if values.isEmpty || report?.state == "error" || report?.state == "empty" {
                let message: String = {
                    switch report?.state {
                    case "error": return values.isEmpty ? "TCL returned no energy readings." : "Could not refresh TCL readings."
                    case "empty", "ok": return values.isEmpty ? "No readings for this period." : "Waiting for new TCL readings."
                    default: return "Waiting for energy readings."
                    }
                }()
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct PowerPoint: Identifiable {
        let sample: WattSample
        let group: Int
        var id: TimeInterval { sample.timestamp }
        var date: Date { Date(timeIntervalSince1970: sample.timestamp) }
    }
    private var wattBody: some View {
        let now = Date()
        let samples = history.watts(for: device, now: now)
        var previous: TimeInterval?
        var group = 0
        let points: [PowerPoint] = samples.map { sample in
            if let previous, sample.timestamp - previous > 600 { group += 1 }
            previous = sample.timestamp
            return PowerPoint(sample: sample, group: group)
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let last = points.last {
                HStack {
                    Text("Power, W").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Self.n(last.sample.watts)) W · \(last.date.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                }.font(.caption)
                Chart(points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("W", point.sample.watts),
                             series: .value("Series", point.group))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Time", point.date), y: .value("W", point.sample.watts))
                        .symbolSize(6).foregroundStyle(Color.accentColor)
                }
                .chartXScale(domain: now.addingTimeInterval(-86400)...now)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisTick(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 69)
            } else {
                Text("No power readings in the past 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func n(_ number: Double) -> String {
        number.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2)))
    }
}
