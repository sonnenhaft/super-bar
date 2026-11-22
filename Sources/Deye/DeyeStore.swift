import Foundation
import Combine

@MainActor final class DeyeStore: ObservableObject {
    private let defaults: UserDefaults
    let loginDraft: LoginDraft
    @Published private(set) var reading: DeyeReading?
    @Published private(set) var refreshing = false
    @Published private(set) var problem: String?
    @Published var ratePinned: Bool { didSet { defaults.set(ratePinned, forKey: "deye.showHourlyRate") } }
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "deye.showPower") } }
    var refreshInterval: Int { RefreshPreferences.seconds(.deye, preferences: defaults) }
    private var task: Task<Void, Never>?
    private let accountGeneration = CurrentValueSubject<Int, Never>(0)
    private var historyVisible = false
    private var historyTask: Task<Void, Never>?
    @Published private(set) var historyRefreshing = false
    private var historyFetchedAt: Date?
    func showHistory(_ visible: Bool) {
        historyVisible = visible
        guard visible else { return }
        if reading == nil { refresh() } else { refreshHistory() }
    }
    private let cloud: DeyeCloud
    @Published private(set) var needsSignIn = false
    init(defaults: UserDefaults = .standard, cloud: DeyeCloud = DeyeCloud(file: PrivateJSONFile.appFile("Deye/session.json"), importFile: PrivateJSONFile.importFile("deye"))) {
        self.defaults = defaults
        loginDraft = LoginDraft(provider: "deye", preferences: defaults)
        self.cloud = cloud
        defaults.removeObject(forKey: "deye.showDailyRate")
        ratePinned = defaults.bool(forKey: "deye.showHourlyRate")
        pinned = defaults.bool(forKey: "deye.showPower")
        if !AccountConnection.signedOut("deye", preferences: defaults), let data = defaults.data(forKey: "deye.lastReading"), data.count <= 8 * 1024 * 1024 {
            reading = try? JSONDecoder().decode(DeyeReading.self, from: data)
        }
    }
    deinit { task?.cancel(); historyTask?.cancel() }
    var readout: String? { pinned ? DeyeReading.power(reading?.power_w) : nil }
    var status: String {
        if let problem { return problem }
        if refreshing { return "Refreshing…" }
        guard let reading else { return "No readings" }
        return reading.status + " · " + (reading.date.map { ReadingAge.label($0) } ?? "Time unknown")
    }
    func start() { refresh() }
    func stop() { task?.cancel(); historyTask?.cancel() }
    func logout() {
        AccountConnection.setConnected(false, provider: "deye", preferences: defaults)
        accountGeneration.send(accountGeneration.value + 1)
        stop(); reading = nil; needsSignIn = true; problem = "Logged out"
    }
    func manualRefreshAndWait() async {
        if refreshing && task == nil {
            // A successful sign-in starts a read before releasing the main actor.
            let generation = accountGeneration.value
            for await _ in $refreshing.combineLatest(accountGeneration).values {
                guard !Task.isCancelled, generation == accountGeneration.value else { return }
                if let task { await task.value; return }
                if !refreshing { return }
            }
            return
        }
        guard !Task.isCancelled else { return }
        await refreshAndWait()
    }
    func refreshAndWait(waitForHistory: Bool = false) async {
        refresh()
        guard let task else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if waitForHistory, !Task.isCancelled, let historyTask {
            await withTaskCancellationHandler { await historyTask.value } onCancel: { historyTask.cancel() }
        }
    }
    func refresh() {
        guard !AccountConnection.signedOut("deye", preferences: defaults) else { return }
        guard !refreshing else { return }
        refreshing = true
        let previous = reading
        task = Task { [weak self, cloud] in
            defer { self?.refreshing = false; self?.task = nil }
            do {
                let saved = await cloud.savedLogin()
                self?.loginDraft.prefill(email: saved.email, server: saved.server)
                let result = try await cloud.current(previous: previous)
                guard let self, !Task.isCancelled else { return }
                self.save(result.withHistory(from: self.reading))
                self.problem = nil
                self.needsSignIn = false
                self.refreshHistory()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.needsSignIn = (error as? DeyeError)?.needsSignIn ?? false
                self.problem = (error as? DeyeError)?.errorDescription ?? "Could not read Deye; showing saved readings."
            }
        }
    }
    private func save(_ result: DeyeReading) {
        reading = result
        if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "deye.lastReading") }
    }
    private func refreshHistory() {
        guard historyVisible, historyTask == nil, !AccountConnection.signedOut("deye", preferences: defaults),
              let reading, HistoryPolling.due(since: historyFetchedAt, calendar: ChartHistory.calendar) else { return }
        historyFetchedAt = Date()
        historyRefreshing = true
        historyTask = Task { [weak self, cloud] in
            defer {
                if Task.isCancelled { self?.historyFetchedAt = nil }
                self?.historyRefreshing = false
                self?.historyTask = nil
            }
            guard let history = try? await cloud.history(for: reading), !Task.isCancelled,
                  let self, let current = self.reading, current.id == history.id else { return }
            self.save(current.withHistory(from: history))
            self.historyFetchedAt = Date()
        }
    }
    func signIn(email: String, password: String, server: String) async -> Bool {
        guard !refreshing else { return false }
        CredentialAccess.retry()
        loginDraft.email = email; loginDraft.password = password; loginDraft.server = server
        refreshing = true
        let generation = accountGeneration.value
        defer { if generation != accountGeneration.value { refreshing = false } }
        do {
            historyTask?.cancel()
            await historyTask?.value
            guard generation == accountGeneration.value else { return false }
            try await cloud.signIn(email: email, password: password, base: server)
            guard generation == accountGeneration.value else { return false }
            AccountConnection.setConnected(true, provider: "deye", preferences: defaults)
            reading = nil
            historyFetchedAt = nil
            defaults.removeObject(forKey: "deye.lastReading")
            problem = nil
            needsSignIn = false
            refreshing = false
            refresh()
            return true
        } catch {
            guard generation == accountGeneration.value else { return false }
            problem = (error as? DeyeError)?.errorDescription ?? ((error as NSError).domain == NSOSStatusErrorDomain ? error.localizedDescription : "Could not save the Deye login. Your entered password is still available.")
            refreshing = false
            return false
        }
    }
}
