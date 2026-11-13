import SwiftUI

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
