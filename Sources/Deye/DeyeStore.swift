import AppKit
import Combine

@MainActor final class DeyeStore: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var reading: DeyeReading?
    @Published private(set) var refreshing = false
    @Published private(set) var problem: String?
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "deye.showPower") } }
    var refreshInterval: Int { PowerPolling.interval }
    private var task: Task<Void, Never>?
    private var historyVisible = false
    private var pendingHistory = false
    private var historyFetchedAt: Date?
    func showHistory(_ visible: Bool) {
        historyVisible = visible
        guard visible else { return }
        if refreshing { pendingHistory = true } else { refresh() }
    }
    private let cloud: DeyeCloud
    @Published private(set) var needsSignIn = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloud = DeyeCloud(file: PrivateJSONFile.appFile("Deye/session.json"), importFile: PrivateJSONFile.importFile("deye"))
        pinned = defaults.bool(forKey: "deye.showPower")
        if let data = defaults.data(forKey: "deye.lastReading") { reading = try? JSONDecoder().decode(DeyeReading.self, from: data) }
    }
    var readout: String? { pinned ? DeyeReading.power(reading?.power_w) : nil }
    var status: String {
        if let problem { return problem }
        if refreshing { return "Refreshing…" }
        guard let reading else { return "No readings" }
        return reading.status + " · " + (reading.date.map { ReadingAge.label($0) } ?? "Time unknown")
    }
    func start() { refresh() }
    func stop() { task?.cancel(); task = nil }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let previous = reading
        let includeHistory = historyVisible && HistoryPolling.due(since: historyFetchedAt, calendar: TuyaHistory.calendar)
        if includeHistory { historyFetchedAt = Date() } // Also throttle unsuccessful attempts.
        task = Task { [weak self, cloud] in
            do {
                let result = try await cloud.snapshot(previous: previous, includeHistory: includeHistory)
                guard let self, !Task.isCancelled else { return }
                self.reading = result
                if includeHistory { self.historyFetchedAt = Date() }
                self.problem = nil
                self.needsSignIn = false
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: "deye.lastReading") }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.needsSignIn = (error as? DeyeError)?.needsSignIn ?? false
                self.problem = (error as? DeyeError)?.errorDescription ?? "Could not read Deye; showing saved readings."
            }
            self?.refreshing = false
            self?.task = nil
            if let self, self.pendingHistory {
                self.pendingHistory = false
                if self.historyVisible && !includeHistory { self.refresh() }
            }
        }
    }
    func signIn(email: String, password: String, server: String) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        do {
            try await cloud.signIn(email: email, password: password, base: server)
            reading = nil
            historyFetchedAt = nil
            defaults.removeObject(forKey: "deye.lastReading")
            problem = nil
            needsSignIn = false
            refreshing = false
            refresh()
            return true
        } catch {
            problem = (error as? DeyeError)?.errorDescription ?? "Could not sign in to Deye."
            refreshing = false
            return false
        }
    }
}
