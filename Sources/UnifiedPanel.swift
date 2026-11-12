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
    @ObservedObject var lg: App
    @ObservedObject var batteries: BatteryPanelState
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    var availableHeight: CGFloat = 720
    var contentHeight: (CGFloat) -> Void
    let settings: NSView
    @State private var measuredHeight: CGFloat = 0
    @State private var showSettings = false
    private var climate: ClimatePanel { ClimatePanel(store: tcl, history: history, preferences: fields, selection: selection) }
    private var thinQ: LGPanel { LGPanel(model: lg, selection: selection) }
    private var solar: DeyeCard { DeyeCard(model: deye, tuya: tuya, selection: selection) }
    private var meter: TuyaPanel { TuyaPanel(model: tuya, selection: selection) }
    private var blue: BlueBarDelegate { batteries.model }
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Climate", summary: climateSummary, brand: climateBrand)
                climate
                if selection.openBrand == .tcl { charts }
                thinQ
                if selection.openBrand == .lg { charts }
                Divider().padding(.vertical, 3)
                sectionTitle("Battery", summary: batterySummary, brand: .bluetti)
                batteryControls
                if selection.openBrand == .bluetti { charts }
                if tuya.needsSignIn { meter }
                Divider().padding(.vertical, 3)
                sectionTitle("Energy", summary: "", brand: .deye)
                solar
                if selection.openBrand == .deye || selection.openBrand == .tuya { charts }
                Divider().padding(.top, 6)
                HStack {
                    Button { showSettings.toggle() } label: {
                        Label("Settings…", systemImage: "gearshape").font(.system(size: 15, weight: .semibold))
                    }.buttonStyle(.plain)
                    Spacer()
                    if !showSettings {
                        Button { NSApp.terminate(nil) } label: { Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 19)) }
                            .buttonStyle(.plain).help("Quit Super Bar").accessibilityLabel("Quit Super Bar")
                    }
                }.padding(.vertical, 4)
                if showSettings {
                    EnergyTariffSettings()
                    Divider()
                    PanelControl(control: settings).id(selection.chartBrand).frame(height: selection.chartBrand == .lg ? SuperFooter.height : SuperFooter.height - 36)
                }
            }.padding(14).fixedSize(horizontal: false, vertical: true)
                .reportContentHeight { height in
                    measuredHeight = height
                    contentHeight(min(height, availableHeight))
                }
        }
        .scrollDisabled(measuredHeight <= availableHeight)
        .scrollIndicators(measuredHeight > availableHeight ? .automatic : .hidden)
        .frame(width: PanelLayout.width)
        .tint(cobalt).environment(\.locale, Locale(identifier: "en_US"))
        .transaction { $0.animation = nil }
        .onChange(of: selection.expanded) { _, _ in updateBatteries() }
        .onChange(of: selection.detailsCollapsed) { _, _ in updateBatteries() }
        .onChange(of: selection.openBrand, initial: true) { _, brand in
            deye.showHistory(brand == .deye)
            tuya.showHistory(brand == .deye)
        }
    }
    private var climateBrand: Brand { selection.expanded == .lg ? .lg : .tcl }
    private var climateSummary: String {
        if climateBrand == .lg {
            let sample = lg.sample(for: lg.selected)
            return summary(name: lg.devices.first(where: { $0.id == lg.selected })?.name ?? "", target: sample?.target, room: sample?.room, on: sample?.power.map { $0 == "POWER_ON" })
        }
        guard let ac = tcl.selected else { return "" }
        return summary(name: ac.name, target: ac.target, room: ac.indoor, on: ac.online == true && !tcl.offline ? ac.power : nil)
    }
    private func summary(name: String, target: Double?, room: Double?, on: Bool?) -> String {
        var parts = [DeviceDisplayName.clean(name)]
        if on == true, let target { parts.append("Set " + tempText(target)) }
        if on != nil, let room { parts.append("Room " + tempText(room)) }
        return parts.joined(separator: " · ")
    }
    private var batterySummary: String {
        guard let card = blue.stationRows.first(where: { $0.key == blue.selectedKnownStation?.key })?.details.card else { return "" }
        return card.summaryName + " · " + card.summaryPercent
    }
    private func sectionTitle(_ title: String, summary: String, brand: Brand) -> some View {
        HStack(spacing: 6) {
            Button {
                if brand == .deye { selection.toggleEnergy(); if selection.openBrand == .deye { deye.pinned = true } }
                else { selection.select(brand, sameDevice: true) }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 19, weight: .bold))
                    Image(systemName: selection.openBrand == brand ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold))
                }
            }.buttonStyle(.plain)
            Spacer(minLength: 4)
            if brand == .deye {
                HStack(spacing: 4) {
                    Text(DeyeReading.power(deye.reading?.power_w)).foregroundStyle(sunlight)
                    Text("/")
                    Text(tuya.reading?.consumption().map(DisplayUnits.power) ?? "—").foregroundStyle(ice)
                }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
            } else { Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85) }
        }.padding(.bottom, 2)
    }
    private func updateBatteries() { blue.rebuildStationMenu(); batteries.refresh() }
    @ViewBuilder private var batteryControls: some View {
        DeviceSelector(brand: .bluetti) {
            if !blue.bluetoothActivated {
                DeviceChoice(action: { blue.activateBluetooth(); batteries.refresh() }) {
                    Text("Allow Bluetooth").font(.system(size: 12))
                }
            } else if blue.stationRows.isEmpty {
                DeviceChoice(action: { blue.refreshClicked() }) { Text("Find BLUETTI devices").font(.system(size: 12)) }
            } else {
                ForEach(blue.stationRows, id: \.key) { entry in
                    let card = entry.details.card
                    DeviceChoice(selected: selection.expanded == .bluetti && blue.selectedKnownStation?.key == entry.key, action: card.selectSummary) {
                        HStack(spacing: 6) {
                            Image(systemName: card.summaryBatterySymbol).foregroundStyle(leafGreen).font(.system(size: 28))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(card.summaryName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(card.summaryPercent).font(.system(size: 22, weight: .bold)).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }.frame(minHeight: 42)
                    }
                }
            }
        }
        if blue.bluetoothActivated && selection.expanded == .bluetti && !selection.detailsCollapsed,
           let entry = blue.stationRows.first(where: { $0.key == blue.selectedKnownStation?.key }) {
            PanelControl(control: entry.details.card).frame(height: max(144, entry.details.card.contentHeight))
                .deviceSurface(selected: true).padding(.leading, PanelLayout.logoColumn)
        }
    }
    private var charts: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch selection.chartBrand {
            case .tcl: climate.charts
            case .lg: thinQ.charts
            case .deye:
                solar.charts
                if let reading = deye.reading { EnergyValueView(reading: reading, consumption: tuya.chartHistory?.hours ?? [], live: tuya.samples, consumptionDays: tuya.chartHistory?.days ?? []) }
            case .tuya: meter.charts
            case .bluetti:
                if blue.lastGood != nil {
                    Text("Output power · 30 minutes").font(.caption).foregroundStyle(.secondary)
                    PanelControl(control: blue.loadGraph).frame(height: 106)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
