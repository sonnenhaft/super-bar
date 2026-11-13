import SwiftUI

struct PhoneClimateView: View {
    @ObservedObject var tcl: ClimateStore
    @ObservedObject var lg: PhoneLG
    var expanded: Bool
    var open: () -> Void
    @Binding var selected: ClimateDeviceID?
    var close: () -> Void
    private var devices: [ClimateDeviceItem] {
        tcl.devices.map { ac in
            ClimateDeviceItem(id: .tcl(ac.id), name: ac.name, room: tempText(ac.indoor),
                target: ac.power == true ? tempText(ac.target) : "",
                power: ac.online == true && !ac.failed && !tcl.offline ? ac.power : nil, online: ac.online)
        } + lg.devices.map { device in
            ClimateDeviceItem(id: .lg(device.id), name: device.name, room: degree(device.room),
                target: device.power == true ? degree(device.target) : "",
                power: device.problem == nil ? device.power : nil, online: device.online)
        }
    }
    var body: some View {
        ClimateDeviceList(devices: devices, selected: expanded ? selected : nil, select: { id in
            if expanded && selected == id { selected = nil; close(); return }
            selected = id
            if case .tcl(let rawID) = id, let ac = tcl.devices.first(where: { $0.id == rawID }) { tcl.select(ac) }
            open()
        }) { id in
            switch id {
            case .tcl(let rawID):
                if let ac = tcl.devices.first(where: { $0.id == rawID }) {
                    PhoneTCLCard(store: tcl, ac: ac).phoneCard()
                }
            case .lg(let rawID):
                if let device = lg.devices.first(where: { $0.id == rawID }) {
                    PhoneLGCard(model: lg, device: device).phoneCard()
                }
            }
        }
        if devices.isEmpty {
            Text("Connect your air conditioners in Settings").foregroundStyle(.secondary).superBarSurface()
        }
        if expanded, let selected {
            if case .tcl = selected, let problem = tcl.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if case .lg = selected, let problem = lg.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct PhoneTCLCard: View {
    @ObservedObject var store: ClimateStore
    let ac: Aircon
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ac.name).font(.system(size: 13, weight: .semibold))
                    Text(ac.status + " · Room " + tempText(ac.indoor)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.set(ac, "powerSwitch", ac.power == true ? 0 : 1, "Power") } label: {
                    Image(systemName: "power").font(.title2).frame(width: 48, height: 48)
                        .background(ac.power == true ? SuperBarPanelStyle.cyan.opacity(0.2) : .white.opacity(0.06), in: Circle())
                }.disabled(!ac.has("powerSwitch") || ac.power == nil)
            }
            PanelTemperatureControl(name: ac.name, targetValue: tempText(ac.target), powerOn: ac.power,
                temperatureOptions: ac.has("targetTemperature") ? ac.setpoints : [],
                changeTemperature: { store.setTemperature(ac, $0) }, ecoEnabled: ac.code("ECO") == 1,
                trailingControl: ac.has(ac.fanField) ? AnyView(fanPicker) : nil)
            if ac.has("workMode") {
                Picker("Mode", selection: Binding(get: { ac.code("workMode") ?? -1 }, set: { store.set(ac, "workMode", $0, "Mode") })) {
                    if ac.code("workMode") == nil { Text("Unknown").tag(-1) }
                    ForEach(tclModes, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.menu)
            }
            HStack(spacing: 8) {
                if ac.ecoChanges != nil {
                    Button { store.toggleEco(ac) } label: { Label("Eco", systemImage: "leaf") }
                        .buttonStyle(.bordered)
                        .tint(ac.code("ECO") == 1 ? SuperBarPanelStyle.green : SuperBarPanelStyle.cyan)
                }
                Spacer(minLength: 0)
                ForEach([true, false], id: \.self) { vertical in
                    let axis = vertical ? "vertical" : "horizontal"
                    if ac.has(axis + "Direction") || ac.has(axis + "Switch") {
                        TCLAirflowPicker(ac: ac, vertical: vertical) { field, value in
                            store.set(ac, field, value, "Air direction")
                        }
                    }
                }
            }
            HStack {
                ForEach(TCLCoolingPreset.allCases, id: \.self) { preset in
                    Button { store.preset(ac, preset) } label: {
                        HStack(spacing: 6) {
                            Text("\(preset.degrees)°")
                            FanSpeedIcon(symbol: preset.fanSymbol).frame(width: 22, height: 22)
                        }
                    }.disabled(preset.fields(for: ac) == nil)
                        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                        .accessibilityLabel(preset.label)
                        .help(preset.label)
                }
            }.buttonStyle(.bordered)
            PhoneTCLHistory(history: store.history, name: ac.name)
            if store.isPending(id: ac.id) { ProgressView("Confirming setting…") }
            PhoneTimestamp(date: ac.sensorTime ?? store.statusDate)
        }.disabled(ac.online != true || ac.failed || store.offline || store.isPending(id: ac.id))
    }
    private var fanPicker: some View {
        PanelFanSpeedPicker(options: ac.fanSpeedOptions, selected: ac.selectedFanOption,
            currentSymbol: ac.currentFanSymbol, currentName: ac.fan) { level in
            if level == 0 { store.autoFan(ac, enabled: true) }
            else { store.setFan(ac, level: level) }
        }
    }
}

struct PhoneTCLHistory: View {
    @ObservedObject var history: EnergyHistory
    var name: String
    var body: some View {
        if let report = history.report(for: name) {
            if let period = EnergyPeriod.reading(report, now: Date()) {
                Text("Since 9am: " + period.text).font(.headline)
                Text(period.detail).font(.caption).foregroundStyle(.secondary)
            }
            EnergyCharts(days: report.days.map {
                EnergyDayPoint(key: $0.day.replacingOccurrences(of: "-", with: ""), label: String($0.day.suffix(2)), wattHours: $0.kwh * 1000)
            }, power: [])
        }
        let points = history.watts(for: name).map { PowerPoint(time: Date(timeIntervalSince1970: $0.timestamp), watts: $0.watts) }
        if !points.isEmpty { EnergyCharts(days: [], power: points) }
    }
}

struct PhoneLGCard: View {
    @ObservedObject var model: PhoneLG
    let device: PhoneLGDevice
    @State private var expanded = false
    private func send(_ group: String, _ key: String, _ value: Any) {
        Task { await model.send(device, group: group, key: key, value: value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                    if device.online == false { Text("Offline").foregroundStyle(.secondary) }
                    else if device.power == true { Text("Room " + degree(device.room)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { send("operation", "airConOperationMode", device.power == true ? "POWER_OFF" : "POWER_ON") } label: {
                    Image(systemName: "power").font(.title2).frame(width: 48, height: 48)
                        .background(device.power == true ? SuperBarPanelStyle.cyan.opacity(0.2) : .white.opacity(0.06), in: Circle())
                }.disabled(device.power == nil || !device.allowed("operation", "airConOperationMode", device.power == true ? "POWER_OFF" : "POWER_ON"))
            }
            PanelTemperatureControl(name: device.name, targetValue: degree(device.target), powerOn: device.power,
                temperatureOptions: Array(16...30).filter {
                    device.bounds.contains(Double($0)) && device.allowed("temperature", "targetTemperature", Double($0))
                }, changeTemperature: { send("temperature", "targetTemperature", Double($0)) })
            options("Mode", "airConJobMode", "currentJobMode")
            Button(expanded ? "Less" : "Fan & airflow") { expanded.toggle() }.buttonStyle(.bordered)
            if expanded {
                options("Fan", "airFlow", device.windKey)
                options("Vertical swing", "airFlow", "verticalStep")
                options("Horizontal swing", "airFlow", "horizontalStep")
                if let enabled = device.value("powerSave", "powerSaveEnabled"), device.writable("powerSave", "powerSaveEnabled") {
                    let on = (enabled as? Bool) == true || (enabled as? String) == "ON"
                    Button { send("powerSave", "powerSaveEnabled", enabled is String ? (on ? "OFF" : "ON") : !on) } label: { Label(on ? "Eco on" : "Eco off", systemImage: "leaf") }
                }
                if let watts = liveWatts(device.state) { Text("Power: " + DisplayUnits.power(watts)) }
                if let history = model.history[device.id] {
                    EnergyCharts(days: history, power: [])
                    Text("Completed calendar days · " + TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
                }
                if let problem = model.historyProblem[device.id] { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
            if let problem = device.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            PhoneTimestamp(date: device.checked)
        }.disabled(model.busy || device.checked == nil || Date().timeIntervalSince(device.checked ?? .distantPast) > 300)
            .task(id: expanded) { if expanded { await model.loadHistory(device) } }
    }
    @ViewBuilder private func options(_ label: String, _ group: String, _ key: String) -> some View {
        let choices = device.options(group, key)
        if !choices.isEmpty {
            Picker(label, selection: Binding(get: { device.value(group, key) as? String ?? "" }, set: { send(group, key, $0) })) {
                Text("Unknown").tag("")
                ForEach(choices, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }
        }
    }
}
