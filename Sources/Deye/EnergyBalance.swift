import AppKit

struct EnergyBalance {
    let watts: Double?
    private let consumptionOnly: Bool
    init(production: DeyeReading?, consumption: TuyaSnapshot?, now: Date = Date()) {
        guard let load = consumption?.consumption(now: now), load.isFinite, load >= 0 else {
            watts = nil; consumptionOnly = false; return
        }
        guard let production, let power = production.power_w, let measured = production.date,
              now.timeIntervalSince(measured) >= -60, now.timeIntervalSince(measured) < 600,
              production.status == "NORMAL", power.isFinite, power > 0 else {
            watts = -load; consumptionOnly = true; return
        }
        consumptionOnly = false
        watts = power - load
    }
    var text: String { watts.map { consumptionOnly ? DisplayUnits.power(abs($0)) : ($0 > 0 ? "+" : "") + DisplayUnits.power($0) } ?? "—" }
    var color: NSColor { watts.map { consumptionOnly || $0 < 0 ? NSColor(srgbRed: 0.32, green: 0.77, blue: 0.87, alpha: 1) : .systemYellow } ?? .secondaryLabelColor }
}
