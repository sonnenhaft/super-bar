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
        lastReadTimer?.invalidate()
        lastReadTimer = nil
        stopStationSpinners()
        refreshRow.update(status: refreshState.rawValue, loading: false, enabled: false)
        cancelStationRename()
    }

    @objc func closeMenu() {
        if mainMenuIsOpen { menu.cancelTracking() }
    }
}
