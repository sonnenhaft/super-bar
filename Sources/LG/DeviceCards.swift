import SwiftUI

// Passive summaries never replace the selected device's control state.
struct LGSample {
    var room: Double?
    var target: Double?
    var eco: Bool?
    var fan: String?
    var power: String?
    init(_ snapshot: [String: Any]) {
        let temperature = celsius(find("temperature", in: snapshot) ?? [:])
        room = lgNumber(temperature["currentTemperature"] ?? temperature["currentTemperatureC"])
        target = lgNumber(temperature["targetTemperature"] ?? temperature["targetTemperatureC"])
        eco = find("powerSaveEnabled", in: snapshot) as? Bool
        let flow = find("airFlow", in: snapshot) ?? [:]
        fan = ((find("windStrengthDetail", in: flow) ?? find("windStrength", in: flow)) as? String)?.capitalized
        power = find("airConOperationMode", in: find("operation", in: snapshot) ?? [:]) as? String
    }
    var status: String { power == "POWER_OFF" ? "OFF" : power == "POWER_ON" ? "ON" : "Connected" }
    func value(_ key: String) -> String {
        key == "sensor" ? degree(room) : power == "POWER_OFF" ? "OFF" : degree(target)
    }
}

extension App {
    func shown(_ key: String, for id: String) -> Bool {
        defaults.object(forKey: "lg.fields." + id + "." + key) as? Bool ?? defaults.bool(forKey: key)
    }
    func sample(for id: String) -> LGSample? {
        if id == selected {
            if connected { return LGSample(state) }
            guard polling else { return nil }
        }
        return samples[id]
    }
    func summaryValue(for id: String) -> String {
        guard let sample = sample(for: id) else { return "—" }
        if sample.power == "POWER_OFF" { return "OFF" + (sample.room.map { " / " + degree($0) } ?? "") }
        let preferred = defaults.string(forKey: "lg.lastField." + id)
        let keys = [preferred, "current", "sensor"].compactMap { $0 }
        return keys.first(where: { shown($0, for: id) && sample.value($0) != "—" }).map(sample.value) ?? "—"
    }
    func deviceCard(_ device: Device, expanded: Bool, summary: Bool = false) -> some View {
        let id = device.id, active = id == selected, sample = sample(for: id)
        let status = sample?.status ?? (active && polling ? "Reading…" : (active || checked[id] != nil ? "No reading" : "Waiting"))
        let displayed = BarSelection.shared.current == .lg && pinnedDeviceID == id
        func choose(_ key: String) {
            let visible = displayed && shown(key, for: id)
            pinnedDeviceID = id
            defaults.set(!visible, forKey: "lg.fields." + id + "." + key)
            BarSelection.shared.pin(.lg)
            updateStatus()
            objectWillChange.send()
        }
        return ClimateDeviceCard(brand: .lg, name: device.name, selected: expanded,
            status: active && !connected && sample != nil ? "Saved · " + status : status,
            metrics: [("current", "AC", "scope"), ("sensor", "Room", "thermometer.medium"), ("fanIndicator", "Fan", "fanblades"), ("ecoIndicator", "Eco", "leaf")].map { key, label, symbol in
                DeviceMetric(id: key, label: label, symbol: symbol, value: key == "fanIndicator" ? (sample?.fan ?? "—") : key == "ecoIndicator" ? (active ? self.ecoChoice.enabled.map { $0 ? "ON" : "OFF" } ?? "—" : "—") : key == "current" ? degree(sample?.target) : sample?.value(key) ?? "—",
                             visible: displayed && shown(key, for: id), toggle: { choose(key) })
            }, reading: active && polling, readAt: active ? lastRead : (sample == nil ? nil : checked[id]), refresh: {
                if self.selected == id { self.manualRefresh() } else { self.selectDevice(id) }
            }, select: { self.selectDevice(id); BarSelection.shared.activate(.lg) }, powerOn:sample?.power == nil ? nil : sample?.power == "POWER_ON",
            temperatureOptions:Array(16...26).filter { !active || profile.isEmpty || (Double($0) >= bounds().0 && Double($0) <= bounds().1 && allowed("temperature","targetTemperature",Double($0))) },
            changeTemperature:{ degree in self.useCard(id) { self.setDegrees(Double(degree)) } },
            turnOff:{ self.useCard(id) { self.send([("operation","airConOperationMode","POWER_OFF")]) } },
            livePower: (active && connected ? liveWatts(state) : snapshots[id].flatMap(liveWatts)).map(DisplayUnits.power),
            message: message.isEmpty ? nil : message, presets: AnyView(coolingPresets), summaryOnly: summary) {
                let hasProfile = active && !self.profile.isEmpty
                let options = self.speeds.filter { !hasProfile || self.allowed("airFlow", self.windKey, $0) }
                let speed = active ? self.displayValue("airFlow", self.windKey) as? String : sample?.fan?.uppercased()
                CardMenus(eco: active ? self.ecoChoice.enabled : sample?.eco,
                          toggleEco: { self.useCard(id) { self.toggleEco() } },
                          fan: options.isEmpty ? "" : (speed?.capitalized ?? "Fan"), fanLevel: FanIndicator.count(for: speed)) {
                    ForEach(options, id: \.self) { speed in
                        Button(speed.capitalized) { self.useCard(id) { self.send([("airFlow", self.windKey, speed)]) } }
                    }
                }.disabled(active && !self.connected && self.profile.isEmpty && !self.polling)
            }
    }

    private var coolingPresets: some View {
        CoolingPresetRow(enabled: { self.connected && self.presetAllowed(Double($0.degrees), $0.speed) },
            selected: { preset in
                self.powerIsOn && self.displayValue("airConJobMode", "currentJobMode") as? String == "COOL"
                    && self.displayValue("airFlow", self.windKey) as? String == preset.speed
                    && lgNumber(self.displayValue("temperature", "targetTemperature")) == Double(preset.degrees)
            }, apply: { self.preset(Double($0.degrees), $0.speed) }, showFanLevels: true)
    }

    func saveSnapshot(_ snapshot: [String: Any], for id: String) {
        snapshots[id] = snapshot
        samples[id] = LGSample(snapshot)
        recordPower(liveWatts(snapshot), for:id)
    }

    func rememberField(_ key: String) {
        defaults.set(key, forKey: "lg.lastField." + selected)
        panelChanged?()
    }

    func refreshOtherCards() {
        guard menuVisible, summaryTask == nil else { return }
        let pending = devices.map(\.id).filter { $0 != selected && Date().timeIntervalSince(checked[$0] ?? .distantPast) >= 60 }
        guard !pending.isEmpty else { return }
        summaryTask = Task {
            for id in pending {
                guard !Task.isCancelled, id != selected else { break }
                let result = try? await api.request("devices/\(id)/state")
                guard !Task.isCancelled else { return }
                checked[id] = Date()
                if let result { saveSnapshot(object(result), for: id) } else { samples[id] = nil; snapshots[id] = nil }
                panelChanged?()
            }
            if !Task.isCancelled { summaryTask = nil }
        }
    }
    func cancelOtherCards() {
        summaryTask?.cancel()
        summaryTask = nil
    }
}

@MainActor struct LGPanel: View {
    @ObservedObject var model: App
    @ObservedObject var selection: BarSelection
    var body: some View {
      if model.api.token.isEmpty {
        DeviceSelector(brand: .lg) {
            DeviceChoice(action: { model.openSettings() }) { Text("Sign in to LG ThinQ").font(.system(size: 12)) }
        }
      } else {
        VStack(alignment: .leading, spacing: 2) {
            if !model.devices.isEmpty {
                DeviceSelector(brand: .lg) {
                    ForEach(model.devices, id: \.id) { device in
                        model.deviceCard(device, expanded: selection.expanded == .lg && model.selected == device.id, summary: true)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(model.devices, id: \.id) { device in
                let active = selection.expanded == .lg && model.selected == device.id && !selection.detailsCollapsed
                if active {
                    model.deviceCard(device, expanded: true).padding(.leading, PanelLayout.logoColumn)
                }
            }
            if model.devices.isEmpty {
                Button { model.openSettings() } label: {
                    HStack { Text("Sign in to LG ThinQ"); Spacer() }
                }.buttonStyle(.plain).overviewSurface(selected: false)
            }
        }
      }
    }
    @ViewBuilder var charts: some View {
        Text((model.devices.first { $0.id == model.selected }?.name ?? "LG") + " · LG")
            .font(.caption).foregroundStyle(.secondary)
        EnergyCharts(days: Array(model.weekBars.suffix(ChartHistory.dayCount)).map {
            EnergyDayPoint(key: $0.day, label: $0.label, wattHours: $0.wh)
        }, power: model.powerSamples[model.selected] ?? [], currentDay: true)
    }
}
