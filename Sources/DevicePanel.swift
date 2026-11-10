import SwiftUI
import AppKit

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
    let brand: Brand
    let sections: [DeviceSection]
    let refresh: () -> Void
    @ViewBuilder let devices: () -> Devices

    private func perform(_ item: NSMenuItem) {
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if brand == .lg { Image(nsImage: lgIcon()).accessibilityLabel("LG") }
                else { Image("bluetti-icon").resizable().scaledToFit().frame(width: 24, height: 24).accessibilityLabel("BLUETTI") }
                Text(brand == .lg ? "Climate" : "Power station").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh readings").accessibilityLabel("Refresh")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    devices()
                    ForEach(sections) { section in
                        let visible = section.items.filter { !$0.isHidden && !$0.isSeparatorItem }
                        if !visible.isEmpty {
                            Card {
                                SectionName(section.title, section.symbol)
                                ForEach(visible, id: \.self) { item in row(item) }
                            }
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7)
            }
        }.tint(cobalt).background(Color(nsColor: BarTheme.background))
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
