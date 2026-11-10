import Foundation

struct StationRowTitle {
    let name: String
    let accessibilityLabel: String
    let isConnected: Bool

    init(name: String, watts: Double?, connectedPercent: Int?) {
        self.name = name
        let output = watts.flatMap { $0 > 0 ? MenuPresentation.watts($0) : nil } ?? "off"
        let summary = name + " · " + output
        isConnected = connectedPercent != nil
        accessibilityLabel = connectedPercent.map { "\(summary), connected, \($0)%" } ?? summary
    }
}
