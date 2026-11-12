import SwiftUI

struct TuyaPanel: View {
    @ObservedObject var model: TuyaStore
    @ObservedObject var selection: BarSelection
    @State private var signingIn = false
    @State private var password = ""
    var body: some View {
        VStack(spacing: 2) {
            if model.needsSignIn {
                DeviceSelector(brand: .tuya) {
                    DeviceChoice(action: { signingIn.toggle() }) { Text("Sign in to Smart Life").font(.system(size: 12)) }
                }
            } else {
                DeviceSelector(brand: .tuya) {
                    ForEach(model.devices) { device in
                        DeviceChoice(selected: selection.expanded == .tuya && model.selected?.id == device.id, action: {
                            selection.select(.tuya, sameDevice: model.selected?.id == device.id); model.selectedID = device.id
                        }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(device.id == model.reading?.meterID ? "Main meter" : device.name).lineLimit(1)
                                    Circle().fill(device.online == true ? Color.green : device.online == false ? .red : .gray).frame(width: 5, height: 5)
                                }.font(.system(size: 12))
                                Text(device.online == false ? "OFF" : device.watts.map(DisplayUnits.power) ?? "—").font(.system(size: 12)).foregroundStyle(ice)
                            }
                        }
                    }
                    if model.devices.isEmpty { DeviceChoice(action: model.refresh) { Text(model.refreshing ? "Loading Tuya…" : "Refresh Tuya").font(.system(size: 12)) } }
                }
                if selection.expanded == .tuya && !selection.detailsCollapsed, let device = model.selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(device.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                            Spacer()
                            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                        }
                        HStack {
                            Button(device.online == false ? "OFF" : device.watts.map(DisplayUnits.power) ?? "—") { model.pin(device.id) }.buttonStyle(.plain).foregroundStyle(ice).help("Show meter power in menu bar")
                            if let value = device.voltage { Text(String(format: "%.1f V", value)) }
                            if let value = device.current { Text(String(format: "%.3f A", value)) }
                        }.monospacedDigit().font(.system(size: 13))
                        HStack {
                            if let energy = device.energyKWh { Text(DisplayUnits.energy(energy * 1000)) }
                            if let temp = device.temperature { Text(String(format: "%.0f°", temp)) }
                            if let leakage = device.leakageMA { Text(String(format: "%.0f mA", leakage)) }
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                        if device.id != model.reading?.meterID { Button("Use as consumption meter") { model.useAsMeter(device.id) }.buttonStyle(.plain).font(.caption) }
                        Text(model.problem ?? "Read only · " + (model.reading.map { ReadingAge.label($0.fetchedAt) } ?? "No readings"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.overviewSurface(selected: true).padding(.leading, PanelLayout.logoColumn)
                }
            }
            if signingIn {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Email", text: $model.email)
                    SecureField("Password (leave blank to reuse)", text: $password)
                    Text("Smart Life · Country 63 · EU").font(.caption).foregroundStyle(.secondary)
                    if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                    Button("Sign in") { let secret = password; password = ""; Task { if await model.signIn(password: secret) { signingIn = false } } }.disabled(model.refreshing || model.email.isEmpty)
                }.textFieldStyle(.roundedBorder).padding(.leading, PanelLayout.logoColumn)
            }
        }
    }
    var charts: some View {
        EnergyCharts(days: [], power: model.samples, color: ice, maximumPowerGap: 1800)
    }
}
