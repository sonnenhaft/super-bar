import Foundation

enum DeviceVisibility {
    static let showOfflineKey = "showOfflineDevices"

    static func includes(online: Bool?, showOffline: Bool) -> Bool {
        showOffline || online != false
    }

    static func includesBattery(hasReading: Bool, online: Bool?, showOffline: Bool) -> Bool {
        showOffline || (hasReading && online != false)
    }
}

// Provider is part of identity, never a visual grouping or a display label.
enum ClimateDeviceID: Hashable {
    case tcl(String)
    case lg(String)
}

enum DeviceDisplayName {
    static func batterySymbol(percent: Int?) -> String {
        let charge = min(100, max(0, percent ?? 0))
        return "battery.\((charge + 12) / 25 * 25)percent"
    }

    static func clean(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"(?i)\b(?:air\s*con(?:ditioner)?|aricon)\b|\ba\s*/\s*c\b"#, with:"", options:.regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#,with:" ",options:.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"-–·")))
        return cleaned.isEmpty ? "Unit" : cleaned
    }
}
