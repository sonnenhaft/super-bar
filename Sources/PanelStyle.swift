import SwiftUI
import UniformTypeIdentifiers

let cobalt = Color(nsColor: BarTheme.cobalt)
let ice = Color(red: 0.32, green: 0.77, blue: 0.87)
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
            .background(Color(nsColor:selected ? BarTheme.navy : BarTheme.panel),in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(Color.white.opacity(0.16),lineWidth:0.5))
            .shadow(color:.black.opacity(0.12),radius:2,y:1)
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

struct CardSelectionButton: NSViewRepresentable {
    let name: String
    var dragID = ""
    var dragGroup = ""
    let selected: Bool
    let select: () -> Void

    final class Control: HoldDragButton {
        var selectDevice: (() -> Void)?
        var active = false
        var selectionStarted: TimeInterval?
        @objc func choose() {
            guard !active else { return }
            selectionStarted = ProcessInfo.processInfo.systemUptime
            active = true
            font = .systemFont(ofSize: 15, weight: .bold)
            setAccessibilityValue("Selected")
            needsDisplay = true
            displayIfNeeded()
            selectDevice?()
        }
        override func mouseDown(with event: NSEvent) {
            // Selection is a mouse-down action; do not enter NSButton's tracking loop.
            choose()
            armDrag(event)
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if active, let start = selectionStarted {
                selectionStarted = nil
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                DispatchQueue.main.async { UserDefaults.standard.set(ms, forKey: "lastDeviceSelectionDrawMilliseconds") }
            }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.sendAction(on: [.leftMouseDown])
        button.target = button
        button.action = #selector(Control.choose)
        return button
    }
    func updateNSView(_ button: Control, context: Context) {
        button.dragID = dragID; button.dragGroup = dragGroup
        button.selectDevice = select
        button.active = selected
        button.title = DeviceDisplayName.clean(name)
        button.font = .systemFont(ofSize: 15, weight: selected ? .bold : .regular)
        button.contentTintColor = .white
        button.setAccessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct ClimateDeviceCard<Controls: View>: View {
    let brand: Brand
    let iconVisible: Bool
    let toggleIcon: () -> Void
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
    var reorderID = ""
    var knownIDs: [String] = []
    var directions: AnyView? = nil
    @ViewBuilder let controls: () -> Controls

    @ObservedObject private var ageSnapshot = ReadingAge.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardSelectionButton(name: name, dragID:reorderID, dragGroup:brand.rawValue, selected: selected, select: select)
                    .frame(width:min(200,ceil((DeviceDisplayName.clean(name) as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:15,weight:selected ? .bold : .regular)]).width)+6),height:24)
                if let powerOn {
                    if powerOn { Circle().fill(Color.green).frame(width:6,height:6).accessibilityLabel("ON") }
                    else { Image(systemName:"power").foregroundStyle(.red).font(.system(size:14,weight:.semibold)).accessibilityLabel("OFF") }
                }
                Spacer(minLength:8)
                if selected {
                    CardRefresh(reading:reading,status:status,readAt:readAt,refresh:refresh).frame(width:24,height:24)
                }
                if let temperature = metrics.first(where:{ $0.label == (powerOn == false ? "Room" : "AC") })?.value {
                    if let changeTemperature {
                        TemperaturePicker(value:temperature,degrees:temperatureOptions,off:turnOff,choose:changeTemperature)
                    } else { TemperatureText(value:temperature).font(.system(size:15)).fixedSize() }
                }

            }
            .contentShape(Rectangle())
            .onTapGesture { if !selected { select() } }

            if selected {
            if let livePower {
                Label(livePower, systemImage:"bolt.fill").foregroundStyle(Color(nsColor:BarTheme.energy)).monospacedDigit()
            }
            HStack(alignment: .center, spacing: 8) {
                metricButtons
                Spacer(minLength: 8)
                if let directions { directions.frame(width:112) }
            }
            HStack(spacing:8) {
                Text(CardRefresh.status(reading:reading,status:status,readAt:readAt))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                controls()
            }
            }
        }.overviewSurface(selected: selected)
        .transaction { $0.animation = nil }
        .onDrop(of:[UTType.utf8PlainText.identifier], delegate:CardDrop(group:brand.rawValue,target:reorderID,known:knownIDs))
        .contextMenu {
            ForEach(metrics) { metric in
                Button((metric.visible ? "Unpin " : "Pin ") + metric.label, action: metric.toggle)
            }
        }
    }

    @ViewBuilder private var metricButtons: some View {
        let rows = metrics.filter {
            !["AC", "Fan", "Eco"].contains($0.label) && !$0.value.isEmpty && $0.value != "—"
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { metric in
                    Button(action: metric.toggle) {
                        HStack(spacing: 4) {
                            Image(systemName: metric.symbol).foregroundStyle(metric.id == "energy" ? Color(nsColor: BarTheme.energy) : ice).font(.system(size: 14)).frame(width: 17)
                            if metric.id != "energy" { Text(metric.label).frame(width: 42, alignment: .leading) }
                            TemperatureText(value:metric.value).monospacedDigit()
                        }
                        .font(.system(size: 13, weight: metric.visible ? .bold : .regular))
                        .foregroundStyle(ice).lineLimit(1).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help((metric.visible ? "Hide " : "Show ") + metric.label + " in menu bar")
                    .accessibilityValue(metric.visible ? "Visible in menu bar" : "Hidden from menu bar")
                }
            }
        }
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
    let degrees: [Int]
    let target: String
    let off: (() -> Void)?
    let eco: Bool?
    let toggleEco: () -> Void
    let change: (Int) -> Void
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
                            .foregroundStyle(eco ? Color.green : .secondary)
                            .frame(width: 25, height: 26).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Eco").accessibilityValue(eco ? "ON" : "OFF")
                     .help("Eco " + (eco ? "ON" : "OFF"))
                }
                if !fan.isEmpty {
                    Menu(content: fanOptions) {
                        HStack(spacing: 6) {
                            Text(fan)
                            if let fanLevel {
                                VStack(spacing: 1) {
                                    ForEach((0..<3).reversed(), id: \.self) { level in
                                        Circle().fill(Color.white.opacity(level < fanLevel ? 1 : 0.16))
                                            .frame(width: 5, height: 5)
                                    }
                                }.accessibilityLabel("Fan speed " + String(fanLevel))
                            } else { Image(systemName: "fanblades") }
                        }
                    }
                        .climateMenu(width: 112)
                        .accessibilityLabel("Set fan speed").accessibilityValue(fan)
                }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
        .fixedSize().padding(.top, 4)
    }

}

extension View {
    func climateMenu(width: CGFloat? = nil) -> some View {
        self.menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
            .font(.system(size: 13)).foregroundStyle(.white).tint(.white)
            .padding(.horizontal, 6).frame(width: width, height: 27)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(Color(nsColor: BarTheme.navy), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(cobalt.opacity(0.65), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct CoolingPresetRow: View {
    let enabled: (CoolingPreset) -> Bool
    let selected: (CoolingPreset) -> Bool
    let apply: (CoolingPreset) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CoolingPreset.allCases, id: \.self) { preset in
                Button { apply(preset) } label: {
                    TemperatureText(value:preset.label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 29)
                        .background(selected(preset) ? cobalt : Color(nsColor: BarTheme.panel),
                                    in: RoundedRectangle(cornerRadius: 4))
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
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: { TemperatureText(value:value).font(.system(size:15,weight:.regular)).fixedSize() }
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
