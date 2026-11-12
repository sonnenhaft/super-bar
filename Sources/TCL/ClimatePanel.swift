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
    @State private var horizontalPicker = false
    @State private var verticalPicker = false
    var body: some View {
        VStack(spacing: 2) {
            if store.needsSignIn {
                DeviceSelector(brand: .tcl) {
                    DeviceChoice(action: { showSignIn.toggle() }) { Text("Sign in to TCL Home").font(.system(size: 12)) }
                }
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
                DeviceSelector(brand: .tcl) {
                    ForEach(store.devices) { device in
                        deviceCard(device, active: selection.expanded == .tcl && device.id == store.selected?.id, summary: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                if selection.expanded == .tcl && !selection.detailsCollapsed, let device = store.selected {
                    deviceCard(device, active: true).padding(.leading, PanelLayout.logoColumn)
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
            Text(DeviceDisplayName.clean(ac.name) + " · TCL").font(.caption).foregroundStyle(.secondary)
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
                          fan: ac.has(ac.fanField) ? ac.fan : "") {
                    Button("Auto") { store.autoFan(ac, enabled: true) }
                    ForEach(ac.manualFanCodes, id: \.self) { level in
                        Button(ac.fanLabel(level)) { store.setFan(ac, level: level) }
                    }
                }.disabled(store.offline || ac.online != true || ac.failed)
            }
    }
    @ViewBuilder private func controls(_ ac: Aircon) -> some View {
        CoolingPresetRow(enabled: { $0.fields(for: ac) != nil }, selected: { $0.isSelected(on: ac) },
                         apply: { store.preset(ac, $0) })
    }

    private func vane(_ ac: Aircon, _ vertical: Bool) -> some View {
        let axis = vertical ? "vertical" : "horizontal"
        let direction = axis + "Direction", motor = axis + "Switch"
        let title = vertical ? "Vertical" : "Horizontal"
        let hasDirection = ac.has(direction)
        let stops = vertical ? verticalStops : horizontalStops
        let swings = vertical ? ["Up and down", "Upper zone", "Lower zone"] : ["Left to right", "Left zone", "Center zone", "Right zone"]
        let code = ac.code(direction)
        let stopped = ac.code(motor) == 0
        let selected = hasDirection ? (stopped && !(9...13).contains(code ?? -1) ? 8 : code) : ac.code(motor)
        let value = selected == (hasDirection ? 8 : 0) ? "Stopped" : ac.vane(vertical)
        return Group {
            if ac.power != false, hasDirection, let selected,
               TCLAirflowArtwork.image("TCL-" + axis + "-" + String(selected)) != nil {
            HStack(spacing:0) {
            Button { if vertical { verticalPicker.toggle() } else { horizontalPicker.toggle() } } label: {
                HStack(spacing:1) {
                    if let image = TCLAirflowArtwork.image("TCL-" + axis + "-" + String(selected)) {
                        Image(nsImage:image).renderingMode(.template).resizable().scaledToFit().frame(width:28,height:28)
                    }
                    Image(systemName:"chevron.down").font(.system(size:7,weight:.semibold))
                }.foregroundStyle(.white).frame(width: 50, height: 34).deviceSurface(selected: false).contentShape(Rectangle())
            }.buttonStyle(.plain).help(title + ": " + value)
                .popover(isPresented: Binding(get:{vertical ? verticalPicker : horizontalPicker},set:{if vertical { verticalPicker = $0 } else { horizontalPicker = $0 }}), arrowEdge: .bottom) {
                    let options = hasDirection ? Array(9...13) + Array(1...(vertical ? 3 : 4)) + [8] : [1, 0]
                    VStack(spacing: 8) {
                        ForEach(0..<2) { row in
                            HStack(spacing: 8) {
                                let split = (options.count + 1) / 2
                                ForEach(Array(options.dropFirst(row * split).prefix(split)), id: \.self) { option in
                                    let label = option == (hasDirection ? 8 : 0) ? "Stop" :
                                        ((9...13).contains(option) ? stops[option - 9] :
                                        (swings.indices.contains(option - 1) ? swings[option - 1] : "Swing"))
                                    Button {
                                        store.set(ac, hasDirection ? direction : motor, option, title)
                                        if vertical { verticalPicker = false } else { horizontalPicker = false }
                                    } label: {
                                        ZStack(alignment: .topTrailing) {
                                            airflowIcon(axis:axis, option:option)
                                                .frame(width:32,height:32).padding(8)
                                            if selected == option {
                                                Image(systemName:"checkmark.circle.fill").foregroundStyle(.white, cobalt).font(.system(size:13))
                                            }
                                        }.background(selected == option ? cobalt.opacity(0.7) : Color(nsColor:BarTheme.panel),
                                                     in: RoundedRectangle(cornerRadius:4))
                                            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(selected == option ? Color.white : .clear, lineWidth:1.5))
                                    }.buttonStyle(.plain).help(label).accessibilityLabel(label)
                                        .accessibilityAddTraits(selected == option ? .isSelected : [])
                                }
                            }
                        }
                    }.padding(12).foregroundStyle(ice).background(Color(nsColor:BarTheme.background))
                }
        }.disabled(!hasDirection && !ac.has(motor))
            .accessibilityLabel(title + " air direction").accessibilityValue(value)
            .help(title + ": " + value)
            }
        }
    }

    @ViewBuilder private func airflowIcon(axis:String, option:Int) -> some View {
        let name = "TCL-\(axis)-\(option)"
        if let image = TCLAirflowArtwork.image(name) {
            Image(nsImage:image).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName:"stop.circle").resizable().scaledToFit()
        }
    }

}
