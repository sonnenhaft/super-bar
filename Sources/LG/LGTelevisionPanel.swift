import SwiftUI
#if os(iOS)
import WidgetKit
#endif

/// Both app shells use the same local TV connection and selection lifecycle.
struct LGTelevisionPanel: View {
    let accounts: [LGAccountTelevision]
    let expanded: Bool
    let open: () -> Void
    let showSummaries: Bool
    @StateObject private var store: LGTelevisionStore

    init(accounts: [LGAccountTelevision], expanded: Bool, open: @escaping () -> Void,
         store: LGTelevisionStore? = nil, showSummaries: Bool = true) {
        self.accounts = accounts; self.expanded = expanded; self.open = open
        self.showSummaries = showSummaries
        _store = StateObject(wrappedValue: store ?? LGTelevisionStore())
    }
    @Environment(\.scenePhase) private var phase
    @State private var scanRevision = 0
    @State private var editor: Editor?

    private struct Editor {
        var id: String?
        var name = ""
        var host = ""
        var mac = ""
        var endpoint: WebOSTVEndpoint?
        var error: String?
    }

    private struct ConnectionKey: Equatable {
        let id: String
        let host: String
        let pairingID: String?
        init(_ link: TelevisionLink) { id = link.id; host = link.host; pairingID = link.pairingID }
    }

    private struct ScanKey: Equatable {
        let active: Bool
        let revision: Int
    }

    private var visible: Bool {
        #if os(iOS)
        expanded && phase != .background
        #else
        expanded
        #endif
    }

    var body: some View {
        let devices = store.items(accounts)
        let selected = devices.first { $0.id == store.selectedID } ?? devices.first
        VStack(alignment: .leading, spacing: 6) {
            TelevisionSection(devices: devices, selectedID: selected?.id, expanded: expanded, showSummaries: showSummaries) { id in
                store.select(id)
                editor = nil
                if !expanded { open() }
            } send: { id, action in
                if action == .configure {
                    if editor?.id == id { editor = nil; return }
                    edit(id: id, name: devices.first { $0.id == id }?.name ?? "LG TV")
                } else {
                    store.send(action, id: id, accountMAC: account(id)?.macAddress)
                }
            }
            if expanded {
                if let id = store.pinTV, selected?.id == id {
                    TelevisionPairingForm(submitting: store.submittingPIN) { code in
                        Task { await store.submitPIN(code, id: id) }
                    } cancel: { store.cancelPIN(id: id) }
                    .id(id)
                }
                if let draft = editor { connectionEditor(draft) }
                if editor != nil || devices.isEmpty {
                    HStack(spacing: 14) {
                        Button { scanRevision &+= 1 } label: {
                            HStack(spacing: 5) {
                                RefreshGlyph(isRefreshing: store.scanning, size: 12)
                                Text(store.scanning ? "Finding TVs…" : "Find LG TVs")
                            }
                        }.disabled(store.scanning)
                        Button { edit(id: nil, name: "") } label: { Label("Add by IP", systemImage: "plus") }
                    }.panelButtonStyle().font(.caption)
                    if let message = store.scanMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    } else if devices.isEmpty && !store.scanning && editor == nil {
                        Text("To pair, turn on your LG TV and connect it to the same network.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: devices, initial: true) { _, devices in
            #if os(iOS)
            store.publishWidgetReadings(accounts)
            #endif
        }
        .onChange(of: selected?.id) { _, _ in editor = nil }
        .onChange(of: expanded) { _, value in if !value { editor = nil } }
        .onDisappear { store.close() }
        .onChange(of: accounts) { _, new in store.reconcile(new) }
        .onChange(of: store.nearby) { _, _ in store.reconcile(accounts) }
        .task(id: ScanKey(active: visible, revision: scanRevision)) {
            guard visible else { return }
            await store.scanWhileVisible()
        }
        .task(id: visible ? selected.flatMap { store.links[$0.id] }.map(ConnectionKey.init) : nil) {
            await store.watch(visible ? selected.flatMap { store.links[$0.id] } : nil)
        }
    }

    private func account(_ id: String) -> LGAccountTelevision? {
        accounts.first { LGTelevisionStore.accountID($0) == id }
    }

    private func edit(id: String?, name: String) {
        let link = id.flatMap { store.links[$0] }
        let mac = id.flatMap { account($0)?.macAddress }
        editor = Editor(id: id, name: name, host: link?.host ?? "", mac: link?.mac ?? mac ?? "")
    }

    private func field(_ path: WritableKeyPath<Editor, String>) -> Binding<String> {
        Binding(get: { editor?[keyPath: path] ?? "" }, set: { value in
            editor?[keyPath: path] = value
            if path == \Editor.host { editor?.endpoint = nil }
            editor?.error = nil
        })
    }

    @ViewBuilder private func connectionEditor(_ draft: Editor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = draft.id {
                HStack {
                    Button(store.connected ? "Pair again" : "Pair TV") { store.send(.pair, id: id, accountMAC: nil) }
                    Button("Refresh controls") { store.send(.refreshFeatures, id: id, accountMAC: nil) }.disabled(!store.connected)
                    Button("Unpair", role: .destructive) { store.send(.unpair, id: id, accountMAC: nil) }
                }.font(.caption).disabled(store.busy)
                if let message = store.featureMessage { Text(message).font(.caption) }
            }
            if !store.nearby.isEmpty {
                Menu("Choose a nearby LG TV") {
                    ForEach(store.nearby, id: \.id) { endpoint in
                        Button(endpoint.name + " · " + endpoint.host) {
                            editor?.endpoint = endpoint
                            editor?.host = endpoint.host
                            if draft.host != endpoint.host { editor?.mac = "" }
                            if editor?.mac.isEmpty == true, let mac = endpoint.macAddress { editor?.mac = mac }
                            if draft.name.isEmpty { editor?.name = endpoint.name }
                            editor?.error = nil
                        }
                    }
                }
            }
            if draft.id == nil {
                TextField("TV name", text: field(\.name))
            }
            TextField("TV’s local IPv4 address", text: field(\.host))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            if let id = draft.id, let addresses = store.links[id]?.networkMACs, !addresses.isEmpty {
                Text("Saved TV network MAC: " + addresses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            TextField("TV network MAC from router (for power on)", text: field(\.mac))
                #if os(iOS)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                #endif
            Text("Power on uses the saved network MAC. Enable Mobile TV On / Turn on via Wi-Fi on the TV and keep both devices on the same network.")
                .font(.caption).foregroundStyle(.secondary)
            if let id = draft.id, let diagnostic = store.wakeDiagnostics[id] {
                Text("Last power-on attempt: " + diagnostic).font(.caption).foregroundStyle(.secondary)
            }
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Save") {
                    if let error = store.configure(id: draft.id, name: draft.name, host: draft.host, mac: draft.mac,
                                                   endpoint: draft.endpoint, accounts: accounts) {
                        editor?.error = error
                    } else { editor = nil }
                }
                Button("Cancel") { editor = nil }
            }
        }.textFieldStyle(.roundedBorder).panelHistorySurface()
    }
}
