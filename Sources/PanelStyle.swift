import SwiftUI

let cobalt = Color(nsColor: BarTheme.cobalt)
let ice = Color(nsColor: BarTheme.cobalt)
let sunlight = Color(nsColor: BarTheme.energy)
let leafGreen = Color(nsColor: BarTheme.green)
enum PanelLayout { static let width: CGFloat = 460; static let logoColumn: CGFloat = 56 }
struct DeviceChoice<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content().padding(.horizontal, 10).padding(.vertical, 9)
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
    func compactSurface() -> some View {
        self.foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading).deviceSurface(selected: false)
    }
    func deviceSurface(selected: Bool) -> some View {
        self.background(LinearGradient(colors: [Color(nsColor: selected ? BarTheme.navy : BarTheme.panel), Color(nsColor: BarTheme.panel).opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color(nsColor: BarTheme.selection) : Color.white.opacity(0.32), lineWidth: selected ? 1 : 0.6))
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
        } else if brand == .lg {
            VStack(alignment: .leading, spacing: 8) {
                HStack { brandLabel; Spacer() }
                choices
            }.padding(.top, 6)
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
                if brand == .tcl || brand == .lg || brand == .bluetti {
                    Text(brand.rawValue).font(.system(size: brand == .bluetti ? 10 : 17, weight: .semibold))
                } else {
                    BrandLogo(brand: brand).frame(width: 36, height: 24)
                }
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
    var summaryOnly = false
    @ViewBuilder let controls: () -> Controls

    @ObservedObject private var ageSnapshot = ReadingAge.shared
    var body: some View {
        Group {
            if summaryOnly { compactCard }
            else { expandedCard }
        }.transaction { $0.animation = nil }
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
            .onTapGesture { if !selected { select() } }

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

    private var compactCard: some View {
        Group {
            if brand == .tcl {
                VStack(alignment: .leading, spacing: 3) { summaryNameButton; summaryReadings }
            } else {
                HStack(spacing: 8) {
                    Button(action: select) { ClimateArtwork(brand: .lg).frame(width: 44, height: 34) }.buttonStyle(.plain).accessibilityLabel("Open " + name)
                    VStack(alignment: .leading, spacing: 3) {
                        summaryNameButton
                        summaryReadings
                        if let livePower, powerOn != nil { Label(livePower, systemImage: "bolt.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(ice) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Open " + DeviceDisplayName.clean(name))
        }
        .deviceSurface(selected: selected)
    }
    private var summaryNameButton: some View {
        Button(action: select) { summaryName.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var summaryName: some View {
        HStack(spacing: 4) {
            Text(DeviceDisplayName.clean(name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Circle().fill(powerOn == true ? leafGreen : powerOn == false ? .red : .gray)
                .frame(width: 5, height: 5).accessibilityLabel(powerOn.map { $0 ? "ON" : "OFF" } ?? "Unknown")
        }
    }
    private var summaryReadings: some View {
        HStack(spacing: 3) {
            if powerOn != nil {
                ForEach(metrics.filter { ($0.label == "Room" || (powerOn == true && $0.label == "AC")) && $0.value.contains(where: { $0.isNumber }) }) { metric in
                    metricButton(metric, compact: true)
                }
            }
        }.fixedSize()
    }

    private var ecoEnabled: Bool { powerOn == true && metrics.first(where: { $0.label == "Eco" })?.value == "ON" }
    private var targetValue: String { metrics.first(where: { $0.label == "AC" })?.value ?? "—" }
    private var targetDegrees: Double? {
        Double(targetValue.prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.replacingOccurrences(of: ",", with: "."))
    }
    private func adjacentTemperature(_ delta: Int) -> Int? {
        guard let targetDegrees else { return nil }
        return delta < 0 ? temperatureOptions.filter { Double($0) < targetDegrees }.max() : temperatureOptions.filter { Double($0) > targetDegrees }.min()
    }
    private var temperatureControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Set temperature").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let changeTemperature {
                    temperatureStep(-1, change: changeTemperature)
                    HStack(spacing: 2) {
                        TemperaturePicker(value: targetValue, degrees: temperatureOptions, off: turnOff, choose: changeTemperature, fontSize: 38)
                        if ecoEnabled { Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(leafGreen) }
                    }
                    temperatureStep(1, change: changeTemperature)
                } else { TemperatureText(value: targetValue).font(.system(size: 28, weight: .semibold)) }
                Spacer(minLength: 2)
                if let directions { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 32); directions.frame(width: 116) }
                if let turnOff {
                    Button(action: turnOff) { Image(systemName: "power").font(.system(size: 22)).frame(width: 38, height: 36).contentShape(Rectangle()) }
                        .buttonStyle(.plain).deviceSurface(selected: false).foregroundStyle(powerOn == false ? Color.red : .white)
                        .help("Turn off").accessibilityLabel("Turn off " + DeviceDisplayName.clean(name)).disabled(powerOn != true)
                }
            }
        }
    }
    private func temperatureStep(_ delta: Int, change: @escaping (Int) -> Void) -> some View {
        let next = adjacentTemperature(delta)
        return Button { if let next { change(next) } } label: {
            Image(systemName: delta < 0 ? "minus" : "plus").font(.system(size: 18, weight: .medium))
                .frame(width: 30, height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.white.opacity(0.04), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)).disabled(next == nil || powerOn == nil)
            .accessibilityLabel(delta < 0 ? "Decrease set temperature" : "Increase set temperature")
    }
    private func metricButton(_ metric: DeviceMetric, compact: Bool) -> some View {
        Button(action: metric.toggle) {
            HStack(spacing: 3) {
                if compact {
                    Text(metric.label == "AC" ? "Set" : metric.label).foregroundStyle(.secondary)
                } else {
                    if metric.id == "energy" { Image(systemName: metric.symbol).foregroundStyle(ice) }
                    else { Text(metric.label == "AC" ? "Set" : metric.label).foregroundStyle(.secondary) }
                }
                TemperatureText(value: metric.value)
                if metric.label == "AC" && ecoEnabled { Image(systemName: "leaf.fill").foregroundStyle(leafGreen).font(.system(size: compact ? 8 : 10)) }
            }.font(.system(size: compact ? 10 : 13, weight: metric.visible ? .semibold : .regular)).monospacedDigit().lineLimit(1)
                .padding(.horizontal, compact ? 1 : 5).padding(.vertical, compact ? 1 : 4)
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
                    metricButton(metric, compact: false)
                }
            }
        }
    }
}

struct BrandLogo: View {
    let brand: Brand
    var body: some View {
        Group {
            switch brand {
            case .tuya:
                Text("tuya").font(.system(size: 13, weight: .bold)).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.6)
            case .deye:
                Text("Deye").font(.system(size: 14, weight: .heavy)).italic().foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .overlay(alignment: .topLeading) { Rectangle().fill(.red).frame(width: 3, height: 3).offset(x: 1, y: -1) }
            case .tcl: TCLLogo()
            case .lg:
                Image(nsImage: lgIcon()).resizable().scaledToFit()
            case .bluetti:
                if let image = BrandArtwork.bluetti { Image(nsImage: image).resizable().scaledToFit() }
                else { Text("BL").font(.caption.bold()) }
            }
        }.accessibilityLabel(brand.rawValue)
    }
}

struct TCLLogo: View {
    private static let image = Bundle.main.url(forResource: "TCLWordmark", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).renderingMode(.original).resizable().scaledToFit() }
            else { Text("TCL").font(.system(size: 10, weight: .black)).foregroundStyle(.red) }
        }.padding(2).background(.white, in: RoundedRectangle(cornerRadius: 3)).accessibilityLabel("TCL")
    }
}

// Menu commands are sent only after a value is picked.
struct CardMenus<Fan: View>: View {
    let eco: Bool?
    let toggleEco: () -> Void
    let fan: String
    var fanLevel: Int? = nil
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
                if !fan.isEmpty {
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

struct CoolingPresetRow: View {
    let enabled: (CoolingPreset) -> Bool
    let selected: (CoolingPreset) -> Bool
    let apply: (CoolingPreset) -> Void
    var showFanLevels = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CoolingPreset.allCases, id: \.self) { preset in
                Button { apply(preset) } label: {
                    HStack(spacing: 6) {
                        TemperatureText(value: preset.label)
                        if showFanLevels { FanLevelDots(level: FanIndicator.count(for: preset.speed)) }
                    }.font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 34)
                        .deviceSurface(selected: selected(preset))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!enabled(preset))
                    .accessibilityAddTraits(selected(preset) ? .isSelected : [])
            }
        }
    }
}

struct TemperaturePicker: View {
    let value:String
    let degrees:[Int]
    let off:(() -> Void)?
    let choose:(Int)->Void
    var fontSize: CGFloat = 15
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: { TemperatureText(value:value).font(.system(size:fontSize,weight:.semibold)).fixedSize() }
            .buttonStyle(.plain).help("Set temperature")
            .popover(isPresented:$presented,arrowEdge:.bottom) {
                let split = (degrees.count+1)/2
                VStack(spacing:6) {
                    ForEach(0..<split,id:\.self) { row in
                        HStack(spacing:8) {
                            ForEach(0..<2) { column in
                                let index = row + column * split
                                if degrees.indices.contains(index) {
                                    let degree = degrees[index]
                                    let selected = value.replacingOccurrences(of:"°",with:"").trimmingCharacters(in:.whitespaces) == String(degree)
                                    Button { choose(degree); presented = false } label: {
                                        Label { TemperatureText(value:String(degree)+" °C") } icon: { Image(systemName:"thermometer.medium") }
                                            .font(.system(size:14)).frame(width:92,height:32)
                                            .background(selected ? cobalt.opacity(0.6) : Color(nsColor:BarTheme.panel),in:RoundedRectangle(cornerRadius:4))
                                            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(selected ? Color.white : .clear,lineWidth:1))
                                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                                } else { Color.clear.frame(width:92,height:32) }
                            }
                        }
                    }
                    if let off { Button { off(); presented = false } label: { Label("OFF",systemImage:"power").foregroundStyle(.red).frame(maxWidth:.infinity,minHeight:28) }.buttonStyle(.plain) }
                }.padding(10).background(Color(nsColor:BarTheme.background))
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
