import AppKit

struct EnergyBalance {
    let watts: Double?
    init(production: DeyeReading?, consumption: TuyaSnapshot?, now: Date = Date()) {
        guard let production, let power = production.power_w, let measured = production.date,
              now.timeIntervalSince(measured) >= -60, now.timeIntervalSince(measured) < 600,
              production.status == "NORMAL", let load = consumption?.consumption(now: now) else { watts = nil; return }
        watts = power - load
    }
    var text: String { watts.map { ($0 > 0 ? "+" : "") + DisplayUnits.power($0) } ?? "—" }
    var color: NSColor { watts.map { $0 < 0 ? NSColor(srgbRed: 0.32, green: 0.77, blue: 0.87, alpha: 1) : .systemYellow } ?? .secondaryLabelColor }
}
