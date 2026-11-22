import AppKit
import SwiftUI

struct StationRowTitle {
    let name: String
    let accessibilityLabel: String
    let isConnected: Bool

    init(name: String, watts: Double?, connectedPercent: Int?) {
        self.name = name
        let summary = watts.map { name + " · " + MenuPresentation.watts($0) } ?? name
        isConnected = connectedPercent != nil
        accessibilityLabel = connectedPercent.map { "\(summary), connected, \($0)%" } ?? summary
    }
}

private final class BatteryCardModel: ObservableObject {
    @Published var content = BatteryDetailContent()
    @Published var brandImage: NSImage?
    @Published var legacyWidth: CGFloat = 264
}

private struct BatteryCardContent: View {
    @ObservedObject var model: BatteryCardModel
    let actions: BatteryDetailActions
    var alias = ""
    var constrainWidth = false

    var body: some View {
        BatteryDetailCard(content: model.content, actions: actions,
                          brandImage: model.brandImage.map { Image(nsImage: $0) }, alias: alias)
            .frame(width: constrainWidth ? model.legacyWidth : nil)
    }
}

/// Keeps the old target/action API without creating a second rendered button.
final class BatteryRefreshAction: NSButton {
    var stateChanged: ((Bool, Bool) -> Void)?
    func update(status: String, loading: Bool, enabled: Bool) {
        isEnabled = enabled
        setAccessibilityValue(status)
        stateChanged?(loading, enabled)
    }
}

/// AppKit keeps menu targets and the legacy inline editor; SwiftUI owns the card.
final class BatteryCard: NSView {
    let selectButton = PanelButton()
    let refreshButton = BatteryRefreshAction(frame: .zero)
    let renameButton = PanelButton()
    var onToggle: ((MenuBarField) -> Void)?
    private let model = BatteryCardModel()
    private var host: NSHostingView<BatteryCardContent>?
    private weak var editor: BlueBarAliasEditor?
    var expanded = true {
        didSet {
            guard expanded != oldValue else { return }
            model.content.expanded = expanded
            arrangeContents()
        }
    }
    private(set) var contentHeight: CGFloat = 144
    var summaryName: String { model.content.name }
    var hasReading: Bool { model.content.percent != nil }
    var summaryPercent: String { model.content.percent.map { "\($0)%" } ?? "—" }
    var summaryReadingPercent: Int? { model.content.percent }
    var summaryBatterySymbol: String { DeviceDisplayName.batterySymbol(percent: model.content.percent) }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        refreshButton.stateChanged = { [weak self] loading, enabled in
            guard let self else { return }
            var content = self.model.content
            content.refreshing = loading
            content.refreshEnabled = enabled
            self.updateContent(content)
        }
        arrangeContents()
    }
    required init?(coder: NSCoder) { nil }

    /// The primary panel can render this directly, without an NSView bridge.
    func detailView(alias: String = "", saveName: ((String) -> Void)? = nil) -> some View {
        BatteryCardContent(model: model, actions: actions(saveName: saveName), alias: alias)
    }

    private func actions(saveName: ((String) -> Void)? = nil) -> BatteryDetailActions {
        BatteryDetailActions(
            select: { [weak self] in self?.selectSummary() },
            rename: { [weak self] in self?.invoke(self?.renameButton) },
            refresh: { [weak self] in self?.invoke(self?.refreshButton) },
            toggleField: { [weak self] in
                guard let field = MenuBarField(rawValue: $0.rawValue) else { return }
                self?.onToggle?(field)
            }, saveName: saveName)
    }

    func selectSummary() { invoke(selectButton) }
    func toggleSummaryPercent() { onToggle?(.percentage) }
    private func invoke(_ button: NSButton?) {
        guard let button, button.isEnabled else { return }
        _ = button.sendAction(button.action, to: button.target)
    }

    func updateHeader(title: StationRowTitle, checked: Bool, enabled: Bool, canRename: Bool) {
        var content = model.content
        content.name = title.name
        content.connected = title.isConnected
        content.selected = checked
        content.selectionEnabled = enabled
        content.canRename = canRename
        updateContent(content)
        selectButton.isEnabled = enabled
        selectButton.setAccessibilityLabel(title.accessibilityLabel)
        selectButton.setAccessibilityValue(NSNumber(value: checked))
        selectButton.state = checked ? .on : .off
        renameButton.isEnabled = canRename
        arrangeContents()
    }

    func editName(with editor: BlueBarAliasEditor) {
        self.editor = editor
        addSubview(editor)
        arrangeContents()
    }
    func endEditingName() {
        editor?.removeFromSuperview()
        editor = nil
    }

    func setFields(_ fields: Set<MenuBarField>, brand image: NSImage?) {
        if model.brandImage !== image { model.brandImage = image }
        var content = model.content
        content.pinnedFields = Set(fields.compactMap { BatteryDisplayField(rawValue: $0.rawValue) })
        updateContent(content)
    }

    func update(readingPercent: Int?, power: MenuPowerRow, chargeTime: String, batteryTime: String) {
        var content = model.content
        content.percent = readingPercent
        content.input = power.input
        content.output = power.output
        content.chargeTime = chargeTime
        content.runtime = batteryTime
        content.outputHelp = power.toolTip
        updateContent(content)
        arrangeContents()
    }

    func updateStatus(_ status: String, loading: Bool, enabled: Bool, help: String? = nil, measuredAt: Date? = nil) {
        var content = model.content
        content.status = status
        content.refreshing = loading
        content.refreshEnabled = enabled
        content.statusHelp = help
        content.measuredAt = measuredAt
        updateContent(content)
        refreshButton.update(status: status, loading: loading, enabled: enabled)
    }

    private func updateContent(_ content: BatteryDetailContent) {
        if content != model.content { model.content = content }
    }

    override func layout() {
        super.layout()
        arrangeContents()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The main panel uses detailView directly. Allocate the legacy host only
        // when an actual AppKit menu displays this adapter, and release it on close.
        if window != nil, host == nil {
            let host = NSHostingView(rootView: BatteryCardContent(model: model, actions: actions(), constrainWidth: true))
            host.sizingOptions = []
            self.host = host
            addSubview(host, positioned: .below, relativeTo: editor)
        } else if window == nil {
            host?.removeFromSuperview()
            host = nil
        }
        arrangeContents()
    }

    private func arrangeContents() {
        refreshButton.isHidden = !expanded
        renameButton.isHidden = !expanded
        let width = max(1, bounds.width)
        if model.legacyWidth != width { model.legacyWidth = width }
        contentHeight = expanded ? max(144, host?.fittingSize.height ?? 144) : 26
        let frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        if host?.frame != frame { host?.frame = frame }
        editor?.frame = NSRect(x: 39, y: 7, width: max(1, width - 99), height: 24)
    }
}
