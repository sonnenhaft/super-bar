import Foundation

struct DeyeDay: Codable, Identifiable {
    let day: String
    let kwh: Double?
    var id: String { day }
}
struct DeyeReading: Codable {
    let id: Int
    var name: String
    let power_w: Double?
    let today_kwh: Double?
    let status: String
    let measured_at: Double?
    var days: [DeyeDay]
    var curve: [PowerPoint]? = nil
    var historyDay: String? = nil
    var date: Date? { measured_at.map(Date.init(timeIntervalSince1970:)) }
    static func power(_ watts: Double?) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        return DisplayUnits.power(watts)
    }
}
