import AppKit
import SwiftUI

struct ClimatePanel: View {
    @ObservedObject var store: ClimateStore
    @ObservedObject var history: EnergyHistory
    @ObservedObject var preferences: ReadoutPreferences
    @ObservedObject var selection: BarSelection
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
                    deviceCard(device, active: true)
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
            EnergyChartView(history: history, device: ac.name)
        }
    }
    private func deviceCard(_ ac: Aircon, active: Bool, summary: Bool = false) -> some View {
        let pins = preferences.ordered(ac.id)
        let energy = history.cardEnergy[ac.name]
        let choices: [(ReadoutField, String, String)] = [
            (.target, "AC", tempText(ac.target)), (.indoor, "Room", tempText(ac.indoor)),
            (.fan, "Fan", ac.fan), (.energy, "Energy", energy ?? "—"),
            (.eco, "Eco", ac.code("ECO") == 1 ? "ON" : "OFF")
        ]
        let displayed = selection.current == .tcl && preferences.device(in: store)?.id == ac.id
        return ClimateDeviceCard(brand: .tcl, name: ac.name, selected: active, status: store.offline ? "Offline" : ac.status,
            metrics: choices.map { field, label, value in
                let visible = pins.contains(field)
                return DeviceMetric(id: field.rawValue, label: label, symbol: field.symbol, value: value,
                    visible: displayed && visible) {
                    preferences.set(field, for: ac.id, visible: !displayed || !visible)
                }
            }, reading: store.refreshing, readAt: store.statusDate, refresh: store.manualRefresh, select: { store.select(ac); selection.activate(.tcl) }, powerOn: store.offline || ac.online != true || ac.failed ? nil : ac.power,
            temperatureOptions:ac.setpoints.filter { (16...26).contains($0) },
            changeTemperature:{ store.setTemperature(ac,$0) },
            turnOff:ac.power == nil ? nil : { store.set(ac,"powerSwitch",0,"Power") },
            message: store.problem ?? store.command,
            presets: AnyView(controls(ac).disabled(store.offline || ac.online != true || ac.failed)),
            directions: AnyView(HStack(spacing: 8) {
                vane(ac, true)
                vane(ac, false)
            }.disabled(store.offline || ac.online != true || ac.failed)), summaryOnly: summary) {
                CardMenus(eco: ac.ecoChanges != nil ? ac.code("ECO") == 1 : nil, toggleEco: { store.toggleEco(ac) },
                          fan: "", fanControl: ac.has(ac.fanField) ? AnyView(
                            PanelFanSpeedPicker(options: ac.fanSpeedOptions, selected: ac.selectedFanOption,
                                currentSymbol: ac.currentFanSymbol, currentName: ac.fan) { level in
                                if level == 0 { store.autoFan(ac, enabled: true) }
                                else { store.setFan(ac, level: level) }
                            }) : nil) { EmptyView() }
                    .disabled(store.offline || ac.online != true || ac.failed)
            }
    }
    @ViewBuilder private func controls(_ ac: Aircon) -> some View {
        CoolingPresetRow<TCLCoolingPreset>(label: { "\($0.degrees)°" }, enabled: { $0.fields(for: ac) != nil }, selected: { $0.isSelected(on: ac) },
                         apply: { store.preset(ac, $0) }, icon: { $0.fanSymbol }, accessibilityName: { $0.label })
    }

    @ViewBuilder private func vane(_ ac: Aircon, _ vertical: Bool) -> some View {
        let axis = vertical ? "vertical" : "horizontal"
        if ac.power != false, ac.has(axis + "Direction") || ac.has(axis + "Switch") {
            TCLAirflowPicker(ac: ac, vertical: vertical) { field, value in
                store.set(ac, field, value, "Air direction")
            }
        }
    }
}
