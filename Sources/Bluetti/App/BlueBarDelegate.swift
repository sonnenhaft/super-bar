import AppKit

final class BlueBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var bluetoothActivated = false
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
    var generation = 0
    var pendingRefresh = false
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
    var sleeping = false
    var quitting = false
    var awaitingFirstRead = true
    var lastGood: Reading?
    var lastGoodSnapshot: [String: Any]?
    var lastError: String? = "Connecting…"
    var hasConnectionFailure = false
    var runtimeFrozenAt: Date?
    var loadHistory = LoadChartHistory()
    let loadGraph = LoadGraphView()

    let menu = NSMenu()
    let loadGraphItem = NSMenuItem()
    let graphBottomSeparator = NSMenuItem.separator()
    let fixedMenuFont = NSFont.systemFont(ofSize: 12)
    var lastReadTimer: Timer?
    var mainMenuIsOpen = false
    let percentVisibilityItem = PanelButton()
    let timeVisibilityItem = PanelButton()
    let outputVisibilityItem = PanelButton()
    var visibility: StatusVisibility {
        StatusVisibility(defaults: defaults, reading: lastGood, station: selectedKnownStation?.key ?? identifier)
    }

    var visibleMenuBarFields: Set<MenuBarField> { visibility.visibleFields(for: lastGood) }

    let iconVisibilityItem = PanelButton()
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

    var customStatusTextColor: NSColor? { nil }



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
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BluettiBar")
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

    }

    // Opening BLUETTI is the first user action that needs a station connection.
    // Startup, wake and timers must not request Bluetooth permission before it.
    func activateBluetooth() {
        guard !bluetoothActivated else { return }
        bluetoothActivated = true
        restartPollTimer()
        refresh()
    }

    @objc private func willSleep(_ notification: Notification) {
        closeMenu()
        sleeping = true
        generation += 1
        pendingRefresh = false
        job?.cancel(reason: "Mac is sleeping.")
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
        pollTimer?.invalidate()
        ageTimer?.invalidate()
        guard let running = job else { return .terminateNow }
        running.cancel(reason: "BluettiBar is quitting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.quitting, self.job != nil else { return }
            self.job?.forceStop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeMenu()
        job?.forceStop()
        freezeRuntime()
        saveReadingState()
        writeFailure("BluettiBar is not running.")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { return true }
}
