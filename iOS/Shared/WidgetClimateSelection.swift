import Foundation

// Separate from the readings snapshot: foreground refreshes must not dismiss a
// widget's open temperature grid or overwrite its selected conditioner.
struct WidgetClimateSelection: Codable, Equatable {
    var brand: String? = nil
    var deviceID: String? = nil
    var pickingTemperature = false
    var message: String? = nil

    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetCache.groupID)?
            .appendingPathComponent("widget-climate-selection.json")
    }
    static func read(from file: URL? = Self.file) -> Self {
        guard let file, let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    static func write(_ value: Self, to file: URL? = Self.file) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(value).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func selected(in snapshot: WidgetSnapshot) -> WidgetMetric? {
        if let brand, let deviceID,
           let selected = snapshot.climate.first(where: { $0.brand == brand && $0.id == deviceID }) {
            return selected
        }
        return snapshot.climate.first { $0.control != nil }
    }
}
