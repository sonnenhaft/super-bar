import AppKit
import CoreFoundation
import CoreBluetooth

final class BlueBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    let defaults = UserDefaults.standard
    var bluetoothActivated = false
    private var permissionManager: CBCentralManager?
    var needsBluetoothPermission: Bool { !demo && CBManager.authorization != .allowedAlways }
    private(set) var bluetoothMessage: String?
    var streaming = false
    let demo = CommandLine.arguments.contains("--demo")
    let readout = NSButton()
    var didRender: (() -> Void)?
    var panelChanged: (() -> Void)?
    var panelSettings: [NSMenuItem] = []
    let statusIcons = StatusItemIcons()
    lazy var brandBadge: NSImage? = {
        guard let url = Bundle.main.url(forResource: "bluetti-icon", withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()
    var pollTimer: Timer?
    var ageTimer: Timer?
    var job: CLIJob?
    var stationPreview: (key: String, job: CLIJob)?
    var previewAfter: [String: Date] = [:]
    var previewDevices: [String: BluettiNativeDevice] = [:]
    var primaryDiscoveryKey: String?
    enum StationContact { case sample(Date), failed }
    var stationContacts: [String: StationContact] = [:]
    var previewInterval: TimeInterval { max(30, refreshInterval) }
    var generation = 0
    var pendingRefresh = false
    enum ManualRead { case queued, reading }
    var manualRead: ManualRead?
    var isManuallyRefreshing: Bool { manualRead != nil }
    var lastManualRefreshError: String?
    let maximumReadRetries = 3
    var consecutiveReadFailures = 0
    var nextReadRetryAt: Date?
    lazy var stationDirectory: BlueBarStationDirectory = {
        return self.demo ? BlueBarStationDirectory(defaults: nil) : BlueBarStationDirectory()
    }()
    lazy var readingStore = BlueBarReadingStore(defaults: self.demo ? nil : self.defaults,
                                                       fallbackStatusURL: self.demo ? nil : self.cacheURL)
    let aliasField = BlueBarAliasEditor(frame: .zero)
    var stationRows: [StationMenuEntry] = []
    var connectedStationKey: String?
    func stationReachability(_ key: String, now: Date = Date()) -> Bool? {
        if sleeping || quitting || bluetoothMessage != nil { return false }
        let maxAge = selectedKnownStation?.key == key ? maximumAge : 3 * previewInterval
        switch stationContacts[key] {
        case .sample(let date):
            return (-5..<maxAge).contains(now.timeIntervalSince(date))
        case .failed:
            return false
        case nil:
            if let station = stationDirectory.stations.first(where: { $0.key == key }),
               let sample = readingStore.savedSnapshot(for: station, knownStations: stationDirectory.stations),
               let observed = sample["observed_at"] as? Double, now.timeIntervalSince1970 - observed >= maxAge { return false }
            return nil
        }
    }
    func stationIsOffline(_ key: String) -> Bool { stationReachability(key) != true }
    var sleeping = false
    var quitting = false
    var awaitingFirstRead = true
    var lastGood: Reading?
    var lastGoodSnapshot: [String: Any]?
    var lastError: String? = "Connecting…"
    var hasConnectionFailure = false
    var runtimeFrozenAt: Date?
    var loadHistory = LoadChartHistory()
    @MainActor lazy var outputHistory = DevicePowerHistory(provider: "bluetti", preferences: demo ? nil : defaults,
                                                          maximumGap: 360)
    let loadGraph = LoadGraphView()

    let menu = NSMenu()
    let loadGraphItem = NSMenuItem()
    let graphBottomSeparator = NSMenuItem.separator()
    let fixedMenuFont = NSFont.systemFont(ofSize: 12)
    var mainMenuIsOpen = false
    var visibility: StatusVisibility {
        StatusVisibility(defaults: defaults, reading: lastGood, station: selectedKnownStation?.key ?? identifier)
    }

    var visibleMenuBarFields: Set<MenuBarField> { visibility.visibleFields(for: lastGood) }

    let emptyRefreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
    enum RefreshState: String {
        case idle = "", connecting = "Connecting…", reading = "Refreshing…"
        case connected = "Connected", refreshed = "Refreshed"
        case connectFailed = "Failed to connect", readFailed = "Refresh failed"
    }
    var refreshState = RefreshState.idle
    let refreshRow = RefreshRowButton(frame: .zero)
    let refreshSlider = PanelSlider(frame: .zero)
    let refreshValue = NSTextField(labelWithString: "Refresh: 30s")

    var selectedInterval: PollInterval {
        let saved = defaults.integer(forKey: "refreshIntervalSeconds")
        return PollInterval(rawValue: saved) ?? .thirtySeconds
    }

    var refreshInterval: TimeInterval { TimeInterval(selectedInterval.rawValue) }

    var maximumAge: TimeInterval { return 3 * refreshInterval }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss d/M/yy"
        return formatter
    }()

    func shortDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    var statusFontSize: CGFloat {
        CGFloat(BarSelection.shared.size)
    }

    var isLoadingReading: Bool {
        return job != nil && !sleeping && !quitting
            && (refreshState == .connecting || refreshState == .reading)
    }

    var identifier: String {
        return defaults.string(forKey: "stationIdentifier") ?? ""
    }

    var cacheURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
        return directory.appendingPathComponent(demo ? "demo-status.json" : "status.json")
    }

    var helperURL: URL {
        return Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SuperBar")
    }

    private func buildMenu() {
        // Read the separate per-station store before status.json is replaced by
        // a pending/error response. A restored sample never becomes fresh API data.
        restoreSelectedReading()
        makeMenu()
        menu.delegate = self
        render()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        writeFailure("Waiting for a fresh Bluetooth reading.")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        restartAgeTimer()
        // OS permission survives app launches independently of cloud credentials.
        // Checking this property cannot open a Bluetooth permission dialog.
        if demo { activateBluetooth() }
        else if CBManager.authorization != .notDetermined { observeBluetoothPermission() }
    }

    private func observeBluetoothPermission() {
        if permissionManager == nil {
            // Create the manager in Super Bar so the system prompt belongs to the app.
            permissionManager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func activateBluetooth() {
        if demo { bluetoothActivated = true; refresh(); return }
        observeBluetoothPermission()
        if CBManager.authorization == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, CBManager.authorization == .allowedAlways {
            bluetoothMessage = nil
            if !bluetoothActivated {
                bluetoothActivated = true
                resetReadRetryBudget()
                pendingRefresh = true
                runQueuedWork()
            }
        } else {
            switch central.state {
            case .poweredOff: bluetoothMessage = "Turn on Bluetooth in System Settings."
            case .unsupported: bluetoothMessage = "Bluetooth is unavailable on this Mac."
            case .unauthorized: bluetoothMessage = "Allow Bluetooth for Super Bar in System Settings."
            default: bluetoothMessage = nil
            }
            bluetoothActivated = false
            generation += 1
            pendingRefresh = false
            manualRead = nil
            connectedStationKey = nil
            stationContacts.removeAll()
            previewDevices.removeAll()
            previewAfter.removeAll()
            restartPollTimer()
            job?.cancel()
            stationPreview?.job.cancel()
        }
        render()
    }

    @objc private func willSleep(_ notification: Notification) {
        closeMenu()
        sleeping = true
        manualRead = nil
        connectedStationKey = nil
        stationContacts.removeAll()
        previewDevices.removeAll()
        previewAfter.removeAll()
        generation += 1
        pendingRefresh = false
        job?.cancel(reason: "Mac is sleeping.")
        stationPreview?.job.cancel()
        fail("Mac is sleeping; Bluetooth reading paused.")
        rebuildStationMenu()
    }

    @objc private func didWake(_ notification: Notification) {
        sleeping = false
        guard bluetoothActivated else { return }
        generation += 1
        resetReadRetryBudget()
        pendingRefresh = true
        fail("Reconnecting after wake…")
        job?.cancel()
        rebuildStationMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        stationPreview?.job.cancel()
        manualRead = nil
        pollTimer?.invalidate()
        ageTimer?.invalidate()
        guard let running = job else { return .terminateNow }
        running.cancel(reason: "Super Bar is quitting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.quitting, self.job != nil else { return }
            self.job?.forceStop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeMenu()
        stationPreview?.job.forceStop()
        job?.forceStop()
        freezeRuntime()
        saveReadingState()
        writeFailure("Super Bar is not running.")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { return true }
}

extension BlueBarDelegate {
    @discardableResult
    func accept(_ snapshot: [String: Any], restoring: Bool = false) -> Bool {
        var reading: Reading
        do {
            reading = try Reading.decode(snapshot, previous: restoring ? nil : lastGood, now: Date(),
                                         maximumAge: restoring ? nil : maximumAge)
        } catch {
            if !restoring { readFailed(error.localizedDescription) }
            return false
        }
        if !restoring, let previous = lastGood,
           !previous.matchesStation(id: reading.deviceID, name: reading.device) {
            loadHistory.clear()
        }
        if reading.runtimeCarriedForward { freezeRuntime() }
        else { runtimeFrozenAt = nil }
        if restoring {
            let frozen = restoreDisplayMetadata(snapshot["_bluebar_display"], into: &reading)
            // Offline elapsed time is not a new measurement. Freeze the saved
            // estimate at its saved display moment, or at its observation.
            runtimeFrozenAt = frozen ?? reading.runtimeMeasuredAt
        }
        lastGood = reading
        lastGoodSnapshot = snapshot
        let station = stationDirectory.ingestStatus(snapshot)
        if demo && !restoring { connectedStationKey = station?.key }
        if restoring {
            loadHistory.markGap()
            lastError = "Waiting for a fresh Bluetooth reading."
            hasConnectionFailure = false
            return true
        }
        finishManualRead(error: nil)
        if let station { stationContacts[station.key] = .sample(reading.measuredAt) }
        // Older versions allowed a partial CLI selector. Once a real reading
        // identifies it, persist the exact target so restart can restore it.
        if !demo && !identifier.isEmpty {
            defaults.set(reading.deviceID ?? reading.device, forKey: "stationIdentifier")
        }
        if consecutiveReadFailures > 0 {
            consecutiveReadFailures = 0
            restartPollTimer()
        }
        nextReadRetryAt = nil
        refreshState = awaitingFirstRead || lastError != nil ? .connected : .refreshed
        awaitingFirstRead = false
        loadHistory.append(timestamp: reading.measuredAt, watts: reading.outputWatts, maximumGap: maximumAge)
        if let station {
            MainActor.assumeIsolated {
                outputHistory.record(reading.outputWatts, for: station.key, at: reading.measuredAt)
            }
        }
        lastError = nil
        restartAgeTimer()
        hasConnectionFailure = false
        saveReadingState()
        // Keep the actual helper payload in the API cache. Retained display
        // fields are never relabelled with the new sample's timestamp.
        writeCache(snapshot)
        render()
        return true
    }

    func restoreSelectedReading() {
        lastGood = nil
        lastGoodSnapshot = nil
        runtimeFrozenAt = nil
        guard !demo,
              let snapshot = readingStore.reading(for: identifier, knownStations: stationDirectory.stations) else { return }
        accept(snapshot, restoring: true)
    }

    func restoreDisplayMetadata(_ value: Any?, into reading: inout Reading) -> Date? {
        guard let display = value as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? {
            guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  raw.doubleValue.isFinite else { return nil }
            return raw.doubleValue
        }
        func date(_ key: String) -> Date? {
            return number(display[key]).map { Date(timeIntervalSince1970: $0) }
        }
        guard number(display["version"]) == 1 else { return nil }
        for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w"] {
            if let raw = display[key] {
                guard let watts = number(raw), watts >= 0 else { return nil }
            }
        }
        if let raw = display["runtime_battery_percent"], number(raw) == nil { return nil }
        let percent = number(display["runtime_battery_percent"]) ?? Double(reading.percent)
        guard percent.rounded() == percent, (0...100).contains(percent),
              let runtime = RuntimeEstimate.parse(display["runtime"], percent: Int(percent)),
              let observed = number(display["runtime_observed_at"]), observed >= 0,
              observed <= reading.measuredAt.timeIntervalSince1970 + 30,
              observed <= Date().timeIntervalSince1970 + 30 else { return nil }
        for key in ["input_retained_at", "output_retained_at", "runtime_frozen_at"] {
            if let raw = display[key] {
                guard let seconds = number(raw), seconds >= 0,
                      seconds <= Date().timeIntervalSince1970 + 30,
                      (key == "runtime_frozen_at" ? seconds >= observed
                       : seconds <= reading.measuredAt.timeIntervalSince1970 + 30) else { return nil }
            }
        }
        var carried = false
        if let raw = display["runtime_carried_forward"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            carried = flag.boolValue
        }
        // A current valid raw value, especially zero, wins over retained data.
        reading.acOutput = reading.acOutput ?? number(display["ac_output_w"])
        reading.dcOutput = reading.dcOutput ?? number(display["dc_output_w"])
        reading.outputPowerRetainedAt = date("output_retained_at")
        if carried && reading.runtime.canCarry(runtime, percent: reading.percent) {
            reading.runtime = runtime
            reading.runtimeMeasuredAt = Date(timeIntervalSince1970: observed)
            reading.runtimePercent = Int(percent)
            reading.runtimeCarriedForward = true
        }
        return date("runtime_frozen_at")
    }

    func saveReadingState() {
        guard let reading = lastGood, var snapshot = lastGoodSnapshot else { return }
        var display: [String: Any] = [
            "version": 1,
            "runtime": reading.runtime.json,
            "runtime_observed_at": reading.runtimeMeasuredAt.timeIntervalSince1970,
            "runtime_battery_percent": reading.runtimePercent,
            "runtime_carried_forward": reading.runtimeCarriedForward
        ]
        if let watts = reading.acOutput { display["ac_output_w"] = watts }
        if let watts = reading.dcOutput { display["dc_output_w"] = watts }
        if let date = reading.outputPowerRetainedAt { display["output_retained_at"] = date.timeIntervalSince1970 }
        if let date = runtimeFrozenAt { display["runtime_frozen_at"] = date.timeIntervalSince1970 }
        snapshot["_bluebar_display"] = display
        readingStore.save(snapshot, automatic: identifier.isEmpty)
    }

    func freezeRuntime() {
        guard runtimeFrozenAt == nil, let sample = lastGood else { return }
        runtimeFrozenAt = min(Date(), sample.runtimeMeasuredAt.addingTimeInterval(maximumAge))
    }

    func writeFailure(_ error: String) {
        var snapshot: [String: Any] = [
            "ok": false, "model": "AC50P", "error": error,
            "checked_at": Date().timeIntervalSince1970
        ]
        if let reading = lastGood {
            snapshot["last_success_at"] = reading.measuredAt.timeIntervalSince1970
        }
        if demo { snapshot["demo"] = true }
        writeCache(snapshot)
    }

    private func writeCache(_ snapshot: [String: Any]) {
        var cached = snapshot
        cached["refresh_interval_seconds"] = Int(refreshInterval)
        guard var data = try? JSONSerialization.data(withJSONObject: cached, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: nil)
            try data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            NSLog("Super Bar: cannot write status cache: %@", error.localizedDescription)
        }
    }
}
