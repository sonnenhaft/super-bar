import SwiftUI
import Charts

struct StationOutputCharts: View {
    @ObservedObject var history: DevicePowerHistory
    let station: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output power recorded by Super Bar").font(.caption).foregroundStyle(.secondary)
            EnergyCharts(days: history.days[station] ?? [], power: history.power[station] ?? [],
                         showEmptyPower: true, maximumPowerGap: history.maximumGap)
        }
    }
}

struct EnergyCharts: View {
    @ObservedObject private var pricing = EnergyPricing.shared
    let days: [EnergyDayPoint]
    let power: [PowerPoint]
    var color: Color = cobalt
    var showEmptyPower = false
    var showEmptyMonth = false
    var powerIntervals: [PowerInterval] = []
    var consumptionDays: [EnergyDayPoint] = []
    var consumptionHours: [PowerInterval] = []
    var rollingSummary: EnergyTariff.RollingSummary?
    private var showConsumption: Bool { rollingSummary != nil }
    var consumptionPower: [PowerPoint] = []
    var maximumPowerGap: TimeInterval = 600
    @State private var highlightedBar: DayBar?
    private struct DayBar: Equatable { let day: String; let consumption: Bool }
    static func normalizedDays(_ source:[EnergyDayPoint], now:Date = Date(), count: Int = ChartHistory.dayCount) -> [EnergyDayPoint] {
        let calendar = ChartHistory.calendar
        let formatter = ChartHistory.formatter("yyyyMMdd")
        let values = Dictionary(source.map { ($0.key.replacingOccurrences(of:"-",with:""),$0.wattHours) },uniquingKeysWith:{ _,last in last })
        return (-(max(1, count) - 1)...0).compactMap { offset in
            guard let date = calendar.date(byAdding:.day,value:offset,to:now) else { return nil }
            let key = formatter.string(from:date)
            return EnergyDayPoint(key:key,label:offset == 0 ? "Today" : offset == -1 ? "Yesterday" : "\(-offset)d ago",wattHours:values[key] ?? nil)
        }
    }
    var body: some View {
        let days = Self.normalizedDays(days)
        let consumption = Self.normalizedDays(consumptionDays)
        let axisDays = (0...5).map { tick in
            days[Int((Double(tick * (days.count - 1)) / 5).rounded())].key
        }
        let energyMax = (days + consumption).compactMap(\.wattHours).max() ?? 0
        let range = rollingSummary?.range ?? RollingEnergy.last24Hours(endingAt: Date())
        let periodBill = pricing.tariff.summary(generation: days, consumption: consumption, todayKey: days.last!.key)
        VStack(alignment: .leading, spacing: 12) {
            if showConsumption {
                HStack(spacing: 14) {
                    Label { Text("Generation") } icon: { Circle().fill(color).frame(width: 6, height: 6) }
                    Spacer()
                    Label { Text("Consumption") } icon: { Circle().fill(ice).frame(width: 6, height: 6) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            powerSection(in: RollingEnergy.lastHour(endingAt: range.upperBound), lastHour: true)
            powerSection(in: range, lastHour: false)
            if showEmptyMonth || (days + consumption).contains(where: { $0.wattHours != nil }) {
                adaptiveReadout {
                    HStack {
                        Text("30 days")
                        if showConsumption, let bill = periodBill.bill {
                            billCaption(bill, incomplete: periodBill.billDays < days.count)
                        }
                    }
                } trailing: {
                    HStack(spacing: 5) {
                        Text(total(days)).foregroundStyle(showConsumption ? color : .primary).monospacedDigit()
                            .help("Sum of available days; * means some days are missing.")
                        if showConsumption {
                            Text("/").foregroundStyle(.secondary)
                            Text(total(consumption)).foregroundStyle(ice).monospacedDigit()
                                .help("Consumption: sum of available days; * means some days are missing.")
                        }
                    }
                }.font(.system(size:14,weight:.semibold))
                Chart(days) { day in
                    if let value = day.wattHours {
                        BarMark(x: .value("Day", day.key), y: .value("Energy", value))
                            .foregroundStyle((highlightedBar == DayBar(day: day.key, consumption: false) ? Color.white : color).gradient).cornerRadius(3)
                            .position(by: .value("Series", "Generation"))
                    }
                    if showConsumption, let value = consumption.first(where: { $0.key == day.key })?.wattHours {
                        BarMark(x: .value("Day", day.key), y: .value("Energy", value))
                            .foregroundStyle((highlightedBar == DayBar(day: day.key, consumption: true) ? Color.white : ice).gradient).cornerRadius(3)
                            .position(by: .value("Series", "Consumption"))
                    }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: 0...max(1, energyMax * 1.08))
                .chartXScale(domain:days.map(\.key))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let value = tick.as(Double.self) { Text(DisplayUnits.energyAxis(value)) } }
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
                            ChartInspection(proxy: proxy, tint: color, onHoverValue: { (key: String?, rightHalf: Bool) in
                                let bar = key.flatMap { day -> DayBar? in
                                    let hasGeneration = days.first { $0.key == day }?.wattHours != nil
                                    let hasConsumption = showConsumption && consumption.first { $0.key == day }?.wattHours != nil
                                    guard hasGeneration || hasConsumption else { return nil }
                                    return DayBar(day: day, consumption: hasConsumption && (!hasGeneration || rightHalf))
                                }
                                if bar != highlightedBar { highlightedBar = bar }
                            }) { (key: String) in
                                if let day = days.first(where: { $0.key == key }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(day.label).foregroundStyle(.secondary)
                                    tooltipValue(showConsumption ? "Generation" : "Energy", value: day.wattHours.map(DisplayUnits.energy) ?? "—", tint: color)
                                    if showConsumption {
                                        tooltipValue("Consumption", value: consumption.first(where: { $0.key == key })?.wattHours.map(DisplayUnits.energy) ?? "—", tint: ice)
                                        if let bill = dailyBill(day, consumption: consumption.first { $0.key == key }, today: key == days.last?.key) {
                                            Text("Consumption ≈ " + EnergyTariff.money(bill.importCost))
                                            Text("Sold ≈ " + EnergyTariff.money(bill.exportRevenue))
                                            Text(bill.formatted).fontWeight(.semibold)
                                        }
                                    }
                                }
                                }
                            }
                        }.transaction { $0.animation = nil }
                    }
                }.frame(height:112).padding(.bottom, 18)
                if !(days + consumption).contains(where: { $0.wattHours != nil }) {
                    Text("No monthly readings yet").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .chartPlotStyle { $0.background(Color.white.opacity(0.018)) }
    }
    @ViewBuilder private func powerSection(in range: ClosedRange<Date>, lastHour: Bool) -> some View {
        let power = self.power.filter { range.contains($0.time) }.sorted { $0.time < $1.time }
        let intervals = RollingEnergy.clipped(powerIntervals, to: range)
        let liveConsumption = consumptionPower.filter { range.contains($0.time) }.sorted { $0.time < $1.time }
        let hours = RollingEnergy.clipped(consumptionHours, to: range)
        let powerMax = max((power + liveConsumption).map(\.watts).max() ?? 0, (hours + intervals).map(\.watts).max() ?? 0)
        if showEmptyPower || showConsumption || !power.isEmpty || !intervals.isEmpty || !hours.isEmpty || !liveConsumption.isEmpty {
            adaptiveReadout {
                HStack {
                    Text(lastHour ? "Last hour" : "Last 24 hours").font(.system(size:14,weight:.semibold))
                    if !lastHour, let rollingSummary, let bill = rollingSummary.bill {
                        billCaption(bill, incomplete: rollingSummary.partial)
                    }
                }
            } trailing: {
                if !lastHour, let rollingSummary {
                    HStack(spacing: 5) {
                        Text(rollingSummary.generation.label(in: range))
                            .foregroundStyle(color)
                        Text("/").foregroundStyle(.white)
                        Text(rollingSummary.consumption.label(in: range))
                            .foregroundStyle(ice)
                    }.font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
                        .help("Generation / consumption over the last 24 hours. Estimated from measured intervals; * means coverage is incomplete.")
                } else {
                    Text(DisplayUnits.powerUnit(powerMax))
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
            }
            let points = segments(Self.plotPoints(power, in: range, maximumGap: maximumPowerGap))
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
                ForEach(Self.consumptionSegments(hours: hours, live: Self.plotPoints(liveConsumption, in: range, maximumGap: 600), maximumGap: 600), id: \.id) { entry in
                    LineMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts),
                             series: .value("Segment", "consumption-\(entry.segment)"))
                        .foregroundStyle(ice).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Time", entry.point.time), y: .value("Power", entry.point.watts))
                        .foregroundStyle(ice).symbolSize(3)
                }
            }
            .chartXScale(domain: range)
            .chartYScale(domain: 0...max(1, powerMax * 1.08))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { tick in
                AxisValueLabel {
                    if let date = tick.as(Date.self) { Text(lastHour ? timeLabel(date) : hourLabel(date)) }
                }
            } }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                    AxisGridLine()
                    AxisValueLabel { if let value = tick.as(Double.self) { Text(DisplayUnits.powerAxis(value)) } }
                }
            }
            .chartOverlay { proxy in
                ChartInspection(proxy: proxy, tint: color) { (time: Date) in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(timeLabel(time)).foregroundStyle(.secondary)
                        tooltipValue(showConsumption ? "Generation" : "Power",
                            value: Self.powerValue(at: time, points: power, intervals: intervals, maximumGap: maximumPowerGap).map(DisplayUnits.power) ?? "No reading", tint: color)
                        if showConsumption {
                            tooltipValue("Consumption", value: Self.powerValue(at: time, points: liveConsumption, intervals: hours, maximumGap: 600).map(DisplayUnits.power) ?? "No reading", tint: ice)
                        }
                    }
                }
            }.frame(height: 112)
            if power.isEmpty && intervals.isEmpty && hours.isEmpty && liveConsumption.isEmpty {
                Text(lastHour ? "No readings in the last hour" : "No readings in the last 24 hours").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if !intervals.isEmpty {
                Text("Average power from measured consumption intervals").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            adaptiveReadout {
                if let latest = power.last {
                    Text((showConsumption ? "Generation · " : "") + DisplayUnits.power(latest.watts) + " · " + timeLabel(latest.time))
                        .foregroundStyle(showConsumption ? color : .secondary)
                }
            } trailing: {
                if showConsumption {
                    Text(consumptionCaption(live: liveConsumption, hours: hours))
                        .foregroundStyle(ice)
                        .help("Reported meter power and live readings. Hourly averages fill periods without detailed readings.")
                }
            }.font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)

        }
    }

    /// Keep complete values and timestamps. Desktop keeps its single row;
    /// compact panels move the trailing readings below the heading or series.
    private func adaptiveReadout<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let leading = leading()
        let trailing = trailing()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailing.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                leading
                trailing
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tooltipValue(_ name: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(name + ": " + value).foregroundStyle(tint)
        }
    }
    static func powerValue(at time: Date, points: [PowerPoint], intervals: [PowerInterval], maximumGap: TimeInterval) -> Double? {
        // The two chart series pass their timestamp-sorted observations.
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        let right = lower < points.count ? points[lower] : nil
        if let right, right.time == time { return right.watts }
        let left = lower > 0 ? points[lower - 1] : nil
        if let left, let right {
            let gap = right.time.timeIntervalSince(left.time)
            if gap > 0, gap <= maximumGap {
                let fraction = time.timeIntervalSince(left.time) / gap
                return left.watts * (1 - fraction) + right.watts * fraction
            }
        }
        if let interval = intervals.first(where: { $0.start <= time && time < $0.end }) { return interval.watts }
        // Keep individual reported points easy to inspect across a large gap.
        let hitRadius = min(60, maximumGap / 2)
        return [left, right].compactMap { $0 }.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
            .flatMap { abs($0.time.timeIntervalSince(time)) <= hitRadius ? $0.watts : nil }
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
    private func total(_ days: [EnergyDayPoint]) -> String {
        let values = days.compactMap(\.wattHours)
        guard !values.isEmpty else { return "—" }
        return DisplayUnits.energy(values.reduce(0, +)) + (values.count < days.count ? "*" : "")
    }
    private static func dateLabel(_ key: String) -> String {
        String(key.suffix(2)) + "." + String(key.dropFirst(4).prefix(2))
    }
    // Keep peaks and valleys for drawing; inspection and accounting use all reports.
    static func plotPoints(_ ordered: [PowerPoint], in range: ClosedRange<Date>, maximumGap: TimeInterval) -> [PowerPoint] {
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard ordered.count > 1200, duration > 0, maximumGap > 0 else { return ordered }
        // Each retained pair within a bucket must stay inside the real link's gap limit.
        let width = min(duration / 300, maximumGap)
        let groups = Dictionary(grouping: ordered) { Int($0.time.timeIntervalSince(range.lowerBound) / width) }
        return groups.keys.sorted().flatMap { key -> [PowerPoint] in
            let bucket = groups[key]!
            let keep = [bucket.first!, bucket.min { $0.watts < $1.watts }!, bucket.max { $0.watts < $1.watts }!, bucket.last!]
            return Dictionary(keep.map { ($0.time, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.time < $1.time }
        }
    }

    // Detailed samples take precedence throughout the window. In the remaining
    // gaps an available meter interval represents its measured average power.
    static func consumptionSegments(hours: [PowerInterval], live: [PowerPoint], maximumGap: TimeInterval = 1800) -> [(id: Int, point: PowerPoint, segment: Int)] {
        let samples = live.sorted { $0.time < $1.time }
        var runs: [ClosedRange<Date>] = []
        for sample in samples {
            if let last = runs.last, sample.time.timeIntervalSince(last.upperBound) <= maximumGap {
                runs[runs.count - 1] = last.lowerBound...sample.time
            } else {
                runs.append(sample.time...sample.time)
            }
        }
        var remainder: [PowerInterval] = []
        for hour in hours.sorted(by: { $0.start < $1.start }) {
            var cursor = hour.start
            for run in runs where run.upperBound >= hour.start && run.lowerBound <= hour.end {
                if cursor < run.lowerBound {
                    remainder.append(.init(start: cursor, end: run.lowerBound, watts: hour.watts))
                }
                cursor = max(cursor, run.upperBound)
            }
            if cursor < hour.end { remainder.append(.init(start: cursor, end: hour.end, watts: hour.watts)) }
        }
        var result: [(id: Int, point: PowerPoint, segment: Int)] = []
        var previous: Date?
        var segment = 0
        func append(_ point: PowerPoint) {
            if let previous, point.time.timeIntervalSince(previous) > maximumGap { segment += 1 }
            result.append((result.count, point, segment))
            previous = point.time
        }
        var sampleIndex = 0
        for hour in remainder {
            while sampleIndex < samples.count && samples[sampleIndex].time <= hour.start {
                append(samples[sampleIndex])
                sampleIndex += 1
            }
            append(PowerPoint(time: hour.start, watts: hour.watts))
            // The hour itself is observed coverage, not an hour-long data gap.
            result.append((result.count, PowerPoint(time: hour.end, watts: hour.watts), segment))
            previous = hour.end
        }
        for point in samples.dropFirst(sampleIndex) { append(point) }
        return result
    }
    private func hourLabel(_ date: Date) -> String {
        ChartHistory.formatter("HH").string(from: date)
    }
    private func timeLabel(_ date: Date) -> String {
        ChartHistory.formatter("HH:mm").string(from: date)
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

// The same inspection layer supports a pointer on Mac and a finger on iPhone.
private struct ChartHover<Value> {
    let value: Value
    let point: CGPoint
}

// Hover state lives below the history/price calculations and chart marks.
// Moving the pointer redraws only this overlay on either platform.
private struct ChartInspection<Value: Plottable, Tooltip: View>: View {
    let proxy: ChartProxy
    let tint: Color
    var onHoverValue: ((Value?, Bool) -> Void)? = nil
    @ViewBuilder let tooltip: (Value) -> Tooltip
    @State private var hover: ChartHover<Value>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ChartPointer { point in
                    guard let point, let anchor = proxy.plotFrame, geometry[anchor].contains(point),
                          let value = proxy.value(atX: point.x - geometry[anchor].minX, as: Value.self) else {
                        hover = nil
                        onHoverValue?(nil, false)
                        return
                    }
                    hover = ChartHover(value: value, point: point)
                    if let onHoverValue {
                        let center = proxy.position(forX: value) ?? 0
                        onHoverValue(value, point.x - geometry[anchor].minX >= center)
                    }
                }
                if let hover, let anchor = proxy.plotFrame {
                    let rect = geometry[anchor]
                    Rectangle().fill(tint.opacity(0.35)).frame(width: 1, height: rect.height)
                        .position(x: hover.point.x, y: rect.midY).allowsHitTesting(false)
                    ChartTooltip(point: hover.point, bounds: geometry.size, tint: tint) {
                        tooltip(hover.value)
                    }
                }
            }.transaction { $0.animation = nil }
        }
    }
}

private struct ChartTooltip<Content: View>: View {
    let point: CGPoint
    let bounds: CGSize
    let tint: Color
    @ViewBuilder let content: () -> Content
    @State private var size: CGSize = .zero

    private var position: CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let x = min(max(point.x, halfWidth), max(halfWidth, bounds.width - halfWidth))
        let y = point.y - 10 - halfHeight
        return CGPoint(x: x, y: y)
    }
    private var measurement: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { self.size = geometry.size }
                .onChange(of: geometry.size) { self.size = $0 }
        }
    }

    var body: some View {
        content().font(.system(size: 11)).monospacedDigit().padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
            .fixedSize()
            .background(measurement)
            .position(position)
            .allowsHitTesting(false)
    }
}

private struct ChartPointer: View {
    let select: (CGPoint?) -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): select(point)
                case .ended: select(nil)
                }
            }
            #if os(iOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { select($0.location) }
                .onEnded { _ in select(nil) })
            #endif
    }
}
