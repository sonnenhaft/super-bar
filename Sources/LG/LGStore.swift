import AppKit
import Combine

let intervals: [Double] = [1, 5, 30, 60, 300, 600]
@MainActor final class LGStore: NSObject, ObservableObject {
  let readout = NSButton()
  var didRender: (() -> Void)?
  var panelChanged: (() -> Void)?
  var devices: [Device] = []
  @Published private(set) var televisions: [LGAccountTelevision] = []
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
  @Published private(set) var selections = SelectionState()
  lazy var api = API()
  let fanIndicator = FanIndicator()
  private var ecoAttachment: (size: CGFloat, text: NSAttributedString)?
  private func ecoMarker(size: CGFloat) -> NSAttributedString? {
    if let ecoAttachment, ecoAttachment.size == size { return ecoAttachment.text }
    let points = max(7, size - 2)
    guard let image = NSImage(systemSymbolName: ClimateEcoIcon.symbol, accessibilityDescription: "Eco")?
      .withSymbolConfiguration(.init(pointSize: points, weight: .regular))?
      .withSymbolConfiguration(.init(paletteColors: [PanelPalette.green.nsColor])) else { return nil }
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: -points * 0.12, width: image.size.width, height: image.size.height)
    let text = NSAttributedString(attachment: attachment)
    ecoAttachment = (size, text)
    return text
  }
  var summaryTask: Task<Void, Never>?
  var summaryRequestedAt: Date?
  var samples: [String: LGSample] = [:]
  var checked: [String: Date] = [:]
  let speeds = ["LOW", "MID", "HIGH"]
  var panelVisible = false

  var pollTask: Task<Void, Never>?
  var commandTask: Task<Void, Never>?
  var timer: Timer?
  var lastRead: Date?
  var message = ""
  var current: Double? {
    lgNumber(temperatures["targetTemperature"] ?? temperatures["targetTemperatureC"])
  }
  var temperatures: [String: Any] { celsius(find("temperature", in: state) ?? [:]) }
  var windKey = "windStrength"
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
    guard !autoRetry.stopped || (panelVisible && devices.count > 1) else { return }
    let interval = max(autoRetry.delay, Double(RefreshPreferences.seconds(.lg)))
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
    if autoRetry.stopped { startTimer() }
    refreshOtherCards()
    updateStatus()
  }
  func panelClosed() {
    panelVisible = false
    cancelOtherCards()
    if autoRetry.stopped { timer?.invalidate() }
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
      modes: modes, returnMode: "COOL")
  }
  func toggleEco() {
    let choice = ecoChoice
    guard let change = choice.change else {
      message = "Eco control unavailable for this device"
      notifyPanel()
      return
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
    let eco = sample?.eco
    let set = live ? (lgNumber(displayValue("temperature", "targetTemperature")) ?? current) : sample?.target
    var readings: [(text: String, isAC: Bool)] = []
    if let sample {
      if off {
        if shown("current", for: pinned) { readings.append(("⏻", true)) }
        if shown("sensor", for: pinned), sample.room != nil { readings.append((sample.roomReading, false)) }
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
      if reading.isAC && eco == true && !off && shown("ecoIndicator", for: pinned), let marker = ecoMarker(size: size) {
        title.append(marker)
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
  private func matchesReported(_ changes: [ControlChange]) -> Bool {
    changes.allSatisfy { group, key, wanted in reported(group, key).map { equal($0, wanted) } ?? false }
  }
  func displayValue(_ g: String, _ k: String) -> Any? {
    selections.display(g, k) ?? reported(g, k)
  }
  var displayedTarget: Double? { lgNumber(displayValue("temperature", "targetTemperature")) }
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
  func manualRefresh(allDevices: Bool = false) {
    guard !AccountConnection.signedOut("lg") else { return }
    if allDevices && panelVisible { summaryRequestedAt = Date() }
    autoRetry = AutoRetry()
    if polling || sending { manualReadPending = true; return }
    message = ""
    startTimer()
    refresh()
  }
  private enum DeferredControl {
    case action(() -> Void)
    case preset(LGCoolingPreset)
  }
  @Published private var deferredControls: [DeferredControl] = []
  private var hasControlState: Bool {
    connected || (!state.isEmpty && !profile.isEmpty && LGSample(state).online != false)
  }
  func applyDeferredControls() {
    let actions = deferredControls
    deferredControls.removeAll()
    for control in actions {
      switch control {
      case .action(let action): action()
      case .preset(let preset): send(preset.changes(windKey: windKey))
      }
    }
  }
  func useCard(_ id: String, action: @escaping () -> Void) {
    if id != selected { selectDevice(id) }
    guard selected == id else { return }
    // A command with a saved profile can show its selection immediately.
    // send() still checks the live device before the first write.
    if deferredControls.isEmpty && hasControlState { action(); return }
    deferredControls.append(.action(action))
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
    deferredControls.removeAll()
    manualReadPending = false
    cancelOtherCards()
    generation += 1
    selections = SelectionState()
    autoRetry = AutoRetry()
    startTimer()
    pollTask?.cancel()
    commandTask?.cancel()
    polling = false
    sending = false
    state = [:]
    profile = [:]
    lastRead = nil
    connected = false
    message = ""
  }
  func refresh() {
    guard !AccountConnection.signedOut("lg") else { return }
    guard !polling && !sending else { return }
    guard !autoRetry.stopped else { refreshOtherCards(); return }
    polling = true
    let gen = generation
    pollTask = Task {
      defer {
        if gen == generation && !Task.isCancelled {
          polling = false
          drainManualRead()
        }
      }
      do {
        let api = self.api
        let directory = try await api.accountDirectoryIfNeeded(hasDevices: !devices.isEmpty || !televisions.isEmpty)
        try Task.checkCancellation()
        guard gen == generation else { return }
        if let directory {
          if directory.televisions != televisions { televisions = directory.televisions }
          if devices.isEmpty { devices = directory.airConditioners }
        }
        guard !devices.isEmpty else {
          guard !televisions.isEmpty else { throw LGError(message: "No air conditioners in this account") }
          message = ""
          return
        }
        if !devices.contains(where: { $0.id == selected }) { selected = devices[0].id }
        refreshOtherCards()
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
        lastRead = Date()
        message = ""
        if autoRetry.failures > 0 {
          autoRetry = AutoRetry()
          startTimer()
        }
        if changed || firstProfile { updateStatus() }
        if !deferredControls.isEmpty { applyDeferredControls() }
      } catch {
        if gen == generation && !Task.isCancelled {
          deferredControls.removeAll()
          connected = false
          autoRetry.fail()
          message = autoRetry.stopped ? "No connection · Click Refresh" : error.localizedDescription
          startTimer()
          updateStatus()
        }
      }
    }
  }
  func canSelectPreset(_ preset: LGCoolingPreset, for id: String) -> Bool {
    guard !id.isEmpty, id == selected, !AccountConnection.signedOut("lg") else { return false }
    return profile.isEmpty || preset.changes(windKey: windKey).allSatisfy { allowed($0.0, $0.1, $0.2) }
  }
  func isSelectedPreset(_ preset: LGCoolingPreset, for id: String) -> Bool {
    guard id == selected else { return false }
    for case .preset(let wanted) in deferredControls { return wanted == preset }
    return powerIsOn && displayValue("airConJobMode", "currentJobMode") as? String == "COOL"
        && displayValue("airFlow", windKey) as? String == preset.speed && displayedTarget == Double(preset.degrees)
  }
  func selectPreset(_ preset: LGCoolingPreset, for id: String) {
    guard canSelectPreset(preset, for: id) else { return }
    // Keep the tap order relative to other controls, replacing only the older preset.
    if !deferredControls.isEmpty || profile.isEmpty || !hasControlState {
      deferredControls.removeAll { control in
        if case .preset = control { return true }
        return false
      }
      deferredControls.append(.preset(preset))
      if !polling { manualRefresh() }
      return
    }
    send(preset.changes(windKey: windKey))
  }
  func setDegrees(_ value: Double) {
    let step = lgNumber(capability("temperature", "targetTemperature")["step"]) ?? 1
    var edits: [ControlChange] = [("temperature", "targetTemperature", (value / step).rounded() * step)]
    if displayValue("operation", "airConOperationMode") as? String == "POWER_OFF" {
      edits.insert(("operation", "airConOperationMode", "POWER_ON"), at: 0)
    }
    send(edits)
  }
  func send(_ commands: [ControlChange]) {
    guard !AccountConnection.signedOut("lg") else { return }
    guard !selected.isEmpty else { return }
    if let unsupported = commands.first(where: { !allowed($0.0, $0.1, $0.2) }) {
      message = "LG cannot apply \(unsupported.1): \(unsupported.2)"
      updateStatus()
      return
    }
    selections.enqueue(commands)
    message = ""
    updateStatus()
    guard !sending else { return }
    sending = true
    if polling && summaryRequestedAt != nil { manualReadPending = true }
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
        message = ""
        var writeInFlight = false
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
               equal(old, wanted) { continue }
            var values = [key: wanted]
            if group == "temperature" { values["unit"] = "C" }
            writeInFlight = true
            _ = try await api.request("devices/\(try API.deviceComponent(id))/control", payload: [group: values])
            try Task.checkCancellation()
            writeInFlight = false
            selections.recordSent((group, key, wanted))
          }
          // Some devices briefly return the previous value after acknowledging a write.
          for attempt in 0..<5 {
            if selections.hasQueued { break }
            if attempt > 0 { try await Task.sleep(nanoseconds: 800_000_000) }
            if selections.hasQueued { break }
            try await readForCommand(id)
            if !selections.needsConfirmation && matchesReported(batch) { break }
          }
          if !selections.hasQueued && (selections.needsConfirmation || !matchesReported(batch)) {
            selections.clearUnconfirmed()
            message = "Change not confirmed by LG"
          }
          if autoRetry.failures > 0 {
            autoRetry = AutoRetry()
            startTimer()
          }
        } catch {
          guard gen == generation && !Task.isCancelled else { return }
          // A transport error can follow an accepted write. Reconcile even a
          // partially applied preset against the device before removing its overlay.
          var applied = false
          if writeInFlight {
            if (try? await readForCommand(id)) != nil {
              applied = matchesReported(batch)
            }
            guard gen == generation && !Task.isCancelled else { return }
          }
          selections.clearUnconfirmed()
          message = applied ? "" : error.localizedDescription
        }
        guard gen == generation && !Task.isCancelled else { return }
        selections.finishBatch()
        updateStatus()
      }
    }
  }
  func readForCommand(_ id: String) async throws {
    let fresh = try await api.request("devices/\(try API.deviceComponent(id))/state")
    try Task.checkCancellation()
    let snapshot = object(fresh)
    guard !snapshot.isEmpty else { throw LGError(message: "LG returned no current readings.") }
    state = snapshot
    saveSnapshot(state, for: id)
    checked[id] = Date()
    lastRead = checked[id]
    connected = true
    guard LGSample(state).online != false else { throw LGError(message: "LG is offline.") }
    let confirmed = selections.unconfirmed.filter { change in
      reported(change.0, change.1).map { equal($0, change.2) } ?? false
    }
    selections.confirm(confirmed)
  }
  func stop() {
    deferredControls.removeAll()
    timer?.invalidate()
    cancelOtherCards()
    pollTask?.cancel()
    commandTask?.cancel()
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

  private func reloadAccount() {
    reset()
    api = API()
    devices = []
    televisions = []
    profiles.removeAll()
    snapshots.removeAll()
    samples.removeAll()
    checked.removeAll()
    refresh()
  }
  func logout() {
    AccountConnection.setConnected(false, provider: "lg")
    reset(); devices = []; televisions = []; profiles.removeAll(); snapshots.removeAll(); samples.removeAll(); checked.removeAll()
    message = "Logged out"; updateStatus()
  }
}
