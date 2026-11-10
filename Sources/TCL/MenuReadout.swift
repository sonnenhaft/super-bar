import AppKit
import SwiftUI

struct MenuReadout: View {
    var size: CGFloat = 12
    var textColor: NSColor? = nil
    let ac: Aircon?
    let visible: Set<ReadoutField>
    let energyText: String?
    var body: some View {
        HStack(spacing: 4) {
            if visible.contains(.icon) || ac?.power == false {
                TCLLogo().frame(width: 30, height: 15)
            }
            if let ac, ac.power != false {
                if visible.contains(.target) {
                    Text(ac.acTemperature).fontWeight(ac.acTemperature == "OFF" ? .bold : .semibold)
                }
                if visible.contains(.target) && visible.contains(.indoor) { Text("/") }
                if visible.contains(.indoor) { Text(tempText(ac.indoor)).fontWeight(.semibold) }
                if visible.contains(.power), let on = ac.power {
                    Image(systemName: on ? "power.circle.fill" : "power.circle").font(.system(size: max(7, size - 2)))
                }
                if visible.contains(.fan) {
                    HStack(spacing: 2) {
                        Image(systemName: "fanblades").font(.system(size: max(7, size - 2), weight: .medium))
                        Text(Self.speed(ac)).font(.system(size: max(7, size - 2), weight: .semibold)).monospacedDigit()
                    }
                }
                if visible.contains(.vertical) {
                    VaneIndicator(vertical: true, direction: ac.code("verticalDirection"), motor: ac.code("verticalSwitch"))
                }
                if visible.contains(.horizontal) {
                    VaneIndicator(vertical: false, direction: ac.code("horizontalDirection"), motor: ac.code("horizontalSwitch"))
                }
                if visible.contains(.eco), ac.code("ECO") == 1 {
                    Image(systemName: "leaf.fill").font(.system(size: max(7, size - 2))).foregroundStyle(.green)
                }
                if visible.contains(.energy), let energyText {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                        Text(energyText).monospacedDigit()
                    }.font(.system(size: max(7, size - 2), weight: .medium))
                }
            }
        }.font(.system(size: size)).monospacedDigit().foregroundStyle(Color(nsColor: textColor ?? .labelColor)).frame(height: 22).fixedSize()
    }
    private static func speed(_ ac: Aircon) -> String {
        guard ac.has(ac.fanField) else { return "–" }
        if ac.code("turbo") == 1 { return "T" }
        if ac.code("silenceSwitch") == 1 { return "S" }
        let speed = ac.code(ac.fanField)
        if ac.fanField == "windSpeed7Gear" {
            if speed == 0 || ac.code("windSpeedAutoSwitch") == 1 { return "A" }
            if speed == 7 { return "T" }
            return speed.map(String.init) ?? "–"
        }
        return [0:"A", 2:"Lo", 3:"M−", 4:"M", 5:"M+", 6:"Hi"][speed ?? -1] ?? "–"
    }
}

// A dot locates one of the five stops. A double arrow spans the active swing
// zone. A dashed track means the unit did not report its stopped position.
private struct VaneIndicator: View {
    let vertical: Bool
    let direction: Int?
    let motor: Int?
    var body: some View {
        Canvas { context, size in
            let range = CGFloat(11)
            func point(_ level: CGFloat, cross: CGFloat = 0) -> CGPoint {
                let offset = (level / 4 - 0.5) * range
                return CGPoint(x: size.width / 2 + (vertical ? cross : offset),
                               y: size.height / 2 + (vertical ? offset : cross))
            }
            func line(_ points: [CGPoint], opacity: Double = 1, dashed: Bool = false) {
                var path = Path()
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                context.stroke(path, with: .color(.primary.opacity(opacity)),
                               style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: dashed ? [1, 2] : []))
            }
            let code = direction ?? -1
            if (9...13).contains(code) {
                line([point(0), point(4)], opacity: 0.48)
                for end: CGFloat in [0, 4] { line([point(end, cross: -1.5), point(end, cross: 1.5)], opacity: 0.65) }
                let p = point(CGFloat(code - 9))
                context.fill(Path(ellipseIn: CGRect(x: p.x-2.1, y: p.y-2.1, width: 4.2, height: 4.2)), with: .color(.primary))
            } else if motor != 0 && ((1...(vertical ? 3 : 4)).contains(code) || motor == 1) {
                let zone: (CGFloat, CGFloat)
                switch (vertical, code) {
                case (_, 2): zone = (0, 2.5)
                case (true, 3), (false, 4): zone = (1.5, 4)
                case (false, 3): zone = (0.75, 3.25)
                default: zone = (0, 4)
                }
                line([point(0), point(4)], opacity: 0.3)
                let (a,b) = zone
                line([point(a), point(b)])
                line([point(a+0.7, cross:-2), point(a), point(a+0.7, cross:2)])
                line([point(b-0.7, cross:-2), point(b), point(b-0.7, cross:2)])
            } else {
                line([point(0), point(4)], opacity: 0.65, dashed: true)
            }
        }.frame(width: vertical ? 8 : 15, height: 16)
    }
}
