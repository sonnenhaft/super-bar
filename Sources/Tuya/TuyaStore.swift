import AppKit
import Combine

@MainActor final class TuyaStore: ObservableObject {
    @Published private(set) var reading: TuyaSnapshot?
    @Published private(set) var refreshing = false
    @Published private(set) var problem: String?
    @Published private(set) var needsSignIn = false
    @Published var selectedID: String?
    @Published var email = ""
    @Published private(set) var pinnedID: String?
    @Published var samples: [PowerPoint] = []
    @Published private(set) var history: TuyaHistory?
    @Published private(set) var historyProblem: String?
    @Published private(set) var historyRefreshing = false
    private let cloud: TuyaCloud
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
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
    func pin(_ id: String) { pinnedID = id; defaults.set(id, forKey: "tuya.pinnedDevice"); BarSelection.shared.pin(.tuya) }
    init(defaults: UserDefaults = .standard, cloud: TuyaCloud = TuyaCloud()) {
        self.defaults = defaults; self.cloud = cloud
        pinnedID = defaults.string(forKey: "tuya.pinnedDevice")
        if let data = defaults.data(forKey: "tuya.readings") { reading = try? JSONDecoder().decode(TuyaSnapshot.self, from: data) }
        selectedID = reading?.meterID
        if let data = defaults.data(forKey: "tuya.history") { history = try? JSONDecoder().decode(TuyaHistory.self, from: data) }
    }
    func start() { refresh(); Task { email = await cloud.savedEmail() } }
    func stop() { task?.cancel(); historyTask?.cancel() }
    func showHistory(_ visible: Bool) {
        historyVisible = visible
        if visible { refreshHistory() }
    }
    private func refreshHistory() {
        guard historyVisible, !historyRefreshing, let meter = reading?.meter else { return }
        let now = Date()
        let changed = historyAttemptMeterID != meter.id
        guard changed || HistoryPolling.due(since: historyAttemptAt, now: now, calendar: TuyaHistory.calendar) else { return }
        historyAttemptAt = now
        historyAttemptMeterID = meter.id
        historyRefreshing = true
        let previous = chartHistory
        historyTask = Task {
            defer { historyRefreshing = false }
            do {
                let result = try await cloud.history(for: meter, previous: previous)
                guard !Task.isCancelled, reading?.meterID == result.meterID else { return }
                history = result; historyProblem = result.problem
                if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "tuya.history") }
            } catch {
                guard !Task.isCancelled else { return }
                historyProblem = (error as? TuyaError)?.errorDescription ?? "Could not read Tuya history."
            }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        task = Task {
            do {
                let result = try await cloud.snapshot()
                guard !Task.isCancelled else { return }
                reading = result; problem = nil; needsSignIn = false
                if selectedID == nil { selectedID = result.meterID ?? devices.first?.id }
                if let watts = result.consumption() { samples.append(PowerPoint(time: result.fetchedAt, watts: watts)); samples.removeAll { $0.time < Date().addingTimeInterval(-86400) } }
                if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "tuya.readings") }
                refreshHistory()
            } catch {
                guard !Task.isCancelled else { return }
                problem = (error as? TuyaError)?.errorDescription ?? "Could not read Tuya."
                if let error = error as? TuyaError { switch error { case .signIn, .expired: needsSignIn = true; default: break } }
            }
            refreshing = false
        }
    }
    func signIn(password: String) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        do {
            historyTask?.cancel()
            try await cloud.signIn(email: email, password: password)
            history = nil; historyAttemptAt = nil; historyProblem = nil
            defaults.removeObject(forKey: "tuya.history")
            needsSignIn = false; problem = nil; refreshing = false; refresh(); return true
        }
        catch { problem = (error as? TuyaError)?.errorDescription ?? "Could not sign in to Smart Life."; refreshing = false; return false }
    }
    func useAsMeter(_ id: String) {
        Task {
            do {
                try await cloud.selectMeter(id); reading?.meterID = id; samples = []
                history = nil; historyAttemptAt = nil; historyProblem = nil
                defaults.removeObject(forKey: "tuya.history")
                refreshHistory()
            }
            catch { problem = "Could not save the meter selection." }
        }
    }
}
