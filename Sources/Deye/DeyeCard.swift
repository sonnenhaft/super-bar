import SwiftUI

struct DeyeCard: View {
    @ObservedObject var model: DeyeStore
    @ObservedObject var tuya: TuyaStore
    @ObservedObject var selection: BarSelection
    @ObservedObject private var age = ReadingAge.shared
    @State private var showSignIn = false
    var body: some View {
      VStack(spacing: 3) {
        DeviceSelector(brand: .deye, toggleLogo: {
            selection.showEnergy()
            model.pinned = true
        }) {
            if model.needsSignIn {
                DeviceChoice(action: { showSignIn.toggle() }) { Text("Sign in to Deye Cloud").font(.system(size: 12)) }
            } else {
                powerChoice(DeyeReading.power(model.reading?.power_w), title: "Generation", generation: true)
                powerChoice(tuya.reading?.consumption().map(DisplayUnits.power) ?? "—", title: "Consumption", generation: false)
            }
        }
        if showSignIn { DeyeSignIn(model: model) { showSignIn = false } }
      }
    }
    private func powerChoice(_ value: String, title: String, generation: Bool) -> some View {
        DeviceChoice(selected: model.pinned, action: {
            model.pinned.toggle()
            selection.showEnergy()
        }) {
            PanelEnergyContent(title: title, value: value, generation: generation, emphasized: model.pinned)
        }.help((model.pinned ? "Hide" : "Show") + " net power in menu bar")
            .accessibilityValue(model.pinned ? "Visible in menu bar" : "Hidden from menu bar")
    }
    var charts: some View { EnergyDetails(deye: model, tuya: tuya) }

}

struct DeyeSignIn: View {
    @ObservedObject var model: DeyeStore
    let close: () -> Void
    @ObservedObject private var draft: LoginDraft
    init(model: DeyeStore, close: @escaping () -> Void) {
        self.model = model; self.close = close; draft = model.loginDraft
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deye Cloud").font(.headline)
            CloudLoginForm(draft: draft, provider: "Deye", unavailable: model.refreshing, hasServer: true) { email, password, server in
                if await model.signIn(email: email, password: password, server: server) { close(); return nil }
                return model.problem ?? "Deye is busy. Try again shortly."
            }
        }.padding(12).frame(maxWidth: .infinity)
    }
}

// Keep Deye to the left of the existing readout without changing its pins or icon order.
enum SolarReadout {
    static func prepend(_ prefix: String, to button: NSButton, size: CGFloat, color: NSColor = .systemYellow) {
        let text = NSAttributedString(string: prefix + "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color
        ])
        let title = button.attributedTitle.copy() as! NSAttributedString
        let icon = button.image
        let position = button.imagePosition
        let showTitle = position != .imageOnly
        let iconSize = icon?.size ?? .zero
        let titleSize = showTitle ? title.size() : .zero
        let prefixSize = text.size()
        let gap: CGFloat = icon != nil && titleSize.width > 0 ? 4 : 0
        let total = NSSize(width: ceil(prefixSize.width + iconSize.width + gap + titleSize.width),
                           height: max(22, ceil(max(prefixSize.height, max(iconSize.height, titleSize.height)))))
        let result = NSImage(size: total, flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - prefixSize.height) / 2))
            var x = prefixSize.width
            if position == .imageRight || position == .imageTrailing {
                title.draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2))
                x += titleSize.width + gap
                icon?.draw(in: NSRect(x: x, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            } else {
                icon?.draw(in: NSRect(x: x, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
                x += iconSize.width + gap
                if showTitle { title.draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2)) }
            }
            return true
        }
        result.isTemplate = false
        button.title = ""
        button.image = result
        button.imagePosition = .imageOnly
    }
}
