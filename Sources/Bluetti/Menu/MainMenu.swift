import AppKit

extension BlueBarDelegate {
    func makeMenu() {
        menu.autoenablesItems = false
        menu.font = fixedMenuFont
        menu.minimumWidth = 264
        addControl(sectionHeader("Batteries", closeButton: true))
        refreshRow.frame = NSRect(x: 0, y: 0, width: 264, height: 22)
        refreshRow.autoresizingMask = [.width]
        refreshRow.target = self
        refreshRow.action = #selector(refreshClicked)
        emptyRefreshItem.target = self
        emptyRefreshItem.view = refreshRow
        menu.addItem(emptyRefreshItem)
        addStationControl()
        addControl(sectionHeader("Settings"))
        let start = menu.numberOfItems
        addControl(intervalControl())
        panelSettings = Array(menu.items.dropFirst(start))
        menu.addItem(.separator())
        loadGraphItem.view = loadGraph
        loadGraphItem.isEnabled = false
        menu.addItem(loadGraphItem)
        menu.addItem(graphBottomSeparator)
    }

    private func addControl(_ view: NSView) {
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
    }

    private func sectionHeader(_ title: String, closeButton: Bool = false) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 264, height: 22))
        row.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .labelColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 32, y: (row.bounds.height - label.frame.height) / 2)
        row.addSubview(label)

        func line(from start: CGFloat, to end: CGFloat) -> NSBox {
            let line = NSBox(frame: NSRect(x: start, y: row.bounds.midY, width: end - start, height: 1))
            line.boxType = .separator
            row.addSubview(line)
            return line
        }
        _ = line(from: 12, to: label.frame.minX - 5)
        let rightInset: CGFloat = closeButton ? 38 : 12
        line(from: label.frame.maxX + 5, to: row.bounds.maxX - rightInset).autoresizingMask = [.width]
        guard closeButton else { return row }
        let close = PanelButton(frame: NSRect(x: row.bounds.width - 32, y: 0, width: 24, height: row.bounds.height))
        close.autoresizingMask = [.minXMargin]
        close.title = ""
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.imagePosition = .imageOnly
        close.setAccessibilityLabel("Close")
        close.target = self
        close.action = #selector(closeMenu)
        row.addSubview(close)
        return row
    }

    func mainMenuWillOpen() {
        mainMenuIsOpen = true
        render()
    }

    // Match the system window surface used by TCL Bar. The menu keeps its
    // native margins, separators and outside-click behavior.
    func updateMenuBackground() {
        menu.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.cgColor
            for item in menu.items {
                guard let view = item.view else { continue }
                view.wantsLayer = true
                if view.layer?.backgroundColor != color { view.layer?.backgroundColor = color }
            }
        }
    }

    func mainMenuDidClose() {
        mainMenuIsOpen = false
        stopStationSpinners()
        refreshRow.update(status: refreshState.rawValue, loading: false, enabled: false)
        cancelStationRename()
    }

    @objc func closeMenu() {
        if mainMenuIsOpen { menu.cancelTracking() }
    }
}

extension BlueBarDelegate {
    func toggleMenuBarField(_ field: MenuBarField) {
        pinnedStationKey = selectedKnownStation?.key ?? identifier
        BarSelection.shared.pin(.bluetti)
        var choices = visibility
        choices.toggle(field, reading: lastGood, defaults: defaults)
        render()
    }

    func intervalControl() -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        row.autoresizingMask = [.width]
        refreshValue.frame = NSRect(x: 12, y: 25, width: 180, height: 15)
        refreshValue.autoresizingMask = [.width]
        refreshValue.font = .systemFont(ofSize: 11)
        refreshValue.textColor = .secondaryLabelColor
        row.addSubview(refreshValue)
        refreshSlider.frame = NSRect(x: 10, y: 1, width: 180, height: 24)
        refreshSlider.autoresizingMask = [.width]
        refreshSlider.controlSize = .small
        refreshSlider.minValue = 0
        refreshSlider.maxValue = Double(PollInterval.allCases.count - 1)
        refreshSlider.numberOfTickMarks = PollInterval.allCases.count
        refreshSlider.allowsTickMarkValuesOnly = true
        refreshSlider.isContinuous = true
        refreshSlider.target = self
        refreshSlider.action = #selector(changeRefreshInterval(_:))
        refreshSlider.toolTip = PollInterval.allCases.map { $0.label }.joined(separator: " / ")
        refreshSlider.setAccessibilityLabel("Refresh interval")
        row.addSubview(refreshSlider)
        updateRefreshControl()
        return row
    }

    private func updateRefreshControl() {
        guard let index = PollInterval.allCases.firstIndex(of: selectedInterval) else { return }
        refreshSlider.doubleValue = Double(index)
        refreshValue.stringValue = "Refresh: " + selectedInterval.label
        refreshSlider.setAccessibilityValue(selectedInterval.label)
    }

    @objc func changeRefreshInterval(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let index = Int(min(Double(PollInterval.allCases.count - 1), max(0, sender.doubleValue)).rounded())
        let seconds = PollInterval.allCases[index].rawValue
        guard seconds != Int(refreshInterval) else { updateRefreshControl(); return }
        defaults.set(seconds, forKey: "refreshIntervalSeconds")
        updateRefreshControl()
        if consecutiveReadFailures > 0 {
            nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        }
        if streaming { stopPollingSession() }
        restartAgeTimer()
        restartPollTimer()
        refresh()
    }
}

final class PanelButton: NSButton {
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.28 : 0.17).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
}

final class PanelSlider: NSSlider {
    override init(frame: NSRect) {
        super.init(frame: frame)
        trackFillColor = BarTheme.cobalt
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); trackFillColor = BarTheme.cobalt }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); trackFillColor = BarTheme.cobalt }
}

final class RefreshRowButton: NSButton {
    enum Style { case statusAndIcon, iconOnly, textOnly }
    private let style: Style

    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    var iconTint: NSColor? {
        get { arrow.contentTintColor }
        set { arrow.contentTintColor = newValue }
    }
    private var loading = false
    private var hovered = false { didSet { needsDisplay = true } }
    private var rowCursor: NSCursor {
        guard isEnabled else { return .arrow }
        return .pointingHand
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, style: .statusAndIcon)
    }

    init(frame: NSRect, style: Style) {
        self.style = style
        super.init(frame: frame)
        title = ""
        isBordered = false
        setAccessibilityLabel("Refresh")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = style == .iconOnly
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        arrow.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        arrow.imageScaling = .scaleNone
        arrow.isHidden = style == .textOnly
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        for view in [statusLabel, arrow, spinner] as [NSView] {
            addSubview(view)
            view.setAccessibilityElement(false)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    override func layout() {
        super.layout()
        let icon = NSRect(x: style == .iconOnly ? bounds.midX - 8 : bounds.maxX - 23, y: bounds.midY - 8, width: 16, height: 16)
        spinner.frame = icon.insetBy(dx: 2, dy: 2)
        arrow.frame = icon
        let labelEnd = style == .textOnly ? bounds.maxX : icon.minX
        statusLabel.frame = NSRect(x: 8, y: bounds.midY - 8, width: max(0, labelEnd - 16), height: 16)
    }

    func update(status: String, loading: Bool, enabled: Bool) {
        if statusLabel.stringValue != status {
            statusLabel.stringValue = status
            setAccessibilityValue(status)
        }
        let cursorChanged = isEnabled != enabled || self.loading != loading
        if isEnabled != enabled { isEnabled = enabled }
        if self.loading != loading {
            self.loading = loading
            arrow.isHidden = loading || style == .textOnly
            if loading && style != .textOnly { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        if cursorChanged, let window = window {
            window.invalidateCursorRects(for: self)
            if hovered && window.isVisible && visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                rowCursor.set()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
    }

    // Mouse tracking belongs to the button even over the text or spinning indicator.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        rowCursor.set()
    }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: rowCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
            bounds.insetBy(dx: 0, dy: 1).fill()
        }
        super.draw(dirtyRect)
    }
}
