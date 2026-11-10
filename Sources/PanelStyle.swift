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
        self.foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 7)
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
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                Button(action: select) {
                    HStack {
                        Text(verbatim: name).fontWeight(selected ? .bold : .regular).lineLimit(1)
                        Spacer()
                        Text(status).font(.caption.bold())
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(selected ? "Selected" : "Not selected")
            }
            HStack(alignment: .top, spacing: 10) { metricButtons }
            if selected { controls() }
            HStack {
                Text(reading ? "Reading…" : readAt.map { "Last read " + $0.formatted(date: .omitted, time: .standard) } ?? "No reading yet")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    if reading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).frame(width: 26, height: 22).accessibilityLabel("Refresh " + name)
            }
        }.overviewSurface(selected: selected)
    }

    @ViewBuilder private var metricButtons: some View {
        ForEach(metrics) { metric in
            Button(action: metric.toggle) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(metric.label, systemImage: metric.symbol).font(.system(size: 10, weight: metric.visible ? .bold : .regular))
                        .foregroundStyle(ice)
                    Text(verbatim: metric.value).monospacedDigit()
                        .font(.system(size: 16, weight: metric.visible || metric.value == "OFF" ? .bold : .regular, design: .rounded))
                }.lineLimit(1).minimumScaleFactor(0.78).contentShape(Rectangle())
            }.buttonStyle(.plain).help((metric.visible ? "Hide " : "Show ") + metric.label + " in menu bar")
                .accessibilityValue(metric.visible ? "Visible in menu bar" : "Hidden from menu bar")
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
        HStack(spacing: 10) {
            if !degrees.isEmpty {
                Menu {
                    if let off { Button("OFF", action: off); Divider() }
                    ForEach(degrees, id: \.self) { degree in
                        Button(String(degree) + "°") { change(degree) }
                    }
                } label: { Label(target, systemImage: "thermometer.medium") }
                .accessibilityLabel("Set temperature").accessibilityValue(target)
            }
            if !fan.isEmpty {
                Menu(content: fanOptions) { Label(fan, systemImage: "fanblades") }
                    .accessibilityLabel("Set fan speed").accessibilityValue(fan)
            }
            if let eco { Button("Eco " + (eco ? "ON" : "OFF"), action: toggleEco).buttonStyle(.bordered).fontWeight(.bold).foregroundStyle(eco ? Color.green : Color.secondary) }
        }.menuStyle(.borderedButton).controlSize(.small).fixedSize()
    }
}
