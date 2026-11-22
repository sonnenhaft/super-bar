import Foundation
import Combine

@MainActor final class TuyaStore: ObservableObject {
    @Published private(set) var reading: TuyaSnapshot?
    @Published private(set) var refreshing = false
    @Published private(set) var problem: String?
    @Published private(set) var needsSignIn = false
    @Published var selectedID: String?
    let loginDraft: LoginDraft
    var email: String { get { loginDraft.email } set { loginDraft.email = newValue } }
    @Published private(set) var pinnedID: String?
    @Published private(set) var samples: [PowerPoint] = []
    private struct Observations: Codable {
        var account = ""
        var meters: [String: [PowerPoint]] = [:]
    }
    private var observations = Observations()
    private var sampleMeter: String?
    private var samplesChanged = false
    private var lastSampleSave: Date?
    @Published private(set) var history: TuyaHistory?
    @Published private(set) var historyProblem: String?
    @Published private(set) var historyRefreshing = false
    private let cloud: TuyaCloud
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private let accountGeneration = CurrentValueSubject<Int, Never>(0)
    private var selectingMeter = false
    private var historyTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var historyVisible = false
    private var historyAttemptAt: Date?
    private var historySource: HistorySource?
    private struct HistorySource: Equatable {
        let meterID: String
        let statistics: Int?
        let power: TuyaPowerDP?
        init(_ meter: TuyaDevice) {
            meterID = meter.id
            statistics = meter.historyDP
            power = meter.powerDP
        }
    }
    var chartHistory: TuyaHistory? { history?.meterID == reading?.meterID ? history : nil }
    var chartPower: [PowerPoint] {
        guard let reports = chartHistory?.power, !reports.isEmpty else { return samples }
        return Dictionary((samples + reports).map { ($0.time, $0) }, uniquingKeysWith: { _, reported in reported })
            .values.sorted { $0.time < $1.time }
    }
    var refreshInterval: Int { RefreshPreferences.seconds(.tuya, preferences: defaults) }
    var devices: [TuyaDevice] { reading?.devices.filter(\.isMeter) ?? [] }
    var selected: TuyaDevice? { devices.first { $0.id == selectedID } ?? reading?.meter ?? devices.first }
    var pinnedWatts: Double? {
        guard let reading, Date().timeIntervalSince(reading.fetchedAt) < 90,
              let device = reading.devices.first(where: { $0.id == (pinnedID ?? reading.meterID) }), device.online == true else { return nil }
        return device.watts
    }
    func pin(_ id: String) {
        pinnedID = id; defaults.set(id, forKey: "tuya.pinnedDevice")
    }
    init(defaults: UserDefaults = .standard, cloud: TuyaCloud = TuyaCloud()) {
        self.defaults = defaults; self.cloud = cloud
        loginDraft = LoginDraft(provider: "tuya", preferences: defaults)
        pinnedID = defaults.string(forKey: "tuya.pinnedDevice")
        if !AccountConnection.signedOut("tuya", preferences: defaults), let data = defaults.data(forKey: "tuya.readings"), data.count <= 8 * 1024 * 1024 {
            reading = try? JSONDecoder().decode(TuyaSnapshot.self, from: data)
        }
        selectedID = reading?.meterID
        if let data = defaults.data(forKey: "tuya.history"), data.count <= 8 * 1024 * 1024 {
            history = try? JSONDecoder().decode(TuyaHistory.self, from: data)
        }
        if !AccountConnection.signedOut("tuya", preferences: defaults),
           let data = defaults.data(forKey: "tuya.observedPower"), data.count <= 8 * 1024 * 1024,
           let saved = try? JSONDecoder().decode(Observations.self, from: data) {
            observations = saved
        }
    }
    deinit { task?.cancel(); historyTask?.cancel(); accountTask?.cancel() }
    func start() {
        guard !AccountConnection.signedOut("tuya", preferences: defaults) else { return }
        refresh()
        guard accountTask == nil else { return }
        accountTask = Task { [weak self, cloud] in
            defer { self?.accountTask = nil }
            let email = await cloud.savedEmail()
            guard !Task.isCancelled else { return }
            self?.loginDraft.prefill(email: email)
        }
    }
    func stop() { saveSamples(); task?.cancel(); historyTask?.cancel(); accountTask?.cancel() }
    func logout() {
        AccountConnection.setConnected(false, provider: "tuya", preferences: defaults)
        accountGeneration.send(accountGeneration.value + 1)
        clearSamples()
        stop(); reading = nil; history = nil; needsSignIn = true; problem = "Logged out"
    }
    func manualRefreshAndWait() async {
        if refreshing && task == nil {
            let generation = accountGeneration.value
            let needsMeterRead = selectingMeter
            for await _ in $refreshing.combineLatest(accountGeneration).values {
                guard !Task.isCancelled, generation == accountGeneration.value else { return }
                // Sign-in starts its own snapshot. A saved meter selection needs one.
                if task != nil { break }
                if !refreshing {
                    guard needsMeterRead, problem == nil else { return }
                    break
                }
            }
            guard generation == accountGeneration.value else { return }
        }
        guard !Task.isCancelled else { return }
        await refreshAndWait()
    }
    func refreshAndWait(waitForHistory: Bool = false) async {
        refresh()
        guard let task else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if Task.isCancelled { return }
        while waitForHistory, !Task.isCancelled, let historyTask {
            await withTaskCancellationHandler { await historyTask.value } onCancel: { historyTask.cancel() }
        }
    }
    func showHistory(_ visible: Bool) {
        historyVisible = visible
        if visible { refreshHistory() }
    }
    private func refreshHistory() {
        guard !AccountConnection.signedOut("tuya", preferences: defaults) else { return }
        guard historyVisible, !historyRefreshing, let meter = reading?.meter else { return }
        let now = Date()
        let source = HistorySource(meter)
        guard source != historySource || HistoryPolling.due(since: historyAttemptAt, now: now, calendar: ChartHistory.calendar) else { return }
        historyAttemptAt = now
        historySource = source
        historyRefreshing = true
        let previous = chartHistory
        historyTask = Task { [weak self, cloud] in
            defer {
                if Task.isCancelled { self?.historyAttemptAt = nil }
                self?.historyRefreshing = false; self?.historyTask = nil
                if !Task.isCancelled, let current = self?.reading?.meter, HistorySource(current) != source {
                    self?.refreshHistory()
                }
            }
            do {
                let result = try await cloud.history(for: meter, previous: previous)
                guard let self, !Task.isCancelled, self.reading?.meterID == result.meterID else { return }
                self.history = result; self.historyProblem = result.problem
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: "tuya.history") }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.historyProblem = (error as? TuyaError)?.errorDescription ?? "Could not read Tuya history."
            }
        }
    }
    func refresh() {
        guard !AccountConnection.signedOut("tuya", preferences: defaults) else { return }
        guard !refreshing else { return }
        refreshing = true
        task = Task { [weak self, cloud] in
            defer { self?.refreshing = false; self?.task = nil }
            do {
                let savedEmail = await cloud.savedEmail()
                guard !Task.isCancelled else { return }
                self?.restoreSamples(account: savedEmail, meter: self?.reading?.meterID)
                self?.loginDraft.prefill(email: savedEmail)
                let result = try await cloud.snapshot()
                guard let self, !Task.isCancelled else { return }
                self.reading = result; self.problem = nil; self.needsSignIn = false
                if self.selectedID == nil { self.selectedID = result.meterID ?? self.devices.first?.id }
                self.recordSamples(from: result, account: savedEmail)
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: "tuya.readings") }
                self.refreshHistory()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.problem = (error as? TuyaError)?.errorDescription ?? "Could not read Tuya."
                if let error = error as? TuyaError { switch error { case .signIn, .expired: self.needsSignIn = true; default: break } }
            }
        }
    }
    // A saved meter ID alone cannot identify the account after a new login.
    // Verify the session owner before presenting the local readings, even offline.
    private func restoreSamples(account: String, meter: String?, now: Date = Date()) {
        let owner = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !owner.isEmpty else {
            if sampleMeter != nil { saveSamples(); samples = []; sampleMeter = nil }
            return
        }
        if observations.account != owner {
            clearSamples()
            observations.account = owner
        }
        let range = RollingEnergy.last24Hours(endingAt: now)
        if sampleMeter != meter {
            saveSamples()
            sampleMeter = meter
            samples = meter.flatMap { observations.meters[$0] }?.filter {
                range.contains($0.time) && $0.watts.isFinite && $0.watts >= 0
            } ?? []
            lastSampleSave = nil
        } else if let first = samples.first, let last = samples.last,
                  first.time < range.lowerBound || last.time > now {
            samples.removeAll { !range.contains($0.time) }
            samplesChanged = true
        }
    }
    func recordSamples(from result: TuyaSnapshot, account: String) {
        let now = result.fetchedAt
        restoreSamples(account: account, meter: result.meterID, now: now)
        guard sampleMeter != nil, let watts = result.consumption(now: now), watts.isFinite, watts >= 0 else { return }
        if samples.last?.time == now { samples.removeLast() }
        samples.append(PowerPoint(time: now, watts: watts))
        // Normal polling produces 5,760 observations per day.
        if samples.count > 6_000 { samples.removeFirst(samples.count - 6_000) }
        samplesChanged = true
        if lastSampleSave.map({ now.timeIntervalSince($0) >= 60 || now < $0 }) ?? true { saveSamples(at: now) }
    }
    func saveSamples(at now: Date = Date()) {
        guard samplesChanged, let sampleMeter else { return }
        observations.meters[sampleMeter] = samples
        let range = RollingEnergy.last24Hours(endingAt: now)
        observations.meters = observations.meters.compactMapValues { points in
            let retained = points.filter { range.contains($0.time) }
            return retained.isEmpty ? nil : retained
        }
        if let data = try? JSONEncoder().encode(observations) {
            defaults.set(data, forKey: "tuya.observedPower")
            lastSampleSave = now
            samplesChanged = false
        }
    }
    private func clearSamples() {
        observations = Observations()
        sampleMeter = nil
        samples = []
        samplesChanged = false
        lastSampleSave = nil
        defaults.removeObject(forKey: "tuya.observedPower")
    }
    func signIn(password: String) async -> Bool {
        guard !refreshing else { return false }
        CredentialAccess.retry()
        if !password.isEmpty { loginDraft.password = password }
        refreshing = true
        let generation = accountGeneration.value
        defer { if generation != accountGeneration.value { refreshing = false } }
        do {
            historyTask?.cancel()
            await historyTask?.value
            guard generation == accountGeneration.value else { return false }
            try await cloud.signIn(email: email, password: password)
            let account = await cloud.savedEmail()
            guard generation == accountGeneration.value else { return false }
            AccountConnection.setConnected(true, provider: "tuya", preferences: defaults)
            // Do not expose a previous account's readings after switching accounts.
            reading = nil; selectedID = nil; restoreSamples(account: account, meter: nil)
            defaults.removeObject(forKey: "tuya.readings")
            history = nil; historyAttemptAt = nil; historySource = nil; historyProblem = nil
            defaults.removeObject(forKey: "tuya.history")
            needsSignIn = false; problem = nil; refreshing = false; refresh(); return true
        }
        catch {
            guard generation == accountGeneration.value else { return false }
            problem = (error as? TuyaError)?.errorDescription ?? ((error as NSError).domain == NSOSStatusErrorDomain ? error.localizedDescription : "Could not save the Smart Life login. Your entered password is still available.")
            refreshing = false
            return false
        }
    }
    func useAsMeter(_ id: String) {
        guard devices.first(where: { $0.id == id })?.online != false else { return }
        Task { await selectMeter(id) }
    }
    func selectMeter(_ id: String) async {
        guard !AccountConnection.signedOut("tuya", preferences: defaults) else { return }
        guard !refreshing else { return }
        let generation = accountGeneration.value
        selectingMeter = true
        refreshing = true
        defer { selectingMeter = false; refreshing = false }
        do {
            historyTask?.cancel()
            await historyTask?.value
            guard generation == accountGeneration.value else { return }
            try await cloud.selectMeter(id)
            let account = await cloud.savedEmail()
            guard generation == accountGeneration.value else { return }
            reading?.meterID = id; selectedID = id
            restoreSamples(account: account, meter: id)
            if let reading, let data = try? JSONEncoder().encode(reading) { defaults.set(data, forKey: "tuya.readings") }
            history = nil; historyAttemptAt = nil; historySource = nil; historyProblem = nil
            defaults.removeObject(forKey: "tuya.history")
            problem = nil
            refreshHistory()
        } catch {
            if generation == accountGeneration.value { problem = "Could not save the meter selection." }
        }
    }
}
