import AppKit

struct EnergyBalance {
    let watts: Double?
    private let consumptionOnly: Bool
    init(production: DeyeReading?, consumption: TuyaSnapshot?, now: Date = Date()) {
        watts = DeyeReading.netForBilling(production: production, load: consumption?.consumption(now: now), now: now)
        consumptionOnly = (production?.currentPower(now: now) ?? 0) == 0
    }
    var text: String { watts.map { consumptionOnly ? DisplayUnits.power(abs($0)) : ($0 > 0 ? "+" : "") + DisplayUnits.power($0) } ?? "—" }
    var color: NSColor { watts.map { consumptionOnly || $0 < 0 ? NSColor(srgbRed: 0.32, green: 0.77, blue: 0.87, alpha: 1) : .systemYellow } ?? .secondaryLabelColor }
}
