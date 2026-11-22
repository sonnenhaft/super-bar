import SwiftUI

struct EnergyHeaderMetrics: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    var openCharts: () -> Void = {}
    var highlightedMetric: String? = nil
    @ObservedObject private var pricing = EnergyPricing.shared
    var body: some View {
        let net = DeyeReading.netForBilling(production: deye.reading, load: tuya.reading?.consumption())
        let power = net.map { ($0 > 0 ? "+" : "") + DisplayUnits.power($0) } ?? DisplayUnits.power(0)
        let rate = pricing.tariff.hourlyReadout(netWatts: net)
        let daily = pricing.tariff.rollingBill(deye: deye, tuya: tuya)
        let dailyTint: Color = daily.bill.map { $0.netCost < 0 ? SuperBarPanelStyle.yellow : $0.netCost > 0 ? SuperBarPanelStyle.cyan : .secondary } ?? .secondary
        let tint: Color = net.map { $0 > 0 ? SuperBarPanelStyle.yellow : $0 < 0 ? SuperBarPanelStyle.cyan : Color.secondary } ?? .secondary
        HStack(spacing: 6) {
            #if os(macOS)
            Button(power) { deye.pinned.toggle(); openCharts() }
                .help(deye.pinned ? "Hide net power in menu bar" : "Show net power in menu bar")
                .accessibilityAddTraits(deye.pinned ? .isSelected : [])
            Text("·").foregroundStyle(.secondary).allowsHitTesting(false)
            Button(rate) { deye.ratePinned.toggle(); openCharts() }
                .help(deye.ratePinned ? "Hide ₱/h in menu bar" : "Show ₱/h in menu bar")
                .accessibilityAddTraits(deye.ratePinned ? .isSelected : [])
            #else
            Text(power)
            Text("·").foregroundStyle(.secondary)
            Text(rate)
                .background(highlightedMetric == "cost-hour" ? SuperBarPanelStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
            #endif
            Text(daily.dailyReadout).foregroundStyle(dailyTint)
                .background(highlightedMetric == "cost-day" ? SuperBarPanelStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .panelButtonStyle().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
    }
}

extension EnergyTariff {
    @MainActor func rollingBill(deye: DeyeStore, tuya: TuyaStore) -> RollingSummary {
        last24Hours(generation: deye.reading?.curve ?? [], load: tuya.chartPower, intervals: tuya.chartHistory?.energyIntervals ?? [])
    }
}

// Both application shells display this exact history and accounting view.
struct EnergyDetails: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore

    @ObservedObject private var pricing = EnergyPricing.shared

    var body: some View {
        let rolling = pricing.tariff.rollingBill(deye: deye, tuya: tuya)
        VStack(alignment: .leading, spacing: 8) {
            if deye.reading?.days.contains(where: { $0.kwh != nil }) == true || tuya.chartHistory != nil
                || deye.reading?.curve?.isEmpty == false || !tuya.samples.isEmpty {
                EnergyCharts(days: (deye.reading?.days ?? []).map {
                    EnergyDayPoint(key: $0.day, label: String($0.day.suffix(2)), wattHours: $0.kwh.map { $0 * 1000 })
                }, power: deye.reading?.curve ?? [], color: sunlight,
                             consumptionDays: tuya.chartHistory?.days ?? [],
                             consumptionHours: tuya.chartHistory?.energyIntervals ?? [],
                             rollingSummary: rolling,
                             consumptionPower: tuya.chartPower)
                if tuya.historyRefreshing && tuya.chartHistory == nil {
                    Text("Loading consumption…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(deye.historyRefreshing ? "Loading 30 days…" : "No generation history yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            EnergyValueView(reading: deye.reading, rolling: rolling, consumptionDays: tuya.chartHistory?.days ?? [])
        }
    }
}

struct EnergyValueView: View {
    let reading: DeyeReading?
    let rolling: EnergyTariff.RollingSummary
    var consumptionDays: [EnergyDayPoint] = []
    @ObservedObject private var pricing = EnergyPricing.shared
    var body: some View {
        let now = Date()
        let todayKey = ChartHistory.formatter("yyyyMMdd").string(from: now)
        let count = ChartHistory.accountingDayCount(now: now)
        let generation = EnergyCharts.normalizedDays((reading?.days ?? []).map {
            EnergyDayPoint(key: $0.day, label: "", wattHours: $0.kwh.map { $0 * 1000 })
        }, now: now, count: count).map { day in
            day.key == todayKey ? EnergyDayPoint(key: day.key, label: day.label,
                wattHours: reading?.date.flatMap { ChartHistory.calendar.isDate($0, inSameDayAs: now) ? reading?.today_kwh.map { $0 * 1000 } : nil } ?? day.wattHours) : day
        }
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Estimated net cost").font(.system(size: 13, weight: .semibold))
            period("Last 24 hours", revenue: rolling.revenue, bill: rolling.bill,
                   coverage: rolling.partial ? "Partial coverage" : nil)
            period("This month", days: generation.filter { $0.key.prefix(6) == todayKey.prefix(6) }, todayKey: todayKey)
            period("30 days", days: Array(generation.suffix(30)), todayKey: todayKey)
            Text("All generation sold · today \(Int((pricing.tariff.todayExportRatio * 100).rounded()))% · previous days \(Int((pricing.tariff.exportRatio * 100).rounded()))% of purchase price")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func period(_ title: String, days: [EnergyDayPoint], todayKey: String) -> some View {
        let summary = pricing.tariff.summary(generation: days, consumption: consumptionDays, todayKey: todayKey)
        let partial = summary.generationDays < days.count || summary.billDays < days.count
        let coverage = partial ? "Available days: generation \(summary.generationDays)/\(days.count) · bill \(summary.billDays)/\(days.count)" : nil
        return period(title, revenue: summary.revenue, bill: summary.bill, coverage: coverage)
    }
    private func period(_ title: String, revenue: Double?, bill: EnergyTariff.Bill?, coverage: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(bill?.formatted ?? EnergyTariff.money(0)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline) {
                if let sold = revenue, let roi = pricing.tariff.roi(revenue: sold) {
                    Text("Sold ≈ " + EnergyTariff.money(sold) + " · ROI " + roi.formatted(.number.precision(.fractionLength(1))) + "%")
                        .foregroundStyle(sunlight)
                        .help(EnergyTariff.money(sold) + " ÷ " + EnergyTariff.money(pricing.tariff.panelCost) + " × 100. Same period; no projection.")
                } else { Text("Sold · " + EnergyTariff.money(0)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let bill {
                    Text(EnergyTariff.money(bill.withoutSolarCost)).strikethrough(color: .white.opacity(0.25))
                        .foregroundStyle(.white.opacity(0.4)).help("Without solar, for the same available days")
                }
            }.font(.system(size: 10)).monospacedDigit()
            if let coverage {
                Text(coverage)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

struct EnergyTariffSettings: View {
    @ObservedObject private var pricing = EnergyPricing.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Energy tariff").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Panel cost")
                Spacer()
                TextField("400,000", value: Binding(get: { pricing.tariff.panelCost }, set: { if $0.isFinite && $0 > 0 { pricing.tariff.panelCost = $0 } }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                Text("₱").foregroundStyle(.secondary)
            }
            HStack {
                Text("Purchase")
                Spacer()
                TextField("13", value: Binding(get: { pricing.tariff.purchasePerKWh }, set: { if $0.isFinite && $0 >= 0 { pricing.tariff.purchasePerKWh = $0 } }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("₱/kWh ⚡️").foregroundStyle(.secondary)
            }
            saleRate("Sale price · previous days", value: $pricing.tariff.exportRatio)
            saleRate("Sale price · today", value: $pricing.tariff.todayExportRatio)
            Text("All generation is sold. Net cost = household consumption × purchase price − generation × sale price.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(.vertical, 6)
    }
    private func saleRate(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Stepper(value: value, in: 0...1, step: 0.05) { Text(title + " · \(Int((value.wrappedValue * 100).rounded()))%") }
            Spacer()
            Text(EnergyTariff.money(pricing.tariff.purchasePerKWh * value.wrappedValue) + "/kWh ⚡️").foregroundStyle(.secondary)
        }
    }
}
