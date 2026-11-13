import SwiftUI

struct PhoneBatteryView: View {
    @ObservedObject var model: PhoneBluetooth
    var expanded: Bool
    var open: () -> Void
    @State private var selectedID: String?
    @State private var renaming: BlueBarKnownStation?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.stations.isEmpty {
                HStack(spacing: 12) {
                    if model.busy { ProgressView() }
                    Image(systemName: "battery.100percent").font(.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BLUETTI").font(.headline)
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).phoneCard()
            }
            ForEach(model.stations, id: \.key) { station in
                stationCard(station)
            }
            HStack(spacing: 8) {
                if model.busy && !model.stations.isEmpty { ProgressView().controlSize(.small) }
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.scan() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Find and refresh BLUETTI stations")
            }
        }
        .alert("Rename station", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Station name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let station = renaming {
                    model.rename(id: station.deviceID, name: station.bluetoothName, alias: draftName)
                }
                renaming = nil
            }
        } message: {
            Text("The name is saved on this iPhone and shown in the widget. Leave it empty to reset.")
        }
    }

    private func stationCard(_ station: BlueBarKnownStation) -> some View {
        let id = station.deviceID ?? station.key
        let reading = model.readings.first { $0.id == id }
        let name = station.alias ?? model.displayName(id: id, name: station.bluetoothName)
        let selected = expanded && (selectedID ?? model.selectedID ?? model.stations.first?.deviceID) == id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { selectedID = id; open() } label: {
                    HStack(spacing: 8) {
                        Text("BLUETTI").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button {
                    draftName = station.alias ?? ""; renaming = station
                } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Rename " + name)
            }
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: batterySymbol(reading?.percent)).font(.system(size: 26))
                    Text(reading.map { "\($0.percent)%" } ?? "—")
                        .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                }.foregroundStyle(SuperBarPanelStyle.green)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("IN  " + power(reading?.acInput, reading?.dcInput))
                    Text("OUT  " + power(reading?.acOutput, reading?.dcOutput))
                }.font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            if let reading {
                if let seconds = reading.chargeSeconds {
                    Label("Full in ≈ " + duration(seconds), systemImage: "bolt.fill")
                        .foregroundStyle(SuperBarPanelStyle.cyan)
                } else if let seconds = reading.remainingSeconds {
                    Label(duration(seconds) + " remaining", systemImage: "clock")
                        .foregroundStyle(SuperBarPanelStyle.cyan)
                }
                if selected {
                    Divider()
                    HStack {
                        PhoneMetric(title: "AC IN", value: reading.acInput.map(DisplayUnits.power) ?? "—", color: SuperBarPanelStyle.green)
                        Spacer()
                        PhoneMetric(title: "DC IN", value: reading.dcInput.map(DisplayUnits.power) ?? "—", color: SuperBarPanelStyle.green)
                        Spacer()
                        PhoneMetric(title: "AC OUT", value: reading.acOutput.map(DisplayUnits.power) ?? "—")
                        Spacer()
                        PhoneMetric(title: "DC OUT", value: reading.dcOutput.map(DisplayUnits.power) ?? "—")
                    }
                }
                PhoneTimestamp(date: reading.date)
            } else if model.activeID != id {
                Text(model.discovered.contains { $0.id == id }
                     ? "Waiting for the first reading…" : "Not nearby · searching automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.problems[id] {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if model.activeID == id {
                Label("Reading station…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            } else if selected {
                Button("Refresh " + name) { model.select(id) }.frame(minHeight: 44)
            }
        }.superBarSurface(selected: selected, padding: 12)
    }
    private func power(_ ac: Double?, _ dc: Double?) -> String {
        guard let ac, let dc else { return "—" }
        return DisplayUnits.power(ac + dc)
    }
    private func duration(_ seconds: Int) -> String { "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
    private func batterySymbol(_ percent: Int?) -> String {
        "battery.\(min(100, max(0, ((percent ?? 0) + 12) / 25 * 25)))percent"
    }
}
