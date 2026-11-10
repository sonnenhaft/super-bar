import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DeviceSection: Identifiable {
    let title: String
    let symbol: String
    let items: [NSMenuItem]
    var id: String { title }
}

private struct PanelControl: NSViewRepresentable {
    let control: NSView
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: control.bounds)
        control.frame.origin = .zero
        control.autoresizingMask = [.width, .height]
        container.addSubview(control)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct DevicePanel<Devices: View>: View {
    @ObservedObject private var order = CardOrder.shared
    let brand: Brand
    let sections: [DeviceSection]
    var contentHeight: (CGFloat) -> Void = { _ in }
    var toggleBattery: (() -> Void)? = nil
    @ViewBuilder let devices: () -> Devices

    private func perform(_ item: NSMenuItem) {
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    devices()
                    ForEach(sections) { section in
                        let visible = order.sorted(section.items.filter { !$0.isHidden && !$0.isSeparatorItem },group:brand.rawValue) {
                            ($0.view as? BatteryCard)?.selectButton.dragID ?? $0.title
                        }
                        if !visible.isEmpty {
                            if section.title == "Batteries" {
                                ForEach(visible,id: \.self) { item in row(item) }
                            } else {
                                Card {
                                    SectionName(section.title,section.symbol)
                                    ForEach(visible,id: \.self) { item in row(item) }
                                }
                            }
                        }
                    }
                }.padding(8).reportContentHeight(contentHeight)
            }
        }.tint(cobalt).background(Color.clear)
    }

    @ViewBuilder private func row(_ item: NSMenuItem) -> some View {
        if let action = item.view as? ActionRow {
            Button { action.action?() } label: {
                HStack {
                    if let icon = action.button.image { Image(nsImage: icon) }
                    Text(action.button.title)
                    Spacer()
                    Text(action.right.stringValue).foregroundStyle(.secondary)
                }.fontWeight((!action.button.title.contains(" ON") && !action.button.title.contains(" OFF") && !action.right.stringValue.contains("ON") && !action.right.stringValue.contains("OFF")) ? .regular : .bold)
                 .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!action.button.isEnabled)
        } else if let control = item.view {
            PanelControl(control: control).id(ObjectIdentifier(control))
                .frame(height: max(16, (control as? BatteryCard)?.contentHeight ?? control.frame.height))
                .onDrop(of:[UTType.utf8PlainText.identifier],delegate:CardDrop(group:brand.rawValue,
                    target:(control as? BatteryCard)?.selectButton.dragID ?? "",
                    known:sections.flatMap(\.items).compactMap { ($0.view as? BatteryCard)?.selectButton.dragID }))
        } else if item.isEnabled, item.action != nil {
            Button { perform(item) } label: {
                HStack {
                    Text(item.title)
                    Spacer()
                    if item.state == .on { Image(systemName: "checkmark") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        } else {
            Text(verbatim: item.title).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
