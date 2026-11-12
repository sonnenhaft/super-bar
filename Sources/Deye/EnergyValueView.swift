import SwiftUI

struct EnergyValueView: View {
    let reading: DeyeReading
    var consumption: [PowerInterval] = []
    var live: [PowerPoint] = []
    var consumptionDays: [EnergyDayPoint] = []
    @ObservedObject private var pricing = EnergyPricing.shared
    private var today: Double? {
        guard let date = reading.date, TuyaHistory.calendar.isDate(date, inSameDayAs: Date()) else { return nil }
        return reading.today_kwh
    }
    var body: some View {
        let matched = EnergyTariff.matched(generation: reading.curve ?? [], consumption: consumption, live: live,
            range: DateInterval(start: TuyaHistory.calendar.startOfDay(for: Date()), end: Date()))
        let days = EnergyCharts.normalizedDays(reading.days.map {
            EnergyDayPoint(key: $0.day, label: "", wattHours: $0.kwh.map { $0 * 1000 })
        })
        let loads = EnergyCharts.normalizedDays(consumptionDays)
        let todayKey = days.last?.key
        let bills = days.compactMap { day in
            pricing.tariff.bill(generationKWh: day.key == todayKey ? today : day.wattHours.map { $0 / 1000 },
                consumptionKWh: loads.first { $0.key == day.key }?.wattHours.map { $0 / 1000 },
                matched: day.key == todayKey ? matched : .init())
        }
        let todayBill = pricing.tariff.bill(generationKWh: today, consumptionKWh: loads.last?.wattHours.map { $0 / 1000 }, matched: matched)
        let total = bills.isEmpty ? nil : EnergyTariff.Bill(importCost: bills.reduce(0) { $0 + $1.importCost }, exportRevenue: bills.reduce(0) { $0 + $1.exportRevenue })
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Estimated net cost").font(.system(size: 13, weight: .semibold))
            HStack {
                amount("Today", value: todayBill)
                Spacer()
                amount("30 days · \(bills.count)/\(days.count) days available", value: total)
            }
            if matched.seconds > 0 {
                Text("Matched data: \(Int(matched.seconds / 60)) min · \(DisplayUnits.energy(matched.selfUseKWh * 1000)) self-use")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Missing intervals: \(Int((pricing.tariff.selfUseRatio * 100).rounded()))% self-use · \(Int(((1 - pricing.tariff.selfUseRatio) * 100).rounded()))% export")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func amount(_ title: String, value: EnergyTariff.Bill?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value?.formatted ?? "—")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }.help(value.map { "Grid purchase ≈ " + EnergyTariff.money($0.importCost) + " · Sold ≈ " + EnergyTariff.money($0.exportRevenue) + ". Self-used generation is already deducted. Energy charges only; hourly averages and missing intervals are estimates." } ?? "Both generation and household consumption are required.")
    }
}

struct EnergyTariffSettings: View {
    @ObservedObject private var pricing = EnergyPricing.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Energy tariff").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Purchase")
                Spacer()
                TextField("13", value: Binding(get: { pricing.tariff.purchasePerKWh }, set: { if $0.isFinite && $0 >= 0 { pricing.tariff.purchasePerKWh = $0 } }), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("₱/kWh").foregroundStyle(.secondary)
            }
            HStack {
                Stepper(value: $pricing.tariff.exportRatio, in: 0...1, step: 0.05) {
                    Text("Export · \(Int((pricing.tariff.exportRatio * 100).rounded()))%")
                }
                Spacer()
                Text(EnergyTariff.money(pricing.tariff.purchasePerKWh * pricing.tariff.exportRatio) + "/kWh").foregroundStyle(.secondary)
            }
            HStack {
                Text("Assumed self-use")
                Spacer()
                Picker("Assumed self-use", selection: $pricing.tariff.selfUseRatio) {
                    Text("20%").tag(0.2); Text("25%").tag(0.25); Text("30%").tag(0.3)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            Text("Whole-house meter. Matching intervals estimate self-use and export; this assumption applies only where interval data is missing.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(.vertical, 6)
    }
}
