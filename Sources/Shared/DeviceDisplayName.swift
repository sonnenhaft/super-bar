import Foundation

enum DeviceDisplayName {
    static func clean(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"(?i)\b(?:air\s*con(?:ditioner)?|aricon)\b|\ba\s*/\s*c\b"#, with:"", options:.regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#,with:" ",options:.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"-–·")))
        return cleaned.isEmpty ? "Unit" : cleaned
    }
}
