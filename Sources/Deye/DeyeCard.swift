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
                powerChoice(DeyeReading.power(model.reading?.power_w), title: "Generation", symbol: "sun.max", color: sunlight)
                powerChoice(tuya.reading?.consumption().map(DisplayUnits.power) ?? "—", title: "Consumption", symbol: "bolt.fill", color: ice)
            }
        }
        if showSignIn { DeyeSignIn(model: model) { showSignIn = false } }
      }
    }
    private func powerChoice(_ value: String, title: String, symbol: String, color: Color) -> some View {
        DeviceChoice(selected: model.pinned, action: {
            model.pinned.toggle()
            selection.showEnergy()
        }) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 28)).frame(width: 29)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    Text(value).font(.system(size: 20, weight: model.pinned ? .bold : .medium)).monospacedDigit()
                }
                Spacer(minLength: 0)
            }.foregroundStyle(color).frame(minHeight: 42)
        }.help((model.pinned ? "Hide" : "Show") + " net power in menu bar")
            .accessibilityValue(model.pinned ? "Visible in menu bar" : "Hidden from menu bar")
    }
    @ViewBuilder var charts: some View {

        if model.reading?.days.contains(where: { $0.kwh != nil }) == true || tuya.chartHistory != nil {
            EnergyCharts(days: (model.reading?.days ?? []).map {
                EnergyDayPoint(key: $0.day, label: String($0.day.suffix(2)), wattHours: $0.kwh.map { $0 * 1000 })
            }, power: model.reading?.curve ?? [], color: sunlight,
                         consumptionDays: tuya.chartHistory?.days ?? [],
                         consumptionHours: tuya.chartHistory?.hours ?? [],
                         consumptionEnergyIntervals: tuya.chartHistory?.energyIntervals ?? [], showConsumption: true,
                         consumptionPower: tuya.samples)
            if let problem = tuya.historyProblem {
                Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
            } else if tuya.historyRefreshing && tuya.chartHistory == nil {
                Text("Loading consumption…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else {
            Text(model.refreshing ? "Loading 30 days…" : "No generation history yet")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DeyeSignIn: View {
    @ObservedObject var model: DeyeStore
    let close: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var server = "https://deyecloud.com"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deye Cloud").font(.headline)
            TextField("Email", text: $email).textContentType(.username)
            SecureField("Password", text: $password).textContentType(.password)
            Picker("Server", selection: $server) {
                Text("Automatic").tag("https://deyecloud.com")
                Text("Europe").tag("https://eu1.deyecloud.com")
                Text("US").tag("https://us1.deyecloud.com")
                Text("India").tag("https://india.deyecloud.com")
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            Button(model.refreshing ? "Connecting…" : "Sign in") {
                let secret = password
                password = ""
                Task { if await model.signIn(email: email, password: secret, server: server) { close() } }
            }.disabled(model.refreshing || !email.contains("@") || password.isEmpty)
        }.textFieldStyle(.roundedBorder).padding(12).frame(maxWidth: .infinity)
            .onDisappear { password = "" }
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
