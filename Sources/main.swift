import AppKit
import SwiftUI
import Combine

@MainActor final class SuperBar: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = BarSelection.shared
    lazy var lg = App()
    lazy var blue = BlueBarDelegate()
    lazy var tcl = ClimateStore()
    let fields = ReadoutPreferences()
    let deye = DeyeStore()
    let tuya = TuyaStore()
    private var solarWatch: AnyCancellable?
    private var powerTimer: Timer?
    private var item: NSStatusItem!
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var watch: AnyCancellable?
    private var scheduled = false
    private var needsReadout = false
    private var cachedTCLImage: (key: [String], image: NSImage?)?
    private var panelReady = false
    private lazy var batteries = BatteryPanelState(blue)
    private var blueStarted = false
    private var cachedHeight: CGFloat = 0
    private var contentHeight: CGFloat?
    private var panelHost: NSHostingView<AnyView>?
    private var panelActive = false
    private var openGeneration = 0
    private var panelUpdateQueued = false
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ n: Notification) {
        EditingCommands.install(in: NSApp)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Super Bar"
        item.isVisible = true
        guard let b = item.button else { return }
        b.target = self; b.action = #selector(showPanel)
        b.sendAction(on: [.leftMouseDown])
        b.title = state.current.rawValue
        b.imageScaling = .scaleNone
        b.setAccessibilityLabel("Super Bar")
        appearanceObservation = b.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.schedule(.tcl) }
        }
        state.readoutChanged = { [weak self] in
            guard let self else { return }
            self.schedule(self.state.current)
        }
        state.didExpand = { [weak self] brand in
            guard let self else { return }
            switch brand {
            case .tcl:
                if let id = self.tcl.selected?.id { self.fields.pinDevice(id) }
            case .lg:
                self.lg.pinnedDeviceID = self.lg.selected
                self.lg.updateStatus()
            case .bluetti:
                if let key = self.blue.selectedKnownStation?.key { self.blue.pinnedStationKey = key }
                self.blue.render()
            case .deye: self.deye.pinned = true
            case .tuya:
                if let device = self.tuya.selected { self.tuya.pin(device.id) }
            }
        }
        configurePanel()
        // Prepare the native surface before any device controller starts.
        preparePanel(for: b)
        DispatchQueue.main.async { self.startServices(n) }
    }
    private func configurePanel() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
    }
    private func startServices(_ n: Notification) {
        lg.panelChanged = { [weak self] in self?.scheduleContent(.lg) }
        lg.didRender = { [weak self] in self?.schedule(.lg) }
        watch = tcl.objectWillChange.merge(with: fields.objectWillChange, tcl.history.objectWillChange).sink { [weak self] _ in self?.schedule(.tcl) }
        lg.applicationDidFinishLaunching(n)
        tcl.start()
        solarWatch = deye.objectWillChange.merge(with: tuya.objectWillChange).sink { [weak self] _ in
            guard let self else { return }
            self.schedule(self.state.current)
        }
        deye.start()
        tuya.start()
        let timer = Timer(timeInterval: Double(PowerPolling.interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPower() }
        }
        timer.tolerance = 1
        powerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        render()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible, !self.panelReady else { return }
            if let button = self.item?.button { self.preparePanel(for:button) }
            self.updatePanel()
            self.panel.contentView?.layoutSubtreeIfNeeded()
            self.panel.displayIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.publishLaunchReceipt() }
    }
    private func publishLaunchReceipt() {
        guard let path = ProcessInfo.processInfo.environment["SUPER_BAR_LAUNCH_RECEIPT"], !path.isEmpty,
              let executable = Bundle.main.executableURL else { return }
        let receipt: [String: Any] = [
            "statusItem": statusItemPlacement(item),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundlePath": Bundle.main.bundleURL.standardizedFileURL.path,
            "executablePath": executable.standardizedFileURL.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: receipt) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("Could not write Super Bar launch receipt: %@", error.localizedDescription) }
    }
    private func schedule(_ brand: Brand) {
        if state.current == brand { needsReadout = true }
        guard (needsReadout || panel.isVisible), !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.needsReadout { self.needsReadout = false; self.render() }
        }
    }
    private func render() {
        guard let button = item?.button else { return }
        switch state.current {
        case .bluetti where !blueStarted:
            button.title = "BLUETTI"
            button.image = nil
        case .bluetti, .lg:
            let readout = state.current == .lg ? lg.readout : blue.readout
            button.image = readout.image
            button.imagePosition = readout.imagePosition
            button.attributedTitle = readout.attributedTitle
        case .tuya:
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: tuya.pinnedWatts.map(DisplayUnits.power) ?? "—", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: CGFloat(state.size), weight: .medium), .foregroundColor: NSColor.white])
        case .tcl, .deye:
            let ac = fields.device(in: tcl)
            let visible = Set(ac.map { fields.ordered($0.id) } ?? (tcl.devices.isEmpty ? [.icon] : []))
            let energy = visible.contains(.energy) ? ac.flatMap { tcl.history.cardEnergy[$0.name] } : nil
            let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let readout = MenuReadout(size: CGFloat(state.size), ac: ac,
                                     visible: visible, energyText: energy)
            let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let key = readout.cacheKey + [String(dark), String(Double(scale))]
            if cachedTCLImage?.key != key {
                let renderer = ImageRenderer(content: readout.environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = scale
                cachedTCLImage = (key, renderer.nsImage.flatMap { $0.size.width > 0 ? $0 : nil })
            }
            button.title = ""
            button.image = cachedTCLImage?.image
            button.imagePosition = .imageOnly
        }
        if button.image == nil && button.title.isEmpty && deye.readout == nil {
            button.imagePosition = .noImage
            button.title = "···"
        }
        if deye.pinned {
            let balance = EnergyBalance(production: deye.reading, consumption: tuya.reading)
            SolarReadout.prepend(balance.text, to: button, size: CGFloat(state.size), color: balance.color)
        }
        button.toolTip = "Super Bar · " + state.current.rawValue + (deye.pinned ? " · Net power: " + deye.status : "")
    }
    private func refreshPower() { deye.refresh(); tuya.refresh() }
    private func footer() -> SuperFooter {
        SuperFooter(refresh:{ [weak self] in
            guard let self else { return }
            switch self.state.chartBrand {
            case .deye: self.refreshPower()
            case .tuya: self.refreshPower()
            case .tcl: self.tcl.manualRefresh()
            case .lg: self.lg.manualRefresh()
            case .bluetti: self.blue.refreshClicked()
            }
        }, settings:{ [weak self] _ in self?.lg.openSettings() }, interval:{ [weak self] in
            guard let self else { return ([60],60) }
            switch self.state.chartBrand {
            case .deye: return ([PowerPolling.interval],PowerPolling.interval)
            case .tuya: return ([PowerPolling.interval],PowerPolling.interval)
            case .tcl: return ([1,5,30,60,300,600],Int(self.tcl.refreshInterval))
            case .lg: return (intervals.map(Int.init),Int(defaults.double(forKey:"interval")))
            case .bluetti: return (PollInterval.allCases.map(\.rawValue),self.blue.selectedInterval.rawValue)
            }
        }, setInterval:{ [weak self] seconds in
            guard let self else { return }
            switch self.state.chartBrand {
            case .deye: break
            case .tuya: break
            case .tcl: self.tcl.setRefreshInterval(seconds)
            case .lg: defaults.set(Double(seconds),forKey:"interval"); self.lg.startTimer()
            case .bluetti:
                let slider = NSSlider()
                slider.doubleValue = Double(PollInterval.allCases.firstIndex(where:{$0.rawValue == seconds}) ?? 4)
                self.blue.changeRefreshInterval(slider)
            }
        }, changed: { [weak self] in
            guard let self else { return }
            self.lg.updateStatus()
            if self.blueStarted { self.blue.render() }
            self.schedule(self.state.current)
        })
    }
    private func scheduleContent(_ brand: Brand) {
        guard panelActive, !panelUpdateQueued else { return }
        panelUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelUpdateQueued = false
            self.lg.objectWillChange.send()
            self.batteries.refresh()
        }
    }

    private func endPanel() {
        ReadingAge.stop()
        openGeneration += 1
        lg.menuDidClose(lg.menu)
        if blueStarted { blue.mainMenuDidClose() }
        panelActive = false
    }
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        // Menu tracking temporarily takes key focus; let the menu action finish.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            if NSApp.keyWindow != nil && NSApp.keyWindow !== self.panel { return }
            self.dismissPanel()
        }
    }
    private func dismissPanel() {
        panel.orderOut(nil)
        endPanel()
    }

    private func beginPanel() {
        panelActive = true
        lg.menuWillOpen(lg.menu)
        if !blueStarted {
            blueStarted = true
            blue.panelChanged = { [weak self] in self?.scheduleContent(.bluetti) }
            blue.didRender = { [weak self] in self?.schedule(.bluetti) }
            blue.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        }
        blue.mainMenuWillOpen()
        batteries.refresh()
        ReadingAge.start { [weak self] in
            guard let self, self.panel.isVisible else { return }
            for row in self.blue.stationRows { _ = row.details.updateAge(now: Date()) }
        }
        if !panelReady { updatePanel() }
    }

    private func updatePanel() {
        guard let host = panelHost else { return }
        panelReady = true
        host.rootView = AnyView(UnifiedPanel(selection: state, tcl: tcl, history: tcl.history,
            fields: fields, lg: lg, batteries: batteries, deye: deye, tuya: tuya, availableHeight: cachedHeight,
            contentHeight: { [weak self] in self?.fitPanel($0) },
            settings: footer()))
    }

    private func fitPanel(_ natural: CGFloat) {
        guard natural.isFinite, natural > 0 else { return }
        let height = min(cachedHeight, max(1, ceil(natural)))
        contentHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelReady else { return }
            self.applyPanelHeight(height)
        }
    }

    private func applyPanelHeight(_ height: CGFloat) {
        guard let host = panelHost, abs(host.frame.height - height) > 1 else { return }
        let top = panel.frame.maxY
        panel.contentViewController?.view.setFrameSize(NSSize(width: PanelLayout.width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: height)
        panel.setContentSize(NSSize(width: PanelLayout.width, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    @objc func showPanel() {
        guard let button = item?.button else { return }
        if panel.isVisible { dismissPanel(); return }
        ReadingAge.panelOpened()
        let started = ProcessInfo.processInfo.systemUptime
        let eventTime = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0.timestamp : nil }
        preparePanel(for: button)
        if !panelReady {
            updatePanel()
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        if let height = contentHeight { applyPanelHeight(height) }
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let width = panel.frame.width
        let x = min(max(anchor.midX - width / 2, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - width - 4)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 2))
        panel.makeKeyAndOrderFront(nil)
        // Return from mouseDown before synchronizing controls or recreating a provider view.
        let generation = openGeneration
        let ordered = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openGeneration == generation, self.panel.isVisible else { return }
            self.beginPanel()
            let origin = eventTime ?? started
            NSLog("Super Bar open: event to handler %.1f ms; handler to window ordered %.1f ms", (started-origin)*1000, (ordered-started)*1000)
            UserDefaults.standard.set((ordered-started)*1000, forKey: "lastMenuOrderMilliseconds")
        }
    }
    private func preparePanel(for button: NSStatusBarButton) {
        let chrome: CGFloat = 0
        let height = max(300, (button.window?.screen?.visibleFrame.height ?? 800) - chrome - 36)
        if cachedHeight != height {
            cachedHeight = height
            let root = NSViewController()
            root.view = NSView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: height + chrome))
            root.view.appearance = NSAppearance(named: .darkAqua)
            root.view.wantsLayer = true
            root.view.layer?.backgroundColor = NSColor.clear.cgColor
            let tint = PanelBackdrop(frame:root.view.bounds)
            tint.autoresizingMask = [.width,.height]
            root.view.addSubview(tint)
            root.view.layer?.cornerRadius = 12
            root.view.layer?.borderWidth = 0.5
            root.view.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            root.view.layer?.masksToBounds = true
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            // The status popover owns its size; child layout must never resize its window.
            host.sizingOptions = []
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            panelReady = false
            panelHost = host
            host.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: height)
            root.view.addSubview(host)
            panel.contentViewController = root
            panel.setContentSize(root.view.frame.size)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item?.isVisible = true
        if !panel.isVisible { showPanel() } else { panel.makeKeyAndOrderFront(nil) }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { blueStarted ? blue.applicationShouldTerminate(sender) : .terminateNow }
    func applicationWillTerminate(_ n: Notification) { powerTimer?.invalidate(); deye.stop(); tuya.stop(); lg.applicationWillTerminate(n); if blueStarted { blue.applicationWillTerminate(n) } }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--bluetti-helper" { exit(BluettiNativeCommand.run(arguments: Array(arguments.dropFirst()))) }
if arguments.first == "--cli" { exit(ClimateCLI.run(Array(arguments.dropFirst()))) }
for domain in ["com.local.bluebar", "ru.tclbar.app", "local.LGBar"] { UserDefaults.standard.addSuite(named: domain) }
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = SuperBar()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
