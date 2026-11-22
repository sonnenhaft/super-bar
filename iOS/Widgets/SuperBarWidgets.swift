import SwiftUI
import WidgetKit

struct SuperBarEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SuperBarProvider: TimelineProvider {
    func placeholder(in context: Context) -> SuperBarEntry {
        SuperBarEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (SuperBarEntry) -> Void) {
        let now = Date()
        completion(SuperBarEntry(date: now, snapshot: WidgetCache.read().forWidget(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SuperBarEntry>) -> Void) {
        let snapshot = WidgetCache.read()
        let now = Date()
        let metrics = snapshot.energy + snapshot.climate + snapshot.batteries
        let timestamps = metrics.compactMap(\.updatedAt) + snapshot.climate.compactMap { $0.control?.checkedAt } + (snapshot.televisions ?? []).map(\.updatedAt)
        var changes = Set(timestamps.map { $0.addingTimeInterval(301) }.filter { $0 > now })
        if let expiry = snapshot.bluetoothExpiresAt, expiry > now { changes.insert(expiry) }
        let entries = ([now] + changes.sorted()).map { SuperBarEntry(date: $0, snapshot: snapshot.forWidget(at: $0)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

// The widget is a snapshot adapter for the app's collapsed cards. Links replace
// the app's selection buttons; the shared cards own their visual presentation.
struct SuperBarWidgetView: View {
    let entry: SuperBarEntry
    @Environment(\.widgetFamily) private var family
    private var climate: [WidgetMetric] { entry.snapshot.visibleClimate }
    private var batteries: [WidgetMetric] { entry.snapshot.visibleBatteries }
    private func energy(_ id: String) -> WidgetMetric? { entry.snapshot.energy.first { $0.id == id } }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: CompactSuperBarWidgetView(entry: entry, layout: .small)
            case .systemMedium: CompactSuperBarWidgetView(entry: entry, layout: .medium)
            #if os(iOS)
            case .accessoryRectangular: CompactSuperBarWidgetView(entry: entry, layout: .lockScreen)
            #endif
            default: largeOverview
            }
        }
        .containerBackground(for: .widget) { SuperBarPanelStyle.background }
        .widgetURL(WidgetRoute.home.url).buttonStyle(.plain)
    }

    private var largeOverview: some View {
        ViewThatFits(in: .vertical) {
            ForEach([1.0, 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6], id: \.self) { scale in
                WidgetScreenScale(scale: scale) {
                    overview.scaleEffect(scale, anchor: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Identical screen sections, grid and card views to PhoneRoot. Only the
    // snapshot data and Link actions are supplied by the widget extension.
    private var overview: some View {
        PanelSections(maximumWidth: nil) {
            heading((entry.snapshot.televisions ?? []).isEmpty ? "AC" : "AC · TV", route: .climate(nil), extra: climate.count - 6).padding(.bottom, 2)
        } climate: {
            if climate.isEmpty && (entry.snapshot.televisions ?? []).isEmpty { empty("No room readings yet", route: .climate(nil)) }
            ClimateSummaryGrid {
                ForEach(Array(climate.prefix(6)), id: \.climateID) { unit in
                    Link(destination: WidgetRoute.climate(unit.climateID).url) {
                        ClimateSummaryCard(device: unit.climateCard(at: entry.date), selected: false)
                            .overlay(alignment: .topTrailing) { savedMark(unit).padding(3) }
                    }
                }
                ForEach(entry.snapshot.televisions ?? []) { tv in
                    WidgetTelevisionCard(tv: tv, date: entry.date)
                }
            }
        } batteryHeading: {
            heading("Battery", route: .battery(nil), extra: batteries.count - 2)
        } battery: {
            if batteries.isEmpty { empty("No battery readings yet", route: .battery(nil)) }
            BatteryStationGrid {
                ForEach(Array(batteries.prefix(2))) { station in
                    Link(destination: WidgetRoute.battery(station.id).url) {
                        BatterySummaryCard(name: station.name,
                            symbol: DeviceDisplayName.batterySymbol(percent: station.batteryPercent),
                            charge: station.value, selected: false)
                            .overlay(alignment: .topTrailing) { savedMark(station).padding(3) }
                    }
                }
            }
        } energyHeading: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    heading("Energy", route: .energy(nil))
                    Spacer(minLength: 0)
                    energyMetrics.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading("Energy", route: .energy(nil))
                    energyMetrics
                }
            }
        } energy: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    energyTile(.solar, title: "Generation", icon: solarIcon)
                    energyTile(.load, title: "Consumption", icon: .consumption)
                }
                if let voltage = energy("voltage") {
                    Link(destination: WidgetRoute.energy(.load).url) {
                        HStack(spacing: 4) {
                            Label("Grid voltage", systemImage: "waveform.path")
                            Spacer(minLength: 0)
                            Text(voltage.hasReading ? voltage.value : "— V").monospacedDigit()
                            savedMark(voltage)
                        }.font(.system(size: 13, weight: .semibold))
                    }.foregroundStyle(SuperBarPanelStyle.cyan)
                }
            }
        } footer: {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Link(destination: WidgetRoute.settings.url) {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 28)
                }.accessibilityLabel("Settings")
                Link(destination: WidgetRoute.home.url) {
                    RefreshGlyph(isRefreshing: false, size: 14).frame(width: 32, height: 28)
                }.accessibilityLabel("Open Super Bar to refresh readings")
            }
        } settings: {
            EmptyView()
        }
    }

    private var energyMetrics: some View {
        HStack(spacing: 6) {
            if let net = energy("net"), net.hasReading {
                Link(destination: WidgetRoute.energy(nil).url) { Text(displayValue(net.value)) }
                Text("·").foregroundStyle(.secondary)
            }
            energyValue(.costHour, fallback: "₱0.0/h")
            energyValue(.costDay, fallback: "₱0.0/d")
        }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(SuperBarPanelStyle.cyan).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func heading(_ title: String, route: WidgetRoute, extra: Int = 0) -> some View {
        Link(destination: route.url) {
            HStack(spacing: 4) {
                PanelSectionHeading(title: title, expanded: false)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if extra > 0 { Text("+\(extra)").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(minHeight: 36).contentShape(Rectangle())
        }
    }
    private func empty(_ title: String, route: WidgetRoute) -> some View {
        Link(destination: route.url) { Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func energyValue(_ component: WidgetRoute.EnergyComponent, fallback: String) -> some View {
        let metric = energy(component.rawValue)
        return Link(destination: WidgetRoute.energy(component).url) {
            HStack(spacing: 2) {
                Text(displayValue(metric.flatMap { $0.hasReading ? $0.value : nil } ?? fallback))
                if let metric { savedMark(metric) }
            }
        }
    }
    private func energyTile(_ component: WidgetRoute.EnergyComponent, title: String, icon: EnergyTileIcon) -> some View {
        let metric = energy(component.rawValue)
        return Link(destination: WidgetRoute.energy(component).url) {
            PanelEnergyTile(title: title, value: displayValue(metric.flatMap { $0.hasReading ? $0.value : nil } ?? "0 W"),
                            icon: icon, selected: false)
                .overlay(alignment: .topTrailing) { if let metric { savedMark(metric).padding(3) } }
        }
    }
    @ViewBuilder private func savedMark(_ metric: WidgetMetric) -> some View {
        if metric.isSaved(at: entry.date) || metric.isSettingSaved(at: entry.date) {
            Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(.secondary)
                .accessibilityLabel("Last known reading")
        }
    }
    private func displayValue(_ value: String) -> String { value.replacingOccurrences(of: " ⚡️", with: "") }
    private var solarIcon: EnergyTileIcon {
        displayValue(energy("solar")?.value ?? "0 W") == "0 W" ? .moon : .sun
    }
}

// Measure the same responsive screen at its logical width, then fit it into
// WidgetKit's fixed canvas while preserving card/font proportions and link areas.
/// Every tap opens TV in the app. The extension never connects or sends remote commands.
private struct WidgetTelevisionCard: View {
    let tv: WidgetTelevision
    let date: Date
    var fontSize: CGFloat = 13

    var body: some View {
        Link(destination: WidgetRoute.television.url) {
            VStack(alignment: .leading, spacing: 3) {
                Label(tv.name, systemImage: "tv").font(.system(size: fontSize, weight: .semibold)).lineLimit(1)
                HStack(spacing: 3) {
                    Circle().fill(tv.isFresh(at: date) && tv.power == true ? SuperBarPanelStyle.green : .gray).frame(width: 5, height: 5)
                    Text(tv.isFresh(at: date) ? tv.power.map { $0 ? "On" : "Off" } ?? "—" : "Saved")
                    Spacer(minLength: 0)
                    if let volume = tv.volume, (0...100).contains(volume) {
                        Label("\(volume)", systemImage: "speaker.wave.2").monospacedDigit()
                    }
                    if !tv.isFresh(at: date) { Image(systemName: "clock").accessibilityLabel("Saved reading") }
                }.font(.system(size: max(5, fontSize - 2))).foregroundStyle(.secondary)
            }.deviceSummarySurface(selected: false)
        }.accessibilityLabel("TV, " + tv.name)
    }
}

private struct WidgetScreenScale: Layout {
    let scale: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 344
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: width / scale, height: nil))
        return CGSize(width: width, height: size.height * scale)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width / scale, height: nil))
    }
}

// Family-specific columns use the available width before fitting text. Keep all
// devices, indicators and links; choose the largest scale that fits the canvas.
struct CompactSuperBarWidgetView: View {
    enum Layout { case small, medium, lockScreen }
    let entry: SuperBarEntry
    let layout: Layout
    @Environment(\.widgetRenderingMode) private var renderingMode
    private func tint(_ color: Color) -> Color { renderingMode == .vibrant ? .white : color }
    private var accessory: Bool { layout == .lockScreen }
    private var small: Bool { layout == .small }
    private var columns: Int { small ? 3 : 2 }
    private var textSize: CGFloat { accessory ? 6 : small ? 9 : 11 }
    private var nameSize: CGFloat { accessory ? 5.5 : small ? 9 : 10 }
    private var readingSize: CGFloat { accessory ? 7.5 : small ? 12 : 15 }
    private var gap: CGFloat { accessory ? 1 : 2 }
    private var climate: [WidgetMetric] { entry.snapshot.visibleClimate }
    private var batteries: [WidgetMetric] { entry.snapshot.visibleBatteries }
    private func energy(_ id: String) -> WidgetMetric? { entry.snapshot.energy.first { $0.id == id } }

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(stride(from: 1.5, through: 0.2, by: -0.025).map { $0 }, id: \.self) { scale in
                WidgetScreenScale(scale: scale) {
                    contents.scaleEffect(scale, anchor: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white).widgetAccentable(accessory)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: gap) {
            if small {
                climateSection
                Divider()
                batterySection
                Divider()
                energySection
            } else {
                HStack(alignment: .top, spacing: accessory ? 3 : 6) {
                    climateSection.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: gap) {
                        batterySection
                        Divider()
                        energySection
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Link(destination: WidgetRoute.settings.url) {
                    Image(systemName: "gearshape").frame(width: textSize * 1.8, height: textSize * 1.6)
                }.accessibilityLabel("Settings")
                Link(destination: WidgetRoute.home.url) {
                    Image(systemName: "arrow.clockwise").frame(width: textSize * 1.6, height: textSize * 1.2)
                }.accessibilityLabel("Open Super Bar to refresh readings")
            }.font(.system(size: textSize, weight: .semibold)).foregroundStyle(tint(SuperBarPanelStyle.cyan))
        }.padding(accessory ? 2 : 4).font(.system(size: textSize)).monospacedDigit()
    }

    private var climateSection: some View {
        VStack(alignment: .leading, spacing: gap) {
            heading((entry.snapshot.televisions ?? []).isEmpty ? "AC" : "AC · TV", route: .climate(nil))
            if climate.isEmpty && (entry.snapshot.televisions ?? []).isEmpty { empty("No room readings yet", route: .climate(nil)) }
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                ForEach(0..<((climate.count + (entry.snapshot.televisions ?? []).count + columns - 1) / columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < climate.count { climateCard(climate[index]) }
                            else if index - climate.count < (entry.snapshot.televisions ?? []).count {
                                WidgetTelevisionCard(tv: (entry.snapshot.televisions ?? [])[index - climate.count], date: entry.date, fontSize: textSize)
                            }
                            else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
            }
        }
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: gap) {
            heading("Battery", route: .battery(nil))
            if batteries.isEmpty { empty("No battery readings yet", route: .battery(nil)) }
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                ForEach(0..<((batteries.count + (small ? 2 : 1) - 1) / (small ? 2 : 1)), id: \.self) { row in
                    GridRow {
                        ForEach(0..<(small ? 2 : 1), id: \.self) { column in
                            let index = row * (small ? 2 : 1) + column
                            if index < batteries.count { batteryCard(batteries[index]) }
                            else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
            }
        }
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: 3) {
                heading("Energy", route: .energy(nil))
                Spacer(minLength: 0)
                if let voltage = energy("voltage") {
                    Link(destination: WidgetRoute.energy(.load).url) {
                        HStack(spacing: 2) {
                            Label(voltage.hasReading ? voltage.value : "— V", systemImage: "waveform.path")
                            savedMark(voltage)
                        }.font(.system(size: textSize, weight: .semibold)).monospacedDigit()
                    }.foregroundStyle(tint(SuperBarPanelStyle.cyan))
                        .accessibilityLabel("Grid voltage, \(voltage.value)")
                }
                energyLink("net", label: "Net", route: .energy(nil))
            }
            HStack(spacing: gap) {
                energyLink("solar", label: "Generation", route: .energy(.solar), symbol: "sun.max.fill")
                energyLink("load", label: "Consumption", route: .energy(.load), symbol: "bolt.fill")
            }
            HStack(spacing: gap) {
                energyLink("cost-hour", label: "Hour", route: .energy(.costHour))
                energyLink("cost-day", label: "Day", route: .energy(.costDay))
            }
        }
    }

    private func heading(_ title: String, route: WidgetRoute) -> some View {
        Link(destination: route.url) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: textSize, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: textSize * 0.65, weight: .bold))
            }.contentShape(Rectangle())
        }
    }
    private func empty(_ title: String, route: WidgetRoute) -> some View {
        Link(destination: route.url) { Text(title).font(.system(size: 8)).foregroundStyle(.secondary) }
    }
    private func climateCard(_ unit: WidgetMetric) -> some View {
        let device = unit.climateCard(at: entry.date)
        return Link(destination: WidgetRoute.climate(unit.climateID).url) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 2) {
                    ClimateHousing(windowUnit: device.windowUnit).frame(width: nameSize, height: nameSize * 0.8)
                    Text(DeviceDisplayName.clean(unit.name)).font(.system(size: nameSize, weight: .semibold))
                        .lineLimit(3).minimumScaleFactor(0.6).frame(maxWidth: .infinity, alignment: .leading)
                    savedMark(unit)
                }
                HStack(spacing: 2) {
                    Text(unit.value).foregroundStyle(.white.opacity(0.8)).fontWeight(.medium)
                    Spacer(minLength: 0)
                    if let on = device.power {
                        Circle().fill(device.online == false ? .gray : on ? tint(Color(red: 0.16, green: 1, blue: 0.36)) : .gray)
                            .frame(width: readingSize * (on ? 0.3 : 0.22), height: readingSize * (on ? 0.3 : 0.22))
                    }
                    Text(device.online == false ? "Offline" : device.power == false ? "Off" : device.target.isEmpty ? "—" : device.target)
                        .fontWeight(.semibold)
                    ClimateIndicatorRow(indicators: device.indicators, size: readingSize, ecoColor: tint(leafGreen))
                }.font(.system(size: readingSize)).lineLimit(1).minimumScaleFactor(0.6)
            }.padding(accessory ? 1 : 2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Rectangle())
        }.accessibilityElement(children: .ignore)
            .accessibilityValue(device.indicators.label)
            .accessibilityLabel("\(unit.name), room \(unit.value), \(device.power == true ? "on" : device.power == false ? "off" : "unknown"), \(unit.setting ?? "setting unavailable")\(unit.isSaved(at: entry.date) ? ", last known reading" : "")")
    }
    private func batteryCard(_ station: WidgetMetric) -> some View {
        Link(destination: WidgetRoute.battery(station.id).url) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Image(systemName: DeviceDisplayName.batterySymbol(percent: station.batteryPercent))
                        .foregroundStyle(tint(SuperBarPanelStyle.green))
                    Text(station.name).lineLimit(2).minimumScaleFactor(0.7)
                    savedMark(station)
                    Spacer(minLength: 0)
                    Text(station.value).font(.system(size: readingSize * 0.9, weight: .bold)).fixedSize()
                }.font(.system(size: nameSize * 0.85, weight: .semibold))
                HStack(spacing: 2) {
                    Text(station.detail).font(.system(size: textSize * 0.85)).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    if let runtime = station.displayedRuntime {
                        Text(runtime).font(.system(size: textSize * 0.7)).foregroundStyle(.secondary)
                    }
                }.lineLimit(1).minimumScaleFactor(0.6)
            }.padding(accessory ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.accessibilityLabel("\(station.name), \(station.value), \(station.detail), \(station.displayedRuntime ?? "")")
    }
    private func energyLink(_ id: String, label: String, route: WidgetRoute, symbol: String? = nil) -> some View {
        let metric = energy(id)
        let value = metric.flatMap { $0.hasReading ? $0.value : nil } ?? (id == "cost-hour" ? "₱0.0/h" : id == "cost-day" ? "₱0.0/d" : id == "net" ? "—" : "0 W")
        return Link(destination: route.url) {
            HStack(spacing: 2) {
                if let symbol { Image(systemName: symbol) }
                if id == "solar" || id == "load" {
                    Text(id == "load" ? "Load" : accessory || small ? "Gen" : label)
                        .font(.system(size: textSize * 0.8)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(value.replacingOccurrences(of: " ⚡️", with: ""))
                    .font(.system(size: textSize * (small ? 1 : 1.18), weight: .semibold))
                if let metric { savedMark(metric) }
            }.font(.system(size: textSize)).lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, minHeight: textSize * 1.15).contentShape(Rectangle())
        }.foregroundStyle(tint(id == "solar" ? SuperBarPanelStyle.yellow : SuperBarPanelStyle.cyan))
            .accessibilityLabel("\(label), \(value)")
    }
    @ViewBuilder private func savedMark(_ metric: WidgetMetric) -> some View {
        if metric.isSaved(at: entry.date) || metric.isSettingSaved(at: entry.date) {
            Image(systemName: "clock").font(.system(size: textSize * 0.6)).foregroundStyle(.secondary)
                .accessibilityLabel("Last known reading")
        }
    }
}

private extension WidgetMetric {
    var climateID: ClimateDeviceID { brand == "LG" ? .lg(id) : .tcl(id) }
    var batteryPercent: Int? { hasBatteryReading ? Int(value.dropLast()) : nil }
    func climateCard(at date: Date) -> ClimateDeviceItem {
        let on = control?.powerOn ?? (setting.map { !$0.hasPrefix("Off") })
        let target = setting.flatMap { $0.hasPrefix("Set ") ? String($0.dropFirst(4)) : nil } ?? ""
        var indicators = ClimateIndicators()
        let current = control?.enabled(at: date) ?? (!isStale(at: date) && savedSetting != true)
        if on == true, online != false, current {
            indicators = brand == "LG" ? ClimateIndicators(eco: ecoEnabled == true, lgSpeed: fanSpeed)
                : ClimateIndicators(eco: ecoEnabled == true, tcl: fanSpeed.flatMap(FanSpeedSymbol.init(rawValue:)))
        }
        return ClimateDeviceItem(id: climateID, name: name, room: value, target: target, power: on,
                                 online: online, indicators: indicators)
    }
}

@main struct SuperBarWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SuperBar.home", provider: SuperBarProvider()) { entry in
            SuperBarWidgetView(entry: entry)
        }
        .configurationDisplayName("Super Bar")
        .description("Room names, temperatures and shortcuts to AC, TVs, batteries, energy and settings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}
