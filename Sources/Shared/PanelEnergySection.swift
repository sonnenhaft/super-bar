import SwiftUI

/// The two application shells supply navigation and optional menu-bar pinning.
/// Tiles, account entry points, meter selection and history have one layout.
struct PanelEnergySection: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    var expanded: Bool
    var highlightedMetric: String? = nil
    var menuBarPinned: Bool? = nil
    var showsDetails = true
    let select: (String) -> Void
    @ObservedObject private var age = ReadingAge.shared
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false
    @State private var signInProvider: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                powerChoice("solar", title: "Generation",
                            value: DeyeReading.power(deye.reading?.currentPower() ?? 0),
                            icon: .generation(watts: deye.reading?.currentPower()))
                powerChoice("load", title: "Consumption",
                            value: DisplayUnits.power(tuya.reading?.consumption() ?? 0), icon: .consumption)
            }
            if let reading = tuya.reading, let meter = reading.meter {
                let current = reading.gridVoltage()
                let last = meter.voltage.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                HStack(spacing: 5) {
                    Label("Grid voltage", systemImage: "waveform.path")
                    Spacer(minLength: 4)
                    if current == nil, last != nil {
                        Image(systemName: "clock").accessibilityLabel("Last known reading")
                    }
                    Text((current ?? last).map(DisplayUnits.voltage) ?? "— V")
                        .fontWeight(.semibold).monospacedDigit()
                }.font(.caption).foregroundStyle(current == nil ? .secondary : SuperBarPanelStyle.cyan)
                    .accessibilityElement(children: .combine)
                    .help(current == nil ? "Last known grid voltage; waiting for a current reading" : meter.name)
            }
            if deye.needsSignIn || tuya.needsSignIn {
                VStack(alignment: .leading, spacing: 6) {
                    if deye.needsSignIn { signInButton("Deye Cloud") }
                    if tuya.needsSignIn { signInButton("Smart Life") }
                }
            }
            if signInProvider == "Deye Cloud", deye.needsSignIn {
                DeyeSignIn(model: deye) { signInProvider = nil }
            } else if signInProvider == "Smart Life", tuya.needsSignIn {
                CloudLoginForm(draft: tuya.loginDraft, provider: "Smart Life", unavailable: tuya.refreshing) { email, password, _ in
                    tuya.email = email
                    if await tuya.signIn(password: password) { signInProvider = nil; return nil }
                    return tuya.problem ?? "Smart Life is busy. Try again shortly."
                }.padding(.vertical, 6)
            }
            if expanded && showsDetails {
                meterSelection
                EnergyDetails(deye: deye, tuya: tuya).panelHistorySurface()
                if let problem = deye.problem {
                    Text("Deye · " + problem).font(.caption).foregroundStyle(.secondary)
                }
                if let problem = tuya.problem {
                    Text("Smart Life · " + problem).font(.caption).foregroundStyle(.secondary)
                }
                if deye.refreshing || tuya.refreshing { ProgressView("Refreshing energy…") }
            }
        }
    }

    private func powerChoice(_ component: String, title: String, value: String, icon: EnergyTileIcon) -> some View {
        let selected = menuBarPinned ?? (expanded && (highlightedMetric == nil || highlightedMetric == component))
        return Button { select(component) } label: {
            PanelEnergyTile(title: title, value: value, icon: icon, selected: selected)
                .contentShape(Rectangle())
        }.panelButtonStyle()
            .help(menuBarPinned.map { ($0 ? "Hide" : "Show") + " net power in menu bar" } ?? "Show " + title.lowercased())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(menuBarPinned.map { $0 ? "Visible in menu bar" : "Hidden from menu bar" } ?? value)
    }

    private func signInButton(_ provider: String) -> some View {
        Button { signInProvider = signInProvider == provider ? nil : provider } label: {
            HStack {
                Text("Sign in to " + provider).font(.system(size: 12))
                Spacer()
                Image(systemName: signInProvider == provider ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.panelButtonStyle()
    }

    @ViewBuilder private var meterSelection: some View {
        let meters = tuya.devices.filter { DeviceVisibility.includes(online: $0.online, showOffline: showOffline) }
        if !meters.isEmpty {
            let selectedID = meters.first { $0.id == tuya.reading?.meterID }?.id ?? ""
            VStack(alignment: .leading, spacing: 4) {
                Text("Main consumption meter").font(.system(size: 13, weight: .semibold))
                Picker("Meter", selection: Binding(get: { selectedID }, set: { tuya.useAsMeter($0) })) {
                    Text("Select a meter").tag("")
                    ForEach(meters) { device in
                        Text(device.online == false ? device.name + " · Offline" : device.name)
                            .tag(device.id).disabled(device.online == false)
                    }
                }.disabled(tuya.refreshing).panelPointer()
            }.padding(.vertical, 6)
        }
    }
}

struct DeyeSignIn: View {
    @ObservedObject var model: DeyeStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deye Cloud").font(.headline)
            CloudLoginForm(draft: model.loginDraft, provider: "Deye", unavailable: model.refreshing, hasServer: true) { email, password, server in
                if await model.signIn(email: email, password: password, server: server) { close(); return nil }
                return model.problem ?? "Deye is busy. Try again shortly."
            }
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared settings keep account, visibility and tariff behavior identical.
/// Only application-specific controls are supplied by the platform shell.
struct PanelSettings<Footer: View>: View {
    let deye: DeyeStore
    let tuya: TuyaStore
    let tcl: ClimateStore
    let connectLG: (String, String, String) async throws -> Void
    let disconnectLG: () -> Void
    let refresh: () -> Void
    var visibilityChanged: () -> Void = {}
    @ViewBuilder var footer: () -> Footer
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false

    var body: some View {
        VStack(alignment: .leading, spacing: SuperBarPanelStyle.gap) {
            Toggle("Show offline devices", isOn: $showOffline).panelPointer()
                .onChange(of: showOffline) { _, _ in visibilityChanged() }
            Divider()
            AccountConnections(deye: deye, tuya: tuya, tcl: tcl,
                               connectLG: connectLG, disconnectLG: disconnectLG, refresh: refresh)
            Divider()
            EnergyTariffSettings()
            Divider()
            PanelRefreshSettings()
            Divider()
            footer()
        }
    }
}

struct PanelRefreshSettings: View {
    @ObservedObject private var preferences = RefreshPreferences.shared
    @AppStorage("settings.refreshProvider") private var scope = "All"
    private var providers: [RefreshProvider] {
        RefreshProvider.allCases.filter { scope == "All" || $0.rawValue == scope }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refresh & traffic").font(.headline)
            Picker("Brand", selection: $scope) {
                Text("All").tag("All")
                ForEach(RefreshProvider.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }.panelPointer()
            TimelineView(.periodic(from: CloudTraffic.boundary(.now), by: 60)) { _ in
                let traffic = CloudTraffic.shared.snapshot(at: .now)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(providers, id: \.rawValue) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(provider.rawValue).fontWeight(.semibold)
                                Spacer(minLength: 6)
                                trafficLabel(provider, snapshot: traffic)
                            }
                            HStack(spacing: 8) {
                                Slider(value: Binding(get: {
                                    Double(provider.choices.firstIndex(of: RefreshPreferences.seconds(provider)) ?? 0)
                                }, set: { value in
                                    let index = Int(value.rounded())
                                    guard provider.choices.indices.contains(index) else { return }
                                    preferences.set(provider, seconds: provider.choices[index])
                                }), in: 0...Double(provider.choices.count - 1), step: 1)
                                    .accessibilityLabel(provider.rawValue + " refresh interval")
                                    .accessibilityValue(RefreshProvider.label(RefreshPreferences.seconds(provider)))
                                Text(RefreshProvider.label(RefreshPreferences.seconds(provider)))
                                    .monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    let other = traffic.forProvider(.other)
                    if scope == "All", other.total.incoming > 0 || other.total.outgoing > 0 {
                        HStack {
                            Text("Other")
                            Spacer(minLength: 6)
                            Text("↓ \(other.averageIncomingLabel)  ↑ \(other.averageOutgoingLabel)").monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text(traffic.coveredSeconds > 0 ? "Minute averages · " + traffic.windowLabel : "Collecting first minute…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.font(.system(size: 12))
            .onAppear { if scope != "All" && RefreshProvider(rawValue: scope) == nil { scope = "All" } }
    }
    @ViewBuilder private func trafficLabel(_ provider: RefreshProvider, snapshot: CloudTraffic.Snapshot) -> some View {
        if let brand = CloudTraffic.Provider(rawValue: provider.rawValue.lowercased()) {
            let traffic = snapshot.forProvider(brand)
            Text(traffic.coveredSeconds > 0
                 ? "↓ \(traffic.averageIncomingLabel)  ↑ \(traffic.averageOutgoingLabel)"
                 : "Collecting first minute…")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityLabel(provider.rawValue + ". " + traffic.minuteLabel)
                .help(traffic.detail)
        } else {
            Text("Bluetooth · no internet traffic").font(.caption).foregroundStyle(.secondary)
        }
    }
}
