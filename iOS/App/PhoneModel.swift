import SwiftUI
import WidgetKit
import Combine
import BackgroundTasks

enum PhoneSection: String, CaseIterable {
    case home, energy, climate, battery, settings
    var title: String { rawValue.capitalized }
}

@MainActor final class PhoneModel: ObservableObject {
    let deye: DeyeStore
    let tuya: TuyaStore
    let tcl: ClimateStore
    let lg: PhoneLG
    let bluetooth: PhoneBluetooth
    @Published var section: PhoneSection = .home {
        didSet {
            deye.showHistory(section == .energy)
            tuya.showHistory(section == .energy)
        }
    }
    @Published var selectedClimate: ClimateDeviceID?
    @Published var widgetProblem: String?
    private var subscriptions = Set<AnyCancellable>()
    init() {
        #if DEBUG && targetEnvironment(simulator)
        PhoneSimulatorSessions.importLG()
        #endif
        deye = DeyeStore()
        tuya = TuyaStore()
        tcl = ClimateStore()
        lg = PhoneLG()
        bluetooth = PhoneBluetooth()
        deye.$reading.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        tuya.$reading.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        lg.changed = { [weak self] in self?.saveWidgets() }
        bluetooth.changed = { [weak self] in self?.saveWidgets() }
        tcl.$statusDate.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.saveWidgets() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .init("SuperBarWidgetClimateChanged"))
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let self else { return }
                if notification.userInfo?["brand"] as? String == "TCL" { self.tcl.refresh() }
                else { Task { await self.lg.refresh() } }
            }.store(in: &subscriptions)
    }
    func refresh() async {
        tcl.refresh()
        async let solar: Void = deye.refreshAndWait()
        async let meter: Void = tuya.refreshAndWait()
        async let climate: Void = lg.refresh()
        _ = await (solar, meter, climate)
    }
    func saveWidgets() {
        let previous = WidgetCache.read()
        // Cached TCL hydration emits statusDate before its first network check.
        // Keep the extension's checked controls until that check succeeds/fails.
        let tclMetrics = tcl.offline && tcl.problem == nil && previous.climate.contains(where: { $0.brand == "TCL" })
            ? previous.climate.filter { $0.brand == "TCL" }
            : tcl.devices.compactMap { tcl.reportedDevice(id: $0.id) }
                .map { $0.widgetMetric(checkedAt: tcl.statusDate, available: !tcl.offline) }
        let lgMetrics = lg.devices.isEmpty && lg.problem == nil
            ? previous.climate.filter { $0.brand == "LG" } : lg.widgetMetrics
        let climate = (tclMetrics + lgMetrics).map { metric in
            // An unrelated energy refresh must not overwrite a newer, confirmed
            // widget command with the foreground model's previous reading.
            guard let checked = metric.control?.checkedAt,
                  let newer = previous.climate.first(where: { $0.brand == metric.brand && $0.id == metric.id }),
                  let newerChecked = newer.control?.checkedAt, newerChecked > checked else { return metric }
            return newer
        }
        do {
            try WidgetCache.write(WidgetSnapshot(energy: energyMetrics,
                climate: climate, batteries: bluetooth.widgetMetrics))
            WidgetCenter.shared.reloadAllTimelines()
            widgetProblem = nil
        } catch { widgetProblem = "Widget sharing is unavailable. Check the App Group signing configuration." }
    }
    private var energyMetrics: [WidgetMetric] {
        [WidgetMetric(id: "solar", name: "Generation", value: DeyeReading.power(deye.reading?.power_w),
                      detail: deye.reading?.today_kwh.map { DisplayUnits.energy($0 * 1000) + " today" } ?? "No reading",
                      symbol: "sun.max.fill", updatedAt: deye.reading?.date),
         WidgetMetric(id: "load", name: "Consumption", value: tuya.reading?.consumption().map(DisplayUnits.power) ?? "—",
                      detail: tuya.reading?.meter?.name ?? "Select a main meter", symbol: "bolt.fill",
                      updatedAt: tuya.reading?.meter?.measuredAt)]
    }
    func open(_ url: URL) {
        guard url.scheme == "superbar", let host = url.host, let section = PhoneSection(rawValue: host) else { return }
        self.section = section
    }
    static let backgroundID = "com.sonnenhaft.superbar.refresh"
    func scheduleRefresh() {
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
                .task(id: phase) {
                    guard phase == .active else { return }
                    model.bluetooth.start()
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                    }
                }
                .onChange(of: phase) { _, phase in
                    if phase == .background {
                        model.bluetooth.stop()
                        model.saveWidgets()
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

#if DEBUG && targetEnvironment(simulator)
// Explicit local development import; never compiled into device or release builds.
private enum PhoneSimulatorSessions {
    private struct Credentials: Decodable {
        let token: String
        let country: String
        let region: String
    }

    static func importLG() {
        let file = PrivateJSONFile.appFile("simulator-lg-import.json")
        do {
            guard let snapshot = try PrivateJSONFile.snapshotIfPresent(from: file) else { return }
            let value = try JSONDecoder().decode(Credentials.self, from: snapshot.data)
            guard !value.token.isEmpty, value.country.count == 2,
                  ["kic", "eic", "aic"].contains(value.region) else { return }
            try TokenCredentialStore(key: "lg-token").save(value.token)
            defaults.set(value.country, forKey: "country")
            defaults.set(value.region, forKey: "region")
            try PrivateJSONFile.removeLegacy(at: file, matching: snapshot.identity)
        } catch {
            // Never include credential data or decoding errors in logs.
            NSLog("Super Bar: simulator LG import failed; use Settings to connect.")
        }
    }
}
#endif
