import SwiftUI

struct PhoneBatteryView: View {
    @ObservedObject var model: PhoneBluetooth
    var expanded: Bool
    var open: () -> Void
    var close: () -> Void
    var requestedID: String? = nil
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false

    var body: some View {
        let stations = model.stations.filter { station in
            let id = station.deviceID ?? station.key
            return DeviceVisibility.includesBattery(hasReading: model.readings.contains { $0.id == id },
                                                     online: model.stationReachability(id), showOffline: showOffline)
        }
        let requested = requestedID.flatMap { id in model.stations.first { ($0.deviceID ?? $0.key) == id } }
        let selection = expanded ? (requested ?? selectedStation(in: stations)) : nil
        BatteryDeviceList(stations: stations.map { station in
            let id = station.deviceID ?? station.key
            return BatteryStationItem(id: id, name: displayName(station),
                                      percent: model.readings.first { $0.id == id }?.percent,
                                      selected: selection?.key == station.key)
        }, needsPermission: model.needsBluetoothPermission,
           permissionRestricted: model.authorization == .restricted,
           emptyMessage: model.message,
           waitingForSelection: expanded && requestedID != nil && selection == nil,
           hasSelection: selection != nil,
           error: unselectedProblem(selection), requestPermission: model.requestBluetoothPermission,
           select: { id in
               if id == (selection?.deviceID ?? selection?.key) { close() }
               else { model.select(id); open() }
           }) {
            if let selection { stationDetails(selection) }
        }
    }

    private func selectedStation(in stations: [BlueBarKnownStation]) -> BlueBarKnownStation? {
        guard let current = model.selectedID else { return stations.first }
        return stations.first { ($0.deviceID ?? $0.key) == current }
    }

    private func displayName(_ station: BlueBarKnownStation) -> String {
        station.alias ?? model.displayName(id: station.deviceID ?? station.key, name: station.bluetoothName)
    }

    private func unselectedProblem(_ selection: BlueBarKnownStation?) -> String? {
        guard let id = model.failedRefreshID, id != (selection?.deviceID ?? selection?.key),
              let problem = model.problems[id] else { return nil }
        let station = model.stations.first { ($0.deviceID ?? $0.key) == id }
        let name = station.map(displayName) ?? model.displayName(id: id, name: "BLUETTI")
        return name + " · " + problem
    }

    private func stationDetails(_ station: BlueBarKnownStation) -> some View {
        let id = station.deviceID ?? station.key
        let reading = model.readings.first { $0.id == id }
        let refreshing = model.refreshRequest == .station(id)
        var content = BatteryDetailContent()
        content.name = displayName(station)
        content.percent = reading?.percent
        content.input = BatteryDetailContent.power("in", dc: reading?.dcInput, ac: reading?.acInput)
        content.output = BatteryDetailContent.power("out", dc: reading?.dcOutput, ac: reading?.acOutput)
        content.chargeTime = reading?.chargeSeconds.map { BatteryDetailContent.duration(seconds: $0) } ?? ""
        content.runtime = reading?.runtimeLabel ?? ""
        content.connected = model.stationReachability(id) == true
        content.selected = true
        content.refreshing = refreshing
        content.refreshEnabled = model.refreshRequest == nil
        content.status = refreshing ? "Refreshing…" : "Not connected"
        content.measuredAt = reading?.date
        content.statusHelp = reading?.date.formatted(date: .abbreviated, time: .standard)
        content.problem = model.problems[id]
        return VStack(alignment: .leading, spacing: 8) {
            BatteryDetailCard(content: content,
                              actions: BatteryDetailActions(select: close, refresh: { model.refreshStation(id) },
                                                            saveName: { model.rename(id: station.deviceID, name: station.bluetoothName, alias: $0) }),
                              alias: station.alias ?? "",
                              renameMessage: "The name is saved on this iPhone and shown in the widget. Leave it empty to reset.")
                .deviceSurface(selected: true)
            if reading != nil {
                StationOutputCharts(history: model.outputHistory, station: id).panelHistorySurface()
            }
        }
    }

}
