import Foundation

// This is the only data shared with the extension. Never put credentials here.
struct WidgetMetric: Codable, Identifiable {
    var id: String
    var name: String
    var value: String
    var detail: String
    var symbol: String
    var updatedAt: Date?
    var brand: String? = nil
    var control: WidgetClimateControl? = nil
    func isStale(at date: Date) -> Bool {
        guard let updatedAt else { return true }
        return date.timeIntervalSince(updatedAt) > 300 || updatedAt > date.addingTimeInterval(60)
    }
}

// Capability and confirmed-state metadata only. The app process owns credentials
// and revalidates a command against the provider before sending it.
struct WidgetClimateControl: Codable {
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

struct WidgetSnapshot: Codable {
    var energy: [WidgetMetric] = []
    var climate: [WidgetMetric] = []
    var batteries: [WidgetMetric] = []
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
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
