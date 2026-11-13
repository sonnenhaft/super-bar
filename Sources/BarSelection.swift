import AppKit
import Combine

enum Brand: String, CaseIterable { case tcl = "TCL", lg = "LG", bluetti = "BLUETTI", deye = "Deye", tuya = "Tuya" }

final class BarSelection: ObservableObject {
    static let sizeRange = 9...24
    static let shared = BarSelection()
    private let defaults: UserDefaults
    @Published var climateDevice: ClimateDeviceID?
    @Published var current: Brand = .tcl
    @Published var expanded: Brand = .tcl { didSet { chartOverride = nil } }
    @Published var chartOverride: Brand? {
        didSet { if chartOverride != nil { detailsCollapsed = true } }
    }
    @Published var detailsCollapsed = false
    var chartBrand: Brand { chartOverride ?? expanded }
    var openBrand: Brand? { chartOverride ?? (detailsCollapsed ? nil : expanded) }
    func showEnergy() { chartOverride = .deye }
    func toggleEnergy() {
        if openBrand == .deye || openBrand == .tuya {
            chartOverride = nil
            detailsCollapsed = true
        } else { showEnergy() }
    }
    func select(_ brand: Brand, sameDevice: Bool) {
        detailsCollapsed = chartBrand == brand && expanded == brand && sameDevice ? !detailsCollapsed : false
        expanded = brand
        if !detailsCollapsed { pin(brand); didExpand?(brand) }
    }
    func activate(_ brand: Brand) {
        expanded = brand
        detailsCollapsed = false
        pin(brand)
        didExpand?(brand)
    }
    var didExpand: ((Brand) -> Void)?
    var readoutChanged: (() -> Void)?
    func pin(_ brand: Brand) {
        current = brand
        readoutChanged?()
    }
    private(set) var size: Int { didSet { defaults.set(size, forKey: "super.size") } }
    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "super.size")
        size = Self.sizeRange.contains(saved) ? saved : 12
    }
    func setSize(_ value: Int) { size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, value)) }
}
