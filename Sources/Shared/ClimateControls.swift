import SwiftUI

/// Press feedback lasts for the gesture. The device model owns the selection
/// after release, including its pending command and subsequent readback.
private struct ClimateSelectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let selected: Bool
    var radius: CGFloat = SuperBarPanelStyle.radius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .deviceSurface(selected: selected || configuration.isPressed, radius: radius)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
            .panelPointer()
    }
}

private struct TemperatureStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SuperBarPanelStyle.selected : .white.opacity(0.04), in: Circle())
            .overlay(Circle().strokeBorder(configuration.isPressed ? SuperBarPanelStyle.outline : .white.opacity(0.3),
                                          lineWidth: configuration.isPressed ? 1 : 0.5))
            .opacity(enabled ? 1 : 0.5)
            .panelPointer()
    }
}

extension Aircon {
    var indicators: ClimateIndicators {
        guard power == true, online == true, !failed else { return ClimateIndicators() }
        return ClimateIndicators(eco: ecoEnabled, tcl: currentFanSymbol)
    }
}

extension LGSample {
    var indicators: ClimateIndicators {
        guard powerOn == true, online != false else { return ClimateIndicators() }
        return ClimateIndicators(eco: eco == true, lgSpeed: fan)
    }
}

extension ClimateStore {
    func reportedIndicators(for id: String) -> ClimateIndicators {
        guard !offline, let device = reportedDevice(id: id) else { return ClimateIndicators() }
        return device.indicators
    }
}

@MainActor struct LGEnergyCharts: View {
    let id: String
    let api: API
    @ObservedObject private var cloud: LGCloudHistory
    @ObservedObject private var local = DevicePowerHistory.lg

    init(id: String, api: API) {
        self.id = id
        self.api = api
        self.cloud = api.history
    }

    var body: some View {
        let readings = cloud.devices[id] ?? LGCloudHistory.Series()
        // EnergyCharts selects the last entry for a given date. A provider day
        // supersedes the local estimate while leaving other local days intact.
        EnergyCharts(days: (local.days[id] ?? []) + readings.days.values,
                     power: local.power[id] ?? [],
                     powerIntervals: readings.hours.values.sorted { $0.start < $1.start })
            .task(id: id) {
                guard !id.isEmpty, !AccountConnection.signedOut("lg") else { return }
                while !Task.isCancelled {
                    await cloud.refresh(id) { try await api.energyHistory(id, $0) }
                    do { try await Task.sleep(nanoseconds: UInt64(HistoryPolling.recent * 1e9)) } catch { break }
                }
            }
        if readings.hasUnspecifiedUnit {
            Text("LG omitted the energy unit for some readings.").font(.caption2).foregroundStyle(.secondary)
        }
        if readings.days.isEmpty && readings.hours.isEmpty {
            if !(local.power[id] ?? []).isEmpty || !(local.days[id] ?? []).isEmpty {
                Text("Estimated from observed power; gaps excluded").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("LG energy history · local readings fill gaps").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// One TCL detail card for both platforms. Only the surrounding readings/history
// and the size of touch targets are platform-specific.
struct TCLClimateCard<Readings: View>: View {
    @ObservedObject var store: ClimateStore
    let ac: Aircon
    @ViewBuilder var readings: () -> Readings
    @ObservedObject private var age = ReadingAge.shared
    private var unavailable: Bool { store.offline || ac.online != true || ac.failed }
    private var sending: Bool { store.isPending(id: ac.id) }
    #if os(iOS)
    private let controlHeight: CGFloat = 44
    #else
    private let controlHeight: CGFloat = 34
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    identity.fixedSize(horizontal: true, vertical: false)
                    temperature
                    Spacer(minLength: 0)
                    headerActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { identity; Spacer(minLength: 0); headerActions }
                    temperature
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { fanAndEco; presets; airflow }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) { fanAndEco; Spacer(minLength: 4); airflow }
                    presets
                }
            }.frame(maxWidth: .infinity, alignment: .leading).disabled(unavailable)
            readings()
            Text(store.problem ?? (unavailable ? "Offline" : store.statusDate.map { ReadingAge.label($0) } ?? "No readings"))
                .font(.system(size: 10)).foregroundStyle(store.problem == nil ? Color.secondary : .orange)
                .lineLimit(1).frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .help(store.problem ?? "")
        }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            ClimateHousing(windowUnit: false).frame(width: 28, height: 20)
            Text(DeviceDisplayName.clean(ac.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
    }
    private var temperature: some View {
        PanelTemperatureControl(name: ac.name, targetValue: tempText(ac.target), powerOn: ac.power,
            temperatureOptions: ac.has("targetTemperature") ? ac.setpoints : [],
            changeTemperature: { store.setTemperature(ac, $0) }, compact: true,
            indicators: store.offline ? ClimateIndicators() : ac.indicators)
            .disabled(unavailable)
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button(action: store.manualRefresh) {
                RefreshGlyph(isRefreshing: store.isRefreshingReadings || sending, size: 14)
                    .frame(width: controlHeight, height: controlHeight).contentShape(Rectangle())
            }.panelButtonStyle().accessibilityLabel("Refresh readings")
                .accessibilityValue(sending ? "Applying setting" : store.isRefreshingReadings ? "Refreshing" : "")
            Button { store.set(ac, "powerSwitch", ac.power == true ? 0 : 1, "Power") } label: {
                Image(systemName: "power").font(.system(size: 20))
                    .frame(width: controlHeight, height: controlHeight)
            }.buttonStyle(ClimateSelectionButtonStyle(selected: ac.power == true))
                .accessibilityLabel(ac.power == true ? "Turn off" : "Turn on")
                .disabled(unavailable || !ac.has("powerSwitch") || ac.power == nil)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var fanPicker: some View {
        PanelFanSpeedPicker(options: ac.fanSpeedOptions, selected: ac.selectedFanOption,
            currentSymbol: ac.currentFanSymbol, currentName: ac.fan) { level in
            if level == 0 { store.autoFan(ac, enabled: true) }
            else { store.setFan(ac, level: level) }
        }
    }
    @ViewBuilder private var fanAndEco: some View {
        if ac.has(ac.fanField) { fanPicker }
        if ac.ecoChanges != nil {
            ClimateEcoButton(enabled: ac.ecoEnabled) { store.toggleEco(ac) }
        }
    }
    private var presets: some View {
        CoolingPresetRow<TCLCoolingPreset>(label: { "\($0.degrees)°" },
            enabled: { $0.fields(for: ac) != nil }, selected: { $0.isSelected(on: ac) },
            apply: { store.preset(ac, $0) }, icon: { $0.fanSymbol }, accessibilityName: { $0.label })
    }
    private var airflow: some View {
        HStack(spacing: 4) {
            ForEach([true, false], id: \.self) { vertical in
                let axis = vertical ? "vertical" : "horizontal"
                if ac.has(axis + "Direction") || ac.has(axis + "Switch") {
                    TCLAirflowPicker(ac: ac, vertical: vertical) { field, value in
                        store.set(ac, field, value, "Air direction")
                    }
                }
            }
        }
    }
}

// Identical control layout and setpoint stepping on Mac and iPhone.
struct PanelTemperatureControl: View {
    var name: String
    var targetValue: String
    var powerOn: Bool?
    var temperatureOptions: [Int]
    var changeTemperature: ((Int) -> Void)?
    var setPower: ((Bool) -> Void)? = nil
    var powerEnabled = true
    var compact = false
    var indicators = ClimateIndicators()
    var directions: AnyView? = nil
    var trailingControl: AnyView? = nil
    #if os(iOS)
    private let stepSize: CGFloat = 44
    private let stepHeight: CGFloat = 44
    #else
    private let stepSize: CGFloat = 30
    private let stepHeight: CGFloat = 34
    #endif
    private var targetDegrees: Double? {
        Double(targetValue.prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.replacingOccurrences(of: ",", with: "."))
    }
    private func adjacentTemperature(_ delta: Int) -> Int? {
        guard let targetDegrees else { return nil }
        return delta < 0 ? temperatureOptions.filter { Double($0) < targetDegrees }.max() : temperatureOptions.filter { Double($0) > targetDegrees }.min()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !compact { Text("Set temperature").font(.system(size: 11)).foregroundStyle(.secondary) }
            if compact {
                temperatureValue
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        temperatureValue
                        if let trailingControl { trailingControl }
                        Spacer(minLength: 2)
                        if let directions { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 32); directions.frame(width: 116) }
                        powerButton
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { temperatureValue; Spacer(minLength: 2); powerButton }
                        if let trailingControl { trailingControl }
                        if let directions { directions }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var temperatureValue: some View {
        HStack(spacing: compact ? 4 : 10) {
            if let changeTemperature {
                temperatureStep(-1, change: changeTemperature)
                HStack(spacing: 2) {
                    TemperaturePicker(value: targetValue, degrees: temperatureOptions, powerOn: powerOn,
                        setPower: powerEnabled ? setPower : nil, choose: changeTemperature, fontSize: compact ? 24 : 38)
                    ClimateIndicatorRow(indicators: indicators, size: 15, reservesSpace: true)
                }
                temperatureStep(1, change: changeTemperature)
            } else { Text(targetValue).font(.system(size: 28, weight: .semibold)) }
        }.fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private var powerButton: some View {
        if let setPower {
            Button { if let powerOn { setPower(!powerOn) } } label: {
                Image(systemName: "power").font(.system(size: 22))
                    .frame(width: max(38, stepSize), height: max(36, stepHeight)).contentShape(Rectangle())
            }.buttonStyle(ClimateSelectionButtonStyle(selected: powerOn == true))
                .foregroundStyle(powerOn == false ? Color.gray : .white)
                .help(powerOn == true ? "Turn off" : "Turn on")
                .accessibilityLabel((powerOn == true ? "Turn off " : "Turn on ") + DeviceDisplayName.clean(name))
                .disabled(powerOn == nil || !powerEnabled)
        }
    }
    private func temperatureStep(_ delta: Int, change: @escaping (Int) -> Void) -> some View {
        let next = adjacentTemperature(delta)
        return Button { if let next { change(next) } } label: {
            Image(systemName: delta < 0 ? "minus" : "plus").font(.system(size: 18, weight: .medium))
                .frame(width: stepSize, height: stepHeight).contentShape(Rectangle())
        }.buttonStyle(TemperatureStepButtonStyle()).disabled(next == nil)
            .accessibilityLabel(delta < 0 ? "Decrease set temperature" : "Increase set temperature")
    }
}

struct TemperaturePicker: View {
    let value:String
    let degrees:[Int]
    let powerOn: Bool?
    let setPower: ((Bool) -> Void)?
    let choose:(Int)->Void
    var fontSize: CGFloat = 15
    @State private var presented = false
    private var popoverEdge: Edge {
        #if os(iOS)
        return .top
        #else
        return .bottom
        #endif
    }
    var body: some View {
        Button { presented.toggle() } label: { Text(value).font(.system(size:fontSize,weight:.semibold)).monospacedDigit().frame(width: fontSize * 2.8) }
            .panelButtonStyle().help("Set temperature")
            .accessibilityLabel("Choose temperature, " + value)
            .disabled(degrees.isEmpty)
            .popover(isPresented:$presented,arrowEdge:popoverEdge) {
                let split = (degrees.count+1)/2
                VStack(spacing:6) {
                    ForEach(0..<split,id:\.self) { row in
                        HStack(spacing:8) {
                            ForEach(0..<2) { column in
                                let index = row + column * split
                                if degrees.indices.contains(index) {
                                    let degree = degrees[index]
                                    let selected = value.replacingOccurrences(of:"°",with:"").trimmingCharacters(in:.whitespaces) == String(degree)
                                    Button { choose(degree); presented = false } label: {
                                        Label { Text(String(degree)+" °C") } icon: { Image(systemName:"thermometer.medium") }
                                            .font(.system(size:14)).frame(width:92,height:32)
                                    }.buttonStyle(ClimateSelectionButtonStyle(selected: selected, radius: 4))
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                } else { Color.clear.frame(width:92,height:32) }
                            }
                        }
                    }
                    if let powerOn, let setPower {
                        Button { setPower(!powerOn); presented = false } label: {
                            Label(powerOn ? "Turn off" : "Turn on", systemImage: "power")
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }.panelButtonStyle()
                    }
                }.padding(10).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
}

struct FanSpeedOption: Identifiable {
    let id: Int
    let name: String
    let symbol: FanSpeedSymbol
}

struct PanelFanSpeedPicker: View {
    let options: [FanSpeedOption]
    let selected: Int?
    let currentSymbol: FanSpeedSymbol
    let currentName: String
    let choose: (Int) -> Void
    @State private var presented = false

    #if os(iOS)
    private let optionSize: CGFloat = 48
    private let buttonHeight: CGFloat = 44
    private let popoverEdge: Edge = .top
    #else
    private let optionSize: CGFloat = 36
    private let buttonHeight: CGFloat = 34
    private let popoverEdge: Edge = .bottom
    #endif

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                FanSpeedIcon(symbol: currentSymbol).frame(width: 25, height: 25)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .frame(width: 44, height: buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ClimateSelectionButtonStyle(selected: presented))
        .foregroundStyle(.white)
        .help("Fan: " + currentName)
        .accessibilityLabel("Set fan speed")
        .accessibilityValue(currentName)
        .disabled(options.isEmpty)
        .popover(isPresented: $presented, arrowEdge: popoverEdge) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(optionSize), spacing: 8), count: 4), spacing: 8) {
                ForEach(options) { option in
                    Button {
                        presented = false
                        choose(option.id)
                    } label: {
                        FanSpeedIcon(symbol: option.symbol)
                            .frame(width: 27, height: 27)
                            .frame(width: optionSize, height: optionSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ClimateSelectionButtonStyle(selected: selected == option.id))
                    .foregroundStyle(selected == option.id ? SuperBarPanelStyle.cyan : .white)
                    .help(option.name)
                    .accessibilityLabel(option.name)
                    .accessibilityAddTraits(selected == option.id ? .isSelected : [])
                }
            }
            .padding(10)
            .background(PanelPalette.background.color)
            #if os(iOS)
                .presentationCompactAdaptation(.popover)
            #endif
        }
    }
}

struct TCLAirflowPicker: View {
    let ac: Aircon
    let vertical: Bool
    let choose: (String, Int) -> Void
    @State private var presented = false
    private var axis: String { vertical ? "vertical" : "horizontal" }
    private var title: String { vertical ? "Vertical" : "Horizontal" }
    private var hasDirection: Bool { ac.has(axis + "Direction") }
    private var options: [Int] {
        hasDirection ? Array(9...13) + Array(1...(vertical ? 3 : 4)) + [8] : [1, 0]
    }
    private var selected: Int? {
        guard hasDirection else { return ac.code(axis + "Switch") }
        let code = ac.code(axis + "Direction")
        return ac.code(axis + "Switch") == 0 && !(9...13).contains(code ?? -1) ? 8 : code
    }
    private func label(_ option: Int) -> String {
        if !hasDirection { return option == 0 ? "Stop" : "Swing" }
        if option == 8 { return "Stop" }
        if (9...13).contains(option) { return (vertical ? verticalStops : horizontalStops)[option - 9] }
        let swings = vertical ? ["Up and down", "Upper zone", "Lower zone"] : ["Left to right", "Left zone", "Center zone", "Right zone"]
        return swings[option - 1]
    }
    #if os(iOS)
    private let buttonHeight: CGFloat = 44
    private let optionSize: CGFloat = 44
    private let popoverEdge: Edge = .top
    #else
    private let buttonHeight: CGFloat = 34
    private let optionSize: CGFloat = 36
    private let popoverEdge: Edge = .bottom
    #endif
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 3) {
                icon(selected).frame(width: 28, height: 28)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.frame(width: 44, height: buttonHeight)
                .contentShape(Rectangle())
        }.buttonStyle(ClimateSelectionButtonStyle(selected: presented)).foregroundStyle(.white)
            .disabled(!hasDirection && !ac.has(axis + "Switch"))
            .accessibilityLabel(title + " air direction").accessibilityValue(ac.vane(vertical))
            .help(title + ": " + ac.vane(vertical))
            .popover(isPresented: $presented, arrowEdge: popoverEdge) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(optionSize), spacing: 8), count: min(5, options.count)), spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            presented = false
                            choose(axis + (hasDirection ? "Direction" : "Switch"), option)
                        } label: {
                            icon(option).frame(width: 28, height: 28)
                                .frame(width: optionSize, height: optionSize)
                        }.buttonStyle(ClimateSelectionButtonStyle(selected: selected == option))
                            .foregroundStyle(selected == option ? SuperBarPanelStyle.cyan : .white)
                            .accessibilityLabel(label(option)).help(label(option))
                            .accessibilityAddTraits(selected == option ? .isSelected : [])
                    }
                }.padding(12).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
    @ViewBuilder private func icon(_ option: Int?) -> some View {
        let code = hasDirection ? option : (option == 1 ? 1 : 8)
        if let code, let url = Bundle.main.url(forResource: "TCL-\(axis)-\(code)", withExtension: "png") {
            #if os(iOS)
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #else
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #endif
        } else {
            Image(systemName: option == nil ? "questionmark.circle" : "stop.circle").resizable().scaledToFit()
        }
    }
}

struct LGFanSpeedPicker: View {
    let options: [String]
    let selected: String?
    let choose: (String) -> Void
    @State private var presented = false
    static func level(_ speed: String?) -> Int {
        ClimateIndicators.lgLevel(speed) ?? 0
    }
    #if os(iOS)
    private let size: CGFloat = 44
    private let edge: Edge = .top
    #else
    private let size: CGFloat = 34
    private let edge: Edge = .bottom
    #endif
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 9) {
                FanLevelDots(level: Self.level(selected))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.frame(width: size + 10, height: size).contentShape(Rectangle())
        }.buttonStyle(ClimateSelectionButtonStyle(selected: presented)).disabled(options.isEmpty)
            .accessibilityLabel("Fan speed").accessibilityValue(selected?.capitalized ?? "Unknown")
            .help("Fan: " + (selected?.capitalized ?? "Unknown"))
            .popover(isPresented: $presented, arrowEdge: edge) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { speed in
                        Button { presented = false; choose(speed) } label: {
                            FanLevelDots(level: Self.level(speed)).frame(width: size, height: size)
                                .contentShape(Rectangle())
                        }.buttonStyle(ClimateSelectionButtonStyle(selected: selected == speed))
                            .accessibilityLabel(speed.capitalized).help(speed.capitalized)
                            .accessibilityAddTraits(selected == speed ? .isSelected : [])
                    }
                }.padding(10).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
}

// Shared presentation; each provider owns its supported preset semantics.
struct CoolingPresetRow<Preset: CaseIterable & Hashable>: View {
    let label: (Preset) -> String
    let enabled: (Preset) -> Bool
    let selected: (Preset) -> Bool
    let apply: (Preset) -> Void
    var fanLevel: ((Preset) -> Int)? = nil
    var icon: ((Preset) -> FanSpeedSymbol)? = nil
    var accessibilityName: ((Preset) -> String)? = nil

    private var controlHeight: CGFloat {
        #if os(iOS)
        44
        #else
        34
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Preset.allCases), id: \.self) { preset in
                Button { apply(preset) } label: {
                    HStack(spacing: 6) {
                        Text(label(preset))
                        if let icon { FanSpeedIcon(symbol: icon(preset)).frame(width: 22, height: 22) }
                        if let fanLevel { FanLevelDots(level: fanLevel(preset)) }
                    }.font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: controlHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(ClimateSelectionButtonStyle(selected: selected(preset))).disabled(!enabled(preset))
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityName?(preset) ?? label(preset))
                    .help(accessibilityName?(preset) ?? label(preset))
                    .accessibilityAddTraits(selected(preset) ? .isSelected : [])
            }
        }
    }
}

struct ClimateEcoButton: View {
    let enabled: Bool?
    let action: () -> Void
    #if os(macOS)
    private let side: CGFloat = 34
    #else
    private let side: CGFloat = 44
    #endif

    var body: some View {
        Button(action: action) {
            ClimateEcoIcon(enabled: enabled == true)
                .font(.system(size: 23, weight: .medium))
                .frame(width: side, height: side).contentShape(Rectangle())
        }.buttonStyle(ClimateSelectionButtonStyle(selected: enabled == true)).accessibilityLabel("Eco")
            .accessibilityValue(enabled.map { $0 ? "On" : "Off" } ?? "Unknown")
            .help("Eco")
    }
}
