import SwiftUI

#if !WIDGET_EXTENSION
struct AccountConnections: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    let tcl: ClimateStore
    let connectLG: (String, String, String) async throws -> Void
    let refresh: () -> Void
    @State private var provider = "Deye"
    @StateObject private var tclDraft = LoginDraft(provider: "tcl")
    @StateObject private var lgDraft = LoginDraft(provider: "lg")
    @State private var country = UserDefaults.standard.string(forKey: "country") ?? "PH"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections").font(.headline)
            KeychainAccessButton {
                deye.loginDraft.restore(); tuya.loginDraft.restore(); tclDraft.restore(); lgDraft.restore()
                refresh()
            }
            // Background polling never locks navigation between accounts.
            Picker("Account", selection: $provider) {
                ForEach(["Deye", "Smart Life", "TCL Home", "LG ThinQ"], id: \.self) { Text($0) }
            }
            if provider == "Deye" {
                CloudLoginForm(draft: deye.loginDraft, provider: provider, unavailable: deye.refreshing, hasServer: true) { email, password, server in
                    await deye.signIn(email: email, password: password, server: server) ? nil : (deye.problem ?? "Deye is busy. Try again shortly.")
                }
            } else if provider == "Smart Life" {
                CloudLoginForm(draft: tuya.loginDraft, provider: provider, unavailable: tuya.refreshing) { email, password, _ in
                    tuya.email = email
                    return await tuya.signIn(password: password) ? nil : (tuya.problem ?? "Smart Life is busy. Try again shortly.")
                }
            } else if provider == "TCL Home" {
                CloudLoginForm(draft: tclDraft, provider: provider) { email, password, _ in
                    await withCheckedContinuation { continuation in
                        tcl.signIn(email: email, password: password) { continuation.resume(returning: $0) }
                    }
                }
            } else {
                CloudLoginForm(draft: lgDraft, provider: provider, country: $country) { email, password, country in
                    do { try await connectLG(email, password, country); return nil }
                    catch { return error.localizedDescription }
                }
            }
        }
    }
}

struct CloudLoginForm: View {
    @ObservedObject var draft: LoginDraft
    let provider: String
    var unavailable = false
    var hasServer = false
    var country: Binding<String>? = nil
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
            if let country {
                TextField("Country code", text: country)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            } else if hasServer {
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
            } else if provider == "Smart Life" {
                Text("Smart Life · Country 63 · EU").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                let email = draft.email, password = draft.password, location = country?.wrappedValue ?? draft.server
                busy = true; result = nil
                Task {
                    let error = await submit(email, password, location)
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
    var refresh: () -> Void
    var body: some View {
        if CredentialAccess.usesKeychain && status.needsAuthorization {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task {
                        await CredentialAccess.authorize()
                        refresh()
                    }
                } label: {
                    #if os(iOS)
                    Label(status.authorizing ? "Проверяем…" : "Повторить доступ к сохранённым аккаунтам", systemImage: "key")
                    #else
                    Label(status.authorizing ? "Ожидаем доступ…" : "Дать доступ к Keychain", systemImage: "key")
                    #endif
                }
                .disabled(status.authorizing)
                if let result = status.result {
                    Text(result).font(.callout).foregroundStyle(status.needsAuthorization ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
