import SwiftUI
import Charts

struct EnergyDayPoint: Identifiable {
    let key: String
    let label: String
    let wattHours: Double?
    var id: String { key }
}
struct PowerPoint: Codable, Identifiable {
    let time: Date
    let watts: Double
    var id: Date { time }
}

struct EnergyCharts: View {
    @State private var hoveredDay: String?
    let days: [EnergyDayPoint]
    let power: [PowerPoint]
    static func normalizedDays(_ source:[EnergyDayPoint], now:Date = Date()) -> [EnergyDayPoint] {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"Asia/Manila")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
        let values = Dictionary(source.map { ($0.key.replacingOccurrences(of:"-",with:""),$0.wattHours) },uniquingKeysWith:{ _,last in last })
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding:.day,value:offset,to:now) else { return nil }
            let key = formatter.string(from:date)
            return EnergyDayPoint(key:key,label:offset == 0 ? "Today" : String(calendar.component(.day,from:date)),wattHours:values[key] ?? nil)
        }
    }
    var body: some View {
        let days = Self.normalizedDays(days)
        VStack(alignment: .leading, spacing: 12) {
            if days.contains(where: { $0.wattHours != nil }) {
                HStack {
                    Text("7 days")
                    Spacer()
                    Text(DisplayUnits.energy(days.compactMap(\.wattHours).reduce(0,+))).monospacedDigit()
                }.font(.system(size:13,weight:.regular))
                Chart(days) { day in
                    if let value = day.wattHours {
                        BarMark(x: .value("Day", day.label), y: .value("Energy", value))
                            .foregroundStyle(cobalt.gradient).cornerRadius(3)

                    }
                }
                .chartXScale(domain:days.map(\.label))
                .chartXAxis { AxisMarks(values:days.map(\.label)) { AxisValueLabel() } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(axisNumber(value,maximum:days.compactMap(\.wattHours).max() ?? 0)) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment:.topLeading) {
                            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    guard let anchor = proxy.plotFrame else { hoveredDay = nil; return }
                                    let rect = geometry[anchor]
                                    guard rect.contains(point), let label = proxy.value(atX:point.x-rect.minX,as:String.self) else { hoveredDay = nil; return }
                                    hoveredDay = days.first(where: { $0.label == label })?.key
                                case .ended: hoveredDay = nil
                                }
                            }
                            if let key = hoveredDay, let day = days.first(where:{$0.key == key}),
                               let value = day.wattHours, let anchor = proxy.plotFrame,
                               let x = proxy.position(forX:day.label), let y = proxy.position(forY:value) {
                                let rect = geometry[anchor]
                                Text(DisplayUnits.energy(value)).font(.system(size:11)).monospacedDigit()
                                    .padding(6).background(Color(nsColor:BarTheme.navy),in:RoundedRectangle(cornerRadius:4))
                                    .fixedSize().position(x:rect.minX+x,y:max(14,rect.minY+y-16))
                                    .allowsHitTesting(false)
                            }
                        }.transaction { $0.animation = nil }
                    }
                }.frame(height:112)
            }
            if !power.isEmpty {
                if days.contains(where: { $0.wattHours != nil }) { Divider() }
                Text("24 hours").font(.system(size:13,weight:.semibold))
                let points = segmentedPower
                Chart(points, id: \.point.id) { entry in
                    LineMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts),
                             series: .value("Segment", entry.segment))
                        .foregroundStyle(cobalt).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts))
                        .foregroundStyle(cobalt).symbolSize(8)
                }
                .chartXScale(domain: Date().addingTimeInterval(-86400)...Date())
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(axisNumber(value,maximum:power.map(\.watts).max() ?? 0)) } }
                    }
                }.frame(height: 112)
                if let latest = power.last {
                    Text(DisplayUnits.power(latest.watts) + " · " + latest.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .chartPlotStyle { $0.background(LinearGradient(colors:[cobalt.opacity(0.18),cobalt.opacity(0.025)],startPoint:.top,endPoint:.bottom)) }
    }
    private func axisNumber(_ value:Double,maximum:Double) -> String {
        (maximum >= 1000 ? value / 1000 : value).formatted(.number.locale(Locale(identifier:"en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2)))
    }
    private var segmentedPower: [(point: PowerPoint, segment: Int)] {
        var previous: Date?
        var segment = 0
        return power.map { point in
            if let previous, point.time.timeIntervalSince(previous) > 600 { segment += 1 }
            previous = point.time
            return (point, segment)
        }
    }
    private func placeholder(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
extension View {
    func reportContentHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height) })
            .onPreferenceChange(ContentHeightKey.self, perform: report)
    }
}
