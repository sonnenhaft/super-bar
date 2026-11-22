import Foundation
import Darwin

// One navigation contract for widget links and the foreground app. These URLs
// select a view only: no credentials or device-control commands are encoded.
enum WidgetRoute: Equatable {
    enum EnergyComponent: String, CaseIterable {
        case solar, load, costHour = "cost-hour", costDay = "cost-day"
    }
    case home, settings, television
    case climate(ClimateDeviceID?)
    case battery(String?)
    case energy(EnergyComponent?)

    var section: String {
        switch self {
        case .home: return "home"
        case .settings: return "settings"
        case .television: return "television"
        case .climate: return "climate"
        case .battery: return "battery"
        case .energy: return "energy"
        }
    }
    var url: URL {
        var parts = URLComponents()
        parts.scheme = "superbar"; parts.host = section
        switch self {
        case .climate(.tcl(let id)):
            parts.queryItems = [.init(name: "brand", value: "TCL"), .init(name: "id", value: id)]
        case .climate(.lg(let id)):
            parts.queryItems = [.init(name: "brand", value: "LG"), .init(name: "id", value: id)]
        case .battery(let id?): parts.queryItems = [.init(name: "id", value: id)]
        case .energy(let component?): parts.queryItems = [.init(name: "component", value: component.rawValue)]
        default: break
        }
        return parts.url!
    }
    init?(url: URL) {
        guard url.absoluteString.utf8.count <= 4096, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "superbar", parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count, items.allSatisfy({ item in
            guard let value = item.value else { return false }
            return !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }) else { return nil }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        switch parts.host {
        case "home" where query.isEmpty: self = .home
        case "settings" where query.isEmpty: self = .settings
        case "television" where query.isEmpty: self = .television
        case "climate":
            if query.isEmpty { self = .climate(nil) }
            else if query.count == 2, let id = query["id"], query["brand"] == "TCL" { self = .climate(.tcl(id)) }
            else if query.count == 2, let id = query["id"], query["brand"] == "LG" { self = .climate(.lg(id)) }
            else { return nil }
        case "battery":
            guard query.isEmpty || (query.count == 1 && query["id"] != nil) else { return nil }
            self = .battery(query["id"])
        case "energy":
            if query.isEmpty { self = .energy(nil) }
            else if query.count == 1, let raw = query["component"], let component = EnergyComponent(rawValue: raw) { self = .energy(component) }
            else { return nil }
        default: return nil
        }
    }
}

// This is the only data shared with the extension. Never put credentials here.
struct WidgetMetric: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var value: String
    var detail: String
    var symbol: String
    var updatedAt: Date?
    var brand: String? = nil
    var control: WidgetClimateControl? = nil
    var online: Bool? = nil
    var ecoEnabled: Bool? = nil
    var fanSpeed: String? = nil
    var batteryRuntime: String? = nil
    var savedReading: Bool? = nil
    var savedSetting: Bool? = nil
    var sourceID: String? = nil
    var hasReading: Bool { value != "—" && !value.isEmpty }
    var hasBatteryReading: Bool {
        guard hasReading, value.hasSuffix("%"), let percent = Int(value.dropLast()) else { return false }
        return (0...100).contains(percent)
    }
    var displayedRuntime: String? { batteryRuntime == "Runtime unavailable" ? nil : batteryRuntime }
    func isSaved(at date: Date) -> Bool {
        hasReading && (savedReading == true || online == false || isStale(at: date))
    }
    var setting: String? {
        guard detail == "Off" || detail.hasPrefix("Off · ") || (detail.hasPrefix("Set ") && detail != "Set —") else { return nil }
        return detail
    }
    func isSettingSaved(at date: Date) -> Bool {
        guard setting != nil else { return false }
        if savedSetting == true || online == false { return true }
        if let control { return !control.enabled(at: date) }
        return isStale(at: date)
    }
    // Keep the sensor value and its measurement time together. A successful
    // settings refresh can report a new target but omit the room temperature.
    func retainingReading(from previous: Self?) -> Self {
        guard let previous, previous.id == id, previous.brand == brand else { return self }
        var result = self
        if brand != nil, setting == nil, let last = previous.setting,
           detail != "Set —" || last.hasPrefix("Set ") {
            result.detail = last
            result.savedSetting = true
        }
        if previous.hasReading && (!hasReading || (online == false && brand != nil)) {
            result.value = previous.value
            result.updatedAt = previous.updatedAt
            result.savedReading = true
            if brand == nil {
                result.detail = previous.detail
                result.symbol = previous.symbol
                result.batteryRuntime = previous.batteryRuntime
            }
        }
        return result
    }
    func isStale(at date: Date) -> Bool {
        guard let updatedAt else { return true }
        return date.timeIntervalSince(updatedAt) > 300 || updatedAt > date.addingTimeInterval(60)
    }
}

// Capability and confirmed-state metadata only. The app process owns credentials
// and revalidates a command against the provider before sending it.
struct WidgetClimateControl: Codable, Equatable {
    var target: Double?
    var temperatures: [Int]
    var powerOn: Bool?
    var canSetPower: Bool
    var checkedAt: Date

    func enabled(at date: Date) -> Bool {
        let age = date.timeIntervalSince(checkedAt)
        return powerOn != nil && age.isFinite && (-60...300).contains(age)
    }
    func validTemperature(_ value: Int) -> Bool { temperatures.contains(value) }
    func adjacent(delta: Int) -> Int? {
        guard let target, target.isFinite else { return nil }
        switch delta {
        case -1: return temperatures.filter { Double($0) < target }.max()
        case 1: return temperatures.filter { Double($0) > target }.min()
        default: return nil
        }
    }
}

/// Display data only. Pairing keys and network addresses never enter the widget.
struct WidgetTelevision: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let power: Bool?
    let volume: Int?
    let updatedAt: Date

    func isFresh(at date: Date) -> Bool { (-60..<300).contains(date.timeIntervalSince(updatedAt)) }
}

struct WidgetSnapshot: Codable, Equatable {
    var energy: [WidgetMetric] = []
    var climate: [WidgetMetric] = []
    var batteries: [WidgetMetric] = []
    var showOfflineDevices: Bool? = nil
    var bluetoothCheckedAt: Date? = nil
    var televisions: [WidgetTelevision]? = nil
    var bluetoothExpiresAt: Date? { bluetoothCheckedAt?.addingTimeInterval(300) }

    // WidgetKit can outlive the app that owns the link. Old builds only recorded
    // advertisements; even a confirmed link expires if the app stops reporting.
    func forWidget(at date: Date) -> Self {
        let checkedRecently = bluetoothCheckedAt.map { (-60..<300).contains(date.timeIntervalSince($0)) } ?? false
        var saved = self
        for i in saved.batteries.indices where !checkedRecently || saved.batteries[i].isStale(at: date) {
            saved.batteries[i].online = false
        }
        return saved
    }
    var visibleClimate: [WidgetMetric] {
        climate.filter { DeviceVisibility.includes(online: $0.online, showOffline: showOfflineDevices == true) }
    }
    var visibleBatteries: [WidgetMetric] {
        batteries.filter {
            DeviceVisibility.includesBattery(hasReading: $0.hasBatteryReading, online: $0.online, showOffline: showOfflineDevices == true)
        }
    }
    // Keep new measurement times on disk without reloading the timeline for
    // every unchanged poll. Freshness transitions still change presentation.
    func hasSamePresentation(as other: Self, at date: Date) -> Bool {
        presentation(at: date) == other.presentation(at: date)
    }
    private func presentation(at date: Date) -> Self {
        var value = forWidget(at: date)
        func display(_ metric: WidgetMetric) -> WidgetMetric {
            var value = metric
            value.savedReading = metric.isSaved(at: date)
            value.savedSetting = metric.isSettingSaved(at: date)
            value.updatedAt = nil
            value.control?.checkedAt = Date(timeIntervalSince1970: 0)
            return value
        }
        value.energy = value.energy.map(display)
        value.climate = value.climate.map(display)
        value.batteries = value.batteries.map(display)
        value.bluetoothCheckedAt = nil
        value.showOfflineDevices = value.showOfflineDevices == true
        return value
    }
    static let empty = WidgetSnapshot()
}

enum WidgetCache {
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "SuperBarAppGroup") as? String ?? "group.com.sonnenhaft.superbar"
    }
    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("widget-readings.json")
    }
    static func read() -> WidgetSnapshot {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
    // All writers lock the same sibling file; the snapshot itself is replaced atomically.
    @discardableResult static func update(_ transform: (inout WidgetSnapshot) throws -> Void) throws -> Bool {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let fd = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        let previous: WidgetSnapshot
        do { previous = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { previous = .empty }
        var snapshot = previous
        try transform(&snapshot)
        guard snapshot != previous else { return false }
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}
