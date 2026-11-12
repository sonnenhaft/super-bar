import Foundation
import Combine

struct EnergyTariff: Codable {
    var purchasePerKWh = 13.0
    var exportRatio = 0.7
    var todayExportRatio = 0.5
    var panelCost = 400_000.0

    struct Bill {
        let importCost: Double
        let exportRevenue: Double
        var withoutSolarCost: Double { importCost }
        var netCost: Double { importCost - exportRevenue }
        var label: String { netCost < 0 ? "Credit" : "To pay" }
        var formatted: String { label + " ≈ " + EnergyTariff.money(abs(netCost)) }
    }

    func roi(revenue: Double) -> Double? {
        guard panelCost.isFinite, panelCost > 0, revenue.isFinite, revenue >= 0 else { return nil }
        return revenue / panelCost * 100
    }

    struct Summary {
        let revenue: Double?
        let bill: Bill?
        let generationDays: Int
        let billDays: Int
    }
    func summary(generation: [EnergyDayPoint], consumption: [EnergyDayPoint], todayKey: String) -> Summary {
        let loads = Dictionary(consumption.map { ($0.key.replacingOccurrences(of: "-", with: ""), $0.wattHours) }, uniquingKeysWith: { _, last in last })
        let revenues = generation.compactMap { revenue(generationKWh: $0.wattHours.map { $0 / 1000 }, today: $0.key == todayKey) }
        let bills = generation.compactMap { day in
            bill(generationKWh: day.wattHours.map { $0 / 1000 },
                 consumptionKWh: (loads[day.key] ?? nil).map { $0 / 1000 }, today: day.key == todayKey)
        }
        return Summary(revenue: revenues.isEmpty ? nil : revenues.reduce(0, +),
                       bill: bills.isEmpty ? nil : Bill(importCost: bills.reduce(0) { $0 + $1.importCost }, exportRevenue: bills.reduce(0) { $0 + $1.exportRevenue }),
                       generationDays: revenues.count, billDays: bills.count)
    }

    func revenue(generationKWh: Double?, today: Bool = false) -> Double? {
        let ratio = today ? todayExportRatio : exportRatio
        guard let generation = generationKWh, generation.isFinite, generation >= 0,
              purchasePerKWh.isFinite, purchasePerKWh >= 0, (0...1).contains(ratio) else { return nil }
        return generation * purchasePerKWh * ratio
    }

    // User's accounting model: all generation is sold, all household use is bought.
    // Today's known sale rate is separate from the historical estimate.
    func bill(generationKWh: Double?, consumptionKWh: Double?, today: Bool = false) -> Bill? {
        guard let consumption = consumptionKWh, consumption.isFinite, consumption >= 0,
              let sold = revenue(generationKWh: generationKWh, today: today) else { return nil }
        return Bill(importCost: consumption * purchasePerKWh, exportRevenue: sold)
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "PHP").locale(Locale(identifier: "en_PH")))
    }
}

extension EnergyTariff {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        purchasePerKWh = try values.decodeIfPresent(Double.self, forKey: .purchasePerKWh) ?? 13
        exportRatio = try values.decodeIfPresent(Double.self, forKey: .exportRatio) ?? 0.7
        todayExportRatio = try values.decodeIfPresent(Double.self, forKey: .todayExportRatio) ?? 0.5
        panelCost = try values.decodeIfPresent(Double.self, forKey: .panelCost) ?? 400_000
    }
}

final class EnergyPricing: ObservableObject {
    static let shared = EnergyPricing()
    private let defaults: UserDefaults
    @Published var tariff: EnergyTariff {
        didSet { if let data = try? JSONEncoder().encode(tariff) { defaults.set(data, forKey: "energy.tariff") } }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var saved = defaults.data(forKey: "energy.tariff").flatMap { try? JSONDecoder().decode(EnergyTariff.self, from: $0) } ?? EnergyTariff()
        if !defaults.bool(forKey: "energy.allGenerationSold.v1") {
            saved.exportRatio = 0.7
            saved.todayExportRatio = 0.5
            defaults.set(true, forKey: "energy.allGenerationSold.v1")
            if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "energy.tariff") }
        }
        tariff = saved
    }
}
