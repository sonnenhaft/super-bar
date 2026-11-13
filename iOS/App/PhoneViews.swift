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
    init(model: PhoneModel) {
        self.model = model; deye = model.deye; tuya = model.tuya; tcl = model.tcl; lg = model.lg; battery = model.bluetooth
    }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: SuperBarPanelStyle.gap) {
                    sectionHeader(.climate).id(PhoneSection.climate)
                    PhoneClimateView(tcl: tcl, lg: lg, expanded: model.section == .climate,
                                     open: { model.section = .climate }, selected: $model.selectedClimate,
                                     close: { model.section = .home })
                    Divider().padding(.vertical, 3)
                    sectionHeader(.battery).id(PhoneSection.battery)
                    PhoneBatteryView(model: battery, expanded: model.section == .battery,
                                     open: { model.section = .battery })
                    Divider().padding(.vertical, 3)
                    sectionHeader(.energy).id(PhoneSection.energy)
                    HStack(spacing: 8) {
                        Button { model.section = .energy } label: {
                            PanelEnergyTile(title: "Generation", value: DeyeReading.power(deye.reading?.power_w),
                                            generation: true, selected: model.section == .energy)
                        }
                        Button { model.section = .energy } label: {
                            PanelEnergyTile(title: "Consumption", value: tuya.reading?.consumption().map(DisplayUnits.power) ?? "—",
                                            generation: false, selected: model.section == .energy)
                        }
                    }.buttonStyle(.plain)
                    if model.section == .energy { PhoneEnergyView(deye: deye, tuya: tuya) }
                    Divider().padding(.top, 6)
                    HStack {
                        Button { toggle(.settings) } label: {
                            Label("Settings…", systemImage: "gearshape").font(.system(size: 15, weight: .semibold))
                                .frame(minHeight: 44)
                        }
                        Spacer()
                        Button { Task { await model.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                        }.accessibilityLabel("Refresh readings")
                    }.buttonStyle(.plain).id(PhoneSection.settings)
                    if model.section == .settings { PhoneSettings(model: model) }
                }
                .padding(SuperBarPanelStyle.appInset)
                .frame(maxWidth: SuperBarPanelStyle.maximumWidth)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(SuperBarPanelStyle.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .font(.system(size: 13))
            .refreshable { await model.refresh() }
            .onChange(of: model.section) { _, section in
                if section != .home { scroll.scrollTo(section, anchor: .top) }
            }
        }
    }
    private func toggle(_ section: PhoneSection) {
        model.section = model.section == section ? .home : section
    }
    private func sectionHeader(_ section: PhoneSection) -> some View {
        Button { toggle(section) } label: {
            HStack {
                PanelSectionHeading(title: section.title, expanded: model.section == section)
                Spacer(minLength: 4)
                if section == .energy {
                    HStack(spacing: 4) {
                        Text(DeyeReading.power(deye.reading?.power_w)).foregroundStyle(SuperBarPanelStyle.yellow)
                        Text("/")
                        Text(tuya.reading?.consumption().map(DisplayUnits.power) ?? "—").foregroundStyle(SuperBarPanelStyle.cyan)
                    }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }.frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct PhoneMetric: View {
    let title: String, value: String
    var color: Color = SuperBarPanelStyle.cyan
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(color).monospacedDigit()
                .minimumScaleFactor(0.65).lineLimit(1)
        }
    }
}

struct PhoneTimestamp: View {
    var date: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 5) {
                Image(systemName: "clock")
                if let date {
                    Text("Updated")
                    Text(date, style: .relative)
                    if context.date.timeIntervalSince(date) > 300 { Text("· Saved reading").foregroundStyle(.orange) }
                } else { Text("No timestamp available") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PhoneEnergyView: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    var body: some View {
        if !tuya.devices.isEmpty {
            VStack(alignment: .leading) {
                Text("Main consumption meter").font(.headline)
                Picker("Meter", selection: Binding(get: { tuya.reading?.meterID ?? "" }, set: { tuya.useAsMeter($0) })) {
                    Text("Select a meter").tag("")
                    ForEach(tuya.devices) { Text($0.name).tag($0.id) }
                }.disabled(tuya.refreshing)
            }.phoneCard()
        }
        EnergyDetails(deye: deye, tuya: tuya).phoneCard()
        if let problem = deye.problem {
            Text("Deye · " + problem).font(.caption).foregroundStyle(.secondary)
        }
        if let problem = tuya.problem {
            Text("Smart Life · " + problem).font(.caption).foregroundStyle(.secondary)
        }
        if deye.refreshing || tuya.refreshing { ProgressView("Refreshing energy…") }
    }
}
