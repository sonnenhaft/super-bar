import SwiftUI

// Both application shells display this exact history and accounting view.
struct EnergyDetails: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if deye.reading?.days.contains(where: { $0.kwh != nil }) == true || tuya.chartHistory != nil {
                EnergyCharts(days: (deye.reading?.days ?? []).map {
                    EnergyDayPoint(key: $0.day, label: String($0.day.suffix(2)), wattHours: $0.kwh.map { $0 * 1000 })
                }, power: deye.reading?.curve ?? [], color: sunlight,
                             consumptionDays: tuya.chartHistory?.days ?? [],
                             consumptionHours: tuya.chartHistory?.hours ?? [],
                             consumptionEnergyIntervals: tuya.chartHistory?.energyIntervals ?? [], showConsumption: true,
                             consumptionPower: tuya.samples)
                if let problem = tuya.historyProblem {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                } else if tuya.historyRefreshing && tuya.chartHistory == nil {
                    Text("Loading consumption…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(deye.refreshing ? "Loading 30 days…" : "No generation history yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reading = deye.reading {
                EnergyValueView(reading: reading, consumptionDays: tuya.chartHistory?.days ?? [])
            }
        }
    }
}

struct EnergyValueView: View {
    let reading: DeyeReading
    var consumptionDays: [EnergyDayPoint] = []
    @ObservedObject private var pricing = EnergyPricing.shared
    var body: some View {
        let now = Date()
        let todayKey = TuyaHistory.formatter("yyyyMMdd").string(from: now)
        let count = ChartHistory.accountingDayCount(now: now, calendar: TuyaHistory.calendar)
        let generation = EnergyCharts.normalizedDays(reading.days.map {
            EnergyDayPoint(key: $0.day, label: "", wattHours: $0.kwh.map { $0 * 1000 })
        }, now: now, count: count).map { day in
            day.key == todayKey ? EnergyDayPoint(key: day.key, label: day.label,
                wattHours: reading.date.flatMap { TuyaHistory.calendar.isDate($0, inSameDayAs: now) ? reading.today_kwh.map { $0 * 1000 } : nil }) : day
        }
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Estimated net cost").font(.system(size: 13, weight: .semibold))
            period("Today", days: Array(generation.suffix(1)), todayKey: todayKey)
            period("This month", days: generation.filter { $0.key.prefix(6) == todayKey.prefix(6) }, todayKey: todayKey)
            period("30 days", days: Array(generation.suffix(30)), todayKey: todayKey)
            Text("All generation sold · today \(Int((pricing.tariff.todayExportRatio * 100).rounded()))% · previous days \(Int((pricing.tariff.exportRatio * 100).rounded()))% of purchase price")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func period(_ title: String, days: [EnergyDayPoint], todayKey: String) -> some View {
        let summary = pricing.tariff.summary(generation: days, consumption: consumptionDays, todayKey: todayKey)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(summary.bill?.formatted ?? "—").font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline) {
                if let sold = summary.revenue, let roi = pricing.tariff.roi(revenue: sold) {
                    Text("Sold ≈ " + EnergyTariff.money(sold) + " · ROI " + roi.formatted(.number.precision(.fractionLength(2))) + "%")
                        .foregroundStyle(sunlight)
                        .help(EnergyTariff.money(sold) + " ÷ " + EnergyTariff.money(pricing.tariff.panelCost) + " × 100. Same period; no projection.")
                } else { Text("Sold · —").foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let bill = summary.bill {
                    Text(EnergyTariff.money(bill.withoutSolarCost)).strikethrough(color: .white.opacity(0.25))
                        .foregroundStyle(.white.opacity(0.4)).help("Without solar, for the same available days")
                }
            }.font(.system(size: 10)).monospacedDigit()
            if summary.generationDays < days.count || summary.billDays < days.count {
                Text("Available days: generation \(summary.generationDays)/\(days.count) · bill \(summary.billDays)/\(days.count)")
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
                TextField("400,000", value: Binding(get: { pricing.tariff.panelCost }, set: { if $0.isFinite && $0 > 0 { pricing.tariff.panelCost = $0 } }), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                Text("₱").foregroundStyle(.secondary)
            }
            HStack {
                Text("Purchase")
                Spacer()
                TextField("13", value: Binding(get: { pricing.tariff.purchasePerKWh }, set: { if $0.isFinite && $0 >= 0 { pricing.tariff.purchasePerKWh = $0 } }), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("₱/kWh").foregroundStyle(.secondary)
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
            Text(EnergyTariff.money(pricing.tariff.purchasePerKWh * value.wrappedValue) + "/kWh").foregroundStyle(.secondary)
        }
    }
}
