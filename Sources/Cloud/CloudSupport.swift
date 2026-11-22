import Foundation
import CoreFoundation
import Darwin

// Shared by native cloud clients. Authenticated redirects never carry credentials away.
final class CloudRedirects: NSObject, URLSessionTaskDelegate {
    private let isHistory: Bool
    private let provider: CloudTraffic.Provider
    init(provider: CloudTraffic.Provider = .other, isHistory: Bool = false) {
        self.provider = provider; self.isHistory = isHistory
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var incoming: Int64 = 0
        var outgoing: Int64 = 0
        for transfer in metrics.transactionMetrics where transfer.resourceFetchType != .localCache {
            incoming += transfer.countOfResponseHeaderBytesReceived + transfer.countOfResponseBodyBytesReceived
            outgoing += transfer.countOfRequestHeaderBytesSent + transfer.countOfRequestBodyBytesSent
        }
        CloudTraffic.shared.record(incoming: incoming, outgoing: outgoing, at: metrics.taskInterval.end,
                                   history: isHistory, provider: provider)
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config, delegate: CloudRedirects(), delegateQueue: nil)
    }
}

// Count bytes in memory. Publish and save one summary per completed minute.
// Average/minute and the hour total always describe exactly the same window.
final class CloudTraffic: @unchecked Sendable {
    enum Provider: String, Codable, CaseIterable { case tcl, lg, deye, tuya, other }
    static let shared: CloudTraffic = {
        let bundle = Bundle.main
        // Standalone probes and native checks must not touch the app's ledger.
        let command = ProcessInfo.processInfo.arguments.dropFirst().first
        let appProcess = bundle.bundleURL.pathExtension == "app" && command != "--cli" && command != "--bluetti-helper"
        var directory: URL?
        if appProcess, let identifier = bundle.bundleIdentifier {
            directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(identifier, isDirectory: true)
        }
        return CloudTraffic(storageURL: directory?.appendingPathComponent("traffic-minutes.json"),
                            automaticallyUpdates: directory != nil)
    }()
    struct Volume: Codable, Equatable {
        var incoming: Int64 = 0
        var outgoing: Int64 = 0
        var chartIn: Int64 = 0
        var chartOut: Int64 = 0
        mutating func add(_ other: Volume) {
            incoming += other.incoming
            outgoing += other.outgoing
            chartIn += other.chartIn
            chartOut += other.chartOut
        }
        fileprivate var valid: Bool {
            [incoming, outgoing, chartIn, chartOut].allSatisfy { $0 >= 0 && $0 <= Int64.max / 128 }
                && chartIn <= incoming && chartOut <= outgoing
        }
    }
    struct Snapshot: Codable, Equatable {
        let through: Date
        let coveredSeconds: TimeInterval
        let total: Volume
        let averageIncomingBytesPerMinute: Double
        let averageOutgoingBytesPerMinute: Double
        var providers: [String: Volume]? = nil

        init(through: Date, coveredSeconds: TimeInterval, total: Volume) {
            self.through = through; self.coveredSeconds = coveredSeconds; self.total = total
            let minutes = coveredSeconds / 60
            averageIncomingBytesPerMinute = minutes > 0 ? Double(total.incoming) / minutes : 0
            averageOutgoingBytesPerMinute = minutes > 0 ? Double(total.outgoing) / minutes : 0
        }
        var minuteLabel: String {
            guard coveredSeconds > 0 else { return "Traffic · collecting first minute…" }
            return "Rate  IN \(averageIncomingLabel)  OUT \(averageOutgoingLabel)"
        }
        var totalLabel: String {
            guard coveredSeconds > 0 else { return "Updates once per minute" }
            return "\(windowLabel)  IN \(incomingTotalLabel)  OUT \(outgoingTotalLabel)"
        }
        var averageIncomingLabel: String { CloudTraffic.dataSize(averageIncomingBytesPerMinute * 60) + "/ч" }
        var averageOutgoingLabel: String { CloudTraffic.dataSize(averageOutgoingBytesPerMinute * 60) + "/ч" }
        var incomingTotalLabel: String { CloudTraffic.dataSize(Double(total.incoming)) }
        var outgoingTotalLabel: String { CloudTraffic.dataSize(Double(total.outgoing)) }
        func forProvider(_ provider: Provider) -> Snapshot {
            Snapshot(through: through, coveredSeconds: coveredSeconds, total: providers?[provider.rawValue] ?? Volume())
        }
        var windowLabel: String {
            if coveredSeconds >= 3600 { return "Last hour" }
            let seconds = Int(coveredSeconds)
            if seconds < 60 { return "Last \(seconds)s" }
            return "Last \(seconds / 60)m" + (seconds % 60 == 0 ? "" : " \(seconds % 60)s")
        }
        var detail: String {
            guard coveredSeconds > 0 else { return "Counting HTTP headers and bodies locally. The first summary appears after this minute ends. No extra API requests." }
            let minutes = (coveredSeconds / 60).formatted(.number.precision(.fractionLength(0...1)))
            return "HTTP headers and bodies through \(through.formatted(date: .omitted, time: .shortened)). Hourly rates and totals use the same \(minutes)-minute window, including idle minutes. kB = 1,000 bytes. displayed values are rounded. Charts are already included: In \(CloudTraffic.dataSize(Double(total.chartIn))) · Out \(CloudTraffic.dataSize(Double(total.chartOut))). The current unfinished minute is not included. Saved locally once per minute; no extra API requests."
        }
    }
    private struct MinuteSample: Codable {
        let minute: Int
        var volume: Volume
        var providers: [String: Volume]? = nil
        var valid: Bool {
            guard volume.valid else { return false }
            guard let providers else { return true } // Older totals remain unattributed.
            guard providers.count <= Provider.allCases.count,
                  providers.allSatisfy({ Provider(rawValue: $0.key) != nil && $0.value.valid }) else { return false }
            var sum = Volume()
            for value in providers.values { sum.add(value) }
            return sum == volume
        }
    }
    private struct Archive: Codable {
        var version = 1
        let observedSince: Date
        let minutes: [MinuteSample]
        let summary: Snapshot
    }
    private let lock = NSLock()
    private let storageURL: URL?
    private var buckets: [Int: Volume] = [:]
    private var providerBuckets: [Int: [String: Volume]] = [:]
    private var observedSince: Date
    private var newest: Date
    private var cached: Snapshot
    private var timer: DispatchSourceTimer?

    init(startedAt: Date = .now, storageURL: URL? = nil, automaticallyUpdates: Bool = false) {
        let start = Date(timeIntervalSince1970: floor(startedAt.timeIntervalSince1970))
        self.storageURL = storageURL; observedSince = start; newest = start
        let through = Self.boundary(start)
        cached = Snapshot(through: through, coveredSeconds: 0, total: Volume())
        if let url = storageURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue <= 64 * 1024,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Archive.self, from: data), saved.version == 1,
           saved.summary.through <= through, through.timeIntervalSince(saved.summary.through) <= 3600,
           saved.summary.through == Self.boundary(saved.summary.through),
           saved.observedSince >= Date(timeIntervalSince1970: 0),
           saved.observedSince <= saved.summary.through, saved.minutes.count <= 60,
           Set(saved.minutes.map(\.minute)).count == saved.minutes.count,
           saved.minutes.allSatisfy({ $0.valid && $0.minute < Self.minute(saved.summary.through)
               && $0.minute >= Self.minute(saved.summary.through) - 60 }) {
            observedSince = saved.observedSince
            buckets = Dictionary(uniqueKeysWithValues: saved.minutes.filter { $0.minute >= Self.minute(through) - 60 }
                .map { ($0.minute, $0.volume) })
            providerBuckets = Dictionary(uniqueKeysWithValues: saved.minutes.filter { $0.minute >= Self.minute(through) - 60 }
                .map { ($0.minute, $0.providers ?? [Provider.other.rawValue: $0.volume]) })
            // Recompute restored averages from the saved counts, never from rounded labels.
            cached = makeSnapshot(through: through)
        }
        if automaticallyUpdates {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SuperBar.traffic", qos: .utility))
            let delay = max(0.1, Self.boundary(.now).addingTimeInterval(60).timeIntervalSinceNow)
            timer.schedule(wallDeadline: .now() + delay, repeating: 60, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in _ = self?.snapshot(at: .now) }
            self.timer = timer
            timer.resume()
        }
    }
    deinit { timer?.cancel() }

    private static func minute(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 60)) }
    static func boundary(_ date: Date) -> Date { Date(timeIntervalSince1970: Double(minute(date)) * 60) }

    func record(incoming: Int64, outgoing: Int64, at date: Date, history: Bool = false, provider: Provider = .other) {
        guard incoming > 0 || outgoing > 0 else { return }
        let incoming = max(0, incoming), outgoing = max(0, outgoing)
        let volume = Volume(incoming: incoming, outgoing: outgoing,
                            chartIn: history ? incoming : 0, chartOut: history ? outgoing : 0)
        lock.lock()
        defer { lock.unlock() }
        newest = max(newest, date)
        let cutoff = Self.minute(newest) - 60
        let minute = Self.minute(date)
        guard minute >= cutoff else { return }
        observedSince = min(observedSince, Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)))
        buckets = buckets.filter { $0.key >= cutoff }
        providerBuckets = providerBuckets.filter { $0.key >= cutoff }
        buckets[minute, default: Volume()].add(volume)
        providerBuckets[minute, default: [:]][provider.rawValue, default: Volume()].add(volume)
        // Late metrics can correct an earlier bucket, but never republish or
        // write per request. They join the next minute's consistent summary.
    }

    func snapshot(at now: Date) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let through = Self.boundary(now)
        guard through != cached.through else { return cached }
        if through < cached.through { // A wall-clock correction must not show a future summary.
            buckets = buckets.filter { $0.key < Self.minute(through) }
            providerBuckets = providerBuckets.filter { $0.key < Self.minute(through) }
            observedSince = min(observedSince, through)
        }
        newest = now
        buckets = buckets.filter { $0.key >= Self.minute(through) - 60 }
        providerBuckets = providerBuckets.filter { $0.key >= Self.minute(through) - 60 }
        cached = makeSnapshot(through: through)
        save()
        return cached
    }
    private func makeSnapshot(through: Date) -> Snapshot {
        let start = max(observedSince, through.addingTimeInterval(-3600))
        var total = Volume()
        var providers: [String: Volume] = [:]
        for (minute, volume) in buckets where minute >= Self.minute(start) && minute < Self.minute(through) {
            total.add(volume)
            for (provider, value) in providerBuckets[minute] ?? [Provider.other.rawValue: volume] {
                providers[provider, default: Volume()].add(value)
            }
        }
        var snapshot = Snapshot(through: through, coveredSeconds: max(0, through.timeIntervalSince(start)), total: total)
        snapshot.providers = providers
        return snapshot
    }
    private func save() {
        guard let url = storageURL else { return }
        let first = max(Self.minute(observedSince), Self.minute(cached.through) - 60)
        let end = Self.minute(cached.through)
        let samples = first < end ? (first..<end).map {
            MinuteSample(minute: $0, volume: buckets[$0] ?? Volume(), providers: providerBuckets[$0] ?? [:])
        } : []
        let archive = Archive(observedSince: observedSince, minutes: samples, summary: cached)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("Could not save traffic summary: %@", error.localizedDescription) }
    }
    private static func dataSize(_ bytes: Double) -> String {
        let mega = bytes >= 1_000_000
        let value = bytes / (mega ? 1_000_000 : 1_000)
        return value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(1))) + (mega ? " mB" : " kB")
    }
}

// Bound decoded bytes while they arrive, before JSON can expand them further.
// data(for:) buffers the complete response before a caller can inspect its size.
enum CloudResponse {
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "The cloud response exceeded the supported size." }
    }
    static let maximumBytes = 8 * 1024 * 1024
    static func data(for request: URLRequest, using session: URLSession,
                     maximumBytes: Int = maximumBytes, history: Bool = false,
                     provider: CloudTraffic.Provider = .other) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw Failure.tooLarge }
        try Task.checkCancellation()
        // Task-level attribution also covers injected sessions and authentication
        // retries. It overrides the session delegate rather than counting twice.
        let (bytes, response) = try await session.bytes(for: request, delegate: CloudRedirects(provider: provider, isHistory: history))
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw Failure.tooLarge }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 64 * 1024))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw Failure.tooLarge }
                data.append(byte)
                if data.count % (16 * 1024) == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}
enum PrivateJSONFile {
    static let maximumCredentialBytes = 1024 * 1024
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    struct Snapshot { let data: Data; let identity: Identity }

    private static func validate(_ info: stat, privateFile: Bool) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumCredentialBytes,
              !privateFile || info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    static func identityIfPresent(at file: URL) throws -> Identity? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        try validate(info, privateFile: false)
        return Identity(info)
    }
    static func snapshotIfPresent(from file: URL) throws -> Snapshot? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw CocoaError(.fileReadUnknown) }
        try validate(before, privateFile: true)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumCredentialBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if count == 0 { break }
            guard data.count + count <= maximumCredentialBytes else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Identity(before) == Identity(after) else {
            throw CocoaError(.fileReadUnknown)
        }
        return Snapshot(data: data, identity: Identity(after))
    }
    static func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T {
        try JSONDecoder().decode(type, from: readData(from: file))
    }
    static func readData(from file: URL) throws -> Data {
        guard let snapshot = try snapshotIfPresent(from: file) else { throw CocoaError(.fileNoSuchFile) }
        return snapshot.data
    }
    static func removeLegacy(at file: URL, matching expected: Identity?) throws {
        guard let expected else { return } // A file created during the save was never migrated.
        guard let current = try identityIfPresent(at: file) else { return }
        guard current == expected else { throw CocoaError(.fileWriteUnknown) }
        // unlink never recursively deletes a directory or follows a symlink target.
        guard unlink(file.path) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }
    }
    static func appFile(_ relative: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Super Bar/" + relative)
    }
    static func importFile(_ service: String) -> URL? {
        Bundle.main.url(forResource: service + "-session-path", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
enum CloudValue {
    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    static func object(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        if let string = value as? String, let data = string.data(using: .utf8) { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        return [:]
    }
    static func date(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
    }
}
