import AppIntents
import SwiftUI
import WidgetKit

struct SuperBarEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let selection: WidgetClimateSelection
}

struct SuperBarProvider: TimelineProvider {
    func placeholder(in context: Context) -> SuperBarEntry {
        SuperBarEntry(date: Date(), snapshot: .empty, selection: .init())
    }
    func getSnapshot(in context: Context, completion: @escaping (SuperBarEntry) -> Void) {
        completion(SuperBarEntry(date: Date(), snapshot: WidgetCache.read(), selection: .read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SuperBarEntry>) -> Void) {
        let snapshot = WidgetCache.read()
        let selection = WidgetClimateSelection.read()
        let now = Date()
        // Expire both readings and controls even when a background refresh is deferred.
        let timestamps = (snapshot.energy + snapshot.climate + snapshot.batteries).compactMap(\.updatedAt)
            + snapshot.climate.compactMap { $0.control?.checkedAt }
        let dates = Set(timestamps
            .map { $0.addingTimeInterval(301) }.filter { $0 > now })
        let entries = ([now] + dates.sorted()).map {
            SuperBarEntry(date: $0, snapshot: snapshot, selection: selection)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct SuperBarWidgetView: View {
    let entry: SuperBarEntry
    private var metrics: [WidgetMetric] {
        entry.snapshot.climate + entry.snapshot.batteries + entry.snapshot.energy
    }
    private var selected: WidgetMetric? { entry.selection.selected(in: entry.snapshot) }
    private var pickingTemperature: Bool {
        entry.selection.pickingTemperature && !(selected?.control?.temperatures.isEmpty ?? true)
    }
    var body: some View {
        overview
            .padding(SuperBarPanelStyle.widgetInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { SuperBarPanelStyle.background }
            .widgetURL(URL(string: "superbar://home"))
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            climateSection
            Divider()
            Link(destination: URL(string: "superbar://battery")!) {
                batterySection
            }
            Divider()
            Link(destination: URL(string: "superbar://energy")!) {
                if pickingTemperature {
                    compactEnergy
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        PanelSectionHeading(title: "Energy", compact: true)
                        HStack(spacing: 8) { energyTiles }
                    }
                }
            }
            if let message = entry.selection.message, !message.isEmpty {
                Link(destination: URL(string: "superbar://climate")!) {
                    Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let oldest = oldestMetric { age(oldest) }
        }
    }
    private var climateSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                PanelSectionHeading(title: "Climate", compact: true)
                Spacer()
                Link(destination: URL(string: "superbar://climate")!) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 18)
                        .accessibilityLabel("Open climate controls")
                }
            }
            climateRow("TCL")
            climateRow("LG")
            if let selected {
                if let control = selected.control {
                    climateControls(selected, control: control)
                    if pickingTemperature { temperaturePicker(selected, control: control) }
                } else {
                    Link(destination: URL(string: "superbar://climate")!) {
                        HStack {
                            Text("Open app for controls")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var oldestMetric: WidgetMetric? {
        metrics.min { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }
    private func climateRow(_ name: String) -> some View {
        let rows = entry.snapshot.climate.filter { ($0.brand ?? "TCL") == name }
        return HStack(spacing: 8) {
            brand(name)
            if rows.isEmpty {
                Link(destination: URL(string: "superbar://climate")!) { empty("Connect " + name) }
            } else {
                ForEach(Array(rows.prefix(3))) { metric in
                    Button(intent: SelectWidgetClimateIntent(brand: name, deviceID: metric.id)) {
                        climateDevice(metric)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func climateDevice(_ metric: WidgetMetric) -> some View {
        let isSelected = selected?.id == metric.id && selected?.brand == metric.brand
        let on = metric.control.flatMap { $0.enabled(at: entry.date) ? $0.powerOn : nil }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(DeviceDisplayName.clean(metric.name)).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Circle().fill(on == true ? SuperBarPanelStyle.green : on == false ? .red : .gray)
                    .frame(width: 5, height: 5)
            }
            if !pickingTemperature {
                Text("Room " + metric.value).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(minHeight: pickingTemperature ? 16 : 28)
        .superBarSurface(selected: isSelected, padding: 4)
        .accessibilityLabel("\(metric.brand ?? "") \(DeviceDisplayName.clean(metric.name)), room \(metric.value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    private func climateControls(_ metric: WidgetMetric, control: WidgetClimateControl) -> some View {
        let brand = metric.brand ?? "TCL"
        let enabled = control.enabled(at: entry.date)
        let lower = control.adjacent(delta: -1)
        let higher = control.adjacent(delta: 1)
        return HStack(spacing: 5) {
            Button(intent: SetWidgetPowerIntent(brand: brand, deviceID: metric.id,
                                                powerOn: !(control.powerOn ?? false))) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text(control.powerOn.map { $0 ? "On" : "Off" } ?? "—")
                }.font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(control.powerOn == true ? SuperBarPanelStyle.green : .white)
                    .frame(width: 57, height: 30).deviceSurface(selected: control.powerOn == true)
            }
            .disabled(!enabled || !control.canSetPower)
            .opacity(enabled && control.canSetPower ? 1 : 0.45)
            .accessibilityLabel(control.powerOn == true ? "Turn off \(metric.name)" : "Turn on \(metric.name)")
            temperatureStep(metric, value: lower, symbol: "minus", enabled: enabled)
            Button(intent: ToggleWidgetTemperatureIntent(brand: brand, deviceID: metric.id)) {
                HStack(spacing: 5) {
                    Text(control.target.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "°" } ?? "—")
                        .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    Image(systemName: pickingTemperature ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 30)
                .deviceSurface(selected: pickingTemperature)
            }
            .disabled(control.temperatures.isEmpty)
            .accessibilityLabel(pickingTemperature ? "Close temperature selection" : "Choose temperature")
            .accessibilityValue(control.target.map {
                $0.formatted(.number.precision(.fractionLength(0...1))) + " degrees"
            } ?? "Temperature unknown")
            temperatureStep(metric, value: higher, symbol: "plus", enabled: enabled)
        }.buttonStyle(.plain)
    }
    private func temperatureStep(_ metric: WidgetMetric, value: Int?, symbol: String, enabled: Bool) -> some View {
        Button(intent: SetWidgetTemperatureIntent(brand: metric.brand ?? "TCL", deviceID: metric.id,
                                                  temperature: value ?? 0)) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30).deviceSurface(selected: false)
        }
        .disabled(!enabled || value == nil)
        .opacity(enabled && value != nil ? 1 : 0.4)
        .accessibilityLabel(symbol == "minus" ? "Lower temperature" : "Raise temperature")
    }
    private func temperaturePicker(_ metric: WidgetMetric, control: WidgetClimateControl) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: control.temperatures.count > 20 ? 7 : 5)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(control.temperatures, id: \.self) { temperature in
                Button(intent: SetWidgetTemperatureIntent(brand: metric.brand ?? "TCL", deviceID: metric.id,
                                                          temperature: temperature)) {
                    Text("\(temperature)°").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .deviceSurface(selected: control.target == Double(temperature))
                }
                .disabled(!control.enabled(at: entry.date))
                .opacity(control.enabled(at: entry.date) ? 1 : 0.45)
                .accessibilityLabel("Set \(metric.name) to \(temperature) degrees")
                .accessibilityAddTraits(control.target == Double(temperature) ? .isSelected : [])
            }
        }.buttonStyle(.plain)
    }
    private func brand(_ name: String) -> some View {
        PanelBrandLabel(name: name, compact: true)
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: pickingTemperature ? 16 : 28, alignment: .leading)
            .superBarSurface(padding: 4)
    }
    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !pickingTemperature { PanelSectionHeading(title: "Battery", compact: true) }
            HStack(spacing: 8) {
                brand("BLUETTI")
                if let battery = entry.snapshot.batteries.first {
                    HStack(spacing: 6) {
                        Image(systemName: "battery.100percent").font(.system(size: pickingTemperature ? 17 : 23))
                        Text(battery.value).font(.system(size: pickingTemperature ? 12 : 16, weight: .semibold))
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(DeviceDisplayName.clean(battery.name)).font(.system(size: 10, weight: .medium))
                            if !pickingTemperature {
                                Text(battery.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }.lineLimit(1)
                    }.frame(height: pickingTemperature ? 18 : 30).superBarSurface(padding: 4)
                } else { empty("Connect BLUETTI") }
            }
        }
    }
    private var compactEnergy: some View {
        HStack(spacing: 8) {
            compactEnergyReading("Generation", id: "solar", symbol: "sun.max", color: SuperBarPanelStyle.yellow)
            compactEnergyReading("Consumption", id: "load", symbol: "bolt.fill", color: SuperBarPanelStyle.cyan)
        }
    }
    private func compactEnergyReading(_ label: String, id: String, symbol: String, color: Color) -> some View {
        let value = entry.snapshot.energy.first { $0.id == id }?.value ?? "—"
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.7)
        }.foregroundStyle(color).frame(height: 22).superBarSurface(padding: 4)
            .accessibilityLabel("\(label) \(value)")
    }
    @ViewBuilder private var energyTiles: some View {
        let solar = entry.snapshot.energy.first { $0.id == "solar" }
        let load = entry.snapshot.energy.first { $0.id == "load" }
        PanelEnergyTile(title: "Generation", value: solar?.value ?? "—", generation: true, compact: true)
        PanelEnergyTile(title: "Consumption", value: load?.value ?? "—", generation: false, compact: true)
    }
    private func age(_ metric: WidgetMetric) -> some View {
        HStack(spacing: 3) {
            Text(metric.isStale(at: entry.date) ? "Saved" : "Updated")
            if let date = metric.updatedAt { Text(date, style: .relative) }
            else { Text("· time unknown") }
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }
}

@main struct SuperBarWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SuperBar.home", provider: SuperBarProvider()) { entry in
            SuperBarWidgetView(entry: entry)
        }
        .configurationDisplayName("Super Bar")
        .description("Control climate and see BLUETTI and energy together in one panel.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
