import AppKit

enum Brand: String, CaseIterable { case tcl = "TCL", lg = "LG", bluetti = "BLUETTI" }

final class BarSelection {
    static let shared = BarSelection()
    private let defaults: UserDefaults
    var current: Brand = .tcl
    private(set) var size: Int { didSet { defaults.set(size, forKey: "super.size") } }
    var color: NSColor? {
        get {
            guard let rgb = defaults.array(forKey: "super.rgb") as? [CGFloat], rgb.count == 3 else { return nil }
            return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        set {
            guard let c = newValue?.usingColorSpace(.sRGB) else { defaults.removeObject(forKey: "super.rgb"); return }
            defaults.set([c.redComponent,c.greenComponent,c.blueComponent], forKey: "super.rgb")
        }
    }
    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "super.size")
        size = (9...18).contains(saved) ? saved : 12
    }
    func setSize(_ value: Int) { size = min(18, max(9, value)) }
}
