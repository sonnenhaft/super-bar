import SwiftUI

#if !WIDGET_EXTENSION
struct KeychainAccessButton: View {
    @ObservedObject private var status = CredentialAccessStatus.shared
    var alwaysVisible = false
    var refresh: () -> Void
    var body: some View {
        if CredentialAccess.usesKeychain && (alwaysVisible || status.needsAuthorization) {
            Button {
                Task {
                    await CredentialAccess.authorize()
                    refresh()
                }
            } label: {
                Label(status.authorizing ? "Ожидаем доступ…" : "Дать доступ к Keychain", systemImage: "key")
            }
            .disabled(status.authorizing)
        }
    }
}
#endif

extension View {
    func superBarSurface(selected: Bool = false, padding: CGFloat = 8) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .deviceSurface(selected: selected)
    }
    func deviceSurface(selected: Bool) -> some View {
        self.background(LinearGradient(colors: [selected ? SuperBarPanelStyle.selected : SuperBarPanelStyle.panel,
                                                SuperBarPanelStyle.panel.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: SuperBarPanelStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: SuperBarPanelStyle.radius)
                .strokeBorder(selected ? SuperBarPanelStyle.outline : .white.opacity(0.32), lineWidth: selected ? 1 : 0.6))
    }
}

struct PanelBrandLabel: View {
    var name: String
    var compact = false
    var body: some View {
        Text(name).font(.system(size: name == "BLUETTI" ? (compact ? 9 : 10) : (compact ? 15 : 17), weight: .semibold))
            .frame(width: compact ? 46 : SuperBarPanelStyle.brandWidth, alignment: .leading)
    }
}

struct PanelDeviceName: View {
    var name: String
    var on: Bool?
    var spacing: CGFloat = 3
    var body: some View {
        HStack(spacing: spacing) {
            Text(DeviceDisplayName.clean(name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Circle().fill(on == true ? SuperBarPanelStyle.green : on == false ? .red : .gray)
                .frame(width: 5, height: 5).accessibilityLabel(on.map { $0 ? "ON" : "OFF" } ?? "Unknown")
        }
    }
}

struct PanelSectionHeading: View {
    let title: String
    var expanded: Bool? = nil
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: compact ? 15 : 19, weight: .bold))
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold))
            }
        }.foregroundStyle(.white)
    }
}

struct PanelReadingCard: View {
    var name: String
    var primary: String
    var secondary: String = ""
    var symbol: String? = nil
    var on: Bool? = nil
    var selected = false
    var reservesSecondaryLine = false
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let symbol {
                if symbol == "air.conditioner.horizontal" { ClimateHousing(windowUnit: true).frame(width: 28, height: 24) }
                else { Image(systemName: symbol).font(.system(size: 23)).foregroundStyle(.white.opacity(0.85)) }
            }
            VStack(alignment: .leading, spacing: 3) {
                PanelDeviceName(name: name, on: on)
                Text(primary).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                if reservesSecondaryLine || !secondary.isEmpty {
                    Text(secondary.isEmpty ? " " : secondary)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(secondary.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }.foregroundStyle(.white).frame(minHeight: 32, alignment: .topLeading)
            .superBarSurface(selected: selected, padding: 7)
    }
}

struct PanelEnergyTile: View {
    var title: String
    var value: String
    var generation: Bool
    var selected = false
    var compact = false
    var body: some View {
        PanelEnergyContent(title: title, value: value, generation: generation, emphasized: selected, compact: compact)
            .superBarSurface(selected: selected)
    }
}

// The Mac wraps this label in its pinning button; iPhone/widgets wrap it in a tile.
struct PanelEnergyContent: View {
    var title: String
    var value: String
    var generation: Bool
    var emphasized = false
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: generation ? "sun.max" : "bolt.fill").font(.system(size: compact ? 22 : 28))
                .frame(width: compact ? 23 : 29)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Text(value).font(.system(size: compact ? 18 : 20, weight: emphasized ? .bold : .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(generation ? SuperBarPanelStyle.yellow : SuperBarPanelStyle.cyan)
            .frame(minHeight: compact ? 34 : 42)
    }
}
