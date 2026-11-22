import AppKit
import SwiftUI

struct ClimatePanel: View {
    @ObservedObject var store: ClimateStore
    @ObservedObject var history: EnergyHistory
    @ObservedObject var preferences: ReadoutPreferences
    @ObservedObject var selection: BarSelection
    @ObservedObject private var age = ReadingAge.shared
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var showSignIn = false
    @State private var loginError: String?
    var body: some View {
        VStack(spacing: 2) {
            if store.needsSignIn {
                DeviceChoice(action: { showSignIn.toggle() }) { Text("Sign in to TCL Home").font(.system(size: 12)) }
                if showSignIn {
                VStack {
                    Card {
                        SectionName("Sign in to TCL Home", "person.crop.circle")
                        TextField("Email", text: $email).textContentType(.username)
                        SecureField("Password", text: $password).textContentType(.password)
                        if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Spacer()
                            Button(signingIn ? "Signing in…" : "Sign in") {
                                signingIn = true
                                loginError = nil
                                store.signIn(email: email, password: password) { error in
                                    signingIn = false
                                    loginError = error
                                    if error == nil { password = "" }
                                }
                            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                             .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        }
                    }.textFieldStyle(.roundedBorder).disabled(signingIn)
                }
                }
            } else if !store.devices.isEmpty {
                if selection.expanded == .tcl && !selection.detailsCollapsed, let device = store.selected {
                    deviceCard(device)
                }
            } else {
                VStack(spacing:8) {
                    Image(systemName:"air.conditioner.horizontal").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.refreshing ? "Loading air conditioners…" : (store.didRead ? "No air conditioners found" : "No TCL readings yet"))
                }.frame(maxWidth:.infinity).padding(16)
            }
        }
        .tint(cobalt)
        .background(Color.clear)
        .environment(\.locale, Locale(identifier: "en_US"))
        .onDisappear { password = "" }
    }
    @ViewBuilder var charts: some View {
        if let ac = store.selected {
            Text(DeviceDisplayName.clean(ac.name)).font(.caption).foregroundStyle(.secondary)
            EnergyChartView(history: history, device: ac.id)
        }
    }
    private func deviceCard(_ ac: Aircon) -> some View {
        let pins = preferences.ordered(ac.id)
        let displayed = selection.current == .tcl && preferences.device(in: store)?.id == ac.id
        return TCLDeviceDetails(store: store, ac: ac,
            pinnedFields: displayed ? Set(pins.map(\.rawValue)) : []) { id in
                guard let field = ReadoutField(rawValue: id) else { return }
                preferences.set(field, for: ac.id, visible: !(displayed && pins.contains(field)))
            }
    }
}
