import SwiftUI

// Identical control layout and setpoint stepping on Mac and iPhone.
struct PanelTemperatureControl: View {
    var name: String
    var targetValue: String
    var powerOn: Bool?
    var temperatureOptions: [Int]
    var changeTemperature: ((Int) -> Void)?
    var turnOff: (() -> Void)? = nil
    var ecoEnabled = false
    var directions: AnyView? = nil
    var trailingControl: AnyView? = nil
    #if os(iOS)
    private let stepSize: CGFloat = 44
    private let stepHeight: CGFloat = 44
    #else
    private let stepSize: CGFloat = 30
    private let stepHeight: CGFloat = 34
    #endif
    private var targetDegrees: Double? {
        Double(targetValue.prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.replacingOccurrences(of: ",", with: "."))
    }
    private func adjacentTemperature(_ delta: Int) -> Int? {
        guard let targetDegrees else { return nil }
        return delta < 0 ? temperatureOptions.filter { Double($0) < targetDegrees }.max() : temperatureOptions.filter { Double($0) > targetDegrees }.min()
    }
    var body: some View {
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
                } else { Text(targetValue).font(.system(size: 28, weight: .semibold)) }
                if let trailingControl { trailingControl }
                Spacer(minLength: 2)
                if let directions { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 32); directions.frame(width: 116) }
                if let turnOff {
                    Button(action: turnOff) { Image(systemName: "power").font(.system(size: 22)).frame(width: 38, height: 36).contentShape(Rectangle()) }
                        .buttonStyle(.plain).deviceSurface(selected: false).foregroundStyle(powerOn == false ? Color.gray : .white)
                        .help("Turn off").accessibilityLabel("Turn off " + DeviceDisplayName.clean(name)).disabled(powerOn != true)
                }
            }
        }
    }
    private func temperatureStep(_ delta: Int, change: @escaping (Int) -> Void) -> some View {
        let next = adjacentTemperature(delta)
        return Button { if let next { change(next) } } label: {
            Image(systemName: delta < 0 ? "minus" : "plus").font(.system(size: 18, weight: .medium))
                .frame(width: stepSize, height: stepHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.white.opacity(0.04), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)).disabled(next == nil || powerOn == nil)
            .accessibilityLabel(delta < 0 ? "Decrease set temperature" : "Increase set temperature")
    }
}

struct TemperaturePicker: View {
    let value:String
    let degrees:[Int]
    let off:(() -> Void)?
    let choose:(Int)->Void
    var fontSize: CGFloat = 15
    @State private var presented = false
    private var popoverEdge: Edge {
        #if os(iOS)
        return .top
        #else
        return .bottom
        #endif
    }
    var body: some View {
        Button { presented.toggle() } label: { Text(value).font(.system(size:fontSize,weight:.semibold)).fixedSize() }
            .buttonStyle(.plain).help("Set temperature")
            .accessibilityLabel("Choose temperature, " + value)
            .disabled(degrees.isEmpty)
            .popover(isPresented:$presented,arrowEdge:popoverEdge) {
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
                                        Label { Text(String(degree)+" °C") } icon: { Image(systemName:"thermometer.medium") }
                                            .font(.system(size:14)).frame(width:92,height:32)
                                            .background(selected ? cobalt.opacity(0.6) : SuperBarPanelStyle.panel,in:RoundedRectangle(cornerRadius:4))
                                            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(selected ? Color.white : .clear,lineWidth:1))
                                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                                } else { Color.clear.frame(width:92,height:32) }
                            }
                        }
                    }
                    if let off { Button { off(); presented = false } label: { Label("OFF",systemImage:"power").foregroundStyle(.red).frame(maxWidth:.infinity,minHeight:28) }.buttonStyle(.plain) }
                }.padding(10).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
}

// The same vector vocabulary is used by the fan picker and cooling presets.
enum FanSpeedSymbol: Hashable {
    case turbo, high, mediumHigh, medium, mediumLow, low, minimum
    case quiet, automatic, unknown
}

struct FanSpeedOption: Identifiable {
    let id: Int
    let name: String
    let symbol: FanSpeedSymbol
}

struct FanSpeedIcon: View {
    let symbol: FanSpeedSymbol

    var body: some View {
        GeometryReader { geometry in
            FanSpeedGlyph(symbol: symbol)
                .stroke(style: StrokeStyle(lineWidth: min(geometry.size.width, geometry.size.height) / 18,
                                           lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct FanSpeedGlyph: Shape {
    let symbol: FanSpeedSymbol

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch symbol {
        case .turbo: path = blades(6)
        case .high: path = blades(5)
        case .mediumHigh: path = blades(4)
        case .medium: path = blades(3)
        case .mediumLow: path = blades(2)
        case .low, .minimum:
            // One horizontal curled blade, as in the lowest-speed symbol.
            path.move(to: CGPoint(x: 10, y: 12))
            path.addCurve(to: CGPoint(x: 11, y: 21), control1: CGPoint(x: 5, y: 12), control2: CGPoint(x: 5, y: 20))
            path.addCurve(to: CGPoint(x: 25, y: 18), control1: CGPoint(x: 16, y: 23), control2: CGPoint(x: 23, y: 21))
            path.addCurve(to: CGPoint(x: 17, y: 16), control1: CGPoint(x: 20, y: 20), control2: CGPoint(x: 18, y: 19))
            path.addCurve(to: CGPoint(x: 10, y: 12), control1: CGPoint(x: 15, y: 13), control2: CGPoint(x: 13, y: 12))
            path.closeSubpath()
        case .quiet:
            // Ear outline and a diagonal mute stroke; no text is baked in.
            path.move(to: CGPoint(x: 9, y: 13))
            path.addCurve(to: CGPoint(x: 15, y: 4), control1: CGPoint(x: 7, y: 7), control2: CGPoint(x: 11, y: 4))
            path.addCurve(to: CGPoint(x: 24, y: 12), control1: CGPoint(x: 21, y: 2), control2: CGPoint(x: 25, y: 7))
            path.addCurve(to: CGPoint(x: 19, y: 22), control1: CGPoint(x: 24, y: 17), control2: CGPoint(x: 19, y: 18))
            path.addCurve(to: CGPoint(x: 13, y: 28), control1: CGPoint(x: 18, y: 25), control2: CGPoint(x: 17, y: 28))
            path.addCurve(to: CGPoint(x: 9, y: 23), control1: CGPoint(x: 10, y: 28), control2: CGPoint(x: 8, y: 26))
            path.move(to: CGPoint(x: 12, y: 12))
            path.addCurve(to: CGPoint(x: 18, y: 8), control1: CGPoint(x: 11, y: 8), control2: CGPoint(x: 15, y: 7))
            path.addCurve(to: CGPoint(x: 19, y: 15), control1: CGPoint(x: 22, y: 9), control2: CGPoint(x: 21, y: 13))
            path.addCurve(to: CGPoint(x: 14, y: 18), control1: CGPoint(x: 17, y: 17), control2: CGPoint(x: 14, y: 15))
            path.addCurve(to: CGPoint(x: 15, y: 22), control1: CGPoint(x: 13, y: 19), control2: CGPoint(x: 13, y: 22))
            path.move(to: CGPoint(x: 5, y: 28))
            path.addLine(to: CGPoint(x: 27, y: 4))
        case .automatic:
            path.move(to: CGPoint(x: 10, y: 12))
            path.addLine(to: CGPoint(x: 14, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 12))
            path.move(to: CGPoint(x: 12, y: 9))
            path.addLine(to: CGPoint(x: 16, y: 9))
            path.move(to: CGPoint(x: 5, y: 16))
            path.addLine(to: CGPoint(x: 23, y: 16))
            path.addCurve(to: CGPoint(x: 23, y: 8), control1: CGPoint(x: 29, y: 16), control2: CGPoint(x: 29, y: 8))
            path.move(to: CGPoint(x: 5, y: 21))
            path.addLine(to: CGPoint(x: 19, y: 21))
            path.addCurve(to: CGPoint(x: 19, y: 29), control1: CGPoint(x: 25, y: 21), control2: CGPoint(x: 25, y: 29))
            path.move(to: CGPoint(x: 5, y: 26))
            path.addLine(to: CGPoint(x: 12, y: 26))
        case .unknown:
            path.move(to: CGPoint(x: 10, y: 10))
            path.addCurve(to: CGPoint(x: 16, y: 5), control1: CGPoint(x: 10, y: 7), control2: CGPoint(x: 13, y: 5))
            path.addCurve(to: CGPoint(x: 22, y: 11), control1: CGPoint(x: 20, y: 5), control2: CGPoint(x: 23, y: 7))
            path.addCurve(to: CGPoint(x: 16, y: 20), control1: CGPoint(x: 22, y: 15), control2: CGPoint(x: 16, y: 15))
            path.move(to: CGPoint(x: 16, y: 26))
            path.addLine(to: CGPoint(x: 16, y: 26.1))
        }
        let scale = min(rect.width, rect.height) / 32
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: rect.midX - 16 * scale, y: rect.midY - 16 * scale))
    }

    private func blades(_ count: Int) -> Path {
        var blade = Path()
        blade.move(to: CGPoint(x: 16, y: 13.5))
        blade.addCurve(to: CGPoint(x: 15.6, y: 4), control1: CGPoint(x: 14, y: 9), control2: CGPoint(x: 12.7, y: 6))
        blade.addCurve(to: CGPoint(x: 19.6, y: 7.2), control1: CGPoint(x: 18.2, y: 2.3), control2: CGPoint(x: 21, y: 4.6))
        blade.addCurve(to: CGPoint(x: 17, y: 12.5), control1: CGPoint(x: 18.7, y: 9.1), control2: CGPoint(x: 16.7, y: 9.6))
        blade.addQuadCurve(to: CGPoint(x: 16, y: 13.5), control: CGPoint(x: 16.8, y: 13.5))
        blade.closeSubpath()
        var result = Path()
        for index in 0..<count {
            // Two-blade speed uses the horizontal pair shown in the reference.
            let offset = count == 2 ? Double.pi / 2 : 0
            let angle = CGFloat(Double(index) * 2 * Double.pi / Double(count) + offset)
            let transform = CGAffineTransform(translationX: 16, y: 16)
                .rotated(by: angle).translatedBy(x: -16, y: -16)
            result.addPath(blade, transform: transform)
        }
        return result
    }
}

struct PanelFanSpeedPicker: View {
    let options: [FanSpeedOption]
    let selected: Int?
    let currentSymbol: FanSpeedSymbol
    let currentName: String
    let choose: (Int) -> Void
    @State private var presented = false

    #if os(iOS)
    private let optionSize: CGFloat = 48
    private let buttonHeight: CGFloat = 44
    private let popoverEdge: Edge = .top
    #else
    private let optionSize: CGFloat = 36
    private let buttonHeight: CGFloat = 34
    private let popoverEdge: Edge = .bottom
    #endif

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                FanSpeedIcon(symbol: currentSymbol).frame(width: 25, height: 25)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .frame(width: 58, height: buttonHeight)
            .contentShape(Rectangle())
            .deviceSurface(selected: presented)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help("Fan: " + currentName)
        .accessibilityLabel("Set fan speed")
        .accessibilityValue(currentName)
        .disabled(options.isEmpty)
        .popover(isPresented: $presented, arrowEdge: popoverEdge) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(optionSize), spacing: 8), count: 4), spacing: 8) {
                ForEach(options) { option in
                    Button {
                        presented = false
                        choose(option.id)
                    } label: {
                        FanSpeedIcon(symbol: option.symbol)
                            .frame(width: 27, height: 27)
                            .frame(width: optionSize, height: optionSize)
                            .contentShape(Rectangle())
                            .deviceSurface(selected: selected == option.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected == option.id ? SuperBarPanelStyle.cyan : .white)
                    .help(option.name)
                    .accessibilityLabel(option.name)
                    .accessibilityAddTraits(selected == option.id ? .isSelected : [])
                }
            }
            .padding(10)
            .background(PanelPalette.background.color)
            #if os(iOS)
                .presentationCompactAdaptation(.popover)
            #endif
        }
    }
}

struct TCLAirflowPicker: View {
    let ac: Aircon
    let vertical: Bool
    let choose: (String, Int) -> Void
    @State private var presented = false
    private var axis: String { vertical ? "vertical" : "horizontal" }
    private var title: String { vertical ? "Vertical" : "Horizontal" }
    private var hasDirection: Bool { ac.has(axis + "Direction") }
    private var options: [Int] {
        hasDirection ? Array(9...13) + Array(1...(vertical ? 3 : 4)) + [8] : [1, 0]
    }
    private var selected: Int? {
        guard hasDirection else { return ac.code(axis + "Switch") }
        let code = ac.code(axis + "Direction")
        return ac.code(axis + "Switch") == 0 && !(9...13).contains(code ?? -1) ? 8 : code
    }
    private func label(_ option: Int) -> String {
        if !hasDirection { return option == 0 ? "Stop" : "Swing" }
        if option == 8 { return "Stop" }
        if (9...13).contains(option) { return (vertical ? verticalStops : horizontalStops)[option - 9] }
        let swings = vertical ? ["Up and down", "Upper zone", "Lower zone"] : ["Left to right", "Left zone", "Center zone", "Right zone"]
        return swings[option - 1]
    }
    #if os(iOS)
    private let buttonHeight: CGFloat = 44
    private let optionSize: CGFloat = 44
    private let popoverEdge: Edge = .top
    #else
    private let buttonHeight: CGFloat = 34
    private let optionSize: CGFloat = 36
    private let popoverEdge: Edge = .bottom
    #endif
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 3) {
                icon(selected).frame(width: 28, height: 28)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.frame(width: 58, height: buttonHeight).deviceSurface(selected: presented)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!hasDirection && !ac.has(axis + "Switch"))
            .accessibilityLabel(title + " air direction").accessibilityValue(ac.vane(vertical))
            .help(title + ": " + ac.vane(vertical))
            .popover(isPresented: $presented, arrowEdge: popoverEdge) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(optionSize), spacing: 8), count: min(5, options.count)), spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            presented = false
                            choose(axis + (hasDirection ? "Direction" : "Switch"), option)
                        } label: {
                            icon(option).frame(width: 28, height: 28)
                                .frame(width: optionSize, height: optionSize)
                                .deviceSurface(selected: selected == option)
                        }.buttonStyle(.plain)
                            .foregroundStyle(selected == option ? SuperBarPanelStyle.cyan : .white)
                            .accessibilityLabel(label(option)).help(label(option))
                            .accessibilityAddTraits(selected == option ? .isSelected : [])
                    }
                }.padding(12).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
    @ViewBuilder private func icon(_ option: Int?) -> some View {
        let code = hasDirection ? option : (option == 1 ? 1 : 8)
        if let code, let url = Bundle.main.url(forResource: "TCL-\(axis)-\(code)", withExtension: "png") {
            #if os(iOS)
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #else
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #endif
        } else {
            Image(systemName: option == nil ? "questionmark.circle" : "stop.circle").resizable().scaledToFit()
        }
    }
}
