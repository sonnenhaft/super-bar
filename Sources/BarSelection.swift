import AppKit

enum Brand: String, CaseIterable { case tcl = "TCL", lg = "LG", bluetti = "BLUETTI" }

final class BarSelection {
    static let shared = BarSelection()
    private let defaults: UserDefaults
    var current: Brand = .tcl
    private(set) var size: Int { didSet { defaults.set(size, forKey: "super.size") } }
    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "super.size")
        size = (9...18).contains(saved) ? saved : 12
    }
    func setSize(_ value: Int) { size = min(18, max(9, value)) }
}
