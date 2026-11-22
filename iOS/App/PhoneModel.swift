import SwiftUI
import WidgetKit
import Combine
import BackgroundTasks
import UIKit

typealias PhoneSection = PanelSection

@MainActor final class PhoneModel: ObservableObject {
    let deye: DeyeStore
    let tuya: TuyaStore
    let tcl: ClimateStore
    let lg: PhoneLG
    let bluetooth: PhoneBluetooth
    let televisions = LGTelevisionStore()
    @Published var section: PhoneSection = .home
    @Published var selectedClimate: ClimateDeviceID?
    @Published var selectedEnergy: WidgetRoute.EnergyComponent?
    @Published private(set) var widgetNavigationID: UUID?
    @Published private(set) var widgetRoute: WidgetRoute?
    @Published var widgetProblem: String?
    @Published private(set) var manuallyRefreshing = false
    @Published private(set) var manualWidgetSaveDate: Date?
    private var manualRefreshTask: Task<Void, Never>?
    private var widgetReloadTask: Task<Void, Never>?
    private var lastWidgetReload: Date?
    private var bluetoothCheckedAt: Date?
    private var sceneActive = false
    private var foregroundPolls = 0
    private var widgetBackgroundRefresh: Task<Void, Never>?
    private var widgetBackgroundLease: UIBackgroundTaskIdentifier = .invalid
    private var widgetBackgroundGeneration = UUID()
    private var climateBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var climateBackgroundGeneration = UUID()
    private var climateBackgroundExpired = false
    private var subscriptions = Set<AnyCancellable>()
    init() {
        _ = CloudTraffic.shared
        deye = DeyeStore()
        tuya = TuyaStore()
        tcl = ClimateStore()
        lg = PhoneLG()
        bluetooth = PhoneBluetooth()
        deye.$reading.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        tuya.$reading.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        tuya.$history.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        EnergyPricing.shared.$tariff.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        lg.changed = { [weak self] in self?.climateChanged() }
        bluetooth.changed = { [weak self] in
            if self?.sceneActive == true { self?.bluetoothCheckedAt = Date() }
            self?.saveWidgets()
        }
        tcl.$reportedRevision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.climateChanged() }.store(in: &subscriptions)
        tcl.$command.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.maintainClimateBackgroundTask() }.store(in: &subscriptions)
        lg.$busy.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.maintainClimateBackgroundTask() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .init("SuperBarWidgetClimateChanged"))
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let self else { return }
                if notification.userInfo?["brand"] as? String == "TCL" { self.tcl.refresh() }
                else { Task { await self.lg.refresh() } }
            }.store(in: &subscriptions)
        // The home-screen widget needs the rolling bill even if Energy is never opened.
        deye.showHistory(true)
        tuya.showHistory(true)
    }
    func refresh(waitForHistory: Bool = false) async {
        async let television: Void = televisions.refreshWidgetReadings()
        async let aircon: Void = tcl.refreshAndWait()
        async let solar: Void = deye.refreshAndWait(waitForHistory: waitForHistory)
        async let meter: Void = tuya.refreshAndWait(waitForHistory: waitForHistory)
        async let climate: Void = lg.refreshAndWait()
        _ = await (aircon, solar, meter, climate, television)
        televisions.publishWidgetReadings(lg.televisions)
        publishWidgets(forceReload: true)
    }
    func pollWhileActive() async {
        foregroundPolls += 1
        defer { foregroundPolls -= 1 }
        // Each brand owns one loop. A slow provider cannot delay another brand,
        // and foreground cancellation stops the loops together.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.televisions.refreshWidgetReadings()
                    guard !Task.isCancelled else { return }
                    self.televisions.publishWidgetReadings(self.lg.televisions)
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                }
            }

            for provider in [RefreshProvider.tcl, .lg, .deye, .tuya] {
                group.addTask { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        let started = ProcessInfo.processInfo.systemUptime
                        switch provider {
                        case .tcl: await self.tcl.refreshAndWait()
                        case .lg: await self.lg.refreshAndWait()
                        case .deye: await self.deye.refreshAndWait()
                        case .tuya: await self.tuya.refreshAndWait()
                        case .bluetti: break
                        }
                        do {
                            try await RefreshPreferences.wait(provider, since: started)
                            // Always yield after a slow or failed request.
                            try await Task.sleep(nanoseconds: 100_000_000)
                        } catch { return }
                    }
                }
            }
        }
    }
    func manualRefresh() async {
        if let manualRefreshTask {
            await manualRefreshTask.value
            return
        }
        manuallyRefreshing = true
        let task = Task {
            async let aircon: Void = tcl.refreshAndWait()
            async let climate: Void = lg.refreshAndWait()
            async let solar: Void = deye.manualRefreshAndWait()
            async let meter: Void = tuya.manualRefreshAndWait()
            async let batteries: Void = bluetooth.refreshNow()
            _ = await (aircon, climate, solar, meter, batteries)
            saveWidgets()
            manualWidgetSaveDate = widgetProblem == nil ? Date() : nil
            manuallyRefreshing = false
            manualRefreshTask = nil
        }
        manualRefreshTask = task
        await task.value
    }
    func saveWidgets() { publishWidgets(forceReload: false) }

    private func climateChanged() {
        selectRequestedClimate()
        saveWidgets()
        maintainClimateBackgroundTask()
    }
    private func publishWidgets(forceReload: Bool) {
        let now = Date()
        do {
            var changedPresentation = false
            try WidgetCache.update { snapshot in
                let previous = snapshot
                snapshot = makeWidgetSnapshot(previous: previous)
                changedPresentation = !snapshot.hasSamePresentation(as: previous, at: now)
            }
            if forceReload || changedPresentation || (lastWidgetReload.map { now.timeIntervalSince($0) >= 240 } ?? true) {
                requestWidgetReload(immediate: forceReload)
            }
            widgetProblem = nil
        } catch { widgetProblem = "Could not save readings for the widget." }
    }

    private func makeWidgetSnapshot(previous: WidgetSnapshot) -> WidgetSnapshot {
        // Cached TCL hydration emits statusDate before its first network check.
        // Keep the extension's checked controls until that check succeeds/fails.
        let tclMetrics = tcl.offline && tcl.problem == nil && previous.climate.contains(where: { $0.brand == "TCL" })
            ? previous.climate.filter { $0.brand == "TCL" }
            : tcl.devices.compactMap { tcl.reportedDevice(id: $0.id) }
                .map { $0.widgetMetric(checkedAt: tcl.reportedDate(id: $0.id), available: !tcl.offline) }
        func savedClimate(_ brand: String) -> [WidgetMetric] {
            previous.climate.filter { $0.brand == brand }.map {
                var saved = $0
                saved.online = false
                saved.control = nil
                return saved
            }
        }
        let lgMetrics = lg.mayRestoreWidgetList
            ? (lg.problem == nil ? previous.climate.filter { $0.brand == "LG" } : savedClimate("LG"))
            : lg.devices.map { device in
                if device.checked == nil, device.problem == nil,
                   let saved = previous.climate.first(where: { $0.brand == "LG" && $0.id == device.id }) { return saved }
                return device.widgetMetric
            }
        let tclReadings = !tcl.didRead && tcl.problem != nil ? savedClimate("TCL") : tclMetrics
        let climate = ((AccountConnection.signedOut("tcl") ? [] : tclReadings)
            + (AccountConnection.signedOut("lg") ? [] : lgMetrics)).map { metric in
            // An unrelated energy refresh must not overwrite a newer, confirmed
            // widget command with the foreground model's previous reading.
            let old = previous.climate.first { $0.brand == metric.brand && $0.id == metric.id }
            if let checked = metric.control?.checkedAt, let old, let newer = old.control?.checkedAt, newer > checked { return old }
            return metric.retainingReading(from: old)
        }
        let energy = energyMetrics.map { metric in
            let old = previous.energy.first { $0.id == metric.id && metric.sourceID != nil && $0.sourceID == metric.sourceID }
            return metric.retainingReading(from: old)
        }
        return WidgetSnapshot(energy: energy, climate: climate, batteries: bluetooth.widgetMetrics,
            showOfflineDevices: UserDefaults.standard.bool(forKey: DeviceVisibility.showOfflineKey),
            bluetoothCheckedAt: bluetoothCheckedAt ?? previous.bluetoothCheckedAt, televisions: previous.televisions)
    }
    private func requestWidgetReload(immediate: Bool) {
        if immediate {
            widgetReloadTask?.cancel(); widgetReloadTask = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "SuperBar.home")
            lastWidgetReload = Date()
        } else if widgetReloadTask == nil {
            widgetReloadTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                WidgetCenter.shared.reloadTimelines(ofKind: "SuperBar.home")
                self.lastWidgetReload = Date()
                self.widgetReloadTask = nil
            }
        }
    }
    func sceneChanged(active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        if active {
            stopWidgetBackgroundRefresh()
            climateBackgroundExpired = false
            endClimateBackgroundTask()
            // A cold foreground model is not yet authoritative. Reload the
            // existing shared snapshot until normal provider reads finish.
            requestWidgetReload(immediate: true)
        } else {
            maintainClimateBackgroundTask()
            publishWidgets(forceReload: true)
            startWidgetBackgroundRefresh()
        }
    }
    // One bounded read after leaving the app; this is not a background polling loop.
    private func startWidgetBackgroundRefresh() {
        guard widgetBackgroundRefresh == nil else { return }
        let generation = UUID()
        widgetBackgroundGeneration = generation
        widgetBackgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Update home widget") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.widgetBackgroundGeneration == generation else { return }
                self.publishWidgets(forceReload: true)
                self.stopWidgetBackgroundRefresh()
            }
        }
        guard widgetBackgroundLease != .invalid else { return }
        widgetBackgroundRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.widgetBackgroundGeneration == generation {
                    self.televisions.publishWidgetReadings(self.lg.televisions)
                    self.publishWidgets(forceReload: true)
                    self.widgetBackgroundRefresh = nil
                    self.endWidgetBackgroundLease()
                }
            }
            // Foreground cancellation must finish before joining provider reads,
            // otherwise the background refresh can join an already cancelled job.
            let waitUntil = ProcessInfo.processInfo.systemUptime + 1
            while self.foregroundPolls > 0, ProcessInfo.processInfo.systemUptime < waitUntil {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard !Task.isCancelled, !self.sceneActive else { return }
            await self.refresh()
        }
    }
    private func stopWidgetBackgroundRefresh() {
        widgetBackgroundGeneration = UUID()
        widgetBackgroundRefresh?.cancel()
        widgetBackgroundRefresh = nil
        endWidgetBackgroundLease()
    }
    private func endWidgetBackgroundLease() {
        guard widgetBackgroundLease != .invalid else { return }
        let lease = widgetBackgroundLease
        widgetBackgroundLease = .invalid
        UIApplication.shared.endBackgroundTask(lease)
    }
    private func maintainClimateBackgroundTask() {
        guard !sceneActive else { return }
        if tcl.hasPendingCommands || lg.hasPendingCommands {
            guard climateBackgroundTask == .invalid, !climateBackgroundExpired else { return }
            let generation = UUID()
            climateBackgroundGeneration = generation
            climateBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish climate widget sync") { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.climateBackgroundGeneration == generation else { return }
                    self.climateBackgroundExpired = true
                    self.publishWidgets(forceReload: true)
                    self.endClimateBackgroundTask()
                }
            }
        } else if climateBackgroundTask != .invalid {
            // Flush the final confirmed state before releasing execution time.
            publishWidgets(forceReload: true)
            endClimateBackgroundTask()
        }
    }
    private func endClimateBackgroundTask() {
        guard climateBackgroundTask != .invalid else { return }
        let task = climateBackgroundTask
        climateBackgroundTask = .invalid
        climateBackgroundGeneration = UUID()
        UIApplication.shared.endBackgroundTask(task)
    }
    private func selectRequestedClimate() {
        if case .tcl(let id)? = selectedClimate, let ac = tcl.devices.first(where: { $0.id == id }) {
            tcl.select(ac)
        }
    }
    private var energyMetrics: [WidgetMetric] {
        var metrics: [WidgetMetric] = []
        if let plant = deye.reading, !AccountConnection.signedOut("deye") {
            metrics.append(WidgetMetric(id: "solar", name: "Generation", value: DeyeReading.power(deye.reading?.power_w),
                      detail: deye.reading?.today_kwh.map { DisplayUnits.energy($0 * 1000) + " today" } ?? "No reading",
                      symbol: EnergyTileIcon.generation(watts: plant.power_w).rawValue, updatedAt: plant.date,
                      savedReading: plant.currentPower() == nil, sourceID: String(plant.id)))
        }
        let load = tuya.reading?.consumption()
        let meterID = tuya.reading?.meterID
        let measured = tuya.reading?.meter?.measuredAt ?? tuya.reading?.fetchedAt
        if meterID != nil, !AccountConnection.signedOut("tuya") {
            metrics.append(WidgetMetric(id: "load", name: "Consumption", value: load.map(DisplayUnits.power) ?? "—",
                      detail: tuya.reading?.meter?.name ?? "Select a main meter", symbol: "bolt.fill",
                      updatedAt: measured, sourceID: meterID))
            let voltage = tuya.reading?.gridVoltage()
            let lastVoltage = tuya.reading?.meter?.voltage.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            metrics.append(WidgetMetric(id: "voltage", name: "Grid voltage", value: (voltage ?? lastVoltage).map(DisplayUnits.voltage) ?? "—",
                      detail: "", symbol: "waveform.path", updatedAt: measured,
                      savedReading: voltage == nil, sourceID: meterID))
        }
        if let meterID, !AccountConnection.signedOut("tuya") {
            let tariff = EnergyPricing.shared.tariff
            let plant = AccountConnection.signedOut("deye") ? nil : deye.reading
            let pair = (plant.map { String($0.id) } ?? "no-solar") + ":" + meterID
            let date = plant?.currentPower() == nil ? measured : [measured, plant?.date].compactMap { $0 }.min()
            let net = DeyeReading.netForBilling(production: plant, load: load)
            metrics.append(WidgetMetric(id: "net", name: "Net power", value: net.map { ($0 > 0 ? "+" : "") + DisplayUnits.power($0) } ?? "—",
                detail: "", symbol: "bolt.fill", updatedAt: date, sourceID: pair))
            metrics.append(WidgetMetric(id: "cost-hour", name: "Net / hour", value: net.map { tariff.hourlyReadout(netWatts: $0) } ?? "—",
                detail: "", symbol: "pesosign", updatedAt: date, sourceID: pair))
            let bill = tariff.rollingBill(deye: deye, tuya: tuya)
            metrics.append(WidgetMetric(id: "cost-day", name: "Last 24h", value: bill.bill == nil ? "—" : bill.dailyReadout,
                detail: "", symbol: "pesosign", updatedAt: [tuya.chartHistory?.fetchedAt, tuya.samples.last?.time].compactMap { $0 }.max(), sourceID: pair))
        }
        return metrics
    }
    func open(_ url: URL) {
        guard let route = WidgetRoute(url: url), let section = PhoneSection(rawValue: route.section) else { return }
        switch route {
        case .climate(let id): selectedClimate = id
        case .battery(let id): if let id { bluetooth.select(id) }
        case .energy(let component): selectedEnergy = component
        default: break
        }
        self.section = section
        widgetRoute = route
        // A repeated tap must scroll again even if this section is already open.
        widgetNavigationID = UUID()
        selectRequestedClimate()
    }
    static let backgroundID = "com.sonnenhaft.superbar.refresh"
    func scheduleRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main struct SuperBarPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .preferredColorScheme(.dark)
                .tint(SuperBarPanelStyle.cyan)
                .onOpenURL { model.open($0) }
                .task(id: phase == .background) {
                    guard phase != .background else { return }
                    await model.pollWhileActive()
                }
                .onChange(of: phase, initial: true) { _, phase in
                    if phase == .active {
                        model.sceneChanged(active: true)
                        model.bluetooth.start()
                    } else if phase == .background {
                        model.bluetooth.stop()
                        model.tuya.saveSamples()
                        model.sceneChanged(active: false)
                        model.scheduleRefresh()
                    }
                }
        }
        .backgroundTask(.appRefresh(PhoneModel.backgroundID)) {
            await model.scheduleRefresh()
            await model.refresh()
        }
    }
}
