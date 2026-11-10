import AppKit
import SwiftUI
import Combine

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor final class SuperBar: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = BarSelection.shared
    lazy var lg = App()
    lazy var blue = BlueBarDelegate()
    lazy var tcl = ClimateStore()
    let fields = ReadoutPreferences()
    private var item: NSStatusItem!
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var watch: AnyCancellable?
    private var scheduled = false
    private var needsReadout = false
    private var cachedTCLImage: (key: [String], image: NSImage?)?
    private var hostedBrand: Brand?
    private var blueStarted = false
    private var cachedHeight: CGFloat = 0
    private var panelHeader: SuperHeader?
    private var panelFooter: SuperFooter?
    private var panelHost: NSHostingView<AnyView>?
    private var activePanel: Brand?
    private var openGeneration = 0
    private var panelUpdateQueued = false
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ n: Notification) {
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
        render()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible, self.hostedBrand == nil else { return }
            self.updatePanel(.tcl)
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
            else { self.syncVisibleHeader() }
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
        case .tcl:
            let ac = fields.device(in: tcl)
            let visible = Set(ac.map { fields.ordered($0.id) } ?? (tcl.devices.isEmpty ? [.icon] : []))
            let energy = visible.contains(.energy) ? ac.flatMap { tcl.history.barEnergy(for: $0.name)?.text } : nil
            let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let readout = MenuReadout(size: CGFloat(state.size), textColor: state.color, ac: ac,
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
        if button.image == nil && button.title.isEmpty {
            button.imagePosition = .noImage
            button.title = "···"
        }
        button.toolTip = "Super Bar · " + state.current.rawValue
        syncVisibleHeader()
    }
    private func syncVisibleHeader() {
        if panel.isVisible { panelHeader?.sync() }
    }
    private func reading(for brand: Brand) -> BrandReading {
        switch brand {
        case .lg:
            let name = lg.devices.first { $0.id == lg.selected }?.name ?? ""
            return BrandReading(value: !lg.devices.isEmpty && lg.devices.allSatisfy({ lg.sample(for: $0.id)?.power == "POWER_OFF" && Date().timeIntervalSince(lg.checked[$0.id] ?? .distantPast) < 130 }) ? "All off" : lg.summaryValue(for: lg.selected), name: name)
        case .tcl:
            guard let ac = fields.device(in: tcl) else { return BrandReading() }
            if !tcl.offline && tcl.devices.allSatisfy({ $0.online == true && !$0.failed && $0.power == false }) { return BrandReading(value: "All off", name: ac.name) }
            var value = "—"
            if !tcl.offline && ac.online == true && !ac.failed {
                for field in fields.ordered(ac.id) {
                    switch field {
                    case .indoor: value = tempText(ac.indoor)
                    case .icon: continue
                    case .target: value = ac.acTemperature
                    case .power: value = ac.status
                    case .fan: value = ac.fan
                    case .energy: value = tcl.history.barEnergy(for: ac.name)?.text ?? "—"
                    case .eco: value = ac.code("ECO") == 1 ? "Eco" : "—"
                    case .vertical: value = ac.vane(true)
                    case .horizontal: value = ac.vane(false)
                    }
                    if value != "—" { break }
                }
            }
            return BrandReading(value: value, name: ac.name)
        case .bluetti:
            guard blueStarted else { return BrandReading() }
            let value = blue.lastGood.flatMap { sample in
                Date().timeIntervalSince(sample.measuredAt) < blue.maximumAge && !blue.awaitingFirstRead && !blue.hasConnectionFailure
                    ? blue.visibility.summary(for: sample, at: blue.runtimeFrozenAt ?? Date()) : nil
            }
            return BrandReading(value: value ?? "—", name: blue.selectedKnownStation?.displayName ?? "")
        }
    }
    private func header() -> SuperHeader {
        SuperHeader(reading: { [weak self] brand in
            guard let self, self.watch != nil else { return BrandReading() }
            return self.reading(for: brand)
        }, choose: { [weak self] in self?.choose($0) })
    }
    private func footer() -> SuperFooter {
        SuperFooter(changed: { [weak self] in
            guard let self else { return }
            switch self.state.current {
            case .lg: self.lg.updateStatus()
            case .bluetti: self.blue.render()
            case .tcl: self.schedule(.tcl)
            }
        })
    }
    private func scheduleContent(_ brand: Brand) {
        guard brand == activePanel, !panelUpdateQueued else { return }
        panelUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelUpdateQueued = false
            if let brand = self.activePanel, brand != .tcl { self.updatePanel(brand); self.syncVisibleHeader() }
        }
    }

    private func endPanel() {
        openGeneration += 1
        switch activePanel {
        case .lg: lg.menuDidClose(lg.menu)
        case .bluetti: blue.mainMenuDidClose()
        default: break
        }
        activePanel = nil
    }
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        // Menu tracking temporarily takes key focus; let the menu action finish.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.dismissPanel()
        }
    }
    private func dismissPanel() {
        panel.orderOut(nil)
        endPanel()
    }

    private func beginPanel(_ brand: Brand) {
        endPanel()
        activePanel = brand
        if brand != .bluetti || blueStarted {
            if hostedBrand != brand { updatePanel(brand) }
        }
        panelHeader?.sync()
        panelFooter?.sync()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, self.activePanel == brand else { return }
            switch brand {
            case .lg: self.lg.menuWillOpen(self.lg.menu)
            case .bluetti:
                if !self.blueStarted {
                    self.blueStarted = true
                    self.blue.panelChanged = { [weak self] in self?.scheduleContent(.bluetti) }
                    self.blue.didRender = { [weak self] in self?.schedule(.bluetti) }
                    self.blue.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                    self.updatePanel(.bluetti)
                }
                self.blue.activateBluetooth()
                self.blue.mainMenuWillOpen()
            case .tcl: break
            }
        }
    }

    private func updatePanel(_ brand: Brand) {
        guard let host = panelHost else { return }
        hostedBrand = brand
        switch brand {
        case .tcl:
            host.rootView = AnyView(ClimatePanel(store: tcl, history: tcl.history, preferences: fields, height: cachedHeight))
        case .lg:
            host.rootView = AnyView(DevicePanel(brand: .lg, sections: lg.panelSections) {
                if !self.lg.devices.isEmpty {
                    SectionName("Air conditioners", "air.conditioner.horizontal")
                    ForEach(self.lg.devices, id: \.id) { self.lg.deviceCard($0) }
                    CoolingPresetRow(enabled: { self.lg.connected && self.lg.presetAllowed(Double($0.degrees), $0.speed) },
                        selected: { preset in
                            self.lg.powerIsOn && self.lg.displayValue("airConJobMode", "currentJobMode") as? String == "COOL"
                                && self.lg.displayValue("airFlow", self.lg.windKey) as? String == preset.speed
                                && lgNumber(self.lg.displayValue("temperature", "targetTemperature")) == Double(preset.degrees)
                        }, apply: { self.lg.preset(Double($0.degrees), $0.speed) })
                }
            })
        case .bluetti:
            let sections = [DeviceSection(title: "Batteries", symbol: MenuPresentation.batterySymbol(percent: blue.lastGood?.percent ?? 0), items: [blue.emptyRefreshItem] + blue.stationRows.flatMap { $0.details.items }),
                            DeviceSection(title: "Load history", symbol: "chart.xyaxis.line", items: [blue.loadGraphItem]),
                            DeviceSection(title: "Settings", symbol: "gearshape", items: blue.panelSettings)]
            host.rootView = AnyView(DevicePanel(brand: .bluetti, sections: sections, toggleBattery: { self.blue.toggleMenuBarField(.battery) }) { EmptyView() })
        }
    }

    private func choose(_ brand: Brand) {
        state.current = brand
        beginPanel(brand)
        render()
    }

    @objc func showPanel() {
        guard let button = item?.button else { return }
        if panel.isVisible { dismissPanel(); return }
        let started = ProcessInfo.processInfo.systemUptime
        let eventTime = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0.timestamp : nil }
        preparePanel(for: button)
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
            self.beginPanel(self.state.current)
            let origin = eventTime ?? started
            NSLog("Super Bar open: event to handler %.1f ms; handler to window ordered %.1f ms", (started-origin)*1000, (ordered-started)*1000)
            UserDefaults.standard.set((ordered-started)*1000, forKey: "lastMenuOrderMilliseconds")
        }
    }
    private func preparePanel(for button: NSStatusBarButton) {
        let chrome = SuperHeader.height + SuperFooter.height
        let height = min(720, max(300, (button.window?.screen?.visibleFrame.height ?? 800) - chrome - 36))
        if cachedHeight != height {
            cachedHeight = height
            let root = NSViewController()
            root.view = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: height + chrome))
            root.view.appearance = NSAppearance(named: .darkAqua)
            root.view.wantsLayer = true
            root.view.layer?.backgroundColor = BarTheme.background.cgColor
            root.view.layer?.cornerRadius = 12
            root.view.layer?.masksToBounds = true
            panelHeader = header()
            panelFooter = footer()
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            // The status popover owns its size; child layout must never resize its window.
            host.sizingOptions = []
            hostedBrand = nil
            panelHost = host
            panelHeader!.frame.origin = NSPoint(x: 45, y: height + SuperFooter.height)
            panelFooter!.frame.origin = NSPoint(x: 45, y: 0)
            host.frame = NSRect(x: 0, y: SuperFooter.height, width: 390, height: height)
            [panelHeader!, host, panelFooter!].forEach(root.view.addSubview)
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
    func applicationWillTerminate(_ n: Notification) { lg.applicationWillTerminate(n); if blueStarted { blue.applicationWillTerminate(n) } }
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
