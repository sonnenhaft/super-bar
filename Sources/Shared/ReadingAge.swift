import Foundation
import Combine

// Relative ages update only while the panel is open; no device polling is involved.
final class ReadingAge: ObservableObject {
    static let shared = ReadingAge()
    private static var labels: [Date:String] = [:]
    private static var timer: Timer?
    static func start(tick:@escaping () -> Void) {
        stop()
        panelOpened()
        let timer = Timer(timeInterval:3,repeats:true) { _ in
            panelOpened()
            tick()
        }
        self.timer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    static func stop() { timer?.invalidate(); timer = nil }
    static func panelOpened() {
        labels.removeAll(keepingCapacity:true)
        shared.objectWillChange.send()
    }
    static func label(_ date:Date, now:Date = Date()) -> String {
        if let label = labels[date] { return label }
        let seconds = max(0,Int(now.timeIntervalSince(date)))
        let age = seconds < 3 ? "Just now" : seconds < 60 ? "\(seconds)s ago" : seconds < 3600 ? "\(seconds/60)m ago" : seconds < 86400 ? "\(seconds/3600)h ago" : "\(seconds/86400)d ago"
        let text = "Last read " + age
        if labels.count > 128 { labels.removeAll(keepingCapacity:true) }
        labels[date] = text
        return text
    }
}
