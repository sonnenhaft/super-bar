import SwiftUI

struct BatteryStationItem: Identifiable {
    let id: String
    let name: String
    let percent: Int?
    let selected: Bool
}

/// The station list, permission prompt and pending selection have one layout.
struct BatteryDeviceList<Detail: View>: View {
    let stations: [BatteryStationItem]
    let needsPermission: Bool
    var permissionRestricted = false
    let emptyMessage: String
    var waitingForSelection = false
    var hasSelection = false
    var error: String? = nil
    let requestPermission: () -> Void
    let select: (String) -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if needsPermission {
                Button("Allow Bluetooth", action: requestPermission)
                    .buttonStyle(.bordered).panelPointer().disabled(permissionRestricted)
            }
            if !stations.isEmpty {
                BatteryStationGrid {
                    ForEach(stations) { station in
                        Button { select(station.id) } label: {
                            BatterySummaryCard(name: station.name,
                                               symbol: DeviceDisplayName.batterySymbol(percent: station.percent),
                                               charge: station.percent.map { "\($0)%" } ?? "—",
                                               selected: station.selected)
                        }.panelButtonStyle()
                            .accessibilityAddTraits(station.selected ? .isSelected : [])
                    }
                }
            }
            detail()
            if waitingForSelection {
                Text("Waiting for the selected station…").font(.caption).foregroundStyle(.secondary)
            } else if !needsPermission && stations.isEmpty && !hasSelection {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Platform adapters translate their readings and menu preferences into this value.
enum BatteryDisplayField: String, CaseIterable {
    case percentage, battery, brand, input, output, chargeTime, runtime

    var label: String {
        switch self {
        case .percentage: "Battery percentage"
        case .battery: "Battery icon"
        case .brand: "BLUETTI logo"
        case .input: "Input power"
        case .output: "Output power"
        case .chargeTime: "Time to full charge"
        case .runtime: "Battery runtime"
        }
    }
}

struct BatteryDetailContent: Equatable {
    var name = ""
    var percent: Int?
    var input = ""
    var output = ""
    var chargeTime = ""
    var runtime = ""
    var outputHelp: String? = nil
    var connected = false
    var selected = false
    var expanded = true
    var selectionEnabled = true
    var canRename = true
    var refreshing = false
    var refreshEnabled = true
    var status = ""
    var measuredAt: Date? = nil
    var statusHelp: String? = nil
    var problem: String? = nil
    var pinnedFields: Set<BatteryDisplayField> = []

    static func power(_ direction: String, dc: Double?, ac: Double?) -> String {
        let values = [("DC", dc), ("AC", ac)].compactMap { label, value -> (String, Double)? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return (label, value)
        }
        guard !values.isEmpty else { return "" }
        return direction + " " + values.map(\.0).joined(separator: "|") + ": "
            + values.map { DisplayUnits.power($0.1) }.joined(separator: "|")
    }

    static func duration(seconds: Int) -> String {
        let minutes = Int(ceil(Double(max(0, seconds)) / 60))
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return "\(minutes / 60)h" + (remainder == 0 ? "" : " \(remainder)m")
    }
}

struct BatteryDetailActions {
    var select: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var refresh: (() -> Void)? = nil
    var toggleField: ((BatteryDisplayField) -> Void)? = nil
    var saveName: ((String) -> Void)? = nil
}

/// Desktop card composition shared with iPhone; only hit areas adapt to touch.
struct BatteryDetailCard: View {
    let content: BatteryDetailContent
    var actions = BatteryDetailActions()
    var brandImage: Image? = nil
    var alias = ""
    var renameMessage = "Leave the name empty to reset."
    @State private var renaming = false
    @State private var draftName = ""

    private var controlHeight: CGFloat {
        #if os(iOS)
        44
        #else
        22
        #endif
    }
    private var estimateColor: Color { Color(red: 0.62, green: 0.88, blue: 0.96) }

    var body: some View {
        Group {
            if content.expanded { expandedCard }
            else { compactCard }
        }
        .foregroundStyle(.white)
        .alert("Rename station", isPresented: $renaming) {
            TextField("Station name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { actions.saveName?(draftName) }
        } message: { Text(renameMessage) }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                field(.brand) { brand.frame(width: 25, height: 21) }
                selectionLabel
                Spacer(minLength: 0)
                Button { actions.refresh?() } label: {
                    RefreshGlyph(isRefreshing: content.refreshing, size: 14)
                        .frame(width: controlHeight, height: controlHeight)
                }.panelButtonStyle().disabled(!content.refreshEnabled || actions.refresh == nil)
                    .accessibilityLabel((content.refreshing ? "Refreshing " : "Refresh ") + content.name)
                Button(action: beginRename) {
                    Image(systemName: "pencil").font(.system(size: 14))
                        .frame(width: controlHeight, height: controlHeight)
                }.panelButtonStyle().disabled(!content.canRename)
                    .accessibilityLabel("Rename " + content.name)
            }
            if content.percent != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        percentage
                        Spacer(minLength: 0)
                        powerPairs.fixedSize(horizontal: true, vertical: false)
                        batteryIcon
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { percentage; Spacer(); batteryIcon }
                        powerPairs.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(minHeight: 66, alignment: .top)
            } else {
                Text("Waiting for the first reading…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !content.status.isEmpty {
                Button { actions.refresh?() } label: {
                    statusLabel.font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                }.panelButtonStyle().disabled(!content.refreshEnabled || actions.refresh == nil)
                    .help(content.statusHelp ?? "Refresh " + content.name)
            }
            if let problem = content.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
    }

    private var compactCard: some View {
        HStack(spacing: 6) {
            field(.brand) { brand.frame(width: 24, height: 14) }
            selectionLabel
            Spacer(minLength: 0)
            value(.percentage, text: content.percent.map { "\($0)%" } ?? "—", size: 13)
        }.padding(.horizontal, 8).frame(height: 26)
    }

    @ViewBuilder private var statusLabel: some View {
        if let date = content.measuredAt, !content.refreshing {
            // SwiftUI updates relative Text while visible on both platforms;
            // the phone does not rely on the Mac menu's ReadingAge timer/cache.
            Text("Last read ") + Text(date, style: .relative) + Text(" ago")
        } else { Text(content.status) }
    }

    @ViewBuilder private var selectionLabel: some View {
        let label = HStack(spacing: 3) {
            Text(content.name).font(.system(size: content.expanded ? 15 : 13,
                                           weight: content.expanded ? .bold : .regular))
                .lineLimit(1).truncationMode(.middle)
            if content.connected {
                Circle().fill(SuperBarPanelStyle.green).frame(width: 4, height: 4)
                    .accessibilityLabel("Connected")
            }
        }.contentShape(Rectangle())
        if let select = actions.select {
            Button(action: select) { label }.panelButtonStyle().disabled(!content.selectionEnabled)
                .accessibilityAddTraits(content.selected ? .isSelected : [])
        } else { label }
    }

    @ViewBuilder private var brand: some View {
        if let brandImage { brandImage.resizable().scaledToFit() }
        else { Text("BLUETTI").font(.system(size: 6, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6) }
    }

    private var percentage: some View {
        value(.percentage, text: content.percent.map { "\($0)%" } ?? "", size: 28)
            .frame(minWidth: 64, minHeight: 35, alignment: .leading)
    }

    private var batteryIcon: some View {
        field(.battery) {
            Image(systemName: DeviceDisplayName.batterySymbol(percent: content.percent))
                .font(.system(size: 16, weight: .medium)).frame(width: 20, height: 26)
        }
    }

    private var powerPairs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 4) { inputPair; outputPair }
            VStack(alignment: .trailing, spacing: 4) { inputPair; outputPair }
        }
    }

    @ViewBuilder private var inputPair: some View {
        if !content.input.isEmpty || !content.chargeTime.isEmpty {
            VStack(alignment: .trailing, spacing: 0) {
                value(.input, text: content.input).frame(minHeight: 20)
                value(.chargeTime, text: content.chargeTime, color: estimateColor).frame(minHeight: 20)
            }
        }
    }

    @ViewBuilder private var outputPair: some View {
        if !content.output.isEmpty || !content.runtime.isEmpty {
            VStack(alignment: .trailing, spacing: 0) {
                value(.output, text: content.output).frame(minHeight: 20)
                value(.runtime, text: content.runtime, color: estimateColor).frame(minHeight: 20)
            }
        }
    }

    @ViewBuilder private func value(_ key: BatteryDisplayField, text: String,
                                    size: CGFloat = 13, color: Color = .white) -> some View {
        if !text.isEmpty {
            field(key) {
                Text(text).font(.system(size: size, weight: content.pinnedFields.contains(key) ? .bold : .regular))
                    .monospacedDigit().foregroundStyle(color).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder private func field<Label: View>(_ key: BatteryDisplayField,
                                                @ViewBuilder label: () -> Label) -> some View {
        if let toggle = actions.toggleField {
            Button { toggle(key) } label: {
                label().contentShape(Rectangle())
                    .opacity((key == .battery && !content.pinnedFields.contains(key)) ? 0.4 : 1)
            }.panelButtonStyle()
                .accessibilityLabel(key.label)
                .accessibilityValue(content.pinnedFields.contains(key) ? "Shown in menu bar" : "Hidden from menu bar")
                .help((content.pinnedFields.contains(key) ? "Hide " : "Show ") + key.label
                      + (content.pinnedFields.contains(key) ? " from menu bar" : " in menu bar")
                      + (key == .output ? content.outputHelp.map { "\n" + $0 } ?? "" : ""))
        } else { label() }
    }

    private func beginRename() {
        if actions.saveName != nil { draftName = alias; renaming = true }
        else { actions.rename?() }
    }
}
