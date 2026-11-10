import AppKit
import SwiftUI

struct ClimatePanel: View {
    @ObservedObject var store: ClimateStore
    @ObservedObject var history: EnergyHistory
    @ObservedObject var preferences: ReadoutPreferences
    var contentHeight: (CGFloat) -> Void = { _ in }
    @ObservedObject private var order = CardOrder.shared
    let height: CGFloat
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var loginError: String?
    @State private var horizontalPicker = false
    @State private var verticalPicker = false
    var body: some View {
        VStack(spacing: 0) {
            if store.needsSignIn {
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
                    Spacer()
                }.padding(14)
            } else if let ac = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(order.sorted(store.devices,group:Brand.tcl.rawValue,id:{$0.id})) { device in deviceCard(device, active: device.id == ac.id) }
                        controls(ac)
                            .disabled(ac.online != true || ac.failed)
                        if history.report(for:ac.name)?.days.isEmpty == false || !history.watts(for:ac.name).isEmpty {
                            Card { EnergyChartView(history:history,device:ac.name) }
                        }
                    }.padding(8).reportContentHeight { contentHeight($0 + ((store.problem != nil || store.command != nil) ? 38 : 0)) }
                }
            } else {
                VStack(spacing:8) {
                    Image(systemName:"air.conditioner.horizontal").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.refreshing ? "Loading air conditioners…" : (store.didRead ? "No air conditioners found" : "No TCL readings yet"))
                }.frame(maxWidth:.infinity).padding(16).reportContentHeight(contentHeight)
            }
            if !store.needsSignIn && (store.problem != nil || store.command != nil) {
                footer
            }
        }
        .frame(width: 390).frame(maxHeight: .infinity)
        .tint(cobalt)
        .background(Color.clear)
        .environment(\.locale, Locale(identifier: "en_US"))
        .onDisappear { password = "" }
    }
    private func deviceCard(_ ac: Aircon, active: Bool) -> some View {
        let pins = preferences.ordered(ac.id)
        let energy = history.cardEnergy[ac.name]
        let choices: [(ReadoutField, String, String)] = [
            (.target, "AC", tempText(ac.target)), (.indoor, "Room", tempText(ac.indoor)),
            (.fan, "Fan", ac.fan), (.energy, "Energy", energy ?? "—")
        ]
        let displayed = preferences.device(in: store)?.id == ac.id
        return ClimateDeviceCard(brand: .tcl, iconVisible: displayed && pins.contains(.icon), toggleIcon: {
            if !active { store.select(ac) }
            preferences.set(.icon, for: ac.id, visible: !displayed || !pins.contains(.icon))
        }, name: ac.name, selected: active, status: store.offline ? "Offline" : ac.status,
            metrics: choices.map { field, label, value in
                let visible = pins.contains(field)
                return DeviceMetric(id: field.rawValue, label: label, symbol: field.symbol, value: value,
                    visible: displayed && visible) {
                    if !active { store.select(ac) }
                    preferences.set(field, for: ac.id, visible: !displayed || !visible)
                }
            }, reading: store.refreshing, readAt: store.statusDate, refresh: store.manualRefresh, select: { if !active { store.select(ac) } }, powerOn:ac.power,
            temperatureOptions:ac.setpoints.filter { (16...26).contains($0) },
            changeTemperature:{ store.setTemperature(ac,$0) },
            turnOff:ac.power == nil ? nil : { store.set(ac,"powerSwitch",0,"Power") },
            reorderID:ac.id, knownIDs:store.devices.map(\.id),
            directions: AnyView(HStack(spacing: 8) {
                vane(ac, true)
                vane(ac, false)
            }.disabled(store.offline || ac.online != true || ac.failed))) {
                CardMenus(degrees: ac.setpoints.filter { (16...26).contains($0) && ac.target != nil },
                          target: ac.acTemperature, off: ac.power == nil ? nil : { store.set(ac, "powerSwitch", 0, "Power") }, eco: ac.has("ECO") ? ac.code("ECO") == 1 : nil, toggleEco: { store.set(ac, "ECO", ac.code("ECO") == 1 ? 0 : 1, "Eco") },
                          change: { store.setTemperature(ac, $0) },
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
                }.foregroundStyle(ice).contentShape(Rectangle())
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if let pending = store.command {
                Text(verbatim: pending).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}
