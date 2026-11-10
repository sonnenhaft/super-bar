import SwiftUI

let cobalt = Color(nsColor: BarTheme.cobalt)
let ice = Color(red: 0.32, green: 0.77, blue: 0.87)
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: BarTheme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09)))
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
        self.foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(nsColor: selected ? BarTheme.navy : BarTheme.panel), Color(nsColor: selected ? BarTheme.ocean : BarTheme.navy)], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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

private struct CardSelectionButton: NSViewRepresentable {
    let name: String
    let selected: Bool
    let select: () -> Void

    final class Control: NSButton {
        var selectDevice: (() -> Void)?
        var active = false
        var selectionStarted: TimeInterval?
        @objc func choose() {
            guard !active else { return }
            selectionStarted = ProcessInfo.processInfo.systemUptime
            selectDevice?()
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
        button.selectDevice = select
        button.active = selected
        button.title = name
        button.font = .systemFont(ofSize: 13, weight: selected ? .bold : .regular)
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
    var directions: AnyView? = nil
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button(action: toggleIcon) {
                    HStack(spacing: 4) {
                        if brand == .lg { Image(nsImage: lgIcon()) }
                        else { TCLLogo().frame(width: 28, height: 14) }
                        Image(systemName: iconVisible ? "eye.fill" : "eye.slash")
                            .font(.system(size: 10)).foregroundStyle(iconVisible ? ice : Color.white.opacity(0.65))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(brand.rawValue + " icon")
                    .accessibilityValue(iconVisible ? "Visible in menu bar" : "Hidden from menu bar")
                    .help((iconVisible ? "Hide " : "Show ") + brand.rawValue + " icon in menu bar")
                CardSelectionButton(name: name, selected: selected, select: select)
                    .frame(maxWidth: .infinity, minHeight: 20)
                if !["ON", "OFF", "Connected"].contains(status) { Text(status).font(.caption.bold()) }
            }
            HStack(alignment: .center, spacing: 8) {
                metricButtons
                Spacer(minLength: 4)
                controls()
            }
            if let directions { directions }
            HStack {
                Text(reading ? "Reading…" : readAt.map { "Last read " + $0.formatted(date: .omitted, time: .standard) } ?? "No reading yet")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    if reading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                }.buttonStyle(.plain).frame(width: 20, height: 16).accessibilityLabel("Refresh " + name)
            }
        }.overviewSurface(selected: selected)
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { metric in
                    Button(action: metric.toggle) {
                        HStack(spacing: 4) {
                            Image(systemName: metric.symbol).frame(width: 12)
                            Text(metric.label).frame(width: 39, alignment: .leading)
                            Text(verbatim: metric.value).monospacedDigit()
                        }
                        .font(.system(size: 11, weight: metric.visible ? .bold : .regular))
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
    @ViewBuilder let fanOptions: () -> Fan
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if !degrees.isEmpty || off != nil {
                Menu {
                    if let off { Button("OFF", action: off); Divider() }
                    ForEach(degrees, id: \.self) { degree in
                        Button(String(degree) + "°") { change(degree) }
                    }
                } label: { menuLabel(target, symbol: "thermometer.medium") }
                .accessibilityLabel("Set temperature").accessibilityValue(target)
            }
            HStack(spacing: 4) {
                if let eco {
                    Button(action: toggleEco) {
                        Image(systemName: eco ? "leaf.fill" : "leaf")
                            .font(.system(size: 10))
                            .foregroundStyle(eco ? Color.green : .secondary)
                            .frame(width: 20, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Eco").accessibilityValue(eco ? "ON" : "OFF")
                     .help("Eco " + (eco ? "ON" : "OFF"))
                }
                if !fan.isEmpty {
                    Menu(content: fanOptions) { menuLabel(fan, symbol: "fanblades") }
                        .accessibilityLabel("Set fan speed").accessibilityValue(fan)
                }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.mini)
        .fixedSize()
    }

    private func menuLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).resizable().scaledToFit().frame(width: 11, height: 11)
            Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .font(.system(size: 11)).padding(.horizontal, 6)
        .frame(width: 104, height: 22)
        .foregroundStyle(.white)
        .background(Color(nsColor: BarTheme.navy), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cobalt.opacity(0.65), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

struct CoolingPresetRow: View {
    let enabled: (CoolingPreset) -> Bool
    let selected: (CoolingPreset) -> Bool
    let apply: (CoolingPreset) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(CoolingPreset.allCases, id: \.self) { preset in
                Button { apply(preset) } label: {
                    Text(preset.label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 29)
                        .background(selected(preset) ? cobalt : Color(nsColor: BarTheme.panel),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!enabled(preset))
                    .accessibilityAddTraits(selected(preset) ? .isSelected : [])
            }
        }
    }
}
