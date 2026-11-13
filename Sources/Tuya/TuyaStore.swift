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
    @Published var samples: [PowerPoint] = []
    @Published private(set) var history: TuyaHistory?
    @Published private(set) var historyProblem: String?
    @Published private(set) var historyRefreshing = false
    private let cloud: TuyaCloud
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var historyVisible = false
    private var historyAttemptAt: Date?
    private var historyAttemptMeterID: String?
    var chartHistory: TuyaHistory? { history?.meterID == reading?.meterID ? history : nil }
    var refreshInterval: Int { PowerPolling.interval }
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
    func stop() { task?.cancel(); historyTask?.cancel(); accountTask?.cancel() }
    func logout() {
        AccountConnection.setConnected(false, provider: "tuya", preferences: defaults)
        stop(); reading = nil; samples = []; history = nil; needsSignIn = true; problem = "Logged out"
    }
    func refreshAndWait() async {
        refresh()
        guard let task else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if Task.isCancelled { return }
        if let historyTask {
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
        let changed = historyAttemptMeterID != meter.id
        guard changed || HistoryPolling.due(since: historyAttemptAt, now: now, calendar: TuyaHistory.calendar) else { return }
        historyAttemptAt = now
        historyAttemptMeterID = meter.id
        historyRefreshing = true
        let previous = chartHistory
        historyTask = Task { [weak self, cloud] in
            defer {
                if Task.isCancelled { self?.historyAttemptAt = nil }
                self?.historyRefreshing = false; self?.historyTask = nil
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
                self?.loginDraft.prefill(email: savedEmail)
                let result = try await cloud.snapshot()
                guard let self, !Task.isCancelled else { return }
                self.reading = result; self.problem = nil; self.needsSignIn = false
                if self.selectedID == nil { self.selectedID = result.meterID ?? self.devices.first?.id }
                if let watts = result.consumption() {
                    self.samples.append(PowerPoint(time: result.fetchedAt, watts: watts))
                    self.samples.removeAll { $0.time < Date().addingTimeInterval(-86400) }
                    // A day at normal cadence is 5,760 points; manual refreshes
                    // must not grow the live chart without a count bound.
                    if self.samples.count > 6_000 { self.samples.removeFirst(self.samples.count - 6_000) }
                }
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: "tuya.readings") }
                self.refreshHistory()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.problem = (error as? TuyaError)?.errorDescription ?? "Could not read Tuya."
                if let error = error as? TuyaError { switch error { case .signIn, .expired: self.needsSignIn = true; default: break } }
            }
        }
    }
    func signIn(password: String) async -> Bool {
        guard !refreshing else { return false }
        CredentialAccess.retry()
        if !password.isEmpty { loginDraft.password = password }
        refreshing = true
        do {
            historyTask?.cancel()
            await historyTask?.value
            try await cloud.signIn(email: email, password: password)
            AccountConnection.setConnected(true, provider: "tuya", preferences: defaults)
            // Do not expose a previous account's readings after switching accounts.
            reading = nil; selectedID = nil; samples = []
            defaults.removeObject(forKey: "tuya.readings")
            history = nil; historyAttemptAt = nil; historyAttemptMeterID = nil; historyProblem = nil
            defaults.removeObject(forKey: "tuya.history")
            needsSignIn = false; problem = nil; refreshing = false; refresh(); return true
        }
        catch { problem = (error as? TuyaError)?.errorDescription ?? ((error as NSError).domain == NSOSStatusErrorDomain ? error.localizedDescription : "Could not save the Smart Life login. Your entered password is still available."); refreshing = false; return false }
    }
    func useAsMeter(_ id: String) {
        Task { await selectMeter(id) }
    }
    func selectMeter(_ id: String) async {
        guard !AccountConnection.signedOut("tuya", preferences: defaults) else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            historyTask?.cancel()
            await historyTask?.value
            try await cloud.selectMeter(id)
            reading?.meterID = id; selectedID = id; samples = []
            if let reading, let data = try? JSONEncoder().encode(reading) { defaults.set(data, forKey: "tuya.readings") }
            history = nil; historyAttemptAt = nil; historyAttemptMeterID = nil; historyProblem = nil
            defaults.removeObject(forKey: "tuya.history")
            problem = nil
            refreshHistory()
        } catch { problem = "Could not save the meter selection." }
    }
}
