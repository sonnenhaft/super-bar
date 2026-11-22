import SwiftUI
import AppKit

extension LGStore {
    func shown(_ key: String, for id: String) -> Bool {
        defaults.object(forKey: "lg.fields." + id + "." + key) as? Bool ?? defaults.bool(forKey: key)
    }
    func sample(for id: String) -> LGSample? {
        if id == selected {
            if connected { return LGSample(state) }
            guard polling || sending else { return nil }
        }
        return samples[id]
    }
    func deviceCard(_ device: Device, expanded: Bool) -> some View {
        let id = device.id, active = id == selected, sample = sample(for: id)
        let operation = active ? displayValue("operation", "airConOperationMode") as? String : nil
        let powerOn = operation.map { $0 == "POWER_ON" } ?? sample?.powerOn
        let speed = active ? displayValue("airFlow", windKey) as? String : sample?.fan?.uppercased()
        let eco = active ? ecoChoice.enabled : sample?.eco
        let status = sample?.status ?? (active && polling ? "Reading…" : (active || checked[id] != nil ? "No reading" : "Waiting"))
        let displayed = BarSelection.shared.current == .lg && pinnedDeviceID == id
        return ClimateDeviceCard(windowUnit: true, name: device.name, selected: expanded,
            status: active && !connected && sample != nil ? "Saved · " + status : status,
            metrics: [("current", "AC", "scope"), ("sensor", "Room", "thermometer.medium"), ("fanIndicator", "Fan", "fanblades"), ("ecoIndicator", "Eco", "leaf")].map { key, label, symbol in
                DeviceMetric(id: key, label: label, symbol: symbol, value: key == "fanIndicator" ? (sample?.fan ?? "—") : key == "ecoIndicator" ? (active ? self.ecoChoice.enabled.map { $0 ? "ON" : "OFF" } ?? "—" : "—") : key == "current" ? degree(active ? displayedTarget : sample?.target) : sample?.value(key) ?? "—",
                             visible: displayed && shown(key, for: id), toggle: { self.toggleVisibility(key, for: id) })
            }, reading: active && (polling || sending), readAt: active ? lastRead : (sample == nil ? nil : checked[id]), refresh: {
                if self.selected == id { self.manualRefresh() } else { self.selectDevice(id) }
            }, select: { self.selectDevice(id); BarSelection.shared.activate(.lg) }, powerOn: powerOn,
            indicators: powerOn == true && sample?.online != false ? ClimateIndicators(eco: eco == true, lgSpeed: speed) : ClimateIndicators(),
            temperatureOptions:Array(16...26).filter { !active || profile.isEmpty || (Double($0) >= bounds().0 && Double($0) <= bounds().1 && allowed("temperature","targetTemperature",Double($0))) },
            changeTemperature:{ degree in self.useCard(id) { self.setDegrees(Double(degree)) } },
            setPower: { on in self.useCard(id) { self.send([("operation", "airConOperationMode", on ? "POWER_ON" : "POWER_OFF")]) } },
            livePower: (active && connected ? liveWatts(state) : snapshots[id].flatMap(liveWatts)).map(DisplayUnits.power),
            message: active && !message.isEmpty ? message : nil, presets: AnyView(coolingPresets(for: id))) {
                let hasProfile = active && !self.profile.isEmpty
                let options = self.speeds.filter { !hasProfile || self.allowed("airFlow", self.windKey, $0) }
                CardMenus(eco: eco, toggleEco: { self.useCard(id) { self.toggleEco() } },
                          ecoEnabled: active && self.ecoChoice.change != nil) {
                          LGFanSpeedPicker(options: options, selected: speed) { value in
                              self.useCard(id) { self.send([("airFlow", self.windKey, value)]) }
                          }
                          }.disabled(active && !self.connected && self.profile.isEmpty && !self.polling)
            }
    }

    private func coolingPresets(for id: String) -> some View {
        CoolingPresetRow<LGCoolingPreset>(label: { "\($0.degrees)°" },
            enabled: { self.canSelectPreset($0, for: id) },
            selected: { self.isSelectedPreset($0, for: id) },
            apply: { self.selectPreset($0, for: id) }, fanLevel: { $0.fanLevel }, accessibilityName: { $0.label })
    }

    func saveSnapshot(_ snapshot: [String: Any], for id: String) {
        snapshots[id] = snapshot
        samples[id] = LGSample(snapshot)
        DevicePowerHistory.lg.record(liveWatts(snapshot), for: id)
    }

    func refreshOtherCards() {
        guard panelVisible, summaryTask == nil else { return }
        let cutoff = summaryRequestedAt ?? Date().addingTimeInterval(-Double(RefreshPreferences.seconds(.lg)))
        let pending = devices.map(\.id).filter { $0 != selected && (checked[$0] ?? .distantPast) < cutoff }
        guard !pending.isEmpty else { summaryRequestedAt = nil; return }
        summaryTask = Task {
            for id in pending {
                guard !Task.isCancelled, id != selected else { break }
                let result = try? await api.request("devices/\(try API.deviceComponent(id))/state")
                guard !Task.isCancelled else { return }
                checked[id] = Date()
                if let result { saveSnapshot(object(result), for: id) } else { samples[id] = nil; snapshots[id] = nil }
                if id == pinnedDeviceID { updateStatus() } else { panelChanged?() }
            }
            guard !Task.isCancelled else { return }
            summaryTask = nil
            // A manual click during this pass may still need cards read before the click.
            if summaryRequestedAt != nil { refreshOtherCards() }
            panelChanged?()
        }
    }
    func cancelOtherCards() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryRequestedAt = nil
    }
}

@MainActor struct LGPanel: View {
    @ObservedObject var model: LGStore
    @ObservedObject var selection: BarSelection
    var body: some View {
        if model.api.needsSignIn || model.devices.isEmpty {
            if !model.message.isEmpty && !model.api.needsSignIn && !AccountConnection.signedOut("lg") {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                defaults.set("LG ThinQ", forKey: "settings.accountProvider")
                selection.openSettings()
            } label: {
                HStack { Text("Connect LG ThinQ in Settings"); Spacer() }
            }.panelButtonStyle().overviewSurface(selected: false)
        } else if selection.expanded == .lg && !selection.detailsCollapsed,
                  let device = model.devices.first(where: { $0.id == model.selected }) {
            model.deviceCard(device, expanded: true)
        }
    }
    @ViewBuilder var charts: some View {
        Text((model.devices.first { $0.id == model.selected }?.name ?? ""))
            .font(.caption).foregroundStyle(.secondary)
        LGEnergyCharts(id: model.selected, api: model.api)
    }
}

/// The small filled discs keep their shape at menu-bar font sizes.
final class FanIndicator {
  private var cachedCount = 0
  private var cachedSize: CGFloat = 0
  private var cachedColor: NSColor?
  private var cached: NSAttributedString?

  static func count(for speed: String?) -> Int {
    ClimateIndicators.lgLevel(speed) ?? 0
  }

  func attachment(speed: String?, fontSize: CGFloat, color: NSColor) -> NSAttributedString? {
    let count = Self.count(for: speed)
    guard count > 0 else { return nil }
    if count == cachedCount, fontSize == cachedSize, color == cachedColor { return cached }
    let diameter = fontSize * 0.28
    let gap = fontSize * 0.05
    let size = NSSize(width: ceil(diameter + 2.5), height: fontSize)
    let image = NSImage(size: size, flipped: false) { rect in
      color.setFill()
      let stack = 3 * diameter + 2 * gap
      for i in 0..<count {
        let dot = NSRect(
          x: (rect.width - diameter) / 2,
          y: (rect.height - stack) / 2 + CGFloat(i) * (gap + diameter), width: diameter,
          height: diameter)
        NSBezierPath(ovalIn: dot).fill()
      }
      return true
    }
    let marker = NSTextAttachment()
    marker.image = image
    marker.bounds = NSRect(x: 0, y: -fontSize * 0.14, width: size.width, height: size.height)
    cached = NSAttributedString(attachment: marker)
    cachedCount = count
    cachedSize = fontSize
    cachedColor = color
    return cached
  }
}
