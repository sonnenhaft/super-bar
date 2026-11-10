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
                        controls(ac).id(ac.id)
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
        let energy = history.barEnergy(for: ac.name)?.text
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
            }, reading: store.refreshing, readAt: store.statusDate, refresh: store.manualRefresh, select: { if !active { store.select(ac) } }) {
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
        Card {
            SectionName("Controls", "dial.medium")
            HStack(spacing: 8) {
                presetButton(.quiet, for: ac, title: "22° · Quiet", icon: "speaker.wave.1.fill")
                presetButton(.turbo, for: ac, title: "16° · Turbo", icon: "bolt.fill")
            }
            modePicker(ac)

        }
        Card {
            SectionName("Air direction", "wind")
            vane(ac, true)
            Divider()
            vane(ac, false)
        }
    }
    private func presetButton(_ preset: CoolingPreset, for ac: Aircon, title: String, icon: String) -> some View {
        let selected = preset.isSelected(on: ac)
        return Button {
            store.preset(ac, preset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(cobalt)
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(cobalt) }
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(preset.fields(for: ac) == nil)
        .help(preset.details(for: ac))
    }
    private func modePicker(_ ac: Aircon) -> some View {
        let cooling = ac.modeName == "Cool"
        return HStack {
            Text("Mode").font(.system(size: 12))
            Spacer()
            Menu {
                Button { store.cooling(ac, eco: false) } label: {
                    Label("Cool", systemImage: "snowflake")
                }
                Button { store.cooling(ac, eco: true) } label: {
                    Label("Eco", systemImage: "leaf.fill")
                }.disabled(!ac.has("ECO"))
            } label: {
                if cooling {
                    Label("Cool", systemImage: "snowflake")
                } else {
                    Text(ac.modeName)
                }
            }.fixedSize().controlSize(.small).disabled(!ac.has("workMode"))
        }
    }
    @ViewBuilder private func vane(_ ac: Aircon, _ vertical: Bool) -> some View {
        let prefix = vertical ? "vertical" : "horizontal"
        let field = prefix + "Direction", toggle = prefix + "Switch"
        let label = vertical ? "Vertical" : "Horizontal"
        let stops = vertical ? verticalStops : horizontalStops
        if ac.has(field) {
            let direction = ac.code(field)
            let motor = ac.code(toggle)
            let ranges = vertical ? ["Full", "Upper", "Lower"] : ["Full", "Left", "Center", "Right"]
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(ac.vane(vertical)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<5) { i in
                    vaneButton(stops[i], hint: stops[i], selected: direction == i+9, icon: "TCL-" + prefix + "-" + String(i+9)) {
                        store.set(ac, field, i+9, label)
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                    .font(.caption).frame(width: 14).foregroundStyle(.secondary).help("Swing")
                vaneButton("Stop", hint: "Stop swing", selected: motor == 0 || direction == 8) {
                    store.set(ac, field, 8, label)
                }
                ForEach(Array(ranges.enumerated()), id: \.offset) { i, text in
                    vaneButton(text, hint: "Swing · " + text, selected: direction == i+1 && motor != 0, icon: "TCL-" + prefix + "-" + String(i+1)) {
                        store.set(ac, field, i+1, label)
                    }
                }
            }
        } else if ac.has(toggle) {
            HStack(spacing: 5) {
                Text(label).font(.caption)
                vaneButton("Stop", hint: "Stop swing", selected: ac.code(toggle) == 0) { store.set(ac, toggle, 0, label) }
                vaneButton("Swing", hint: label, selected: ac.code(toggle) == 1) { store.set(ac, toggle, 1, label) }
            }
        } else {
            HStack { Text(label); Spacer(); Text("No data").foregroundStyle(.secondary) }.font(.caption)
        }
    }
    private func vaneButton(_ title: String, hint: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24)
                } else { Text(verbatim: title) }
            }.font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 23)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? cobalt : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(hint).accessibilityLabel(hint)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
