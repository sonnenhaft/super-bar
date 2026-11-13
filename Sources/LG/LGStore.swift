import AppKit
import Combine

let intervals: [Double] = [1, 5, 30, 60, 300, 600]
@MainActor final class LGStore: NSObject, ObservableObject {
  let readout = NSButton()
  var didRender: (() -> Void)?
  var panelChanged: (() -> Void)?
  var settings: NSWindow?
  var devices: [Device] = []
  var pinnedDeviceID: String {
    get { defaults.string(forKey: "lg.pinnedDevice") ?? selected }
    set { defaults.set(newValue, forKey: "lg.pinnedDevice") }
  }
  var state: [String: Any] = [:]
  private var capabilityCache: [String: [String: Any]] = [:]
  var profile: [String: Any] = [:] {
    didSet {
      capabilityCache.removeAll(keepingCapacity: true)
      windKey =
        LGDeviceValues.windKey(in: profile)
    }
  }
  private var profiles: [String: [String: Any]] = [:]
  var connected = false
  @Published var selected = defaults.string(forKey: "selected") ?? "" {
    didSet { if oldValue != selected { defaults.set(selected, forKey: "selected") } }
  }
  var snapshots: [String: [String: Any]] = [:]
  var polling = false { didSet { notifyPanel() } }
  var sending = false { didSet { notifyPanel() } }
  var generation = 0
  var autoRetry = AutoRetry()
  var selections = SelectionState()
  lazy var api = API()
  let fanIndicator = FanIndicator()
  let ecoSymbol = "🍃"
  var summaryTask: Task<Void, Never>?
  var samples: [String: LGSample] = [:]
  var powerSamples: [String: [PowerPoint]] = defaults.data(forKey:"lg.powerHistory").flatMap { try? JSONDecoder().decode([String:[PowerPoint]].self,from:$0) } ?? [:]
  private static let historyFiles = DispatchQueue(label:"superbar.lg.power-history",qos:.utility)
  func recordPower(_ watts: Double?, for id: String) {
    guard let watts, watts.isFinite, watts >= 0 else { return }
    let now = Date()
    var points = (powerSamples[id] ?? []).filter { now.timeIntervalSince($0.time) <= 86400 }
    if let last = points.last, now.timeIntervalSince(last.time) < 60 { return }
    points.append(PowerPoint(time:now,watts:watts))
    powerSamples[id] = Array(points.suffix(1441))
    let snapshot = powerSamples
    Self.historyFiles.async {
      if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data,forKey:"lg.powerHistory") }
    }
  }
  var checked: [String: Date] = [:]
  let speeds = ["LOW", "MID", "HIGH"]
  var weekBars: [DayUsage] = []
  var historyFailures = 0
  var panelVisible = false

  var pollTask: Task<Void, Never>?
  var commandTask: Task<Void, Never>?
  var energyTask: Task<Void, Never>? { didSet { notifyPanel() } }
  var timer: Timer?
  var lastRead: Date?
  var lastEnergy: Date?
  var message = ""
  var observedUse = ObservedUse()
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
  func start() {
    defaults.register(defaults: [
      "font": 13.0, "icon": true, "sensor": true, "current": true, "interval": 60.0,
      "fanIndicator": true, "ecoIndicator": true,
    ])
    updateStatus()
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
  func panelOpened() {
    panelVisible = true
    refreshOtherCards()
    updateStatus()
  }
  func panelClosed() {
    panelVisible = false
    cancelOtherCards()
  }
  private func notifyPanel() {
    if panelVisible { panelChanged?() }
  }
  func value(_ group: String, _ key: String) -> Any? {
    find(key, in: find(group, in: state) ?? [:])
  }
  func capability(_ group: String, _ key: String) -> [String: Any] {
    let cacheKey = group + "." + key
    if let cached = capabilityCache[cacheKey] { return cached }
    let c = LGCapability(profile: profile, group: group, key: key).details
    capabilityCache[cacheKey] = c
    return c
  }
  func canWrite(_ g: String, _ k: String) -> Bool {
    LGCapability(details: capability(g, k)).writable
  }
  func allowed(_ g: String, _ k: String, _ v: Any) -> Bool {
    LGCapability(details: capability(g, k)).allows(v)
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
      notifyPanel()
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
    LGDeviceValues.temperatureBounds(temperatures: temperatures,
                                    capability: capability("temperature", "targetTemperature"))
  }
  func updateStatus() {
    let size = CGFloat(BarSelection.shared.size)
    let pinned = pinnedDeviceID
    let sample = sample(for: pinned)
    let live = pinned == selected && connected
    let off = sample?.power == "POWER_OFF"
    let speed = live ? displayValue("airFlow", windKey) as? String : sample?.fan?.uppercased()
    let eco = live ? ecoChoice.enabled : sample?.eco
    let set = live ? (lgNumber(displayValue("temperature", "targetTemperature")) ?? current) : sample?.target
    var readings: [(text: String, isAC: Bool)] = []
    if let sample {
      if off {
        if shown("current", for: pinned) { readings.append(("⏻", true)) }
        if shown("sensor", for: pinned), let room = sample.room { readings.append((degree(room), false)) }
      } else {
        if shown("current", for: pinned) { readings.append((degree(set), true)) }
        if shown("sensor", for: pinned) { readings.append((sample.value("sensor"), false)) }
      }
    }
    var displayChanged = false
    defer { if displayChanged { didRender?() } }
    let button = readout
    let icon: NSImage? = nil
    if button.image !== icon { button.image = icon; displayChanged = true }
    if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading; displayChanged = true }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
      .foregroundColor: NSColor.white
    ]
    let title = NSMutableAttributedString(string: "")
    for (index, reading) in readings.enumerated() {
      if index > 0 { title.append(NSAttributedString(string: " / ", attributes: attrs.merging([.foregroundColor: NSColor.white]) { _, new in new })) }
      if reading.isAC && eco == true && !off {
        title.append(NSAttributedString(string: ecoSymbol, attributes: attrs))
      }
      var style = attrs
      if reading.isAC && off { style[.foregroundColor] = NSColor.systemRed }
      title.append(NSAttributedString(string:reading.text,attributes:style))
      if reading.isAC && !off && shown("fanIndicator", for: pinned),
        let dots = fanIndicator.attachment(
          speed: speed, fontSize: size, color: .white)
      {
        title.append(dots)
      }
    }
    let colored = TemperatureStyle.attributed(title, menuBar: true)
    if !button.attributedTitle.isEqual(to: colored) { button.attributedTitle = colored; displayChanged = true }
    notifyPanel()
  }
  func reported(_ g: String, _ k: String) -> Any? {
    g == "temperature" && k == "targetTemperature" ? current : value(g, k)
  }
  func displayValue(_ g: String, _ k: String) -> Any? {
    selections.display(g, k) ?? reported(g, k)
  }
  var isReportedOff: Bool { connected && (reported("operation", "airConOperationMode") as? String) == "POWER_OFF" }
  var powerIsOn: Bool { displayValue("operation", "airConOperationMode") as? String == "POWER_ON" }
  func toggleVisibility(_ key: String, for id: String? = nil) {
    let id = id ?? selected
    let visible = BarSelection.shared.current == .lg && pinnedDeviceID == id && shown(key, for: id)
    pinnedDeviceID = id
    defaults.set(!visible, forKey: "lg.fields." + id + "." + key)
    BarSelection.shared.pin(.lg)
    updateStatus()
    objectWillChange.send()
  }
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
    if defaults.string(forKey: "lg.pinnedDevice") == nil { pinnedDeviceID = selected }
    selected = id
    reset()
    state = snapshots[id] ?? [:]
    lastRead = snapshots[id] == nil ? nil : checked[id]
    profile = profiles[id] ?? [:]
    updateStatus()
    let selectionGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self, self.selected == id, self.generation == selectionGeneration else { return }
      self.refresh()
    }
  }
  func reset() {
    pendingCardAction = nil
    manualReadPending = false
    cancelOtherCards()
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
    guard !AccountConnection.signedOut("lg") else { return }
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
          let p = try await api.request("devices/\(try API.deviceComponent(id))/profile")
          try Task.checkCancellation()
          guard gen == generation else { return }
          profile = object(p)
          profiles[id] = profile

        }
        let s = try await api.request("devices/\(try API.deviceComponent(id))/state")
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
        message = ""
        if autoRetry.failures > 0 {
          autoRetry = AutoRetry()
          startTimer()
        }
        if changed || firstProfile { updateStatus() }
        fetchEnergy()
        let requested = pendingCardAction
        pendingCardAction = nil
        requested?()
      } catch {
        if gen == generation && !Task.isCancelled {
          pendingCardAction = nil
          connected = false
          autoRetry.fail()
          message = autoRetry.stopped ? "No connection · Click Refresh" : error.localizedDescription
          startTimer()
          updateStatus()
        }
      }
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
    guard !AccountConnection.signedOut("lg") else { return }
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
        do {
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
            _ = try await api.request("devices/\(try API.deviceComponent(id))/control", payload: [group: values])
            try Task.checkCancellation()
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
        }
        guard gen == generation && !Task.isCancelled else { return }
        updateStatus()
      }
    }
  }
  func readForCommand(_ id: String) async throws {
    let fresh = try await api.request("devices/\(try API.deviceComponent(id))/state")
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
  func stop() {
    flushObserved()
    timer?.invalidate()
    cancelOtherCards()
    pollTask?.cancel()
    commandTask?.cancel()
    energyTask?.cancel()
  }
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
      notifyPanel()
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
      && (lastEnergy.map { now.timeIntervalSince($0) >= HistoryPolling.recent } ?? true)
    guard weekHistory.due(at: now) || boundaryDue else { return }
    let gen = generation
    let id = selected
    let client = api
    if boundaryDue { lastEnergy = now }
    energyTask = Task {
      defer { if gen == generation { energyTask = nil } }
      do {
        if cachedEnergyProfile == nil {
          let profile = try await client.request("devices/energy/\(try API.deviceComponent(id))/profile")
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
            "devices/energy/\(try API.deviceComponent(id))/usage?property=energyUsage&period=DAILY&startDate=\(start)&endDate=\(end)"
          )
        }
        if boundaryDue {
          let sampledAt = Date()
          let reading = try await usage(0, 0)
          try Task.checkCancellation()
          if let total = energyTotal(reading) {
            let daily = find("dataList", in: reading) as? [[String: Any]] ?? []
            let durations = daily.compactMap(LGHistoryDecoder.runtime)
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
          let firstMissing = ((lastOffset - ChartHistory.dayCount + 1)...lastOffset).first { offset in
            let day = WeekHistory.dayKey(calendar.date(byAdding: .day, value: offset, to: today)!, calendar)
            return !weekHistory.days.contains { $0.day == day && $0.wh != nil }
          } ?? lastOffset
          let result = try await usage(firstMissing, lastOffset)
          try Task.checkCancellation()
          let end = calendar.date(byAdding: .day, value: lastOffset, to: today)!
          let savedDays = Dictionary(weekHistory.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
          weekHistory.days = LGHistoryDecoder.series(
            response: result, end: end, calendar: calendar, mornings: weekHistory.mornings ?? [:],
            use: observedUse).map { day in day.wh != nil ? day : savedDays[day.day] ?? day }
          if weekHistory.days.allSatisfy({ $0.wh != nil }) {
            weekHistory.completedThrough = WeekHistory.dayKey(end, calendar)
          }
          weekHistory.save(key)
          weekBars = weekHistory.days
          // Fetch the civil month separately for the month-to-date readout.
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
        notifyPanel()
      } catch { if gen == generation && !Task.isCancelled { historyFailures += 1 } }
    }
  }
  @objc func openSettings() {
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
    Task {
      do {
        try await configureAccount(token: token, country: country, region: region)
        settings?.close(); settings = nil
      } catch { settingsNotice.stringValue = error.localizedDescription }
    }
  }
  private var connectingAccount = false
  func configureMobileAccount(email: String, password: String, country: String) async throws {
    guard !connectingAccount else { throw LGError(message: "LG sign-in is already in progress.") }
    connectingAccount = true
    defer { connectingAccount = false }
    try LGLoginInput(email: email, password: password, country: country).saveDevelopmentDraft()
    try await LGMobileClient.connect(email: email, password: password, country: country)
    AccountConnection.setConnected(true, provider: "lg")
    defaults.set(country.uppercased(), forKey: "country")
    reloadAccount()
  }

  func configureAccount(token: String, country: String, region: String) async throws {
    guard !connectingAccount else { throw LGError(message: "LG sign-in is already in progress.") }
    connectingAccount = true
    defer { connectingAccount = false }
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    try await API.validateCredentials(token: token, country: country, region: region)
    try TokenFile.save(token)
    AccountConnection.setConnected(true, provider: "lg")
    defaults.set(country.uppercased(), forKey: "country")
    defaults.set(region, forKey: "region")
    reloadAccount()
  }
  private func reloadAccount() {
    reset()
    api = API()
    devices = []
    profiles.removeAll()
    snapshots.removeAll()
    samples.removeAll()
    checked.removeAll()
    refresh()
  }
  func logout() {
    AccountConnection.setConnected(false, provider: "lg")
    reset(); devices = []; profiles.removeAll(); snapshots.removeAll(); samples.removeAll(); checked.removeAll()
    message = "Logged out"; updateStatus()
  }
}
func flag(_ code: String) -> String {
  String(
    String.UnicodeScalarView(
      code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
}
