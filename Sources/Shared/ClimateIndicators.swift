import SwiftUI

// The same vector vocabulary is used by the fan picker and cooling presets.
enum FanSpeedSymbol: String {
    case turbo, high, mediumHigh, medium, mediumLow, low, minimum
    case quiet, automatic, unknown
}

struct ClimateIndicators: Equatable {
    enum Fan: Equatable {
        case tcl(FanSpeedSymbol)
        case lg(Int)
    }
    var eco = false
    var fan: Fan?
    init(eco: Bool = false, tcl: FanSpeedSymbol? = nil) {
        self.eco = eco
        if let tcl, tcl != .unknown { fan = .tcl(tcl) }
    }
    init(eco: Bool, lgSpeed: String?) {
        self.eco = eco
        if let level = Self.lgLevel(lgSpeed) { fan = .lg(level) }
    }
    static func lgLevel(_ speed: String?) -> Int? {
        switch speed?.uppercased() { case "LOW": return 1; case "MID": return 2; case "HIGH": return 3; default: return nil }
    }
    var label: String {
        var labels = eco ? ["Eco"] : []
        switch fan {
        case .lg(let level): labels.append("Fan " + ["Low", "Medium", "High"][level - 1])
        case .tcl(let speed):
            switch speed {
            case .mediumLow: labels.append("Fan Medium-low")
            case .mediumHigh: labels.append("Fan Medium-high")
            default: labels.append("Fan " + speed.rawValue.capitalized)
            }
        case nil: break
        }
        return labels.joined(separator: ", ")
    }
}

struct ClimateEcoIcon: View {
    static let symbol = "leaf.fill"
    var enabled = true
    var color = leafGreen
    var body: some View {
        Image(systemName: enabled ? Self.symbol : "leaf")
            .foregroundStyle(enabled ? color : .secondary)
    }
}

struct ClimateIndicatorRow: View {
    let indicators: ClimateIndicators
    let size: CGFloat
    var reservesSpace = false
    var ecoColor = leafGreen
    var body: some View {
        if reservesSpace || indicators.eco || indicators.fan != nil {
            HStack(spacing: max(1, size / 6)) {
                if indicators.eco { ClimateEcoIcon(color: ecoColor).font(.system(size: size * 0.8)) }
                switch indicators.fan {
                case .tcl(let speed): FanSpeedIcon(symbol: speed).frame(width: size, height: size)
                case .lg(let level): FanLevelDots(level: level, height: size)
                case nil: EmptyView()
                }
            }.foregroundStyle(.white).fixedSize()
                .frame(width: reservesSpace ? size * 2 + max(1, size / 6) : nil, height: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(indicators.label)
        }
    }
}

struct FanSpeedIcon: View {
    let symbol: FanSpeedSymbol

    var body: some View {
        GeometryReader { geometry in
            let glyph = FanSpeedGlyph(symbol: symbol)
            if symbol == .turbo {
                glyph.fill(.white)
            } else {
                glyph.stroke(style: StrokeStyle(lineWidth: min(geometry.size.width, geometry.size.height) / 18,
                                                lineCap: .round, lineJoin: .round))
            }
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
        case .turbo: path = flexedArms()
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

    private func flexedArms() -> Path {
        // Trace from the waist around one elbow, fist, shoulder and up to the crown.
        // Mirroring the contour keeps both arms legible at the preset's small size.
        var half = Path()
        half.move(to: CGPoint(x: 16, y: 26.7))
        half.addLine(to: CGPoint(x: 12.7, y: 26.7))
        half.addQuadCurve(to: CGPoint(x: 10.2, y: 22.1), control: CGPoint(x: 11.8, y: 24))
        half.addCurve(to: CGPoint(x: 1.2, y: 16), control1: CGPoint(x: 6.5, y: 20.8), control2: CGPoint(x: 3.3, y: 18.5))
        half.addQuadCurve(to: CGPoint(x: 1.1, y: 14.9), control: CGPoint(x: 0.6, y: 15.4))
        half.addLine(to: CGPoint(x: 7.9, y: 5.9))
        half.addQuadCurve(to: CGPoint(x: 9, y: 5.7), control: CGPoint(x: 8.4, y: 5.2))
        half.addLine(to: CGPoint(x: 10.5, y: 7.1))
        half.addQuadCurve(to: CGPoint(x: 10, y: 7.9), control: CGPoint(x: 11.1, y: 7.9))
        half.addLine(to: CGPoint(x: 7.9, y: 7.9))
        half.addQuadCurve(to: CGPoint(x: 7.7, y: 15.3), control: CGPoint(x: 7.4, y: 12))
        half.addQuadCurve(to: CGPoint(x: 12.9, y: 15.5), control: CGPoint(x: 10.6, y: 12.7))
        half.addQuadCurve(to: CGPoint(x: 14.5, y: 14.1), control: CGPoint(x: 14.1, y: 15.4))
        half.addCurve(to: CGPoint(x: 13.7, y: 10.1), control1: CGPoint(x: 13.7, y: 13.3), control2: CGPoint(x: 13.3, y: 11.8))
        half.addQuadCurve(to: CGPoint(x: 16, y: 8.2), control: CGPoint(x: 14, y: 8.2))
        half.closeSubpath()

        var silhouette = half
        silhouette.addPath(half, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 32, ty: 0))
        return silhouette
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

// The same three vertical dots represent LG fan speeds everywhere.
struct FanLevelDots: View {
    let level: Int
    var height: CGFloat = 17
    var body: some View {
        VStack(spacing: height / 17) {
            ForEach((0..<3).reversed(), id: \.self) { index in
                Circle().fill(.white.opacity(index < level ? 1 : 0.16)).frame(width: height * 5 / 17, height: height * 5 / 17)
            }
        }.frame(width: height * 5 / 17, height: height)
            .accessibilityLabel("Fan speed " + String(level))
    }
}
