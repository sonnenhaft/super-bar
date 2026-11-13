import Foundation
import Darwin

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

// All requests terminate inside this protocol. It never forwards to a server.
private final class LGMemoryNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var heldID: String?
    private static var waiting: [LGMemoryNetwork] = []
    private static var paths: [String] = []
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    static func hold(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        heldID = id; paths = []
        precondition(waiting.isEmpty)
    }
    static func finishHeld() {
        lock.lock(); let pending = waiting; waiting = []; heldID = nil; lock.unlock()
        pending.forEach { $0.reply(["property": ["energyUsage"]]) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.paths.append(path)
        if let id = Self.heldID, path == "/devices/energy/\(id)/profile" {
            Self.waiting.append(self); Self.lock.unlock(); return
        }
        Self.lock.unlock()
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-rejected-token" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path == "/devices" {
            reply([["deviceId": "new-account-device", "deviceInfo": [
                "deviceType": "DEVICE_AIR_CONDITIONER", "alias": "Synthetic room"]]])
        } else if path.contains("/energy/") && path.hasSuffix("/profile") {
            reply(["property": ["energyUsage"]])
        } else if path.hasSuffix("/usage") {
            reply(["dataList": []])
        } else { reply([:]) }
    }
    override func stopLoading() {
        Self.lock.lock(); Self.waiting.removeAll { $0 === self }; Self.lock.unlock()
    }
    private func reply(_ response: Any) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["response": response]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main enum MemoryLifecycle {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let end = now.timeIntervalSince1970
        let points = (0..<12_000).map { WattSample(timestamp: end - Double($0), watts: Double($0)) }
        let invalid = [WattSample(timestamp: end - 90_000, watts: 1),
                       WattSample(timestamp: end + 1, watts: 1),
                       WattSample(timestamp: end, watts: -.infinity)]
        let clipped = EnergyHistory.boundedSamples(["test": points + invalid], now: now)["test"]!
        precondition(clipped.count == 6_000 && clipped.last?.timestamp == end)
        precondition(clipped.allSatisfy { $0.watts.isFinite && $0.timestamp >= end - 86400 && $0.timestamp <= end })
        let manyDevices = Dictionary(uniqueKeysWithValues: (0..<100).map { (String($0), [WattSample(timestamp: end, watts: 1)]) })
        precondition(EnergyHistory.boundedSamples(manyDevices, now: now).count == EnergyHistory.maximumCachedDevices)

        let wattsFile = folder.appendingPathComponent("watts.json")
        try JSONEncoder().encode(["test": points]).write(to: wattsFile)
        var transient: EnergyHistory? = EnergyHistory(directory: folder)
        let reference = WeakReference(transient!)
        transient = nil
        precondition(reference.value == nil, "Queued cache hydration retained a discarded history model")
        let history = EnergyHistory(directory: folder)
        try await wait { history.watts(for: "test").count == 6_000 }

        let huge = folder.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: EnergyCache.maximumBytes + 1).write(to: huge)
        precondition(EnergyCache.readData(from: huge) == nil, "Oversized cache must be rejected before decoding")
        let link = folder.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wattsFile)
        precondition(EnergyCache.readData(from: link) == nil)
        let pipe = folder.appendingPathComponent("pipe.json")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        precondition(EnergyCache.readData(from: pipe) == nil, "FIFO cache must fail without blocking")

        let domain = "SuperBar.phone-memory-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LGMemoryNetwork.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        var savedTokens: [String] = []
        let phone = PhoneLG(makeAPI: { API(network: network, readToken: { "synthetic-only" }, preferences: preferences) },
            saveToken: { savedTokens.append($0) }, preferences: preferences,
            validateCredentials: { try await API.validateCredentials(token: $0, country: $1, region: $2, network: network) })
        let device = PhoneLGDevice(id: "old-account-device", name: "Synthetic old room")
        phone.devices = [device]
        do { try await phone.configure(token: "synthetic-rejected-token", country: "US", region: "aic"); fatalError("Rejected LG login accepted") }
        catch { }
        precondition(savedTokens.isEmpty && phone.devices.map(\.id) == [device.id])
        precondition(preferences.string(forKey: "country") == nil && preferences.string(forKey: "region") == nil)
        precondition(!phone.busy, "A failed login must leave the form usable")

        LGMemoryNetwork.hold(device.id)
        let cancelled = Task { await phone.loadHistory(device) }
        try await wait { !LGMemoryNetwork.requests.isEmpty }
        cancelled.cancel(); await cancelled.value
        LGMemoryNetwork.hold(nil)
        await phone.loadHistory(device)
        precondition(LGMemoryNetwork.requests.contains { $0.hasSuffix("/usage") },
                     "Cancelling history must permit an immediate retry")
        precondition(phone.history[device.id]?.count == 30)

        let oldDevice = PhoneLGDevice(id: "another-old-device", name: "Another synthetic room")
        LGMemoryNetwork.hold(oldDevice.id)
        let oldAccount = Task { await phone.loadHistory(oldDevice) }
        try await wait { !LGMemoryNetwork.requests.isEmpty }
        try await phone.configure(token: "synthetic-new-token", country: "PH", region: "kic")
        LGMemoryNetwork.finishHeld(); await oldAccount.value
        precondition(savedTokens == ["synthetic-new-token"])
        precondition(phone.devices.map(\.id) == ["new-account-device"])
        precondition(phone.history.isEmpty && phone.historyProblem.isEmpty,
                     "An old account request must not repopulate a new account's history")
        precondition(!LGMemoryNetwork.requests.contains("/devices/energy/another-old-device/usage"),
                     "A stale account request must stop before querying more device data")
        print("Memory lifecycle: 12,000 cached samples bounded to 6,000, device/file limits, nonblocking hydration, model release, LG cancellation and account isolation passed.")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Synthetic asynchronous operation did not finish")
    }
}
