import SwiftUI

struct ClimateDeviceItem: Identifiable {
    let id: ClimateDeviceID
    let name: String
    let room: String
    let target: String
    let power: Bool?
    var online: Bool? = nil
    var windowUnit: Bool { if case .lg = id { return true }; return false }
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
                        ClimateSummaryCard(device: device, selected: selected == device.id)
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

private struct ClimateSummaryCard: View {
    let device: ClimateDeviceItem
    let selected: Bool
    private var target: String { device.online == false ? "Offline" : device.power == true && !device.target.isEmpty ? device.target : device.power == false ? "OFF" : "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ClimateHousing(windowUnit: device.windowUnit).frame(width: 21, height: 17)
                Text(DeviceDisplayName.clean(device.name)).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if device.online != false && (!device.windowUnit || device.power == true) {
                    Text("Room " + device.room).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(device.online != false && device.power == true ? Color(red: 0.12, green: 0.88, blue: 0.36) : .gray)
                        .frame(width: 5, height: 5)
                    Text(target).font(.system(size: device.online != false && device.power == true ? 19 : 12, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 40, alignment: .topLeading)
            .superBarSurface(selected: selected, padding: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DeviceDisplayName.clean(device.name)), \(device.windowUnit ? "Window air conditioner" : "Wall-mounted air conditioner"), \(device.online != false && (!device.windowUnit || device.power == true) ? "Room " + device.room + ", " : "")\(device.online != false && device.power == true ? "Set temperature " + target : target)")
    }
}
