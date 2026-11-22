import SwiftUI

// The platform adapter supplies a pin action only where a menu-bar readout exists.
struct DeviceMetric: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let value: String
    var visible = false
    var toggle: (() -> Void)? = nil
}

struct ClimateMetricReading: View {
    let metric: DeviceMetric
    var temperature = false
    var ecoEnabled = false

    var body: some View {
        Group {
            if let toggle = metric.toggle {
                Button(action: toggle) { label }
                    .panelButtonStyle()
                    .help((metric.visible ? "Hide " : "Show ") + metric.label + " in menu bar")
                    .accessibilityValue(metric.visible ? "Visible in menu bar" : "Hidden from menu bar")
            } else { label }
        }.accessibilityLabel(metric.label + " " + metric.value)
    }

    private var label: some View {
        HStack(spacing: 3) {
            if temperature && metric.id == "energy" { Image(systemName: metric.symbol).foregroundStyle(ice) }
            else { Text(metric.label == "AC" ? "Set" : metric.label).foregroundStyle(.secondary) }
            Text(metric.value).foregroundStyle(.white)
            if metric.label == "AC" && ecoEnabled {
                ClimateEcoIcon().font(.system(size: 10))
            }
        }.font(.system(size: 13, weight: metric.visible ? .semibold : .regular))
            .monospacedDigit().lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(ice.opacity(metric.visible ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}

// The complete TCL card has the same readings row on Mac and iPhone.
struct TCLDeviceDetails: View {
    @ObservedObject var store: ClimateStore
    let ac: Aircon
    var pinnedFields: Set<String> = []
    var togglePin: ((String) -> Void)? = nil

    var body: some View {
        TCLClimateCard(store: store, ac: ac) {
            TimelineView(.periodic(from: .now, by: 15)) { tick in
                let draw = store.history.power(for: ac, online: !store.offline, now: tick.date)
                HStack(spacing: 8) {
                    reading("indoor", label: "Room", value: tempText(ac.indoor))
                    reading("energy", label: draw?.label ?? "Power", value: draw?.text ?? "—")
                }
            }
        }.padding(.vertical, 6)
    }

    private func reading(_ id: String, label: String, value: String) -> some View {
        ClimateMetricReading(metric: DeviceMetric(id: id, label: label, symbol: "", value: value,
            visible: pinnedFields.contains(id), toggle: togglePin.map { action in { action(id) } }))
    }
}

// Desktop presentation, shared with iPhone. Models and platform actions stay
// outside the view; narrow layouts only rearrange these same controls.
struct ClimateDeviceCard<Controls: View>: View {
    let windowUnit: Bool
    let name: String
    let selected: Bool
    let status: String
    let metrics: [DeviceMetric]
    let reading: Bool
    let readAt: Date?
    let refresh: () -> Void
    let select: () -> Void
    var powerOn: Bool? = nil
    var indicators = ClimateIndicators()
    var temperatureOptions: [Int] = []
    var changeTemperature: ((Int) -> Void)? = nil
    var setPower: ((Bool) -> Void)? = nil
    var powerEnabled = true
    var controlsEnabled = true
    var livePower: String? = nil
    var message: String? = nil
    var presets: AnyView? = nil
    var directions: AnyView? = nil
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    identity.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    if selected { headerReadings.fixedSize(horizontal: true, vertical: false); refreshButton }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        identity
                        Spacer(minLength: 8)
                        if selected { refreshButton }
                    }
                    if selected { headerReadings }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(perform: select)

            if selected {
                temperatureControls.disabled(!controlsEnabled)
                TimelineView(.periodic(from: .now, by: 15)) { tick in
                    HStack(spacing: 8) {
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
                        Text(message ?? CardRefresh.status(reading: reading, status: status, readAt: readAt, now: tick.date))
                            .font(.system(size: 10)).foregroundStyle(message == nil ? Color.secondary : Color.orange)
                            .lineLimit(1).help(message ?? "")
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
                    }.padding(.top, 2)
                }
            }
        }.foregroundStyle(.white).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            ClimateHousing(windowUnit: windowUnit).frame(width: 28, height: 20)
            Text(DeviceDisplayName.clean(name)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if let powerOn {
                if powerOn { Circle().fill(leafGreen).frame(width: 6, height: 6).accessibilityLabel("ON") }
                else { Image(systemName: "power").foregroundStyle(.gray).font(.system(size: 14, weight: .semibold)).accessibilityLabel("OFF") }
            }
        }
    }
    private var headerReadings: some View {
        HStack(spacing: 8) {
            metricReadings
            Label(livePower ?? "—", systemImage: "bolt.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(ice).monospacedDigit()
                .frame(width: 76, alignment: .trailing).opacity(livePower == nil ? 0 : 1)
                .accessibilityHidden(livePower == nil)
        }
    }
    private var refreshButton: some View {
        CardRefresh(reading: reading, status: status, readAt: readAt, refresh: refresh)
    }
    private var ecoEnabled: Bool { powerOn == true && metrics.first(where: { $0.label == "Eco" })?.value == "ON" }
    private var targetValue: String { metrics.first(where: { $0.label == "AC" })?.value ?? "—" }
    private var temperatureControls: some View {
        PanelTemperatureControl(name: name, targetValue: targetValue, powerOn: powerOn,
            temperatureOptions: temperatureOptions, changeTemperature: changeTemperature,
            setPower: setPower, powerEnabled: powerEnabled, indicators: indicators, directions: directions,
            trailingControl: AnyView(HStack(spacing: 6) {
                controls()
                if let presets { presets.fixedSize(horizontal: true, vertical: false) }
            }))
    }

    @ViewBuilder private var metricReadings: some View {
        let rows = metrics.filter { !["AC", "Fan", "Eco"].contains($0.label) }
        if !rows.isEmpty {
            HStack(spacing: 3) {
                ForEach(rows) { metric in ClimateMetricReading(metric: metric, temperature: true, ecoEnabled: ecoEnabled) }
            }
        }
    }
}

struct CardMenus<Fan: View>: View {
    let eco: Bool?
    let toggleEco: () -> Void
    var ecoEnabled = true
    @ViewBuilder let fan: () -> Fan
    var body: some View {
        HStack(spacing: 8) {
            ClimateEcoButton(enabled: eco, action: toggleEco).disabled(!ecoEnabled)
            fan()
        }.fixedSize()
    }
}

// No AppKit bridge is needed for a refresh button inside a SwiftUI card.
struct CardRefresh: View {
    let reading: Bool
    let status: String
    let readAt: Date?
    let refresh: () -> Void
    #if os(iOS)
    private let side: CGFloat = 44
    #else
    private let side: CGFloat = 24
    #endif
    var body: some View {
        Button(action: refresh) {
            RefreshGlyph(isRefreshing: reading, size: 14)
                .frame(width: side, height: side).contentShape(Rectangle())
        }.panelButtonStyle().disabled(reading)
            .help(Self.status(reading: reading, status: status, readAt: readAt))
            .accessibilityLabel(reading ? "Refreshing readings" : "Refresh readings")
    }
    static func status(reading: Bool, status: String, readAt: Date?, now: Date = Date()) -> String {
        if reading { return "Refreshing…" }
        if status == "Offline" { return "Not connected" }
        guard let readAt else { return "No readings" }
        // Relative text must also advance on iPhone, where the Mac menu timer is absent.
        let seconds = max(0, Int(now.timeIntervalSince(readAt)))
        let age = seconds < 3 ? "Just now" : seconds < 60 ? "\(seconds)s ago" : seconds < 3600 ? "\(seconds / 60)m ago" : seconds < 86400 ? "\(seconds / 3600)h ago" : "\(seconds / 86400)d ago"
        return "Last read " + age
    }
}
