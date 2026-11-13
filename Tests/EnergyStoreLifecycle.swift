import Foundation

// No live cloud calls: cancellation and retry exercise the real stores/clients.
private final class StoreNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var stopped = 0
    private static var reject = false
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var cancellations: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    static func reset(reject: Bool) { lock.lock(); defer { lock.unlock() }; count = 0; stopped = 0; self.reject = reject }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let reject = Self.reject; Self.lock.unlock()
        if reject {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.lock(); Self.stopped += 1; Self.lock.unlock() }
}

@main enum EnergyStoreLifecycle {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "SuperBar.energy-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: domain) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StoreNetwork.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let solar = DeyeReading(id: 1, name: "Saved", power_w: 100, today_kwh: 1, status: "OK", measured_at: 1, days: [])
        defaults.set(try JSONEncoder().encode(solar), forKey: "deye.lastReading")
        let deyeFile = folder.appendingPathComponent("deye.json")
        let vault = MemoryCredentialVault()
        try PrivateJSONFile.write(DeyeCloud.Session(base: "https://eu1.deyecloud.com", token: "test-only"), to: deyeFile)
        let deye = DeyeStore(defaults: defaults, cloud: DeyeCloud(file: deyeFile, network: network, vault: vault))

        StoreNetwork.reset(reject: false)
        let deyeWait = Task { await deye.refreshAndWait() }
        try await started()
        deyeWait.cancel()
        await deyeWait.value
        precondition(!deye.refreshing && deye.problem == nil && deye.reading?.id == 1,
                     "Cancelling Deye must release busy state and preserve cached readings")
        StoreNetwork.reset(reject: true)
        await deye.refreshAndWait()
        precondition(StoreNetwork.requests > 0 && !deye.refreshing && deye.problem != nil && deye.reading?.id == 1,
                     "Deye must accept another refresh after cancellation")

        let tuyaFile = folder.appendingPathComponent("tuya.json")
        var session = TuyaCloud.Session(); session.sid = "test-only"; session.meter_id = "old"; session.email = "test@example.test"
        try PrivateJSONFile.write(session, to: tuyaFile)
        defaults.set(try JSONEncoder().encode(TuyaSnapshot(devices: [], meterID: "old", fetchedAt: Date())), forKey: "tuya.readings")
        let tuya = TuyaStore(defaults: defaults, cloud: TuyaCloud(file: tuyaFile, source: nil, network: network, vault: vault))
        StoreNetwork.reset(reject: false)
        let tuyaWait = Task { await tuya.refreshAndWait() }
        try await started()
        tuyaWait.cancel()
        await tuyaWait.value
        precondition(!tuya.refreshing && tuya.problem == nil, "Cancelling Tuya must release busy state")
        StoreNetwork.reset(reject: true)
        await tuya.refreshAndWait()
        precondition(StoreNetwork.requests > 0 && !tuya.refreshing && tuya.problem != nil,
                     "Tuya must accept another refresh after cancellation")
        await tuya.selectMeter("new")
        precondition(tuya.reading?.meterID == "new" && tuya.selectedID == "new" && !tuya.refreshing)
        let restored = TuyaStore(defaults: defaults, cloud: TuyaCloud(file: tuyaFile, source: nil, network: network, vault: vault))
        precondition(restored.reading?.meterID == "new", "Meter selection must survive application relaunch")
        // An in-flight request must not keep a discarded model alive. Dropping
        // the last UI owner also cancels the request instead of waiting for its timeout.
        StoreNetwork.reset(reject: false)
        var disposableDeye: DeyeStore? = DeyeStore(defaults: defaults,
            cloud: DeyeCloud(file: deyeFile, network: network, vault: vault))
        weak var releasedDeye = disposableDeye
        disposableDeye?.refresh()
        try await started()
        disposableDeye = nil
        precondition(releasedDeye == nil, "Deye request retained its discarded store")
        try await cancelled()

        StoreNetwork.reset(reject: false)
        var disposableTuya: TuyaStore? = TuyaStore(defaults: defaults,
            cloud: TuyaCloud(file: tuyaFile, source: nil, network: network, vault: vault))
        weak var releasedTuya = disposableTuya
        disposableTuya?.refresh()
        try await started()
        disposableTuya = nil
        precondition(releasedTuya == nil, "Tuya request retained its discarded store")
        try await cancelled()
        print("Shared energy stores: cancellation, cached readings, retries, persisted meter selection and in-flight model release verified.")
    }

    private static func started() async throws {
        for _ in 0..<200 {
            if StoreNetwork.requests > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Mock request never started")
    }
    private static func cancelled() async throws {
        for _ in 0..<200 {
            if StoreNetwork.cancellations > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Discarding the store did not cancel its mock request")
    }
}
