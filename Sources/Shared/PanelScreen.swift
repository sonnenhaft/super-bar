import SwiftUI

enum PanelSection: String, CaseIterable {
    case home, energy, climate, television, battery, settings
    var title: String {
        switch self {
        case .climate: "AC"
        case .television: "TV"
        default: rawValue.capitalized
        }
    }
}

/// The same completed-minute ledger and labels on Mac and iPhone.
struct PanelTrafficReadout: View {
    var body: some View {
        TimelineView(.periodic(from: CloudTraffic.boundary(.now), by: 60)) { _ in
            let traffic = CloudTraffic.shared.snapshot(at: .now)
            Group {
                if traffic.coveredSeconds > 0 {
                    Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 1) {
                        GridRow {
                            Text("Rate").gridColumnAlignment(.leading)
                            Text(verbatim: "IN " + traffic.averageIncomingLabel)
                            Text(verbatim: "OUT " + traffic.averageOutgoingLabel)
                        }
                        GridRow {
                            Text(verbatim: traffic.windowLabel)
                            Text(verbatim: "IN " + traffic.incomingTotalLabel)
                            Text(verbatim: "OUT " + traffic.outgoingTotalLabel)
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: traffic.minuteLabel)
                        Text(verbatim: traffic.totalLabel)
                    }
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(traffic.minuteLabel + ". " + traffic.totalLabel)
                .accessibilityHint(traffic.detail)
                .help(traffic.detail)
        }
    }
}

/// The content hierarchy used by both app shells. Platform adapters supply
/// existing models and actions; this view never creates a service or a poller.
struct PanelScreen<Access: View, Climate: View, Television: View, Battery: View, Energy: View, Settings: View, Accessory: View>: View {
    let deye: DeyeStore
    let tuya: TuyaStore
    let climateExpanded: Bool
    let televisionExpanded: Bool
    let batteryExpanded: Bool
    let energyExpanded: Bool
    let settingsExpanded: Bool
    let canExpandClimate: Bool
    let batterySummary: String
    let highlightedEnergy: String?
    let refreshing: Bool
    let toggleSection: (PanelSection) -> Void
    let openEnergy: () -> Void
    let refresh: () -> Void
    let quit: (() -> Void)?
    private let access: Access
    private let climate: Climate
    private let television: Television
    private let battery: Battery
    private let energy: Energy
    private let settings: Settings
    private let accessory: Accessory

    init(deye: DeyeStore, tuya: TuyaStore,
         climateExpanded: Bool, televisionExpanded: Bool, batteryExpanded: Bool, energyExpanded: Bool, settingsExpanded: Bool,
         canExpandClimate: Bool = true, batterySummary: String = "", highlightedEnergy: String? = nil,
         refreshing: Bool, toggleSection: @escaping (PanelSection) -> Void,
         openEnergy: @escaping () -> Void, refresh: @escaping () -> Void, quit: (() -> Void)? = nil,
         @ViewBuilder access: () -> Access, @ViewBuilder climate: () -> Climate, @ViewBuilder television: () -> Television,
         @ViewBuilder battery: () -> Battery, @ViewBuilder energy: () -> Energy,
         @ViewBuilder settings: () -> Settings, @ViewBuilder accessory: () -> Accessory) {
        self.deye = deye; self.tuya = tuya
        self.climateExpanded = climateExpanded; self.batteryExpanded = batteryExpanded
        self.televisionExpanded = televisionExpanded; self.television = television()
        self.energyExpanded = energyExpanded; self.settingsExpanded = settingsExpanded
        self.canExpandClimate = canExpandClimate; self.batterySummary = batterySummary
        self.highlightedEnergy = highlightedEnergy; self.refreshing = refreshing
        self.toggleSection = toggleSection; self.openEnergy = openEnergy; self.refresh = refresh; self.quit = quit
        self.access = access(); self.climate = climate(); self.battery = battery()
        self.energy = energy(); self.settings = settings(); self.accessory = accessory()
    }

    var body: some View {
        PanelSections {
            access
            sectionHeading(.climate, expanded: climateExpanded)
                .disabled(!canExpandClimate).padding(.bottom, 2).id(PanelSection.climate)
        } climate: {
            climate
            #if os(macOS)
            Divider().padding(.vertical, 3)
            sectionHeading(.television, expanded: televisionExpanded).id(PanelSection.television)
            #endif
            television.id(PanelSection.television)
        } batteryHeading: {
            HStack {
                sectionHeading(.battery, expanded: batteryExpanded)
                if !batterySummary.isEmpty {
                    Text(batterySummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.id(PanelSection.battery)
        } battery: {
            battery
        } energyHeading: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sectionHeading(.energy, expanded: energyExpanded)
                    energyMetrics.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeading(.energy, expanded: energyExpanded)
                    energyMetrics
                }
            }.id(PanelSection.energy)
        } energy: {
            energy
        } footer: {
            footer.id(PanelSection.settings)
        } settings: {
            if settingsExpanded { settings }
        }
    }

    private func sectionHeading(_ section: PanelSection, expanded: Bool) -> some View {
        #if os(iOS)
        let title = section == .climate ? "Wi-Fi devices" : section.title
        let isExpanded = section == .climate ? climateExpanded || televisionExpanded : expanded
        #else
        let title = section.title
        let isExpanded = expanded
        #endif
        return Button { toggleSection(section) } label: {
            PanelSectionHeading(title: title, expanded: isExpanded)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: headingHeight, alignment: .leading)
                .contentShape(Rectangle())
        }.panelButtonStyle()
    }

    private var energyMetrics: some View {
        EnergyHeaderMetrics(deye: deye, tuya: tuya, openCharts: openEnergy,
                            highlightedMetric: energyExpanded ? highlightedEnergy : nil)
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 2) {
            footerControls
            #if os(iOS)
            accessory.frame(maxWidth: .infinity, alignment: .trailing)
            #endif
        }.padding(.vertical, 4)
    }

    private var footerControls: some View {
        HStack {
            Button { toggleSection(.settings) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape").accessibilityHidden(true)
                    PanelSectionHeading(title: PanelSection.settings.title, expanded: settingsExpanded, compact: true)
                }.frame(minHeight: controlSize).contentShape(Rectangle())
            }.panelButtonStyle().accessibilityLabel("Settings")
                .accessibilityValue(settingsExpanded ? "Expanded" : "Collapsed")
            Spacer()
            #if os(macOS)
            accessory
            #endif
            Button(action: refresh) {
                RefreshGlyph(isRefreshing: refreshing, size: 14)
                    .frame(width: controlSize, height: controlSize).contentShape(Rectangle())
            }.panelButtonStyle().disabled(refreshing)
                .help("Refresh readings")
                .accessibilityLabel(refreshing ? "Refreshing readings" : "Refresh readings")
            if let quit, !settingsExpanded {
                Button(action: quit) {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 19))
                }.panelButtonStyle().help("Quit Super Bar").accessibilityLabel("Quit Super Bar")
            }
        }
    }

    private var headingHeight: CGFloat {
        #if os(iOS)
        36
        #else
        0
        #endif
    }
    private var controlSize: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }
}
