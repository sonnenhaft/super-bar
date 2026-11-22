import Charts
import CoreFoundation
import Darwin
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
    var hours: [MeterHour]? = nil
    var lastHourlyRequest: TimeInterval? = nil
    var counter: TCLCounterWindow? = nil
    var counterHistory: [TCLCounterWindow]? = nil
}

struct EnergyCache: Codable, Equatable {
    let devices: [DailyEnergyReport]

    static func read(from file: URL) -> Self? {
        guard let data = readData(from: file), let cache = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return Self(devices: cache.devices.prefix(64).map { report in
            DailyEnergyReport(id: report.id, name: report.name, state: report.state,
                attempted: report.attempted, updated: report.updated, days: Array(report.days.suffix(95)),
                hours: report.hours.map { Array($0.suffix(72)) }, lastHourlyRequest: report.lastHourlyRequest, counter: report.counter,
                counterHistory: report.counterHistory.map { Array($0.suffix(200)) })
        })
    }

    // Cache hydration is bounded before decoding. A damaged file, symlink or
    // named pipe must not allocate arbitrary memory or block the file worker.
    static let maximumBytes = 8 * 1024 * 1024
    static func readData(from file: URL) -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes,
              let data = try? handle.read(upToCount: Int(info.st_size) + 1), data.count <= maximumBytes else { return nil }
        return data
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
    private var restoring = true
    private var pendingIngest: ([[String: Any]], Date)?
    private var cloudReadQueued = false
    private var cloudRevision: FileRevision?
    private struct FileRevision: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
        init?(_ file: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.modified = modified; self.size = size.uint64Value; self.inode = inode.uint64Value
        }
    }

    // More than a full day at the supported 15-second cadence, even with jitter.
    static let maximumSamplesPerDevice = 6_000
    static let maximumCachedDevices = 64
    static func boundedSamples(_ saved: [String: [WattSample]], now: Date) -> [String: [WattSample]] {
        let end = now.timeIntervalSince1970, start = end - 86400
        var result: [String: [WattSample]] = [:]
        for key in saved.keys.sorted().prefix(maximumCachedDevices) {
            var values: [TimeInterval: WattSample] = [:]
            for point in saved[key] ?? [] where point.timestamp.isFinite && point.watts.isFinite && point.watts >= 0
                && point.timestamp >= start && point.timestamp <= end {
                values[point.timestamp] = point
            }
            let retained = values.values.sorted { $0.timestamp < $1.timestamp }.suffix(maximumSamplesPerDevice)
            if !retained.isEmpty { result[key] = Array(retained) }
        }
        return result
    }

    init(directory: URL) {
        self.directory = directory
        self.wattFile = directory.appendingPathComponent("watts.json")
        files.async { [weak self, wattFile] in
            let saved = EnergyCache.readData(from: wattFile)
                .flatMap { try? JSONDecoder().decode([String: [WattSample]].self, from: $0) }
                .map { Self.boundedSamples($0, now: Date()) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let saved { self.samples = saved }
                self.restoring = false
                if let (devices, now) = self.pendingIngest { self.ingest(devices, now: now) }
                self.pendingIngest = nil
            }
        }
        loadCloud()
    }

    private func loadCloud() {
        guard !cloudReadQueued else { return }
        cloudReadQueued = true
        let file = directory.appendingPathComponent("tcl-energy.json")
        let previous = cloudRevision
        files.async { [weak self] in
            let revision = FileRevision(file)
            let cache = revision != nil && revision != previous ? EnergyCache.read(from: file) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cloudReadQueued = false
                guard let cache else { return }
                self.cloudRevision = revision
                guard self.cloud != cache.devices else { return }
                self.cloud = cache.devices
            }
        }
    }

    func report(for id: String) -> DailyEnergyReport? { cloud.first { $0.id == id } }

    func watts(for id: String, now: Date = Date()) -> [WattSample] {
        let cutoff = now.timeIntervalSince1970 - 86400
        return (samples[id] ?? []).filter { $0.timestamp >= cutoff && $0.timestamp <= now.timeIntervalSince1970 }
    }

    func power(for ac: Aircon, online: Bool, now: Date = Date()) -> (label: String, text: String, menuText: String)? {
        guard online, ac.online == true, !ac.failed else { return nil }
        if let watts = ac.measuredWatts(at: now) {
            let text = DisplayUnits.power(watts)
            return ("Power", text, text)
        }
        guard ac.power == true, let counter = report(for: ac.id)?.counter,
              counter.first.at >= (ac.powerChangedAt ?? 0),
              let average = counter.average(at: now) else { return nil }
        let text = "≈ " + DisplayUnits.power(average.watts)
        return ("Avg \(average.minutes)m", text, text + " · \(average.minutes)m")
    }

    // Keep a point only at the device's own measurement time. An unchanged
    // shadow can be read repeatedly, even while the air conditioner is offline.
    func ingest(_ devices: [[String: Any]], now: Date = Date()) {
        if restoring { pendingIngest = (devices, now); return }
        let cutoff = now.timeIntervalSince1970 - 86400
        var retained = samples.mapValues { $0.filter { $0.timestamp >= cutoff && $0.timestamp <= now.timeIntervalSince1970 } }
                              .filter { !$0.value.isEmpty }
        var currentKeys = Set<String>()
        var changed = retained.values.reduce(0) { $0 + $1.count } != samples.values.reduce(0) { $0 + $1.count }
        for device in devices {
            guard let key = device["id"] as? String ?? device["name"] as? String else { continue }
            currentKeys.insert(key)
            guard let watts = Self.reportedWatts(device),
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
            if points.count > Self.maximumSamplesPerDevice {
                points.removeFirst(points.count - Self.maximumSamplesPerDevice)
            }
            retained[key] = points
            changed = true
        }
        if changed {
            if retained.count > Self.maximumCachedDevices {
                let keys = retained.keys.sorted {
                    if currentKeys.contains($0) != currentKeys.contains($1) { return currentKeys.contains($0) }
                    return $0 < $1
                }.prefix(Self.maximumCachedDevices)
                retained = Dictionary(uniqueKeysWithValues: keys.compactMap { key in retained[key].map { (key, $0) } })
            }
            samples = retained
            files.async { [wattFile, retained] in
                guard let data = try? JSONEncoder().encode(retained), data.count <= EnergyCache.maximumBytes else { return }
                try? data.write(to: wattFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wattFile.path)
            }
        }
        loadCloud()
    }

    static func reportedWatts(_ row: [String: Any]) -> Double? {
        guard let report = row["reported"] as? [String: Any] else { return nil }
        if let field = row["watts_field"] as? String {
            guard wattFields.contains(field) else { return nil }
            return watts(in: [field: report[field] ?? NSNull()])
        }
        return watts(in: report)
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
        VStack(alignment: .leading, spacing: 8) {
            if let day = report?.days.last {
                HStack {
                    Text(EnergyPeriod.dayLabel(day.day, now: now)).foregroundStyle(.secondary)
                    Spacer()
                    Text(DisplayUnits.energy(day.kwh * 1000)).monospacedDigit()
                }.font(.callout)
            }
            EnergyCharts(days: (report?.days ?? []).map {
                EnergyDayPoint(key: $0.day, label: String($0.day.suffix(2)), wattHours: $0.kwh * 1000)
            }, power: history.watts(for: device, now: now).map {
                PowerPoint(time: Date(timeIntervalSince1970: $0.timestamp), watts: $0.watts)
            }, powerIntervals: report.map { EnergyPeriod.powerIntervals($0, now: now) } ?? [])
            if (report?.hours ?? []).isEmpty {
                Text("TCL provides daily totals. Recent power is estimated from changes in consumption while Super Bar runs.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
