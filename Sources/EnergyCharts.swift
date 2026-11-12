import SwiftUI
import Charts

struct EnergyCharts: View {
    @State private var hoveredDay: String?
    @ObservedObject private var pricing = EnergyPricing.shared
    let days: [EnergyDayPoint]
    let power: [PowerPoint]
    var color: Color = cobalt
    var currentDay = false
    var consumptionDays: [EnergyDayPoint] = []
    var consumptionHours: [PowerInterval] = []
    var showConsumption = false
    var consumptionPower: [PowerPoint] = []
    var maximumPowerGap: TimeInterval = 600
    private var powerRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        let start = currentDay ? calendar.startOfDay(for: Date()) : Date().addingTimeInterval(-86400)
        return start...(currentDay ? start.addingTimeInterval(86400) : Date())
    }
    static func normalizedDays(_ source:[EnergyDayPoint], now:Date = Date()) -> [EnergyDayPoint] {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"Asia/Manila")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
        let values = Dictionary(source.map { ($0.key.replacingOccurrences(of:"-",with:""),$0.wattHours) },uniquingKeysWith:{ _,last in last })
        return (-(ChartHistory.dayCount - 1)...0).compactMap { offset in
            guard let date = calendar.date(byAdding:.day,value:offset,to:now) else { return nil }
            let key = formatter.string(from:date)
            return EnergyDayPoint(key:key,label:offset == 0 ? "Today" : String(calendar.component(.day,from:date)),wattHours:values[key] ?? nil)
        }
    }
    var body: some View {
        let days = Self.normalizedDays(days)
        let consumption = Self.normalizedDays(consumptionDays)
        let axisDays = (0...5).map { tick in
            days[Int((Double(tick * (days.count - 1)) / 5).rounded())].key
        }
        let energyMax = (days + consumption).compactMap(\.wattHours).max() ?? 0
        let hours = consumptionHours.filter { $0.start >= powerRange.lowerBound && $0.end <= powerRange.upperBound }
        let currentHour = TuyaHistory.calendar.dateInterval(of: .hour, for: Date())!.start
        let liveConsumption = consumptionPower.filter { $0.time >= currentHour && $0.time <= Date() }.sorted { $0.time < $1.time }
        let powerMax = max((power + liveConsumption).map(\.watts).max() ?? 0, hours.map(\.watts).max() ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            if showConsumption {
                HStack(spacing: 14) {
                    Label { Text("Generation") } icon: { Circle().fill(color).frame(width: 6, height: 6) }
                    Label { Text("Consumption") } icon: { Circle().fill(ice).frame(width: 6, height: 6) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if (days + consumption).contains(where: { $0.wattHours != nil }) {
                HStack {
                    Text("30 days")
                    Spacer()
                    Text(total(days)).foregroundStyle(showConsumption ? color : .primary).monospacedDigit()
                        .help("Sum of available days; * means some days are missing.")
                    if showConsumption {
                        Text("/").foregroundStyle(.secondary)
                        Text(total(consumption)).foregroundStyle(ice).monospacedDigit()
                            .help("Consumption: sum of available days; * means some days are missing.")
                    }
                }.font(.system(size:14,weight:.semibold))
                Chart(days) { day in
                    if let value = day.wattHours {
                        BarMark(x: .value("Day", day.key), y: .value("Energy", value))
                            .foregroundStyle(color.gradient).cornerRadius(3)
                            .position(by: .value("Series", "Generation"))
                    }
                    if showConsumption, let value = consumption.first(where: { $0.key == day.key })?.wattHours {
                        BarMark(x: .value("Day", day.key), y: .value("Energy", value))
                            .foregroundStyle(ice.gradient).cornerRadius(3)
                            .position(by: .value("Series", "Consumption"))
                    }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: 0...max(1, energyMax * 1.08))
                .chartXScale(domain:days.map(\.key))
                .chartXAxis { AxisMarks(values: axisDays) { tick in
                    AxisValueLabel(anchor: tick.index == 0 ? .topLeading : tick.index == axisDays.count - 1 ? .topTrailing : .top) {
                        if let key = tick.as(String.self) {
                            Text(key == days.last?.key ? "Today" : Self.dateLabel(key)).fixedSize()
                        }
                    }
                } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(axisNumber(value,maximum:energyMax)) } }
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
                                    guard rect.contains(point), let key = proxy.value(atX:point.x-rect.minX,as:String.self) else { hoveredDay = nil; return }
                                    hoveredDay = key
                                case .ended: hoveredDay = nil
                                }
                            }
                            if let key = hoveredDay, let day = days.first(where:{$0.key == key}),
                               let anchor = proxy.plotFrame, let x = proxy.position(forX:day.key) {
                                let rect = geometry[anchor]
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Self.dateLabel(day.key)).foregroundStyle(.secondary)
                                    Text((showConsumption ? "Generation: " : "") + (day.wattHours.map(DisplayUnits.energy) ?? "—"))
                                        .foregroundStyle(showConsumption ? color : .primary)
                                    if showConsumption {
                                        Text("Consumption: " + (consumption.first(where: { $0.key == key })?.wattHours.map(DisplayUnits.energy) ?? "—"))
                                            .foregroundStyle(ice)
                                        if let bill = dailyBill(day, consumption: consumption.first { $0.key == key }, today: key == days.last?.key) {
                                            Text("Grid purchase ≈ " + EnergyTariff.money(bill.importCost))
                                            Text("Sold ≈ " + EnergyTariff.money(bill.exportRevenue))
                                            Text(bill.formatted).fontWeight(.semibold)
                                        } else { Text("Net cost unavailable").foregroundStyle(.secondary) }
                                    }
                                }.font(.system(size:11)).monospacedDigit()
                                    .padding(6).background(Color(nsColor:BarTheme.navy),in:RoundedRectangle(cornerRadius:4))
                                    .fixedSize().position(x:min(max(rect.minX+x, 108), geometry.size.width - 108),y:rect.minY + (showConsumption ? 48 : 24))
                                    .allowsHitTesting(false)
                            }
                        }.transaction { $0.animation = nil }
                    }
                }.frame(height:112)
            }
            if !power.isEmpty || !hours.isEmpty || !liveConsumption.isEmpty {
                if (days + consumption).contains(where: { $0.wattHours != nil }) { Divider() }
                HStack {
                    Text(currentDay ? "Today" : "24 hours").font(.system(size:14,weight:.semibold))
                    Spacer()
                    Text(powerMax >= 1000 ? "kW" : "W")
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
                let points = segmentedPower
                Chart {
                    ForEach(points, id: \.point.id) { entry in
                        AreaMark(x: .value("Time", entry.point.time), yStart: .value("Baseline", 0), yEnd: .value("Power", entry.point.watts), series: .value("Segment", "primary-\(entry.segment)"))
                            .foregroundStyle(color.opacity(0.13))
                        LineMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts),
                             series: .value("Segment", "primary-\(entry.segment)"))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts))
                            .foregroundStyle(color).symbolSize(3)
                    }
                    ForEach(Self.consumptionSegments(hours: hours, live: liveConsumption), id: \.id) { entry in
                        LineMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts),
                                 series: .value("Segment", "consumption-\(entry.segment)"))
                            .foregroundStyle(ice).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts))
                            .foregroundStyle(ice).symbolSize(3)
                    }
                }
                .chartXScale(domain: powerRange)
                .chartYScale(domain: 0...max(1, powerMax * 1.08))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { tick in
                    AxisValueLabel {
                        if let date = tick.as(Date.self) { Text(hourLabel(date)) }
                    }
                } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(axisNumber(value,maximum:powerMax)) } }
                    }
                }.frame(height: 112)
                if let latest = power.last {
                    Text((showConsumption ? "Generation · " : "") + DisplayUnits.power(latest.watts) + " · " + timeLabel(latest.time))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if showConsumption {
                    Text(liveConsumption.last.map { "Consumption · " + DisplayUnits.power($0.watts) + " · " + timeLabel($0.time) }
                         ?? (hours.isEmpty ? "Consumption · No complete hour yet" : "Consumption · Hourly average through " + timeLabel(hours.last!.end)))
                        .font(.system(size: 10)).foregroundStyle(ice)
                        .help("Completed hours: average consumption. Current hour: live readings collected by Super Bar.")
                }
            }
        }
        .chartPlotStyle { $0.background(Color.white.opacity(0.018)) }
    }
    private func dailyBill(_ day: EnergyDayPoint, consumption: EnergyDayPoint?, today: Bool) -> EnergyTariff.Bill? {
        let matched = today ? EnergyTariff.matched(generation: power, consumption: consumptionHours, live: consumptionPower,
            range: DateInterval(start: TuyaHistory.calendar.startOfDay(for: Date()), end: Date())) : .init()
        return pricing.tariff.bill(generationKWh: day.wattHours.map { $0 / 1000 },
            consumptionKWh: consumption?.wattHours.map { $0 / 1000 }, matched: matched)
    }
    private func total(_ days: [EnergyDayPoint]) -> String {
        let values = days.compactMap(\.wattHours)
        guard !values.isEmpty else { return "—" }
        return DisplayUnits.energy(values.reduce(0, +)) + (values.count < days.count ? "*" : "")
    }
    private static func dateLabel(_ key: String) -> String {
        String(key.suffix(2)) + "." + String(key.dropFirst(4).prefix(2))
    }
    // Hourly totals describe whole intervals. Join adjacent intervals at their
    // shared boundary, and measure missing coverage from the previous interval's end.
    static func consumptionSegments(hours: [PowerInterval], live: [PowerPoint]) -> [(id: Int, point: PowerPoint, segment: Int)] {
        var result: [(id: Int, point: PowerPoint, segment: Int)] = []
        var previous: Date?
        var segment = 0
        func append(_ point: PowerPoint) {
            if let previous, point.time.timeIntervalSince(previous) > 1800 { segment += 1 }
            result.append((result.count, point, segment))
            previous = point.time
        }
        for hour in hours.sorted(by: { $0.start < $1.start }) {
            append(PowerPoint(time: hour.start, watts: hour.watts))
            // The hour itself is observed coverage, not an hour-long data gap.
            result.append((result.count, PowerPoint(time: hour.end, watts: hour.watts), segment))
            previous = hour.end
        }
        let historyEnd = previous
        for point in live.sorted(by: { $0.time < $1.time }) where historyEnd.map({ point.time >= $0 }) ?? true {
            append(point)
        }
        return result
    }
    private func hourLabel(_ date: Date) -> String {
        TuyaHistory.formatter("HH", zone: currentDay ? TuyaHistory.calendar.timeZone : .current).string(from: date)
    }
    private func timeLabel(_ date: Date) -> String {
        TuyaHistory.formatter("HH:mm", zone: currentDay ? TuyaHistory.calendar.timeZone : .current).string(from: date)
    }
    private func axisNumber(_ value:Double,maximum:Double) -> String {
        (maximum >= 1000 ? value / 1000 : value).formatted(.number.locale(Locale(identifier:"en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2)))
    }
    private var segmentedPower: [(point: PowerPoint, segment: Int)] {
        segments(power)
    }
    private func segments(_ points: [PowerPoint]) -> [(point: PowerPoint, segment: Int)] {
        var previous: Date?
        var segment = 0
        return points.map { point in
            if let previous, point.time.timeIntervalSince(previous) > maximumPowerGap { segment += 1 }
            previous = point.time
            return (point, segment)
        }
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
