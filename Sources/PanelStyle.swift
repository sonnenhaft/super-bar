import SwiftUI

enum PanelLayout {
    static let width = SuperBarPanelStyle.maximumWidth
    static let logoColumn = SuperBarPanelStyle.logoColumn
}
struct DeviceChoice<Content: View>: View {
    var selected = false
    var compact = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content().padding(.horizontal, 10).padding(.vertical, compact ? 5 : 9)
                .frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
        }.buttonStyle(.plain).deviceSurface(selected: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: BarTheme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.16),lineWidth:0.5))
            .shadow(color:.black.opacity(0.12),radius:2,y:1)
    }
}
struct SectionName: View {
    let title: String, icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
    }
}
extension View {
    func overviewSurface(selected: Bool) -> some View {
        self.foregroundStyle(.white).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .deviceSurface(selected: selected)
    }

}

struct DeviceSelector<Content: View>: View {
    let brand: Brand
    var toggleLogo: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        Group {
        if brand == .deye {
            choices
        } else {
            HStack(spacing: 8) { brandLabel; choices }
        }
        }
    }
    private var brandLabel: some View {
        Button {
                    if let toggleLogo { toggleLogo() }
                    else { BarSelection.shared.select(brand, sameDevice: true) }
        } label: {
            Group {
                if brand == .tuya {
                    Text("tuya").font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: 36, height: 24)
                } else { PanelBrandLabel(name: brand.rawValue) }
            }.frame(width: 48, height: 24, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(brand.rawValue)
    }
    private var choices: some View {
        HStack(spacing: 8, content: content).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
    }
}

// A device name selects its controls; each value independently pins a reading.
struct DeviceMetric: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let value: String
    let visible: Bool
    let toggle: () -> Void
}

struct ClimateDeviceCard<Controls: View>: View {
    let brand: Brand
    let name: String
    let selected: Bool
    let status: String
    let metrics: [DeviceMetric]
    let reading: Bool
    let readAt: Date?
    let refresh: () -> Void
    let select: () -> Void
    var powerOn: Bool? = nil
    var temperatureOptions: [Int] = []
    var changeTemperature: ((Int) -> Void)? = nil
    var turnOff: (() -> Void)? = nil
    var livePower: String? = nil
    var message: String? = nil
    var presets: AnyView? = nil
    var directions: AnyView? = nil
    @ViewBuilder let controls: () -> Controls

    @ObservedObject private var ageSnapshot = ReadingAge.shared
    var body: some View {
        expandedCard.transaction { $0.animation = nil }
    }
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ClimateArtwork(brand: brand).frame(width: 28, height: 20)
                Text(DeviceDisplayName.clean(name)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let powerOn {
                    if powerOn { Circle().fill(leafGreen).frame(width:6,height:6).accessibilityLabel("ON") }
                    else { Image(systemName:"power").foregroundStyle(.red).font(.system(size:14,weight:.semibold)).accessibilityLabel("OFF") }
                }
                Spacer(minLength:8)
                if selected {
                    CardRefresh(reading:reading,status:status,readAt:readAt,refresh:refresh).frame(width:24,height:24)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { select() }

            if selected {
            temperatureControls
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                metricButtons
                if brand == .lg, let livePower {
                    Label(livePower, systemImage: "bolt.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(ice).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                controls()
                if let presets { presets }
            }
            HStack(spacing: 8) {
                Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
                Text(message ?? CardRefresh.status(reading:reading,status:status,readAt:readAt))
                    .font(.system(size: 10)).foregroundStyle(message == nil ? Color.secondary : Color.orange).lineLimit(1).fixedSize(horizontal: true, vertical: false).help(message ?? "")
                Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
            }.padding(.top, 2)
            }
        }.foregroundStyle(.white).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    private var ecoEnabled: Bool { powerOn == true && metrics.first(where: { $0.label == "Eco" })?.value == "ON" }
    private var targetValue: String { metrics.first(where: { $0.label == "AC" })?.value ?? "—" }
    private var temperatureControls: some View {
        PanelTemperatureControl(name: name, targetValue: targetValue, powerOn: powerOn,
            temperatureOptions: temperatureOptions, changeTemperature: changeTemperature,
            turnOff: turnOff, ecoEnabled: ecoEnabled, directions: directions)
    }
    private func metricButton(_ metric: DeviceMetric) -> some View {
        Button(action: metric.toggle) {
            HStack(spacing: 3) {
                if metric.id == "energy" { Image(systemName: metric.symbol).foregroundStyle(ice) }
                else { Text(metric.label == "AC" ? "Set" : metric.label).foregroundStyle(.secondary) }
                TemperatureText(value: metric.value)
                if metric.label == "AC" && ecoEnabled { Image(systemName: "leaf.fill").foregroundStyle(leafGreen).font(.system(size: 10)) }
            }.font(.system(size: 13, weight: metric.visible ? .semibold : .regular)).monospacedDigit().lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(ice.opacity(metric.visible ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help((metric.visible ? "Hide " : "Show ") + (metric.label == "AC" ? "set temperature" : metric.label) + " in menu bar")
            .accessibilityLabel(metric.label + " " + metric.value)
            .accessibilityValue(metric.visible ? "Visible in menu bar" : "Hidden from menu bar")
    }
    @ViewBuilder private var metricButtons: some View {
        let rows = metrics.filter {
            !["AC", "Fan", "Eco"].contains($0.label)
        }
        if !rows.isEmpty {
            HStack(spacing: 3) {
                ForEach(rows) { metric in
                    metricButton(metric)
                }
            }
        }
    }
}

// Menu commands are sent only after a value is picked.
struct CardMenus<Fan: View>: View {
    let eco: Bool?
    let toggleEco: () -> Void
    let fan: String
    var fanLevel: Int? = nil
    var fanControl: AnyView? = nil
    @ViewBuilder let fanOptions: () -> Fan
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if let eco {
                    Button(action: toggleEco) {
                        Image(systemName: eco ? "leaf.fill" : "leaf")
                            .font(.system(size: 12))
                            .foregroundStyle(eco ? leafGreen : .secondary)
                            .frame(width: 30, height: 34).contentShape(Rectangle())
                            .background(leafGreen.opacity(eco ? 0.18 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel("Eco").accessibilityValue(eco ? "ON" : "OFF")
                     .help("Eco " + (eco ? "ON" : "OFF"))
                }
                if let fanControl {
                    fanControl
                } else if !fan.isEmpty {
                    Menu(content: fanOptions) {
                        HStack(spacing: 6) {
                            Text(fan)
                            if let fanLevel {
                                FanLevelDots(level: fanLevel)
                            } else { Image(systemName: "fanblades") }
                        }
                    }
                        .climateMenu(width: 112)
                        .accessibilityLabel("Set fan speed").accessibilityValue(fan)
                }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
        .fixedSize()
    }

}

extension View {
    func climateMenu(width: CGFloat? = nil) -> some View {
        self.menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
            .font(.system(size: 13)).foregroundStyle(.white).tint(.white)
            .padding(.horizontal, 6).frame(width: width, height: 34)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .deviceSurface(selected: false)
    }
}

struct FanLevelDots: View {
    let level: Int
    var body: some View {
        Image(nsImage: Self.image(level: level)).renderingMode(.original)
            .accessibilityLabel("Fan speed " + String(level))
    }
    static func image(level: Int) -> NSImage {
        NSImage(size: NSSize(width: 5, height: 17), flipped: false) { _ in
            for index in 0..<3 {
                NSColor.white.withAlphaComponent(index < level ? 1 : 0.16).setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: index * 6, width: 5, height: 5)).fill()
            }
            return true
        }
    }
}

// Shared presentation; each provider owns its supported preset semantics.
struct CoolingPresetRow<Preset: CaseIterable & Hashable>: View {
    let label: (Preset) -> String
    let enabled: (Preset) -> Bool
    let selected: (Preset) -> Bool
    let apply: (Preset) -> Void
    var fanLevel: ((Preset) -> Int)? = nil
    var icon: ((Preset) -> FanSpeedSymbol)? = nil
    var accessibilityName: ((Preset) -> String)? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Preset.allCases), id: \.self) { preset in
                Button { apply(preset) } label: {
                    HStack(spacing: 6) {
                        TemperatureText(value: label(preset))
                        if let icon { FanSpeedIcon(symbol: icon(preset)).frame(width: 22, height: 22) }
                        if let fanLevel { FanLevelDots(level: fanLevel(preset)) }
                    }.font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 34)
                        .deviceSurface(selected: selected(preset))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!enabled(preset))
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityName?(preset) ?? label(preset))
                    .help(accessibilityName?(preset) ?? label(preset))
                    .accessibilityAddTraits(selected(preset) ? .isSelected : [])
            }
        }
    }
}

struct CardRefresh: NSViewRepresentable {
    let reading:Bool
    let status:String
    let readAt:Date?
    let refresh:()->Void
    final class Coordinator: NSObject {
        var refresh:()->Void = {}
        @objc func run() { refresh() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> RefreshRowButton {
        let button = RefreshRowButton(frame:.zero,style:.iconOnly)
        button.target = context.coordinator; button.action = #selector(Coordinator.run)
        button.iconTint = .white
        return button
    }
    func updateNSView(_ button:RefreshRowButton,context:Context) {
        context.coordinator.refresh = refresh
        let text = Self.status(reading:reading,status:status,readAt:readAt)
        button.update(status:text,loading:reading,enabled:true); button.toolTip = text
    }
    static func status(reading:Bool,status:String,readAt:Date?) -> String {
        if reading { return "Refreshing…" }
        return readAt.map { ReadingAge.label($0) } ?? (status == "Offline" ? "Not connected" : "No readings")
    }
}
