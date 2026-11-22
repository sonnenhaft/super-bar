import SwiftUI

#if !WIDGET_EXTENSION
struct AccountConnections: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    let tcl: ClimateStore
    let connectLG: (String, String, String) async throws -> Void
    let disconnectLG: () -> Void
    let refresh: () -> Void
    @AppStorage("settings.accountProvider") private var provider = "All"
    private let names = ["Deye", "Smart Life", "TCL Home", "LG ThinQ"]
    private var visible: [String] { names.contains(provider) ? [provider] : names }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections").font(.headline)
            Picker("Account", selection: $provider) {
                Text("All").tag("All")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }.panelPointer()
            ForEach(visible, id: \.self) { name in
                AccountConnectionEditor(deye: deye, tuya: tuya, tcl: tcl,
                    connectLG: connectLG, disconnectLG: disconnectLG, refresh: refresh,
                    provider: name, showsKeychainControl: name == visible.first)
            }
        }.onAppear { if provider != "All" && !names.contains(provider) { provider = "All" } }
    }
}

private struct AccountConnectionEditor: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore
    let tcl: ClimateStore
    let connectLG: (String, String, String) async throws -> Void
    let disconnectLG: () -> Void
    let refresh: () -> Void
    @ObservedObject private var credentialStatus = CredentialAccessStatus.shared
    let provider: String
    let showsKeychainControl: Bool
    @StateObject private var tclDraft = LoginDraft(provider: "tcl")
    @StateObject private var lgDraft = LoginDraft(provider: "lg")
    @State private var country = UserDefaults.standard.string(forKey: "country") ?? "PH"
    @State private var loadedLGDraft = false
    @State private var canShowInputs = false
    @State private var hasSavedSession = false
    private var providerKey: String { ["Deye": "deye", "Smart Life": "tuya", "TCL Home": "tcl", "LG ThinQ": "lg"][provider]! }
    private var connected: Bool { hasSavedSession && canShowInputs && AccountConnection.connected(providerKey) }
    private func loadAccount(forceRestore: Bool = false) {
        let data: Data?
        do {
            data = try CredentialAccess.shared.read(providerKey + "-session")
            // A missing account is not a denied Keychain permission. In particular,
            // a newly selected provider must remain editable after an app restart.
            canShowInputs = true
        } catch {
            data = nil
            canShowInputs = !CredentialAccess.usesKeychain
            if !canShowInputs {
                tclDraft.password = ""
                lgDraft.password = ""
            }
        }
        hasSavedSession = data != nil
        if hasSavedSession, !AccountConnection.signedOut(providerKey), !AccountConnection.connected(providerKey) {
            AccountConnection.setConnected(true, provider: providerKey)
        }
        if !connected && canShowInputs {
            switch providerKey {
            case "deye": deye.loginDraft.restore(force: forceRestore)
            case "tuya": tuya.loginDraft.restore(force: forceRestore)
            case "tcl": tclDraft.restore(force: forceRestore)
            default: lgDraft.restore(force: forceRestore)
            }
        }
    }
    private func logout() {
        switch providerKey {
        case "deye": deye.logout()
        case "tuya": tuya.logout()
        case "tcl": tcl.logout()
        default: disconnectLG()
        }
        loadAccount(forceRestore: true)
    }
    private func disallowKeychain() {
        CredentialAccess.disallow()
        deye.logout(); tuya.logout(); tcl.logout(); disconnectLG()
        deye.loginDraft.password = ""; tuya.loginDraft.password = ""
        tclDraft.password = ""; lgDraft.password = ""
        canShowInputs = false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider).font(.subheadline.weight(.semibold))
                Spacer()
                if showsKeychainControl && CredentialAccess.usesKeychain && canShowInputs {
                    Button("Disallow Keychain", action: disallowKeychain).panelPointer()
                        .disabled(credentialStatus.authorizing)
                        .help("Stop all connections and lock saved credentials. Keychain records are kept.")
                }
            }
            if connected {
                HStack {
                    Label("Connected to " + provider, systemImage: "checkmark.circle")
                    Spacer()
                    Button("Logout", action: logout).panelPointer()
                }
            } else if !canShowInputs {
                if showsKeychainControl {
                    KeychainAccessButton(alwaysShow: true, refresh: refresh)
                }
            } else if provider == "Deye" {
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
        }.onChange(of: provider, initial: true) { _, _ in loadAccount() }
        .onChange(of: credentialStatus.accountRevision) { _, _ in loadAccount() }
        .onAppear {
            guard provider == "LG ThinQ", !loadedLGDraft else { return }
            loadedLGDraft = true
            if let input = LGLoginInput.developmentDraft() {
                lgDraft.email = input.email; lgDraft.password = input.password
                country = input.country.uppercased()
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
    private static let countries = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        .map { (code: $0, name: Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted {
            if $0.code == "PH" || $1.code == "PH" { return $0.code == "PH" && $1.code != "PH" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $draft.email).textContentType(.username)
                #if os(iOS)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                #endif
            PasswordEntry(text: $draft.password)
            if let country {
                Picker("Account region", selection: country) {
                    ForEach(Self.countries, id: \.code) { region in
                        Text("\(region.name) (\(region.code))").tag(region.code)
                    }
                }.pickerStyle(.menu).panelPointer()
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
                }.panelPointer().accessibilityLabel("Deye server")
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
            }.buttonStyle(.borderedProminent).panelPointer()
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
            }.panelButtonStyle()
                .accessibilityLabel(visible ? "Hide password" : "Show password")
        }
    }
}

struct KeychainAccessButton: View {
    @ObservedObject private var status = CredentialAccessStatus.shared
    var alwaysShow = false
    var refresh: () -> Void
    var body: some View {
        if CredentialAccess.usesKeychain && (alwaysShow || status.needsAuthorization) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task {
                        if await CredentialAccess.authorize() { refresh() }
                    }
                } label: {
                    Label(status.authorizing ? "Opening Keychain…" : "Allow Keychain", systemImage: "key")
                }
                .panelPointer().disabled(status.authorizing)
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
    func superBarSurface(selected: Bool = false, padding: CGFloat = 8, radius: CGFloat = SuperBarPanelStyle.radius, border: Color? = nil) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .deviceSurface(selected: selected, radius: radius, border: border)
    }
    func deviceSummarySurface(selected: Bool, compact: Bool = false, border: Color? = nil) -> some View {
        frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: compact ? 31 : 40, alignment: .topLeading)
            .superBarSurface(selected: selected, padding: compact ? 4 : 6,
                             radius: compact ? 4 : SuperBarPanelStyle.radius, border: border)
    }
    func offlineDevice(_ offline: Bool, allowsReconnect: Bool = false) -> some View {
        self.saturation(offline ? 0 : 1)
            .opacity(offline ? 0.52 : 1)
            .disabled(offline && !allowsReconnect)
    }

    func deviceSurface(selected: Bool, radius: CGFloat = SuperBarPanelStyle.radius, border: Color? = nil) -> some View {
        self.background(LinearGradient(colors: [selected ? SuperBarPanelStyle.selected : SuperBarPanelStyle.panel,
                                                SuperBarPanelStyle.panel.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(border ?? (selected ? SuperBarPanelStyle.outline : .white.opacity(0.32)), lineWidth: selected || border != nil ? 1 : 0.6))
    }
}

/// Keep station positions and widths stable through discovery and background reads.
struct BatteryStationGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8, content: content)
    }
}

struct BatterySummaryCard: View {
    let name: String
    let symbol: String
    let charge: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(SuperBarPanelStyle.green)
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(charge).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .deviceSummarySurface(selected: selected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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

enum EnergyTileIcon: String {
    case sun = "sun.max", moon = "moon.stars", consumption = "bolt.fill"

    static func generation(watts: Double?) -> Self { watts == 0 ? .moon : .sun }
}

struct PanelEnergyTile: View {
    var title: String
    var value: String
    var icon: EnergyTileIcon
    var selected = false
    var compact = false
    var body: some View {
        PanelEnergyContent(title: title, value: value, icon: icon, emphasized: selected, compact: compact)
            .superBarSurface(selected: selected, padding: compact ? 6 : 8, radius: compact ? 4 : SuperBarPanelStyle.radius, border: icon == .consumption ? nil : SuperBarPanelStyle.yellow.opacity(selected ? 0.85 : 0.5))
    }
}

// The Mac wraps this label in its pinning button; iPhone/widgets wrap it in a tile.
struct PanelEnergyContent: View {
    var title: String
    var value: String
    var icon: EnergyTileIcon
    var emphasized = false
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: icon.rawValue).font(.system(size: compact ? 22 : 28))
                .frame(width: compact ? 23 : 29)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Text(value).font(.system(size: compact ? 18 : 20, weight: emphasized ? .bold : .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(icon == .consumption ? SuperBarPanelStyle.cyan : SuperBarPanelStyle.yellow)
            .frame(minHeight: compact ? 34 : 42)
    }
}

struct ClimateDeviceItem: Identifiable {
    let id: ClimateDeviceID
    let name: String
    let room: String
    let target: String
    let power: Bool?
    var online: Bool? = nil
    var indicators = ClimateIndicators()
    var pinnedInMenuBar = false
    var windowUnit: Bool { if case .lg = id { return true }; return false }
}

struct ClimateSummaryCard: View {
    let device: ClimateDeviceItem
    let selected: Bool
    var compact = false
    private var target: String { device.online == false ? "Offline" : device.power == true && !device.target.isEmpty ? device.target : device.power == false ? "OFF" : "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            HStack(spacing: 4) {
                ClimateHousing(windowUnit: device.windowUnit)
                    .frame(width: compact ? 17 : 21, height: compact ? 14 : 17)
                Text(DeviceDisplayName.clean(device.name)).font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                ClimateIndicatorRow(indicators: device.indicators, size: compact ? 12 : 15)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if device.online != false {
                    ViewThatFits(in: .horizontal) {
                        Text("Room " + device.room)
                        Text(device.room)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if device.online == false {
                        Text("Offline").font(.system(size: 12, weight: .semibold))
                    } else if let on = device.power {
                        Circle().fill(on ? Color(red: 0.16, green: 1, blue: 0.36) : .gray)
                            .frame(width: on ? 7 : 5, height: on ? 7 : 5)
                        if on {
                            Text(target).font(.system(size: compact ? 13 : 19, weight: .semibold))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        } else {
                            Text("Off").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }.foregroundStyle(.white)
            .deviceSummarySurface(selected: selected, compact: compact, border: device.pinnedInMenuBar ? Color(white: 0.70) : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(device.indicators.label)
            .accessibilityLabel("\(DeviceDisplayName.clean(device.name)), \(device.windowUnit ? "Window air conditioner" : "Wall-mounted air conditioner"), \(device.online != false ? "Room " + device.room + ", " : "")\(device.online != false && device.power == true ? "Set temperature " + target : target)")
    }
}
