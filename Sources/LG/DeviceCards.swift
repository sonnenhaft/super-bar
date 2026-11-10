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
        let preferred = defaults.string(forKey: "lg.lastField." + id)
        let keys = [preferred, "current", "sensor"].compactMap { $0 }
        return keys.first(where: { shown($0, for: id) && sample.value($0) != "—" }).map(sample.value) ?? "—"
    }
    func deviceCard(_ device: Device) -> some View {
        let id = device.id, active = id == selected, sample = sample(for: id)
        let status = sample?.status ?? (active && polling ? "Reading…" : (active || checked[id] != nil ? "No reading" : "Waiting"))
        func choose(_ key: String) {
            let visible = shown(key, for: id)
            if !active { selectDevice(id) }
            if !active && visible {
                if key != "icon" { rememberField(key) }
            } else { toggleVisibility(key) }
        }
        return ClimateDeviceCard(brand: .lg, iconVisible: active && shown("icon", for: id),
            toggleIcon: { choose("icon") }, name: device.name, selected: active,
            status: active && !connected && sample != nil ? "Saved · " + status : status,
            metrics: [("current", "AC", "scope"), ("sensor", "Room", "thermometer.medium"), ("fanIndicator", "Fan", "fanblades"), ("ecoIndicator", "Eco", "leaf")].map { key, label, symbol in
                DeviceMetric(id: key, label: label, symbol: symbol, value: key == "fanIndicator" ? (sample?.fan ?? "—") : key == "ecoIndicator" ? (active ? self.ecoChoice.enabled.map { $0 ? "ON" : "OFF" } ?? "—" : "—") : sample?.value(key) ?? "—",
                             visible: active && shown(key, for: id), toggle: { choose(key) })
            }, reading: active && polling, readAt: active ? lastRead : (sample == nil ? nil : checked[id]), refresh: {
                if self.selected == id { self.manualRefresh() } else { self.selectDevice(id) }
            }, select: { self.selectDevice(id) }) {
                let limits = self.bounds()
                let degrees = (16...26).filter { degree in
                    !active || (Double(degree) >= limits.0 && Double(degree) <= limits.1 && self.allowed("temperature", "targetTemperature", Double(degree)))
                }
                let options = self.speeds.filter { !active || self.allowed("airFlow", self.windKey, $0) }
                let speed = active ? self.displayValue("airFlow", self.windKey) as? String : sample?.fan?.uppercased()
                let target = sample?.value("current") ?? "—"
                CardMenus(degrees: degrees, target: target,
                          off: { self.useCard(id) { self.send([("operation", "airConOperationMode", "POWER_OFF")]) } },
                          eco: active ? self.ecoChoice.enabled : sample?.eco,
                          toggleEco: { self.useCard(id) { self.toggleEco() } },
                          change: { degrees in self.useCard(id) { self.setDegrees(Double(degrees)) } },
                          fan: options.isEmpty ? "" : (speed?.capitalized ?? "Fan") + String(repeating: "•", count: FanIndicator.count(for: speed))) {
                    ForEach(options, id: \.self) { speed in
                        Button(speed.capitalized) { self.useCard(id) { self.send([("airFlow", self.windKey, speed)]) } }
                    }
                }.disabled(active && !self.connected)
            }
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
                samples[id] = result.map { LGSample(object($0)) }
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
