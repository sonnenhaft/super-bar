import SwiftUI

struct ClimateDeviceItem: Identifiable {
    let id: ClimateDeviceID
    let name: String
    let room: String
    let target: String
    let power: Bool?
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
    private var target: String { device.power == true && !device.target.isEmpty ? device.target : device.power == false ? "OFF" : "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ClimateHousing(windowUnit: device.windowUnit).frame(width: 21, height: 17)
                Text(DeviceDisplayName.clean(device.name)).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Room").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(device.room).font(.system(size: 11, weight: .medium))
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(device.power == true ? Color(red: 0.12, green: 0.88, blue: 0.36) : .gray)
                        .frame(width: 5, height: 5)
                    Text(target).font(.system(size: device.power == true ? 19 : 13, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 52, alignment: .topLeading)
            .superBarSurface(selected: selected, padding: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DeviceDisplayName.clean(device.name)), \(device.windowUnit ? "Window air conditioner" : "Wall-mounted air conditioner"), Room \(device.room), \(device.power == true ? "Set temperature " + target : target)")
    }
}
