import Foundation
import Combine

struct EnergyTariff: Codable {
    var purchasePerKWh = 13.0
    var exportRatio = 0.5
    var selfUseRatio = 0.3

    struct Bill {
        let importCost: Double
        let exportRevenue: Double
        var netCost: Double { importCost - exportRevenue }
        var label: String { netCost < 0 ? "Credit" : "To pay" }
        var formatted: String { label + " ≈ " + EnergyTariff.money(abs(netCost)) }
    }

    struct Matched {
        var generationKWh = 0.0
        var selfUseKWh = 0.0
        var importKWh = 0.0
        var seconds = 0.0
        var exportKWh: Double { max(0, generationKWh - selfUseKWh) }
    }

    // Tuya measures the whole house. Hourly history is an average, so even
    // matching intervals remain an estimate rather than a utility bill.
    static func matched(generation: [PowerPoint], consumption: [PowerInterval], live: [PowerPoint], range: DateInterval) -> Matched {
        func segments(_ points: [PowerPoint], gap: TimeInterval) -> [PowerInterval] {
            let sorted = Dictionary(points.filter { $0.watts.isFinite && $0.watts >= 0 }.map { ($0.time, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.time < $1.time }
            return zip(sorted, sorted.dropFirst()).compactMap { a, b in
                guard b.time.timeIntervalSince(a.time) <= gap else { return nil }
                return PowerInterval(start: a.time, end: b.time, watts: (a.watts + b.watts) / 2)
            }
        }
        let history = consumption.filter { $0.start < $0.end && $0.watts.isFinite && $0.watts >= 0 }.sorted { $0.start < $1.start }
        let historyEnd = history.map(\.end).max() ?? range.start
        let loads = history + segments(live.filter { $0.time >= historyEnd }, gap: 60)
        var result = Matched()
        for solar in segments(generation, gap: 600) {
            var coveredUntil = max(solar.start, range.start)
            for load in loads {
                let start = max(coveredUntil, load.start)
                let end = min(solar.end, load.end, range.end)
                guard end > start else { continue }
                let hours = end.timeIntervalSince(start) / 3600
                result.generationKWh += solar.watts * hours / 1000
                result.selfUseKWh += min(solar.watts, load.watts) * hours / 1000
                result.importKWh += max(0, load.watts - solar.watts) * hours / 1000
                result.seconds += hours * 3600
                coveredUntil = end
            }
        }
        return result
    }

    func bill(generationKWh: Double?, consumptionKWh: Double?, matched: Matched = Matched()) -> Bill? {
        guard let generation = generationKWh, let consumption = consumptionKWh,
              generation.isFinite, consumption.isFinite, generation >= 0, consumption >= 0,
              purchasePerKWh.isFinite, purchasePerKWh >= 0,
              (0...1).contains(exportRatio), (0...1).contains(selfUseRatio) else { return nil }
        // Daily totals alone cannot reveal when energy was used. Use matched
        // self-consumption where available and the scenario only for the rest.
        let scale = matched.generationKWh > generation && matched.generationKWh > 0 ? generation / matched.generationKWh : 1
        let selfUse = min(generation, consumption, matched.selfUseKWh * scale + max(0, generation - matched.generationKWh) * selfUseRatio)
        return Bill(importCost: max(0, consumption - selfUse) * purchasePerKWh,
                    exportRevenue: max(0, generation - selfUse) * purchasePerKWh * exportRatio)
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "PHP").locale(Locale(identifier: "en_PH")))
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
        tariff = defaults.data(forKey: "energy.tariff").flatMap { try? JSONDecoder().decode(EnergyTariff.self, from: $0) } ?? EnergyTariff()
    }
}
