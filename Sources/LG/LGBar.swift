import AppKit
import Combine
import ServiceManagement

let intervals: [Double] = [1, 5, 30, 60, 300, 600]
let intervalNames = ["1 sec", "5 sec", "30 sec", "1 min", "5 min", "10 min"]
func ago(_ date: Date?) -> String {
  guard let d = date else { return "Not updated" }
  let s = max(0, Int(Date().timeIntervalSince(d)))
  return s < 60 ? "\(s)s ago" : s < 3600 ? "\(s/60)m ago" : "\(s/3600)h ago"
}
@MainActor final class App: NSObject, ObservableObject, NSApplicationDelegate, NSMenuDelegate {
  let readout = NSButton()
  var didRender: (() -> Void)?
  var panelChanged: (() -> Void)?
  var panelSections: [DeviceSection] = []
  let menu = NSMenu()
  var settings: NSWindow?
  var devices: [Device] = []
  var state: [String: Any] = [:]
  private var capabilityCache: [String: [String: Any]] = [:]
  var profile: [String: Any] = [:] {
    didSet {
      capabilityCache.removeAll(keepingCapacity: true)
      windKey =
        find("windStrengthDetail", in: profile) != nil ? "windStrengthDetail" : "windStrength"
    }
  }
  private var profiles: [String: [String: Any]] = [:]
  private lazy var launchAtLogin = SMAppService.mainApp.status == .enabled
  var connected = false
  @Published var selected = defaults.string(forKey: "selected") ?? "" {
    didSet { if oldValue != selected { defaults.set(selected, forKey: "selected") } }
  }
  var snapshots: [String: [String: Any]] = [:]
  var polling = false { didSet { updateHeader() } }
  var sending = false { didSet { updateHeader() } }
  var generation = 0
  var autoRetry = AutoRetry()
  var selections = SelectionState()
  lazy var api = API()
  let emblem = lgIcon()
  let fanIndicator = FanIndicator()
  let locationWeather = LocationWeather()
  let ecoSymbol = "♻️"
  var summaryTask: Task<Void, Never>?
  var samples: [String: LGSample] = [:]
  var checked: [String: Date] = [:]
  private var commandStatusItem: NSMenuItem?
  private var readStatusItem: NSMenuItem?
  private var lastReadResult = "No response yet"
  private var lastCommandResult = "None sent"
  private func recordCommand(_ status: String) {
    lastCommandResult = status + " · " + Date().formatted(date: .omitted, time: .standard)
    updateHeader()
  }
  var errorItem: NSMenuItem?
  var displayRows: [String: ActionRow] = [:]
  let speeds = ["LOW", "MID", "HIGH"]
  var powerRow: ActionRow?
  var refreshRow: ActionRow?
  var monthItem: NSMenuItem?
  var powerItem: NSMenuItem?
  var energySeparator: NSMenuItem?
  var chartItem: NSMenuItem?
  var weekBars: [DayUsage] = []
  var historyFailures = 0
  var textColor: NSColor? { BarSelection.shared.color }
  var menuVisible = false

  var pollTask: Task<Void, Never>?
  var commandTask: Task<Void, Never>?
  var energyTask: Task<Void, Never>? { didSet { updateHeader() } }
  var timer: Timer?
  var ageTimer: Timer?
  var lastRead: Date?
  var lastEnergy: Date?
  var message = ""
  var observedUse = ObservedUse()
  var sensor: Double? {
    lgNumber(temperatures["currentTemperature"] ?? temperatures["currentTemperatureC"])
  }
  var current: Double? {
    lgNumber(temperatures["targetTemperature"] ?? temperatures["targetTemperatureC"])
  }
  var temperatures: [String: Any] { celsius(find("temperature", in: state) ?? [:]) }
  var windKey = "windStrength"
  var tokenSecure = NSSecureTextField()
  var tokenPlain = NSTextField()
  var eye = NSButton()
  var countries = NSComboBox()
  var regions = NSComboBox()
  var settingsNotice = NSTextField(wrappingLabelWithString: "")
  var countryOptions: [(String, String)] = []
  let regionOptions = [
    ("kic", "Asia / Pacific"), ("eic", "Europe / Middle East / Africa"), ("aic", "Americas"),
  ]
  func applicationDidFinishLaunching(_ n: Notification) {
    defaults.register(defaults: [
      "font": 13.0, "icon": true, "sensor": true, "current": true, "interval": 60.0,
      "locationWeather": true, "fanIndicator": true, "ecoIndicator": true,
    ])
    menu.delegate = self
    menu.autoenablesItems = false
    updateStatus()
    locationWeather.changed = { [weak self] in
      guard let self else { return }
      self.buildMenu()
    }
    startTimer()
    refresh()
  }
  func startTimer() {
    timer?.invalidate()
    guard !autoRetry.stopped else { return }
    let interval = max(autoRetry.delay, max(1, defaults.double(forKey: "interval")))
    let t = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    t.tolerance = min(2, interval * 0.1)
    timer = t
    RunLoop.main.add(t, forMode: .common)
  }
  func menuWillOpen(_ m: NSMenu) {
    guard m === menu else { return }
    menuVisible = true
    if panelSections.isEmpty || menuDeviceID != selected { buildMenu() }
    refreshOtherCards()
    locationWeather.start()
    updateStatus()
    updateAge()
    ageTimer?.invalidate()
    let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.updateAge()
        self?.updateEnergyRows()
      }
    }
    ageTimer = t
    RunLoop.main.add(t, forMode: .common)
  }
  func updateAge() { refreshRow?.right.stringValue = ago(lastRead) }
  func updateHeader() {
    guard menuVisible else { return }
    readStatusItem?.title = "Read: " + (polling ? "Checking…" : lastReadResult)
    commandStatusItem?.title = "Command: " + lastCommandResult
    errorItem?.title = message
    errorItem?.isHidden = message.isEmpty
    panelChanged?()
  }
  @discardableResult func item(
    _ title: String, _ action: Selector? = nil, _ represented: Any? = nil
  ) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
    i.target = self
    i.representedObject = represented
    menu.addItem(i)
    return i
  }
  func custom(_ view: NSView) {
    let i = NSMenuItem()
    i.view = view
    menu.addItem(i)
  }
  func row(
    _ title: String, _ suffix: String = "", _ color: NSColor = .labelColor,
    _ action: @escaping () -> Void
  ) -> ActionRow {
    let r = ActionRow(title, suffix, color, action)
    custom(r)
    return r
  }
  func value(_ group: String, _ key: String) -> Any? {
    find(key, in: find(group, in: state) ?? [:])
  }
  func capability(_ group: String, _ key: String) -> [String: Any] {
    let cacheKey = group + "." + key
    if let cached = capabilityCache[cacheKey] { return cached }
    let g = find(group, in: profile) ?? [:]
    let source: Any = group == "temperature" ? celsius(g) : g
    var c = object(find(key, in: source) ?? [:])
    if let v = object(c["value"] ?? [:])["w"] {
      c["writeValues"] = v
      if let r = v as? [String: Any] { for (k, v) in r { c[k] = v } }
    }
    capabilityCache[cacheKey] = c
    return c
  }
  func canWrite(_ g: String, _ k: String) -> Bool {
    let c = capability(g, k)
    if c["mode"] == nil && c["writable"] == nil { return c["writeValues"] != nil }
    return c["writable"] as? Bool == true || (c["mode"] as? [String])?.contains("w") == true
      || (c["mode"] as? String)?.contains("w") == true
  }
  func allowed(_ g: String, _ k: String, _ v: Any) -> Bool {
    guard canWrite(g, k) else { return false }
    let c = capability(g, k)
    if let a = c["writeValues"] as? [Any] { return a.contains { equal($0, v) } }
    if let n = lgNumber(v) {
      if let lo = lgNumber(c["min"]), n < lo { return false }
      if let hi = lgNumber(c["max"]), n > hi { return false }
    }
    return true
  }
  private var priorEcoMode: String?
  var ecoChoice: EcoChoice {
    let flag = capability("powerSave", "powerSaveEnabled")
    let mode = capability("airConJobMode", "currentJobMode")
    let writable = canWrite("powerSave", "powerSaveEnabled")
    let modes =
      canWrite("airConJobMode", "currentJobMode") ? (mode["writeValues"] as? [String] ?? []) : []
    return EcoChoice(
      flag: displayValue("powerSave", "powerSaveEnabled"),
      flagWrites: flag["writeValues"] as? [Any],
      writableFlag: writable, mode: displayValue("airConJobMode", "currentJobMode") as? String,
      modes: modes, returnMode: priorEcoMode)
  }
  func toggleEco() {
    let choice = ecoChoice
    guard let change = choice.change else {
      message = "Eco control unavailable for this device"
      updateHeader()
      return
    }
    if change.0 == "airConJobMode", choice.enabled == false {
      priorEcoMode = displayValue("airConJobMode", "currentJobMode") as? String
    }
    var changes = [change]
    if let temperature = displayValue("temperature", "targetTemperature"),
      allowed("temperature", "targetTemperature", temperature) {
      changes.append(("temperature", "targetTemperature", temperature))
    }
    if let speed = displayValue("airFlow", windKey), allowed("airFlow", windKey, speed) {
      changes.append(("airFlow", windKey, speed))
    }
    send(changes)
  }
  func bounds() -> (Double, Double) {
    let c = capability("temperature", "targetTemperature")
    return (
      lgNumber(temperatures["minTargetTemperature"]) ?? lgNumber(c["min"]) ?? 16,
      lgNumber(temperatures["maxTargetTemperature"]) ?? lgNumber(c["max"]) ?? 30
    )
  }
  func updateStatus() {
    let size = CGFloat(BarSelection.shared.size)
    let speed = displayValue("airFlow", windKey) as? String
    let eco = ecoChoice.enabled
    let set = lgNumber(displayValue("temperature", "targetTemperature")) ?? current
    var readings: [(text: String, isAC: Bool)] = []
    if let sample = sample(for: selected) {
      if shown("current", for: selected) {
        let value = connected && !isReportedOff ? degree(set) : sample.value("current")
        readings.append((value, true))
      }
      if shown("sensor", for: selected) { readings.append((sample.value("sensor"), false)) }
    }
    if defaults.bool(forKey: "locationWeather"), let temperature = locationWeather.temperature {
      readings.append((degree(temperature), false))
    }
    var displayChanged = false
    defer { if displayChanged { didRender?() } }
    let button = readout
    if isReportedOff { readings.removeAll() }
    let icon = isReportedOff || shown("icon", for: selected) ? emblem : nil
    if button.image !== icon { button.image = icon; displayChanged = true }
    if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading; displayChanged = true }
    var attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    ]
    if let textColor { attrs[.foregroundColor] = textColor }
    let title = NSMutableAttributedString(string: "")
    let stacked = readings.count == 3
    for (index, reading) in readings.enumerated() {
      if stacked && index == 1 {
        title.append(NSAttributedString(string: " / ", attributes: attrs))
        title.append(temperatureStack(
          room: reading.text, outside: readings[2].text, fontSize: size,
          color: textColor ?? .labelColor))
        break
      }
      if index > 0 { title.append(NSAttributedString(string: " / ", attributes: attrs)) }
      if reading.isAC && shown("ecoIndicator", for: selected) && eco == true && !isReportedOff {
        title.append(NSAttributedString(string: ecoSymbol, attributes: attrs))
      }
      var style = attrs
      if reading.text == "OFF" { style[.font] = NSFont.systemFont(ofSize: size, weight: .bold) }
      title.append(NSAttributedString(string: reading.text, attributes: style))
      if reading.isAC && connected && !isReportedOff && shown("fanIndicator", for: selected),
        let dots = fanIndicator.attachment(
          speed: speed, fontSize: size, color: textColor ?? .labelColor)
      {
        title.append(dots)
      }
    }
    if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title; displayChanged = true }
    guard menuVisible else { return }
    updateHeader()
    powerRow?.button.font = .boldSystemFont(ofSize: 13)
    powerRow?.button.title = powerIsOn ? "Turn OFF" : "Turn ON"
    updateEnergyRows()
  }
  func reported(_ g: String, _ k: String) -> Any? {
    g == "temperature" && k == "targetTemperature" ? current : value(g, k)
  }
  func displayValue(_ g: String, _ k: String) -> Any? {
    selections.display(g, k) ?? reported(g, k)
  }
  var isReportedOff: Bool { connected && (reported("operation", "airConOperationMode") as? String) == "POWER_OFF" }
  var powerIsOn: Bool { displayValue("operation", "airConOperationMode") as? String == "POWER_ON" }
  var menuDeviceID: String?
  func buildMenu() {
    menuDeviceID = profile.isEmpty ? nil : selected
    menu.removeAllItems()
    panelSections.removeAll()
    var start = 0
    func finish(_ title: String, _ symbol: String) {
      let items = Array(menu.items.dropFirst(start))
      panelSections.append(DeviceSection(title: title, symbol: symbol, items: items))
      start = menu.numberOfItems
    }
    powerRow = nil
    displayRows = [:]
    readStatusItem = item("Read: " + lastReadResult)
    commandStatusItem = item("Command: " + lastCommandResult)
    readStatusItem?.isEnabled = false
    commandStatusItem?.isEnabled = false
    errorItem = item(message)
    errorItem?.isEnabled = false
    menu.addItem(.separator())
    refreshRow = row("Refresh", ago(lastRead)) { [weak self] in self?.manualRefresh() }
    refreshRow?.button.image = NSImage(
      systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    refreshRow?.button.imagePosition = .imageLeading
    menu.addItem(.separator())
    finish("Connection", "antenna.radiowaves.left.and.right")
    if let name = locationWeather.name {
      let visible = defaults.bool(forKey: "locationWeather")
      let location = row(
        "Local weather · " + (visible ? "ON" : "OFF"),
        degree(locationWeather.temperature)
      ) { [weak self] in
        defaults.set(!defaults.bool(forKey: "locationWeather"), forKey: "locationWeather")
        self?.buildMenu()
      }
      location.button.frame.size.width = 205
      location.button.cell?.lineBreakMode = .byTruncatingTail
      location.toolTip = "Current location: \(name) · Weather: Open-Meteo"
    } else {
      _ = row(locationWeather.allowed ? "Refresh location" : "Allow location access…") { [weak self] in
        self?.locationWeather.permit()
      }
    }
    if locationWeather.allowed && !locationWeather.notice.isEmpty {
      let retry = row(locationWeather.notice) { [weak self] in self?.locationWeather.refresh() }
      retry.button.isEnabled = !locationWeather.notice.contains("…")
    }
    menu.addItem(.separator())
    buildAppearanceRows()
    let login = item("Launch at login", #selector(login))
    login.state = launchAtLogin ? .on : .off
    menu.addItem(.separator())
    item("LG settings…", #selector(openSettings))
    finish("Settings", "gearshape")
    energySeparator = .separator()
    menu.addItem(energySeparator!)
    powerItem = item("")
    powerItem?.isEnabled = false
    monthItem = item("")
    monthItem?.isEnabled = false
    let chart = NSMenuItem()
    chart.view = WeekChart()
    menu.addItem(chart)
    chartItem = chart
    menu.addItem(.separator())
    finish("Energy", "bolt.fill")
    updateStatus()
  }
  func updateEnergyRows() {
    guard menuVisible else { return }
    defer { panelChanged?() }
    let watts = connected ? liveWatts(state) : nil
    powerItem?.isHidden = watts == nil
    if let watts { powerItem?.title = String(format: "Power now  %.2f ⚡ kW", watts / 1000) }
    let now = Date()
    let monthWh = weekHistory.month == WeekHistory.monthKey(now, .current) ? weekHistory.monthWh : nil
    monthItem?.isHidden = monthWh == nil
    if let monthWh {
      let month = now.formatted(.dateTime.month(.wide).locale(Locale(identifier: "en_US")))
      monthItem?.title = "\(month) so far  " + formatEnergy(monthWh)
    }
    let showChart = weekBars.contains { $0.wh != nil }
    chartItem?.isHidden = !showChart
    (chartItem?.view as? WeekChart)?.days = weekBars
    energySeparator?.isHidden = watts == nil && !showChart && monthWh == nil
  }
  func buildAppearanceRows() {
    let ix = intervals.firstIndex(of: defaults.double(forKey: "interval")) ?? 3
    let interval = SliderRow(
      value: Double(ix), min: 0, max: 5, ticks: 6, format: { intervalNames[Int($0.rounded())] }
    ) { [weak self] v in
      defaults.set(intervals[Int(v.rounded())], forKey: "interval")
      self?.startTimer()
    }
    interval.topLabel("Refresh interval")
    custom(interval)
  }
  private static let visibilityLabels = ["icon": "LG icon", "current": "AC temperature or OFF",
                                         "sensor": "room temperature", "fanIndicator": "fan indicator",
                                         "ecoIndicator": "eco indicator"]
  func toggleVisibility(_ key: String) {
    let visible = !shown(key, for: selected)
    defaults.set(visible, forKey: "lg.fields." + selected + "." + key)
    if visible && (key == "current" || key == "sensor") { rememberField(key) }
    updateStatus()
  }
  @objc func login() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch { message = error.localizedDescription }
    launchAtLogin = SMAppService.mainApp.status == .enabled
    buildMenu()
  }
  @objc func quit() { NSApp.terminate(nil) }
  private var manualReadPending = false
  private func drainManualRead() {
    if manualReadPending && !sending && !polling { manualReadPending = false; manualRefresh() }
  }
  func manualRefresh() {
    autoRetry = AutoRetry()
    if polling || sending { manualReadPending = true; return }
    historyFailures = 0
    message = ""
    startTimer()
    refresh()
  }
  var pendingCardAction: (() -> Void)?
  func useCard(_ id: String, action: @escaping () -> Void) {
    if id == selected && connected { action(); return }
    if id != selected { selectDevice(id) }
    pendingCardAction = action
    if !polling { manualRefresh() }
  }
  func selectDevice(_ id: String) {
    guard id != selected, devices.contains(where: { $0.id == id }) else { return }
    reset()
    selected = id
    state = snapshots[id] ?? [:]
    lastRead = snapshots[id] == nil ? nil : checked[id]
    profile = profiles[id] ?? [:]
    menuDeviceID = nil
    panelSections.removeAll { $0.title == "Energy" }
    refresh()
    updateStatus()
  }
  func reset() {
    pendingCardAction = nil
    manualReadPending = false
    cancelOtherCards()
    lastCommandResult = "None sent"
    lastReadResult = "No response yet"
    flushObserved()
    generation += 1
    priorEcoMode = nil
    weekHistory = WeekHistory()
    loadedWeekKey = nil
    cachedEnergyProfile = nil
    selections = SelectionState()
    autoRetry = AutoRetry()
    weekBars = []
    energyTask?.cancel()
    energyTask = nil
    historyFailures = 0
    startTimer()
    pollTask?.cancel()
    commandTask?.cancel()
    polling = false
    sending = false
    state = [:]
    profile = [:]
    observedUse = ObservedUse()
    lastEnergy = nil
    lastRead = nil
    connected = false
    message = ""
  }
  func refresh() {
    guard !autoRetry.stopped && !polling && !sending else { return }
    polling = true
    let gen = generation
    pollTask = Task {
      defer { if gen == generation && !Task.isCancelled { polling = false; drainManualRead() } }
      do {
        let api = self.api
        if devices.isEmpty {
          let r = try await api.request("devices")
          try Task.checkCancellation()
          guard gen == generation else { return }
          let list = (r as? [[String: Any]]) ?? (find("devices", in: r) as? [[String: Any]]) ?? []
          devices = list.compactMap { item in
            let info = object(item["deviceInfo"] ?? item)
            guard info["deviceType"] as? String == "DEVICE_AIR_CONDITIONER",
              let id = item["deviceId"] as? String ?? info["deviceId"] as? String
            else { return nil }
            return Device(
              id: id, name: info["alias"] as? String ?? "Air conditioner")
          }
          guard !devices.isEmpty else {
            throw LGError(message: "No air conditioners in this account")
          }
          if !devices.contains(where: { $0.id == selected }) { selected = devices[0].id }
        }
        let id = selected
        let firstProfile = profile.isEmpty
        if firstProfile {
          let p = try await api.request("devices/\(id)/profile")
          try Task.checkCancellation()
          guard gen == generation else { return }
          profile = object(p)
          profiles[id] = profile

        }
        let s = try await api.request("devices/\(id)/state")
        try Task.checkCancellation()
        guard gen == generation else { return }
        let snapshot = object(s)
        let changed = !connected || !(state as NSDictionary).isEqual(to: snapshot)
        if changed { state = snapshot }
        connected = true
        saveSnapshot(snapshot, for: id)
        checked[id] = Date()
        refreshOtherCards()
        lastRead = Date()
        lastReadResult = "OK · " + Date().formatted(date: .omitted, time: .standard)
        message = ""
        if autoRetry.failures > 0 {
          autoRetry = AutoRetry()
          startTimer()
        }
        if menuVisible && (firstProfile || menuDeviceID != id) {
          buildMenu()
        } else if changed {
          updateStatus()
        }
        fetchEnergy()
        let requested = pendingCardAction
        pendingCardAction = nil
        requested?()
      } catch {
        if gen == generation && !Task.isCancelled {
          pendingCardAction = nil
          connected = false
          lastReadResult = error.localizedDescription + " · " + Date().formatted(date: .omitted, time: .standard)
          autoRetry.fail()
          message = autoRetry.stopped ? "No connection · Click Refresh" : error.localizedDescription
          startTimer()
          updateStatus()
        }
      }
    }
  }
  func menuDidClose(_ m: NSMenu) {
    if m === menu {
      menuVisible = false
      cancelOtherCards()
      ageTimer?.invalidate()
      ageTimer = nil
    }
  }
  func presetAllowed(_ t: Double, _ s: String) -> Bool {
    let (lo, hi) = bounds()
    return t >= lo && t <= hi && allowed("temperature", "targetTemperature", t)
      && allowed("airFlow", windKey, s) && allowed("airConJobMode", "currentJobMode", "COOL")
      && allowed("operation", "airConOperationMode", "POWER_ON")
  }
  func preset(_ t: Double, _ s: String) {
    send([
      ("operation", "airConOperationMode", "POWER_ON"), ("airConJobMode", "currentJobMode", "COOL"),
      ("temperature", "targetTemperature", t), ("airFlow", windKey, s),
    ])
  }
  func setDegrees(_ value: Double) {
    let step = lgNumber(capability("temperature", "targetTemperature")["step"]) ?? 1
    var edits: [ControlChange] = [("temperature", "targetTemperature", (value / step).rounded() * step)]
    if isReportedOff { edits.insert(("operation", "airConOperationMode", "POWER_ON"), at: 0) }
    send(edits)
  }
  func send(_ commands: [ControlChange]) {
    guard !selected.isEmpty, commands.allSatisfy({ allowed($0.0, $0.1, $0.2) }) else { return }
    selections.enqueue(commands)
    message = ""
    updateStatus()
    guard !sending else { return }
    sending = true
    pollTask?.cancel()
    polling = false
    let gen = generation
    let id = selected
    commandTask = Task {
      defer {
        if gen == generation {
          sending = false
          drainManualRead()
          updateStatus()
        }
      }
      while let batch = selections.take() {
        var lastWrite: String?
        var awaitingReply = false
        do {
          recordCommand("Checking device · not sent")
          try await readForCommand(id)
          try Task.checkCancellation()
          let changesMode = batch.contains {
            $0.0 == "powerSave" || $0.0 == "airConJobMode"
          }
          for (group, key, wanted) in batch {
            try Task.checkCancellation()
            if group == "temperature", let n = lgNumber(wanted) {
              let (lo, hi) = bounds()
              guard n >= lo && n <= hi else { throw LGError(message: "Outside supported range") }
            }
            let reapplySetting = changesMode && (group == "temperature" || group == "airFlow")
            if !reapplySetting, !selections.hasUnconfirmed(group, key), let old = reported(group, key),
              equal(old, wanted)
            {
              continue
            }
            var values = [key: wanted]
            if group == "temperature" { values["unit"] = "C" }
            let label = group == "temperature" ? degree(lgNumber(wanted)) : String(describing: wanted).replacingOccurrences(of: "POWER_", with: "")
            lastWrite = label
            awaitingReply = true
            recordCommand("Sending " + label)
            _ = try await api.request("devices/\(id)/control", payload: [group: values])
            try Task.checkCancellation()
            awaitingReply = false
            recordCommand(label + " · accepted, checking")
            selections.recordSent((group, key, wanted))
          }
          selections.finishBatch()
          // Some devices briefly return the previous value after acknowledging a write.
          for attempt in 0..<5 {
            if selections.hasQueued { break }
            if attempt > 0 { try await Task.sleep(nanoseconds: 800_000_000) }
            if selections.hasQueued { break }
            try await readForCommand(id)
            if !selections.needsConfirmation { break }
          }
          if !selections.hasQueued && selections.needsConfirmation {
            selections.clearUnconfirmed()
            message = "Change not confirmed by LG"
            recordCommand((lastWrite ?? "Change") + " · unconfirmed")
          } else if !selections.needsConfirmation {
            recordCommand(lastWrite.map { $0 + " · confirmed" } ?? "Already set · not sent")
          }
          if autoRetry.failures > 0 {
            autoRetry = AutoRetry()
            startTimer()
          }
        } catch {
          guard gen == generation && !Task.isCancelled else { return }
          selections.finishBatch()
          selections.clearUnconfirmed()
          message = error.localizedDescription
          if let lastWrite {
            recordCommand(lastWrite + (awaitingReply ? " · request failed" : " · confirmation failed"))
          } else {
            recordCommand("Not sent · check failed")
          }
        }
        guard gen == generation && !Task.isCancelled else { return }
        updateStatus()
      }
    }
  }
  func readForCommand(_ id: String) async throws {
    let fresh = try await api.request("devices/\(id)/state")
    try Task.checkCancellation()
    state = object(fresh)
    saveSnapshot(state, for: id)
    checked[id] = Date()
    lastRead = checked[id]
    connected = true
    let confirmed = selections.unconfirmed.filter { change in
      reported(change.0, change.1).map { equal($0, change.2) } ?? false
    }
    selections.confirm(confirmed)
  }
  private func flushObserved() {
    if let key = loadedWeekKey { observedUse.save(key, at: Date(), force: true) }
  }
  func applicationWillTerminate(_ notification: Notification) { flushObserved() }
  var loadedWeekKey: String?
  var weekHistory = WeekHistory()
  var cachedEnergyProfile: Bool?
  func fetchEnergy() {
    let key = "lgbar.week.v1.\(api.region).\(api.country).\(selected)"
    let now = Date()
    if loadedWeekKey != key {
      loadedWeekKey = key
      weekHistory = WeekHistory.load(key)
      observedUse = ObservedUse.load(key)
      weekBars = weekHistory.days
      updateEnergyRows()
    }
    let calendar = Calendar.current
    let mode = value("operation", "airConOperationMode") as? String
    let on: Bool? = mode == "POWER_ON" ? true : mode == "POWER_OFF" ? false : nil
    observedUse.sample(
      at: now, on: on, interval: defaults.double(forKey: "interval"), calendar: calendar)
    observedUse.save(key, at: now)
    guard energyTask == nil, historyFailures < 5, cachedEnergyProfile != false else { return }
    // Civil-day counters are only needed around the 09:00 boundary.
    let nine = WeekHistory.nine(now, calendar)
    let boundaryDue =
      abs(now.timeIntervalSince(nine)) <= 900
      && (lastEnergy.map { now.timeIntervalSince($0) >= 300 } ?? true)
    guard weekHistory.due(at: now) || boundaryDue else { return }
    let gen = generation
    let id = selected
    let client = api
    if boundaryDue { lastEnergy = now }
    energyTask = Task {
      defer { if gen == generation { energyTask = nil } }
      do {
        if cachedEnergyProfile == nil {
          let profile = try await client.request("devices/energy/\(id)/profile")
          try Task.checkCancellation()
          cachedEnergyProfile =
            (find("property", in: profile) as? [String])?.contains("energyUsage") ?? false
        }
        guard cachedEnergyProfile == true else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func usage(_ from: Int, _ through: Int) async throws -> Any {
          try Task.checkCancellation()
          let start = WeekHistory.dayKey(calendar.date(byAdding: .day, value: from, to: today)!, calendar)
          let end = WeekHistory.dayKey(calendar.date(byAdding: .day, value: through, to: today)!, calendar)
          return try await client.request(
            "devices/energy/\(id)/usage?property=energyUsage&period=DAILY&startDate=\(start)&endDate=\(end)"
          )
        }
        if boundaryDue {
          let sampledAt = Date()
          let reading = try await usage(0, 0)
          try Task.checkCancellation()
          if let total = energyTotal(reading) {
            let daily = find("dataList", in: reading) as? [[String: Any]] ?? []
            let durations = daily.compactMap(WeekChart.runtime)
            let seconds =
              (!daily.isEmpty && durations.count == daily.count) ? durations.reduce(0, +) : nil
            weekHistory.record(
              Boundary(time: sampledAt, wh: total, seconds: seconds), calendar: calendar)
            weekHistory.save(key)
          }
        }
        if weekHistory.due(at: Date()) {
          weekHistory.lastAttempt = Date()
          weekHistory.save(key)
          let lastOffset = now < nine ? -2 : -1
          let result = try await usage(lastOffset - 9, lastOffset)
          try Task.checkCancellation()
          let end = calendar.date(byAdding: .day, value: lastOffset, to: today)!
          weekHistory.days = WeekChart.series(
            response: result, end: end, calendar: calendar, mornings: weekHistory.mornings ?? [:],
            use: observedUse)
          weekHistory.save(key)
          weekBars = weekHistory.days
          // Fetch the entire civil month; the chart intentionally covers only ten days.
          let first = calendar.dateInterval(of: .month, for: today)!.start
          let offset = calendar.dateComponents([.day], from: first, to: today).day!
          do {
            let monthly = try await usage(-offset, 0)
            try Task.checkCancellation()
            weekHistory.month = WeekHistory.monthKey(today, calendar)
            weekHistory.monthWh = energyTotal(monthly)
            weekHistory.save(key)
          } catch {
            try Task.checkCancellation()
            // A missing monthly reading must not discard the daily chart.
          }
        }
        historyFailures = 0
        updateEnergyRows()
      } catch { if gen == generation && !Task.isCancelled { historyFailures += 1 } }
    }
  }
  @objc func openSettings() {
    menu.cancelTracking()
    if let w = settings {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 450, height: 245), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    w.title = "LG settings"
    w.isReleasedWhenClosed = false
    settings = w
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 245))
    w.contentView = root
    func label(_ s: String, _ y: Double) {
      let l = NSTextField(labelWithString: s)
      l.frame = NSRect(x: 20, y: y, width: 400, height: 20)
      root.addSubview(l)
    }
    label("LG ThinQ token", 216)
    tokenSecure.frame = NSRect(x: 20, y: 180, width: 365, height: 26)
    tokenPlain.frame = tokenSecure.frame
    tokenSecure.stringValue = TokenFile.read()
    tokenPlain.stringValue = tokenSecure.stringValue
    tokenPlain.isHidden = true
    root.addSubview(tokenSecure)
    root.addSubview(tokenPlain)
    eye = NSButton(
      image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Show token")!,
      target: self, action: #selector(toggleEye))
    eye.frame = NSRect(x: 392, y: 180, width: 36, height: 26)
    root.addSubview(eye)
    let link = NSButton(title: "Get token ↗", target: self, action: #selector(getToken))
    link.isBordered = false
    link.frame = NSRect(x: 18, y: 151, width: 120, height: 24)
    root.addSubview(link)
    countries = NSComboBox(frame: NSRect(x: 20, y: 74, width: 407, height: 27))
    countries.completes = true
    countries.numberOfVisibleItems = 12
    let en = Locale(identifier: "en_US")
    countryOptions = Locale.Region.isoRegions.map { $0.identifier }.filter { $0.count == 2 }.map {
      code in
      (code, (en.localizedString(forRegionCode: code) ?? code) + " (" + code + ") " + flag(code))
    }.sorted { $0.1 < $1.1 }
    countries.addItems(withObjectValues: countryOptions.map { $0.1 })
    let country = defaults.string(forKey: "country") ?? "PH"
    countries.stringValue = countryOptions.first { $0.0 == country }?.1 ?? country
    root.addSubview(countries)
    regions = NSComboBox(frame: NSRect(x: 20, y: 111, width: 407, height: 27))
    regions.completes = true
    regions.addItems(withObjectValues: regionOptions.map { $0.1 })
    let region = defaults.string(forKey: "region") ?? "kic"
    regions.stringValue = regionOptions.first { $0.0 == region }?.1 ?? region
    root.addSubview(regions)
    regions.setAccessibilityLabel("Region")
    countries.setAccessibilityLabel("Country")
    regions.nextKeyView = countries
    settingsNotice = NSTextField(wrappingLabelWithString: "")
    settingsNotice.frame = NSRect(x: 20, y: 12, width: 280, height: 62)
    settingsNotice.font = .systemFont(ofSize: 11)
    root.addSubview(settingsNotice)
    let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
    save.bezelStyle = .rounded
    save.frame = NSRect(x: 337, y: 24, width: 90, height: 30)
    root.addSubview(save)
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc func toggleEye() {
    if tokenPlain.isHidden {
      tokenPlain.stringValue = tokenSecure.stringValue
      tokenPlain.isHidden = false
      tokenSecure.isHidden = true
      eye.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide token")
    } else {
      tokenSecure.stringValue = tokenPlain.stringValue
      tokenSecure.isHidden = false
      tokenPlain.isHidden = true
      eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show token")
    }
  }
  @objc func getToken() {
    NSWorkspace.shared.open(URL(string: "https://connect-pat.lgthinq.com/tokens")!)
  }
  @objc func saveSettings() {
    let text = countries.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let country = countryOptions.first {
      $0.1.caseInsensitiveCompare(text) == .orderedSame
        || $0.0.caseInsensitiveCompare(text) == .orderedSame
    }?.0
    let regionText = regions.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let region = regionOptions.first {
      $0.1.caseInsensitiveCompare(regionText) == .orderedSame
        || $0.0.caseInsensitiveCompare(regionText) == .orderedSame
    }?.0
    guard let country = country, let region = region else {
      settingsNotice.stringValue = "Choose a country and region from the lists."
      return
    }
    let token = (tokenPlain.isHidden ? tokenSecure.stringValue : tokenPlain.stringValue)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      settingsNotice.stringValue = "Enter a ThinQ personal access token."
      return
    }
    do { try TokenFile.save(token) } catch {
      settingsNotice.stringValue = error.localizedDescription
      return
    }
    defaults.set(country, forKey: "country")
    defaults.set(region, forKey: "region")
    reset()
    api = API()
    devices = []
    profiles.removeAll()
    snapshots.removeAll()
    samples.removeAll()
    checked.removeAll()
    settings?.close()
    settings = nil
    buildMenu()
    refresh()
  }
}
func flag(_ code: String) -> String {
  String(
    String.UnicodeScalarView(
      code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
}
