import SwiftUI

/// Both platforms use one device grid and a single full-width detail below it.
struct ClimateDeviceList<Detail: View>: View {
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false
    var showSummaries = true
    let devices: [ClimateDeviceItem]
    let selected: ClimateDeviceID?
    let select: (ClimateDeviceID) -> Void
    @ViewBuilder let detail: (ClimateDeviceID) -> Detail
    var body: some View {
        let visibleDevices = devices.filter { DeviceVisibility.includes(online: $0.online, showOffline: showOffline) }
        VStack(alignment: .leading, spacing: 8) {
            if showSummaries {
            ClimateSummaryGrid {
                ForEach(visibleDevices) { device in
                    Button { select(device.id) } label: {
                        ClimateSummaryCard(device: device, selected: device.online != false && selected == device.id)
                    }.panelButtonStyle()
                        .offlineDevice(device.online == false)
                        .accessibilityAddTraits(device.online != false && selected == device.id ? .isSelected : [])
                }
            }
            if visibleDevices.isEmpty && !devices.isEmpty {
                Text("No online air conditioners").font(.caption).foregroundStyle(.secondary)
            }
            }
            if let selected, visibleDevices.contains(where: { $0.id == selected && $0.online != false }) {
                VStack(alignment: .leading, spacing: 8) { detail(selected) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
