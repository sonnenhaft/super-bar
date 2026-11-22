import Foundation

private extension TuyaCloud {
    func holdMeterWrite(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        precondition(release.wait(timeout: .now() + 5) == .success)
    }
}

// No live cloud calls: cancellation and retry exercise the real stores/clients.
private final class StoreNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var stopped = 0
    private static var reject = false
    private static var solarWatts: Int?
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var cancellations: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    static func reset(reject: Bool, solarWatts: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        count = 0; stopped = 0; self.reject = reject; self.solarWatts = solarWatts
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let reject = Self.reject, watts = Self.solarWatts; Self.lock.unlock()
        if let watts, request.url!.path.contains("/operating/system/") {
            let body: [String: Any] = ["generationPower": watts, "networkStatus": "NORMAL",
                                       "lastUpdateTime": Date().timeIntervalSince1970]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } else if reject {
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
        let manualDeye = Task { await deye.manualRefreshAndWait() }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(StoreNetwork.requests == 1, "A manual refresh shares the in-flight Deye read")
        deyeWait.cancel()
        await deyeWait.value
        await manualDeye.value
        precondition(!deye.refreshing && deye.problem == nil && deye.reading?.id == 1,
                     "Cancelling Deye must release busy state and preserve cached readings")
        StoreNetwork.reset(reject: true)
        await deye.refreshAndWait()
        precondition(StoreNetwork.requests > 0 && !deye.refreshing && deye.problem != nil && deye.reading?.id == 1,
                     "Deye must accept another refresh after cancellation")

        StoreNetwork.reset(reject: false, solarWatts: 425)
        deye.showHistory(true)
        try await started()
        await deye.manualRefreshAndWait()
        precondition(deye.historyRefreshing && !deye.refreshing && deye.reading?.power_w == 425,
                     "Publish live power even while a history request is stalled")
        await deye.manualRefreshAndWait()
        precondition(StoreNetwork.requests == 3, "A second live refresh must reuse the pending history request")
        deye.showHistory(false)
        deye.stop()
        while deye.historyRefreshing { await Task.yield() }

        let tuyaFile = folder.appendingPathComponent("tuya.json")
        var session = TuyaCloud.Session(); session.sid = "test-only"; session.meter_id = "old"; session.email = "test@example.test"
        try PrivateJSONFile.write(session, to: tuyaFile)
        defaults.set(try JSONEncoder().encode(TuyaSnapshot(devices: [], meterID: "old", fetchedAt: Date())), forKey: "tuya.readings")
        let tuyaCloud = TuyaCloud(file: tuyaFile, source: nil, network: network, vault: vault)
        let tuya = TuyaStore(defaults: defaults, cloud: tuyaCloud)
        StoreNetwork.reset(reject: false)
        let tuyaWait = Task { await tuya.refreshAndWait() }
        try await started()
        let manualTuya = Task { await tuya.manualRefreshAndWait() }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(StoreNetwork.requests == 1, "A manual refresh shares the in-flight Tuya read")
        tuyaWait.cancel()
        await tuyaWait.value
        await manualTuya.value
        precondition(!tuya.refreshing && tuya.problem == nil, "Cancelling Tuya must release busy state")
        StoreNetwork.reset(reject: true)
        await tuya.refreshAndWait()
        precondition(StoreNetwork.requests > 0 && !tuya.refreshing && tuya.problem != nil,
                     "Tuya must accept another refresh after cancellation")
        func sample(_ id: String, _ watts: Double, ago: TimeInterval) -> TuyaSnapshot {
            let meter = TuyaDevice(id: id, name: id, category: "dlq", online: true, watts: watts,
                                   voltage: nil, current: nil, energyKWh: nil, leakageMA: nil, temperature: nil, measuredAt: nil)
            return TuyaSnapshot(devices: [meter], meterID: id, fetchedAt: Date().addingTimeInterval(-ago))
        }
        tuya.recordSamples(from: sample("old", 999, ago: 86_600), account: session.email)
        tuya.recordSamples(from: sample("old", 210, ago: 52), account: session.email)
        let savedBatch = defaults.data(forKey: "tuya.observedPower")
        tuya.recordSamples(from: sample("old", 225, ago: 37), account: session.email)
        precondition(defaults.data(forKey: "tuya.observedPower") == savedBatch, "Avoid rewriting the full local series on each 15-second poll")
        tuya.stop()
        let relaunched = TuyaStore(defaults: defaults, cloud: tuyaCloud)
        await relaunched.refreshAndWait()
        precondition(relaunched.samples.map(\.watts) == [210, 225] && relaunched.history == nil,
                     "Verify the account and restore its recent local samples on launch, even if the network read fails")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Task.detached { await tuyaCloud.holdMeterWrite(entered: entered, release: release) }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        StoreNetwork.reset(reject: true)
        let change = Task { await tuya.selectMeter("new") }
        while !tuya.refreshing { await Task.yield() }
        var finished = false
        let updateMeter = Task { await tuya.manualRefreshAndWait(); finished = true }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(!finished && StoreNetwork.requests == 0, "Manual update must wait for the user's meter selection")
        release.signal()
        await change.value
        await updateMeter.value
        precondition(StoreNetwork.requests > 0, "Manual update must read the newly selected meter")
        precondition(tuya.reading?.meterID == "new" && tuya.selectedID == "new" && !tuya.refreshing)
        let restored = TuyaStore(defaults: defaults, cloud: TuyaCloud(file: tuyaFile, source: nil, network: network, vault: vault))
        precondition(restored.reading?.meterID == "new", "Meter selection must survive application relaunch")
        await restored.refreshAndWait()
        precondition(restored.samples.isEmpty, "A newly selected meter must not inherit another meter's power")
        restored.recordSamples(from: sample("new", 0, ago: 7), account: session.email)
        await restored.selectMeter("old")
        precondition(restored.samples.map(\.watts) == [210, 225])
        await restored.selectMeter("new")
        precondition(restored.samples.map(\.watts) == [0], "Switching back restores observations for that meter, including zero")
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

        StoreNetwork.reset(reject: false)
        let login = Task { await deye.signIn(email: "test@example.test", password: "test", server: "https://eu1.deyecloud.com") }
        try await started()
        finished = false
        let updateAccount = Task { await deye.manualRefreshAndWait(); finished = true }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(!finished, "Manual update must wait for the account operation")
        deye.logout()
        await updateAccount.value
        login.cancel()
        _ = await login.value
        precondition(deye.reading == nil && deye.problem == "Logged out" && !deye.refreshing,
                     "Logging out must release a queued manual update and discard the old login result")
        restored.recordSamples(from: sample("new", 710, ago: 1), account: "different@example.test")
        precondition(restored.samples.map(\.watts) == [710], "Two accounts must not share observations even when the meter ID matches")
        restored.logout()
        precondition(restored.samples.isEmpty && defaults.data(forKey: "tuya.observedPower") == nil)
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
