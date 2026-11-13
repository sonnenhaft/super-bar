import SwiftUI

struct ClimateDeviceItem: Identifiable {
    let id: ClimateDeviceID
    let name: String
    let room: String
    let target: String
    let power: Bool?
}

/// Both platforms use one device grid and a single full-width detail below it.
struct ClimateDeviceList<Detail: View>: View {
    let devices: [ClimateDeviceItem]
    let selected: ClimateDeviceID?
    let select: (ClimateDeviceID) -> Void
    @ViewBuilder let detail: (ClimateDeviceID) -> Detail
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(devices) { device in
                    Button { select(device.id) } label: {
                        PanelReadingCard(name: device.name, primary: "Room " + device.room,
                            secondary: device.target.isEmpty ? "" : "Set " + device.target,
                            on: device.power, selected: selected == device.id, reservesSecondaryLine: true)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected == device.id ? .isSelected : [])
                }
            }
            if let selected, devices.contains(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 8) { detail(selected) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
