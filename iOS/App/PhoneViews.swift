import SwiftUI

extension View {
    func phoneCard() -> some View { superBarSurface(padding: 10) }
}

struct PhoneRoot: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject private var deye: DeyeStore
    @ObservedObject private var tuya: TuyaStore
    @ObservedObject private var tcl: ClimateStore
    @ObservedObject private var lg: PhoneLG
    @ObservedObject private var battery: PhoneBluetooth
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false
    @ObservedObject private var televisions: LGTelevisionStore
    @State private var completedWidgetScroll: UUID?
    private struct WidgetScroll: Hashable {
        let request: UUID?
        let ready: Bool
    }
    init(model: PhoneModel) {
        self.model = model; televisions = model.televisions; deye = model.deye; tuya = model.tuya; tcl = model.tcl; lg = model.lg; battery = model.bluetooth
    }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                PanelScreen(deye: deye, tuya: tuya, climateExpanded: model.section == .climate,
                            televisionExpanded: model.section == .television,
                            batteryExpanded: model.section == .battery, energyExpanded: model.section == .energy,
                            settingsExpanded: model.section == .settings, batterySummary: batterySummary,
                            highlightedEnergy: model.selectedEnergy?.rawValue, refreshing: model.manuallyRefreshing,
                            toggleSection: toggle, openEnergy: { model.section = .energy },
                            refresh: { Task { await model.manualRefresh() } }) {
                    KeychainAccessButton { Task { await model.refresh() } }
                } climate: {
                    wifiDeviceGrid
                    climatePanel
                    if model.section == .climate {
                        Button("Find or add TV") { model.section = .television }
                            .font(.caption).panelButtonStyle()
                    }
                } television: {
                    LGTelevisionPanel(accounts: lg.televisions, expanded: model.section == .television,
                                      open: { model.section = .television }, store: televisions, showSummaries: false)
                } battery: {
                    PhoneBatteryView(model: battery, expanded: model.section == .battery,
                                     open: { model.section = .battery }, close: { model.section = .home }, requestedID: requestedBattery)
                } energy: {
                    PanelEnergySection(deye: deye, tuya: tuya, expanded: model.section == .energy,
                                       highlightedMetric: model.selectedEnergy?.rawValue) { component in
                        model.selectedEnergy = WidgetRoute.EnergyComponent(rawValue: component)
                        model.section = .energy
                    }
                } settings: {
                    PhoneSettings(model: model)
                } accessory: {
                    PanelTrafficReadout()
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(SuperBarPanelStyle.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .font(.system(size: 13))
            .refreshable { await model.manualRefresh() }
            .onChange(of: model.section) { _, section in
                if section != .home { scroll.scrollTo(section, anchor: .top) }
            }
            .task(id: WidgetScroll(request: model.widgetNavigationID, ready: widgetTargetReady)) {
                guard let request = model.widgetNavigationID, completedWidgetScroll != request,
                      model.widgetRoute?.section == model.section.rawValue else { return }
                // Let the selected section enter the layout on a cold launch.
                await Task.yield()
                guard !Task.isCancelled else { return }
                scroll.scrollTo(model.section, anchor: .top)
                if widgetTargetReady { completedWidgetScroll = request }
            }
        }
    }
    private var climatePanel: PhoneClimateView {
        PhoneClimateView(tcl: tcl, lg: lg, expanded: model.section == .climate,
                         open: { model.section = .climate }, selected: $model.selectedClimate,
                         close: { model.section = .home }, requested: requestedClimate, showSummaries: false)
    }

    private var wifiDeviceGrid: some View {
        ClimateSummaryGrid {
            ForEach(climatePanel.devices.filter { DeviceVisibility.includes(online: $0.online, showOffline: showOffline) }) { device in
                Button { climatePanel.selectDevice(device.id) } label: {
                    ClimateSummaryCard(device: device, selected: model.section == .climate && model.selectedClimate == device.id)
                }.panelButtonStyle().offlineDevice(device.online == false)
            }
            ForEach(televisions.items(lg.televisions).filter { DeviceVisibility.includes(online: $0.online, showOffline: showOffline) || $0.canWake || $0.canPair }) { tv in
                Button {
                    if model.section == .television && televisions.selectedID == tv.id { model.section = .home }
                    else { televisions.select(tv.id); model.section = .television }
                } label: {
                    TelevisionSummary(tv: tv, selected: model.section == .television && televisions.selectedID == tv.id)
                }.panelButtonStyle()
            }
        }
    }

    private var requestedClimate: ClimateDeviceID? {
        guard case .climate(let id) = model.widgetRoute, model.section == .climate,
              id == model.selectedClimate else { return nil }
        return id
    }
    private var requestedBattery: String? {
        guard case .battery(let id) = model.widgetRoute, model.section == .battery,
              id == battery.selectedID else { return nil }
        return id
    }
    private var widgetTargetReady: Bool {
        guard let route = model.widgetRoute else { return false }
        let climateLoaded = (tcl.didRead || tcl.problem != nil || AccountConnection.signedOut("tcl"))
            && (!lg.mayRestoreWidgetList || lg.problem != nil || AccountConnection.signedOut("lg"))
        switch route {
        case .climate(.tcl(let id)): return tcl.devices.contains { $0.id == id } || tcl.didRead || tcl.problem != nil
        case .climate(.lg(let id)): return lg.devices.contains { $0.id == id } || !lg.mayRestoreWidgetList || lg.problem != nil
        case .climate(nil): return climateLoaded
        case .battery, .energy, .settings: return climateLoaded
        case .home, .television: return true
        }
    }
    private func toggle(_ section: PhoneSection) {
        if section == .climate && model.section == .television { model.section = .home; return }
        guard model.section != section else { model.section = .home; return }
        if section == .climate { selectClimateForHeading() }
        model.section = section
    }
    private func selectClimateForHeading() {
        let available = tcl.devices.filter { $0.online != false }.map { ClimateDeviceID.tcl($0.id) }
            + lg.devices.filter { $0.online != false }.map { ClimateDeviceID.lg($0.id) }
        if let selected = model.selectedClimate, available.contains(selected) {
            selectTCLIfNeeded(selected)
            return
        }
        // Closing/reopening the section while a widget target is still loading
        // must not replace that explicit device with the first received device.
        if case .climate(let requested) = model.widgetRoute,
           let requested, requested == model.selectedClimate {
            switch requested {
            case .tcl where !tcl.didRead && tcl.problem == nil: return
            case .lg where lg.mayRestoreWidgetList && lg.problem == nil: return
            default: break
            }
        }
        model.selectedClimate = available.first
        if let selected = model.selectedClimate { selectTCLIfNeeded(selected) }
    }
    private func selectTCLIfNeeded(_ selection: ClimateDeviceID) {
        if case .tcl(let id) = selection, let ac = tcl.devices.first(where: { $0.id == id }) {
            tcl.select(ac)
        }
    }
    private var batterySummary: String {
        let visible = battery.stations.filter { station in
            let id = station.deviceID ?? station.key
            return DeviceVisibility.includesBattery(hasReading: battery.readings.contains { $0.id == id },
                                                     online: battery.stationReachability(id), showOffline: showOffline)
        }
        let selected = battery.selectedID.flatMap { id in visible.first { ($0.deviceID ?? $0.key) == id } }
            ?? (battery.selectedID == nil ? visible.first : nil)
        guard let station = selected else { return "" }
        let id = station.deviceID ?? station.key
        let name = station.alias ?? battery.displayName(id: id, name: station.bluetoothName)
        let charge = battery.readings.first { $0.id == id }.map { "\($0.percent)%" } ?? "—"
        return name + " · " + charge
    }
}
