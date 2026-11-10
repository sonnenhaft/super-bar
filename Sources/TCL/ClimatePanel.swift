import AppKit
import SwiftUI

struct ClimatePanel: View {
    @ObservedObject var store: ClimateStore
    @ObservedObject var history: EnergyHistory
    @ObservedObject var preferences: ReadoutPreferences
    let height: CGFloat
    @State private var energyExpanded = false
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var loginError: String?
    @State private var showingSettings = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.needsSignIn && !showingSettings {
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
            } else if showingSettings {
                ScrollView {
                    ReadoutSettings(preferences: preferences, id: store.selected?.id ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }.frame(maxHeight: .infinity)
            } else if let ac = store.selected {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        SectionName("Air conditioners", "air.conditioner.horizontal")
                        ForEach(store.devices) { device in deviceCard(device, active: device.id == ac.id) }
                        controls(ac)
                            .disabled(ac.online != true || ac.failed)
                        Card {
                            DisclosureGroup(isExpanded: $energyExpanded) {
                                if energyExpanded { EnergyChartView(history: history, device: ac.name) }
                            } label: { SectionName("Energy history", "chart.xyaxis.line") }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 7)
                }
            } else {
                Spacer()
                Image(systemName: "air.conditioner.horizontal").font(.largeTitle).foregroundStyle(.secondary)
                Text(store.refreshing ? "Loading air conditioners…" : (store.didRead ? "No air conditioners found" : "No TCL readings yet"))
                    .padding(.top, 5)
                Spacer()
            }
            if !showingSettings && !store.needsSignIn {
                Divider()
                footer
            }
        }
        .frame(width: 390, height: height)
        .tint(cobalt)
        .background(Color(nsColor: BarTheme.background))
        .environment(\.locale, Locale(identifier: "en_US"))
        .onDisappear { password = "" }
    }
    private var header: some View {
        HStack(spacing: 9) {
            if showingSettings {
                Button { showingSettings = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back to devices").accessibilityLabel("Back to devices")
            }
            TCLLogo().frame(width: 41, height: 17)
            Text(showingSettings ? "Menu bar" : "Climate").font(.system(size: 17, weight: .semibold))
            Spacer()
            if !showingSettings {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).keyboardShortcut(",")
                    .help("Menu bar settings").accessibilityLabel("Menu bar settings")
            }
            Menu {
                Text("Super Bar " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                Button("Refresh readings") { store.manualRefresh() }
            } label: { Image(systemName: "ellipsis.circle") }
                .fixedSize().menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("App menu")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    private func deviceCard(_ ac: Aircon, active: Bool) -> some View {
        let pins = preferences.ordered(ac.id)
        let energy = history.cardEnergy[ac.name]
        let choices: [(ReadoutField, String, String)] = [
            (.target, "AC", ac.acTemperature), (.indoor, "Room", tempText(ac.indoor)),
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
            }, reading: store.refreshing, readAt: store.statusDate, refresh: store.manualRefresh, select: { if !active { store.select(ac) } },
            directions: AnyView(HStack(spacing: 5) {
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
        func option(_ label: String, _ value: Int, icon: Bool = true) -> some View {
            Button {
                store.set(ac, hasDirection ? direction : motor, value, title)
            } label: {
                if icon, let image = TCLAirflowArtwork.image("TCL-" + axis + "-" + String(value)) {
                    Label { Text(label) } icon: { Image(nsImage: image).renderingMode(.template) }
                } else { Text(label) }
            }
        }
        return Menu {
                if hasDirection {
                    ForEach(stops.indices, id: \.self) { i in option(stops[i], i + 9) }
                    Divider()
                    ForEach(swings.indices, id: \.self) { i in option(swings[i], i + 1) }
                    option("Stop", 8, icon: false)
                } else {
                    option("Swing", 1, icon: false)
                    option("Stop", 0, icon: false)
                }
            } label: {
                HStack(spacing: 4) {
                    if hasDirection, let selected, let image = TCLAirflowArtwork.image("TCL-" + axis + "-" + String(selected)) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 12, height: 12)
                    }
                    Text(title).fontWeight(.medium)
                    Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 10)).padding(.horizontal, 6)
                .frame(maxWidth: .infinity).frame(height: 22)
                .foregroundStyle(.white)
        .background(Color(nsColor: BarTheme.navy), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cobalt.opacity(0.65), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.mini)
            .disabled(!hasDirection && !ac.has(motor))
            .accessibilityLabel(title + " air direction").accessibilityValue(value)
            .help(title + ": " + value)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Circle().fill(store.offline ? Color.secondary : .green).frame(width: 5, height: 5)
                if let pending = store.command {
                    Text(verbatim: pending)
                } else if let when = store.statusDate {
                    Text((store.offline ? "Saved: " : "Updated: ") + when.formatted(date: Calendar.current.isDateInToday(when) ? .omitted : .abbreviated, time: .standard))
                } else {
                    Text("Waiting for TCL")
                }
                Spacer()
                Text("TCL Home")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}
