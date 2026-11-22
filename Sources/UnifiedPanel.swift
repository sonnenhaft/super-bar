import SwiftUI

@MainActor final class BatteryPanelState: ObservableObject {
    let model: BlueBarDelegate
    @Published var revision = 0
    init(_ model: BlueBarDelegate) { self.model = model }
    func refresh() { revision &+= 1 }
}

struct UnifiedPanel: View {
    @ObservedObject var selection: BarSelection
    @ObservedObject var tcl: ClimateStore
    @ObservedObject var history: EnergyHistory
    @ObservedObject var fields: ReadoutPreferences
    @ObservedObject var lg: LGStore
    @ObservedObject var batteries: BatteryPanelState
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    var availableHeight: CGFloat = 720
    var contentHeight: (CGFloat) -> Void
    let settings: NSView
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false
    @State private var measuredHeight: CGFloat = 0
    @State private var refreshRequestedByUser = false
    @State private var waitingForCloudReadings = false
    private var climate: ClimatePanel { ClimatePanel(store: tcl, history: history, preferences: fields, selection: selection) }
    private var thinQ: LGPanel { LGPanel(model: lg, selection: selection) }
    private var blue: BlueBarDelegate { batteries.model }
    private var energyExpanded: Bool { selection.openBrand == .deye || selection.openBrand == .tuya }
    var body: some View {
        ScrollView(.vertical) {
            PanelScreen(deye: deye, tuya: tuya, climateExpanded: activeClimate != nil,
                        televisionExpanded: selection.showTelevision,
                        batteryExpanded: selection.openBrand == .bluetti, energyExpanded: energyExpanded,
                        settingsExpanded: selection.showSettings,
                        canExpandClimate: climateDevices.contains { $0.online != false }, batterySummary: batterySummary,
                        refreshing: manualRefreshActive, toggleSection: toggleSection,
                        openEnergy: selection.showEnergy, refresh: refreshAllReadings, quit: { NSApp.terminate(nil) }) {
                EmptyView()
            } climate: {
                ClimateDeviceList(devices: climateDevices, selected: activeClimate, select: selectClimate) { id in
                    switch id {
                    case .tcl: climate; charts
                    case .lg: thinQ; charts
                    }
                }
                if tcl.needsSignIn && activeClimate == nil { climate }
                if lg.devices.isEmpty && lg.televisions.isEmpty && !lg.polling { thinQ }
            } television: {
                LGTelevisionPanel(accounts: lg.televisions, expanded: selection.showTelevision,
                                  open: selection.openTelevision)
            } battery: {
                batteryControls
                if selection.openBrand == .bluetti && selectedStation != nil { charts }
            } energy: {
                PanelEnergySection(deye: deye, tuya: tuya, expanded: energyExpanded, menuBarPinned: deye.pinned) { _ in
                    deye.pinned.toggle()
                    selection.showEnergy()
                }
            } settings: {
                PanelSettings(deye: deye, tuya: tuya, tcl: tcl,
                              connectLG: lg.configureMobileAccount, disconnectLG: lg.logout, refresh: refreshAccounts) {
                    PanelControl(control: settings).id(selection.chartBrand)
                        .frame(height: selection.chartBrand == .lg ? SuperFooter.height : SuperFooter.height - 36)
                }
            } accessory: {
                PanelTrafficReadout()
            }
            .reportContentHeight { height in
                measuredHeight = height
                contentHeight(min(height, availableHeight))
            }
        }
        .scrollDisabled(measuredHeight <= availableHeight)
        .scrollIndicators(measuredHeight > availableHeight ? .automatic : .hidden)
        .frame(width: PanelLayout.width)
        .transaction { $0.animation = nil }
        .onChange(of: refreshRequestedByUser && !manualRefreshActive) { _, finished in
            if finished { refreshRequestedByUser = false }
        }
        .onChange(of: selection.expanded) { _, _ in updateBatteries() }
        .onChange(of: selection.detailsCollapsed) { _, _ in updateBatteries() }
        .onAppear {
            deye.showHistory(true)
            tuya.showHistory(true)
        }
    }
    private func toggleSection(_ section: PanelSection) {
        switch section {
        case .climate: toggleClimate()
        case .television:
            if selection.showTelevision { selection.collapseSections() } else { selection.openTelevision() }
        case .battery: selection.select(.bluetti, sameDevice: true)
        case .energy:
            selection.toggleEnergy()
            if selection.openBrand == .deye { deye.pinned = true }
        case .settings:
            if selection.showSettings { selection.collapseSections() }
            else { selection.openSettings() }
        case .home: selection.collapseSections()
        }
    }
    private func refreshAccounts() {
        tcl.manualRefresh(); lg.manualRefresh(); deye.refresh(); tuya.refresh()
    }
    private var manualRefreshActive: Bool {
        refreshRequestedByUser && (waitingForCloudReadings
            || lg.polling || lg.sending || lg.summaryTask != nil || blue.isManuallyRefreshing)
    }
    private func refreshAllReadings() {
        guard !manualRefreshActive else { return }
        refreshRequestedByUser = true
        waitingForCloudReadings = true
        lg.manualRefresh(allDevices: true)
        if blue.bluetoothActivated { blue.refreshClicked() }
        Task {
            async let climate: Void = tcl.refreshAndWait()
            async let solar: Void = deye.manualRefreshAndWait()
            async let meter: Void = tuya.manualRefreshAndWait()
            _ = await (climate, solar, meter)
            waitingForCloudReadings = false
            if !manualRefreshActive { refreshRequestedByUser = false }
        }
    }
    private var activeClimate: ClimateDeviceID? {
        guard let selectedClimate = selection.climateDevice,
              climateDevices.contains(where: { $0.id == selectedClimate && $0.online != false }) else { return nil }
        switch selectedClimate {
        case .tcl(let id): return selection.openBrand == .tcl && tcl.selected?.id == id ? selectedClimate : nil
        case .lg(let id): return selection.openBrand == .lg && lg.selected == id ? selectedClimate : nil
        }
    }
    private var climateDevices: [ClimateDeviceItem] {
        let pinnedTCL = selection.current == .tcl ? fields.device(in: tcl)?.id : nil
        return tcl.devices.map { ac in
            ClimateDeviceItem(id: .tcl(ac.id), name: ac.name, room: tempText(ac.indoor),
                target: ac.power == true ? tempText(ac.target) : "",
                power: ac.online == true && !ac.failed && !tcl.offline ? ac.power : nil,
                online: ac.online, indicators: tcl.reportedIndicators(for: ac.id),
                pinnedInMenuBar: pinnedTCL == ac.id)
        } + lg.devices.map { device in
            let sample = lg.sample(for: device.id)
            return ClimateDeviceItem(id: .lg(device.id), name: device.name, room: sample?.roomReading ?? "—",
                target: sample?.power == "POWER_ON" ? degree(sample?.target) : "",
                power: sample?.powerOn, online: sample?.online, indicators: sample?.indicators ?? ClimateIndicators(),
                pinnedInMenuBar: selection.current == .lg && lg.pinnedDeviceID == device.id)
        }
    }
    private func selectClimate(_ id: ClimateDeviceID) {
        guard climateDevices.contains(where: { $0.id == id && $0.online != false }) else { return }
        if activeClimate == id {
            selection.climateDevice = nil
            selection.detailsCollapsed = true
            return
        }
        selection.climateDevice = id
        switch id {
        case .tcl(let rawID):
            guard let ac = tcl.devices.first(where: { $0.id == rawID }) else { return }
            tcl.select(ac)
            selection.activate(.tcl)
        case .lg(let rawID):
            lg.selectDevice(rawID)
            selection.activate(.lg)
        }
    }
    private func toggleClimate() {
        if activeClimate != nil {
            selection.detailsCollapsed = true
        } else {
            let available = climateDevices.filter { $0.online != false }
            let previous = available.first { $0.id == selection.climateDevice }
            if let device = previous ?? available.first { selectClimate(device.id) }
        }
    }
    private var visibleStations: [StationMenuEntry] {
        blue.stationRows.filter {
            DeviceVisibility.includesBattery(hasReading: $0.details.card.hasReading,
                                             online: blue.stationReachability($0.key), showOffline: showOffline)
        }
    }
    private var selectedStation: StationMenuEntry? {
        visibleStations.first { $0.key == blue.displayedStationKey }
    }
    private var batterySummary: String {
        guard let card = selectedStation?.details.card else { return "" }
        return card.summaryName + " · " + card.summaryPercent
    }
    private func updateBatteries() { blue.rebuildStationMenu(); batteries.refresh() }
    private var batteryControls: some View {
        let stations = visibleStations
        return BatteryDeviceList(stations: stations.map { entry in
            BatteryStationItem(id: entry.key, name: entry.details.card.summaryName,
                               percent: entry.details.card.summaryReadingPercent,
                               selected: selection.openBrand == .bluetti && entry.key == blue.displayedStationKey)
        }, needsPermission: blue.needsBluetoothPermission,
           emptyMessage: blue.bluetoothMessage ?? "Searching for BLUETTI stations…",
           error: blue.lastManualRefreshError,
           requestPermission: { blue.activateBluetooth(); batteries.refresh() },
           select: { key in stations.first { $0.key == key }?.details.card.selectSummary() }) {
            if selection.openBrand == .bluetti, let entry = selectedStation {
                let station = blue.stationDirectory.stations.first { $0.key == entry.key }
                entry.details.card.detailView(alias: station?.alias ?? "", saveName: { alias in
                    guard let station, !blue.quitting else { return }
                    blue.stationDirectory.setAlias(alias, deviceID: station.deviceID,
                                                   bluetoothName: station.bluetoothName, model: station.model)
                    blue.render()
                }).deviceSurface(selected: true)
            }
        }
    }
    private var charts: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch selection.chartBrand {
            case .tcl: climate.charts
            case .lg: thinQ.charts
            case .deye, .tuya: EmptyView()
            case .bluetti:
                if let key = blue.displayedStationKey {
                    StationOutputCharts(history: blue.outputHistory, station: key)
                }
            }
        }.panelHistorySurface()
    }
}

struct PanelControl: NSViewRepresentable {
    let control: NSView
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: control.bounds)
        control.frame.origin = .zero
        control.autoresizingMask = [.width, .height]
        container.addSubview(control)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if control.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            nsView.addSubview(control)
        }
        control.frame = nsView.bounds
        (control as? SuperFooter)?.sync()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 374, height: proposal.height ?? control.frame.height)
    }
}
