import SwiftUI

#if !WIDGET_EXTENSION
struct CloudLoginForm: View {
    @ObservedObject var draft: LoginDraft
    let provider: String
    var unavailable = false
    var hasServer = false
    let submit: (String, String, String) async -> String?
    @State private var busy = false
    @State private var result: String?
    @State private var succeeded = false
    private static let servers = [("Automatic", "https://deyecloud.com"), ("Europe", "https://eu1.deyecloud.com"), ("US", "https://us1.deyecloud.com"), ("India", "https://india.deyecloud.com")]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $draft.email).textContentType(.username)
                #if os(iOS)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                #endif
            PasswordEntry(text: $draft.password)
            if hasServer {
                Menu {
                    ForEach(Self.servers, id: \.1) { name, value in
                        Button { draft.server = value } label: {
                            if draft.server == value { Label(name, systemImage: "checkmark") }
                            else { Text(name) }
                        }
                    }
                } label: {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(Self.servers.first { $0.1 == draft.server }?.0 ?? "Automatic")
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 32)
                }.accessibilityLabel("Deye server")
            } else {
                Text("Smart Life · Country 63 · EU").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                let email = draft.email, password = draft.password, server = draft.server
                busy = true; result = nil
                Task {
                    let error = await submit(email, password, server)
                    succeeded = error == nil
                    result = error ?? "Connected to \(provider). New credentials saved."
                    busy = false
                }
            } label: {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Signing in…" : "Login to " + provider)
                }
            }.buttonStyle(.borderedProminent)
                .disabled(busy || unavailable || draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.password.isEmpty)
            if let result {
                Label(result, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(succeeded ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.textFieldStyle(.roundedBorder).autocorrectionDisabled()
            .onAppear { draft.restore() }
    }
}

struct PasswordEntry: View {
    var title = "Password"
    @Binding var text: String
    @State private var visible = false
    var body: some View {
        HStack {
            Group {
                if visible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            .textContentType(.password)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .frame(minWidth: 32, minHeight: 32)
            }.buttonStyle(.plain)
                .accessibilityLabel(visible ? "Hide password" : "Show password")
        }
    }
}

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
