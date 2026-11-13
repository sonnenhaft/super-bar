import SwiftUI
import Charts

struct EnergyCharts: View {
    @State private var hoveredDay: String?
    @ObservedObject private var pricing = EnergyPricing.shared
    let days: [EnergyDayPoint]
    let power: [PowerPoint]
    var color: Color = cobalt
    var currentDay = false
    var powerIntervals: [PowerInterval] = []
    var consumptionDays: [EnergyDayPoint] = []
    var consumptionHours: [PowerInterval] = []
    var consumptionEnergyIntervals: [PowerInterval] = []
    var showConsumption = false
    var consumptionPower: [PowerPoint] = []
    var maximumPowerGap: TimeInterval = 600
    private var powerRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        let start = currentDay ? calendar.startOfDay(for: Date()) : Date().addingTimeInterval(-86400)
        return start...(currentDay ? start.addingTimeInterval(86400) : Date())
    }
    static func normalizedDays(_ source:[EnergyDayPoint], now:Date = Date(), count: Int = ChartHistory.dayCount) -> [EnergyDayPoint] {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"Asia/Manila")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
        let values = Dictionary(source.map { ($0.key.replacingOccurrences(of:"-",with:""),$0.wattHours) },uniquingKeysWith:{ _,last in last })
        return (-(max(1, count) - 1)...0).compactMap { offset in
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
        let range = powerRange
        let generationTotal = RollingEnergy.total(points: self.power, in: range, maximumGap: maximumPowerGap)
        let consumptionTotal = RollingEnergy.total(points: consumptionPower, intervals: consumptionEnergyIntervals,
                                                   in: range, maximumGap: 600)
        let periodBill = pricing.tariff.summary(generation: days, consumption: consumption, todayKey: days.last!.key)
        let rollingBill = rollingBill(in: range, generation: generationTotal, consumption: consumptionTotal)
        let power = self.power.filter { range.contains($0.time) && $0.time <= Date() }.sorted { $0.time < $1.time }
        let intervals = powerIntervals.filter { $0.start >= powerRange.lowerBound && $0.end <= min(Date(), powerRange.upperBound) }
        let hours = RollingEnergy.clipped(consumptionHours, to: range)
        let currentHour = TuyaHistory.calendar.dateInterval(of: .hour, for: Date())!.start
        let liveConsumption = consumptionPower.filter { $0.time >= currentHour && $0.time <= Date() }.sorted { $0.time < $1.time }
        let powerMax = max((power + liveConsumption).map(\.watts).max() ?? 0, (hours + intervals).map(\.watts).max() ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            if showConsumption {
                HStack(spacing: 14) {
                    Label { Text("Generation") } icon: { Circle().fill(color).frame(width: 6, height: 6) }
                    Spacer()
                    Label { Text("Consumption") } icon: { Circle().fill(ice).frame(width: 6, height: 6) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if (days + consumption).contains(where: { $0.wattHours != nil }) {
                HStack {
                    Text("30 days")
                    if showConsumption, let bill = periodBill.bill {
                        billCaption(bill, incomplete: periodBill.billDays < days.count)
                    }
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
                .chartXSelection(value: $hoveredDay)
                .chartYScale(domain: 0...max(1, energyMax * 1.08))
                .chartXScale(domain:days.map(\.key))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(axisNumber(value,maximum:energyMax)) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment:.topLeading) {
                            // Categorical axes can emit every date on iOS. Position the
                            // six labels using the plot coordinates on both platforms.
                            if let anchor = proxy.plotFrame {
                                let rect = geometry[anchor]
                                ForEach(axisDays, id: \.self) { key in
                                    if let x = proxy.position(forX: key) {
                                        Text(key == days.last?.key ? "Today" : Self.dateLabel(key))
                                            .font(.system(size: 9)).foregroundStyle(.secondary)
                                            .fixedSize().position(x: min(max(rect.minX + x, rect.minX + 14), rect.maxX - 14), y: rect.maxY + 10)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
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
                                            Text("Consumption ≈ " + EnergyTariff.money(bill.importCost))
                                            Text("Sold ≈ " + EnergyTariff.money(bill.exportRevenue))
                                            Text(bill.formatted).fontWeight(.semibold)
                                        } else { Text("Net cost unavailable").foregroundStyle(.secondary) }
                                    }
                                }.font(.system(size:11)).monospacedDigit()
                                    .padding(6).background(PanelPalette.selected.color,in:RoundedRectangle(cornerRadius:4))
                                    .fixedSize().position(x:min(max(rect.minX+x, 108), geometry.size.width - 108),y:rect.minY + (showConsumption ? 48 : 24))
                                    .allowsHitTesting(false)
                            }
                        }.transaction { $0.animation = nil }
                    }
                }.frame(height:112).padding(.bottom, 18)
            }
            if currentDay || showConsumption || !power.isEmpty || !intervals.isEmpty || !hours.isEmpty || !liveConsumption.isEmpty {
                if (days + consumption).contains(where: { $0.wattHours != nil }) { Divider() }
                HStack {
                    Text(currentDay ? "Today" : "24 hours").font(.system(size:14,weight:.semibold))
                    if showConsumption, let bill = rollingBill {
                        billCaption(bill, incomplete: min(generationTotal.coverage, consumptionTotal.coverage) < 85800)
                    }
                    Spacer()
                    if showConsumption {
                        HStack(spacing: 5) {
                            Text(generationTotal.label(in: range))
                                .foregroundStyle(color)
                            Text("/").foregroundStyle(.white)
                            Text(consumptionTotal.label(in: range))
                                .foregroundStyle(ice)
                        }.font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
                            .help("Generation / consumption over the last 24 hours. Estimated from measured intervals; * means coverage is incomplete.")
                    } else {
                        Text(powerMax >= 1000 ? "kW" : "W")
                            .font(.system(size:10)).foregroundStyle(.secondary)
                    }
                }
                let points = segments(power)
                Chart {
                    ForEach(Array(intervals.enumerated()), id: \.offset) { index, interval in
                        RectangleMark(xStart: .value("Start", interval.start), xEnd: .value("End", interval.end),
                                      yStart: .value("Baseline", 0), yEnd: .value("Average power", interval.watts))
                            .foregroundStyle(color.opacity(0.22))
                        RuleMark(xStart: .value("Start", interval.start), xEnd: .value("End", interval.end), y: .value("Average power", interval.watts))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                    }
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
                if power.isEmpty && intervals.isEmpty && hours.isEmpty && liveConsumption.isEmpty {
                    Text(currentDay ? "No readings yet today" : "No readings in the last 24 hours").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if !intervals.isEmpty {
                    Text("Average power from measured consumption intervals").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let latest = power.last {
                        Text((showConsumption ? "Generation · " : "") + DisplayUnits.power(latest.watts) + " · " + timeLabel(latest.time))
                            .foregroundStyle(showConsumption ? color : .secondary)
                    }
                    if showConsumption {
                        Spacer(minLength: 0)
                        Text(consumptionCaption(live: liveConsumption, hours: hours))
                            .foregroundStyle(ice)
                            .help("Completed hours: average consumption. Current hour: live readings collected by Super Bar.")
                    }
                }.font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)

            }
        }
        .chartPlotStyle { $0.background(Color.white.opacity(0.018)) }
    }
    private func consumptionCaption(live: [PowerPoint], hours: [PowerInterval]) -> String {
        if let point = live.last { return "Consumption · " + DisplayUnits.power(point.watts) + " · " + timeLabel(point.time) }
        if let hour = hours.last { return "Consumption · " + DisplayUnits.power(hour.watts) + " · " + timeLabel(hour.end) }
        return "Consumption · —"
    }
    private func dailyBill(_ day: EnergyDayPoint, consumption: EnergyDayPoint?, today: Bool) -> EnergyTariff.Bill? {
        pricing.tariff.bill(generationKWh: day.wattHours.map { $0 / 1000 },
            consumptionKWh: consumption?.wattHours.map { $0 / 1000 }, today: today)
    }
    private func billCaption(_ bill: EnergyTariff.Bill, incomplete: Bool) -> some View {
        Text("≈ " + EnergyTariff.money(bill.netCost) + (incomplete ? "*" : ""))
            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            .help("Net cost after generation credit. Negative means credit; * means incomplete history. Details below.")
    }
    private func rollingBill(in range: ClosedRange<Date>, generation: RollingEnergy.Total,
                             consumption: RollingEnergy.Total) -> EnergyTariff.Bill? {
        guard generation.coverage > 0, consumption.coverage > 0 else { return nil }
        let midnight = TuyaHistory.calendar.startOfDay(for: range.upperBound)
        let today = RollingEnergy.total(points: power, in: max(midnight, range.lowerBound)...range.upperBound,
                                        maximumGap: maximumPowerGap)
        guard let previousRevenue = pricing.tariff.revenue(generationKWh: max(0, generation.wattHours - today.wattHours) / 1000),
              let todayRevenue = pricing.tariff.revenue(generationKWh: today.wattHours / 1000, today: true) else { return nil }
        return EnergyTariff.Bill(importCost: consumption.wattHours / 1000 * pricing.tariff.purchasePerKWh,
                                 exportRevenue: previousRevenue + todayRevenue)
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
        TuyaHistory.formatter("HH", zone: currentDay || showConsumption ? TuyaHistory.calendar.timeZone : .current).string(from: date)
    }
    private func timeLabel(_ date: Date) -> String {
        TuyaHistory.formatter("HH:mm", zone: currentDay || showConsumption ? TuyaHistory.calendar.timeZone : .current).string(from: date)
    }
    private func axisNumber(_ value:Double,maximum:Double) -> String {
        (maximum >= 1000 ? value / 1000 : value).formatted(.number.locale(Locale(identifier:"en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2)))
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
