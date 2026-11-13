import SwiftUI

struct PhoneBatteryView: View {
    @ObservedObject var model: PhoneBluetooth
    var expanded: Bool
    var open: () -> Void
    @State private var selectedID: String?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PanelBrandLabel(name: "BLUETTI").padding(.top, 14)
            if model.readings.isEmpty {
                Button { open(); if !model.busy { model.scan() } } label: {
                    Text("Allow Bluetooth").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).superBarSurface()
                }.buttonStyle(.plain)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(model.readings) { reading in
                        Button { selectedID = reading.id; open() } label: {
                            PanelReadingCard(name: reading.name, primary: String(reading.percent) + "%",
                                secondary: reading.output.map(DisplayUnits.power) ?? "—", symbol: "battery.100percent",
                                on: Date().timeIntervalSince(reading.date) < 300 ? true : nil,
                                selected: expanded && (selectedID ?? model.readings.first?.id) == reading.id)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        if expanded {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nearby stations", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            Text(model.message).foregroundStyle(.secondary)
            if model.busy {
                HStack { ProgressView(); Button("Disconnect") { model.stop() } }
            } else {
                Button("Find BLUETTI stations") { model.scan() }.buttonStyle(.borderedProminent)
                ForEach(model.discovered, id: \.id) { device in
                    Button { model.connect(device) } label: { Label(device.name, systemImage: "battery.100percent") }
                        .frame(minHeight: 44)
                }
            }
        }.phoneCard()
        ForEach(model.readings.filter { $0.id == (selectedID ?? model.readings.first?.id) }) { reading in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(reading.name).font(.headline)
                    Spacer()
                    Text("\(reading.percent)%").font(.system(size: 28, weight: .semibold)).foregroundStyle(SuperBarPanelStyle.green)
                }
                ProgressView(value: Double(reading.percent), total: 100).tint(SuperBarPanelStyle.green)
                HStack {
                    PhoneMetric(title: "AC IN", value: reading.acInput.map(DisplayUnits.power) ?? "—", color: SuperBarPanelStyle.green)
                    Spacer()
                    PhoneMetric(title: "AC OUT", value: reading.acOutput.map(DisplayUnits.power) ?? "—")
                }
                HStack {
                    PhoneMetric(title: "DC IN", value: reading.dcInput.map(DisplayUnits.power) ?? "—", color: SuperBarPanelStyle.green)
                    Spacer()
                    PhoneMetric(title: "DC OUT", value: reading.dcOutput.map(DisplayUnits.power) ?? "—")
                }
                if let seconds = reading.remainingSeconds { Label("Station estimate: \(seconds / 3600)h \((seconds % 3600) / 60)m remaining", systemImage: "clock") }
                if let seconds = reading.chargeSeconds { Label("Full in ≈ \(seconds / 3600)h \((seconds % 3600) / 60)m", systemImage: "bolt.fill") }
                PhoneTimestamp(date: reading.date)
            }.phoneCard()
        }
        Text("AC50P support, as in Super Bar for Mac. Readings update while connected with the app open. Bluetooth disconnects in the background; widgets retain the last reading.")
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
