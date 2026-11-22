import SwiftUI

struct PhoneClimateView: View {
    @ObservedObject var tcl: ClimateStore
    @ObservedObject var lg: PhoneLG
    var expanded: Bool
    var open: () -> Void
    @Binding var selected: ClimateDeviceID?
    var close: () -> Void
    var requested: ClimateDeviceID? = nil
    var showSummaries = true
    var devices: [ClimateDeviceItem] {
        tcl.devices.map { ac in
            ClimateDeviceItem(id: .tcl(ac.id), name: ac.name, room: tempText(ac.indoor),
                target: ac.power == true ? tempText(ac.target) : "",
                power: ac.online == true && !ac.failed && !tcl.offline ? ac.power : nil,
                online: ac.online, indicators: tcl.reportedIndicators(for: ac.id))
        } + lg.devices.map { raw in
            let device = lg.displayDevice(raw)
            return ClimateDeviceItem(id: .lg(device.id), name: device.name, room: device.roomReading,
                target: device.power == true ? degree(device.target) : "",
                power: device.problem == nil ? device.power : nil, online: device.online, indicators: raw.indicators)
        }
    }
    func selectDevice(_ id: ClimateDeviceID) {
            if expanded && selected == id { selected = nil; close(); return }
            selected = id
            if case .tcl(let rawID) = id, let ac = tcl.devices.first(where: { $0.id == rawID }) { tcl.select(ac) }
            open()
    }
    var body: some View {
        ClimateDeviceList(showSummaries: showSummaries, devices: devices, selected: expanded ? selected : nil, select: { id in
            selectDevice(id)
        }) { id in
            switch id {
            case .tcl(let rawID):
                if let ac = tcl.devices.first(where: { $0.id == rawID }) {
                    PhoneTCLCard(store: tcl, ac: ac)
                }
            case .lg(let rawID):
                if let device = lg.devices.first(where: { $0.id == rawID }) {
                    PhoneLGCard(model: lg, device: lg.displayDevice(device))
                }
            }
        }
        if expanded, let requested, requested == selected {
            // A widget may contain the last known reading. Keep its exact target
            // open even if the online filter hides the summary tile after launch.
            switch requested {
            case .tcl(let id):
                if let ac = tcl.devices.first(where: { $0.id == id }), ac.online == false {
                    PhoneTCLCard(store: tcl, ac: ac)
                } else if !tcl.devices.contains(where: { $0.id == id }) {
                    Text(tcl.didRead ? "The selected air conditioner is unavailable." : "Loading the selected air conditioner…")
                        .foregroundStyle(.secondary).superBarSurface()
                }
            case .lg(let id):
                if let device = lg.devices.first(where: { $0.id == id }), device.online == false {
                    PhoneLGCard(model: lg, device: lg.displayDevice(device))
                } else if !lg.devices.contains(where: { $0.id == id }) {
                    Text(lg.mayRestoreWidgetList ? "Loading the selected air conditioner…" : "The selected air conditioner is unavailable.")
                        .foregroundStyle(.secondary).superBarSurface()
                }
            }
        } else if devices.isEmpty {
            Text("Connect your air conditioners in Settings").foregroundStyle(.secondary).superBarSurface()
        }
        if expanded, let selected {
            if case .lg = selected, let problem = lg.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
    }
}

// Platform adapters only: both providers render the desktop-based shared cards.
struct PhoneTCLCard: View {
    @ObservedObject var store: ClimateStore
    let ac: Aircon
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TCLDeviceDetails(store: store, ac: ac)
            VStack(alignment: .leading, spacing: 8) {
                Text(DeviceDisplayName.clean(ac.name)).font(.caption).foregroundStyle(.secondary)
                EnergyChartView(history: store.history, device: ac.id)
            }.panelHistorySurface()
        }
    }
}

struct PhoneLGCard: View {
    @ObservedObject var model: PhoneLG
    let device: PhoneLGDevice
    private func send(_ group: String, _ key: String, _ value: Any) {
        guard device.allowed(group, key, value) else { return }
        model.send(device, group: group, key: key, value: value)
    }
    var body: some View {
        let eco = model.ecoChoice(device)
        let speed = device.value("airFlow", device.windKey) as? String
        ClimateDeviceCard(windowUnit: true, name: device.name, selected: true,
            status: device.online == false ? "Offline" : device.problem ?? "",
            metrics: [
                DeviceMetric(id: "current", label: "AC", symbol: "scope", value: degree(device.target)),
                DeviceMetric(id: "sensor", label: "Room", symbol: "thermometer.medium", value: device.roomReading),
                DeviceMetric(id: "fanIndicator", label: "Fan", symbol: "fanblades", value: speed ?? "—"),
                DeviceMetric(id: "ecoIndicator", label: "Eco", symbol: "leaf", value: eco.enabled.map { $0 ? "ON" : "OFF" } ?? "—")
            ], reading: model.isUpdating(device.id), readAt: device.checked,
            refresh: { Task { await model.refreshAndWait() } }, select: {}, powerOn: device.power,
            indicators: device.power == true && device.online != false && device.problem == nil
                ? ClimateIndicators(eco: eco.enabled == true, lgSpeed: speed) : ClimateIndicators(),
            temperatureOptions: Array(16...30).filter {
                device.bounds.contains(Double($0)) && device.allowed("temperature", "targetTemperature", Double($0))
            }, changeTemperature: { send("temperature", "targetTemperature", Double($0)) },
            setPower: { send("operation", "airConOperationMode", $0 ? "POWER_ON" : "POWER_OFF") },
            powerEnabled: device.allowed("operation", "airConOperationMode", device.power == true ? "POWER_OFF" : "POWER_ON"),
            controlsEnabled: device.online != false && device.checked != nil,
            livePower: liveWatts(device.state).map(DisplayUnits.power),
            message: model.commandErrors[device.id] ?? device.problem,
            presets: AnyView(CoolingPresetRow<LGCoolingPreset>(label: { "\($0.degrees)°" },
                enabled: { model.presetAllowed(device, $0) },
                selected: { device.power == true && device.target == Double($0.degrees)
                    && speed == $0.speed && device.value("airConJobMode", "currentJobMode") as? String == "COOL" },
                apply: { model.preset(device, $0) }, fanLevel: { $0.fanLevel }, accessibilityName: { $0.label }))) {
                CardMenus(eco: eco.enabled, toggleEco: { model.toggleEco(device) }, ecoEnabled: eco.change != nil) {
                    LGFanSpeedPicker(options: ["LOW", "MID", "HIGH"].filter { device.allowed("airFlow", device.windKey, $0) },
                                     selected: speed) { send("airFlow", device.windKey, $0) }
                }
            }
        VStack(alignment: .leading, spacing: 8) {
            Text(device.name).font(.caption).foregroundStyle(.secondary)
            LGEnergyCharts(id: device.id, api: model.api)
        }.panelHistorySurface()
    }
}
