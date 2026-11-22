import Foundation

enum HistoryProbeWindow {
    static let end = Date()
    static let start = end.addingTimeInterval(-48 * 3600)
    static let today = ChartHistory.calendar.startOfDay(for: end)
    static let dayStart = ChartHistory.calendar.date(byAdding: .day, value: -29, to: today)!
    static let timestamp = ChartHistory.formatter("yyyy-MM-dd HH:mm:ss")
    private static let day = ChartHistory.formatter("MM-dd")
    private static let hour = ChartHistory.formatter("HH")
    private static let csvURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/history-probes/history-values-\(Int(end.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).csv")
    private static var csv: FileHandle?
    static var provider = ""

    static func beginExport() {
        do {
            try Data("source,time_manila,time_unix,value,unit,interval\n".utf8).write(to: csvURL, options: .atomic)
            csv = try FileHandle(forWritingTo: csvURL)
            try csv?.seekToEnd()
        } catch { print("Не удалось открыть файл для сохранения числовых показаний.") }
    }

    static func finishExport() {
        guard let file = csv else { return }
        do {
            try file.close()
            print("Исходные числовые показания: \(csvURL.path)")
        } catch { print("Не удалось завершить сохранение числовых показаний.") }
        csv = nil
    }

    static func export(_ label: String, samples: [(Date, Double)], unit: String, interval: String) {
        guard let file = csv else { return }
        func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = samples.filter { $0.0.timeIntervalSince1970.isFinite && $0.1.isFinite }.sorted { $0.0 < $1.0 }.map { date, value in
            [field(provider.isEmpty ? label : provider.uppercased() + " · " + label), field(timestamp.string(from: date)), String(date.timeIntervalSince1970),
             String(value), field(unit), field(interval)].joined(separator: ",")
        }
        guard !lines.isEmpty else { return }
        do { try file.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8)) }
        catch { print("Не удалось дописать числовые показания в файл.") }
    }

    static func reportDays(_ label: String, samples: [(Date, Double)], unit: String, knownUnit: Bool = true) {
        let days = (0..<30).map { ChartHistory.calendar.date(byAdding: .day, value: $0, to: dayStart)! }
        let valid = samples.filter { $0.1.isFinite && $0.1 >= 0 && dayStart <= $0.0 && $0.0 <= today }
        let values = Dictionary(valid.map { (ChartHistory.calendar.startOfDay(for: $0.0), $0.1) }, uniquingKeysWith: { _, last in last })
        export(label, samples: values.map { ($0.key, $0.value) }, unit: unit, interval: "day")
        let format = ChartHistory.formatter("yyyy-MM-dd")
        print("  \(label) — \(values.count)/30 дат с данными.")
        for day in days {
            let value = values[day].map { String(format: "%g", $0) + " " + unit } ?? "нет записи"
            print("    \(format.string(from: day)) = \(value)" + (day == today ? " · сегодня, день ещё идёт" : ""))
        }
        if knownUnit {
            let closed = values.filter { $0.key < today }
            if !closed.isEmpty {
                print("    Сумма за \(closed.count) завершённых дат с данными: \(String(format: "%g", closed.values.reduce(0, +))) \(unit).")
            }
        }
    }

    // A partial clock hour at either edge still intersects the requested 48 h.
    static func includes(_ date: Date, hourly: Bool, from lower: Date, until upper: Date) -> Bool {
        date < upper && (hourly ? date.addingTimeInterval(3600) > lower : date >= lower)
    }

    static func report(_ label: String, samples: [(Date, Double)], unit: String, hourly: Bool) {
        let points = samples.filter {
            $0.1.isFinite && includes($0.0, hourly: hourly, from: start, until: end)
        }
        let unique = Dictionary(points, uniquingKeysWith: { _, last in last }).sorted { $0.key < $1.key }
        export(label, samples: unique.map { ($0.key, $0.value) }, unit: unit, interval: hourly ? "hour" : "report")
        let hourStart = ChartHistory.calendar.dateInterval(of: .hour, for: start)!.start
        var clockHours: [Date] = []
        var clockHour = hourStart
        while clockHour < end {
            clockHours.append(clockHour)
            clockHour = clockHour.addingTimeInterval(3600)
        }
        let groups = Dictionary(grouping: unique) {
            ChartHistory.calendar.dateInterval(of: .hour, for: $0.key)!.start
        }
        let middle = start.addingTimeInterval(24 * 3600)
        let halfCounts = [(start, middle), (middle, end)].map { lower, upper in
            unique.filter { includes($0.key, hourly: hourly, from: lower, until: upper) }.count
        }
        print("  \(label) — точек: \(unique.count), календарных часов с данными: \(groups.count) из \(clockHours.count).")
        print("    Первые 24 ч: \(halfCounts[0]). Вторые 24 ч: \(halfCounts[1])." +
              (hourly ? " Час на границе двух периодов может входить в оба." : ""))
        guard let first = unique.first, let last = unique.last else { return }
        if !hourly {
            let minutes = Set(unique.map { Int(floor($0.key.timeIntervalSince1970 / 60)) })
            print("    Минут, в которых поступило показание: \(minutes.count).")
            let gaps = zip(unique, unique.dropFirst()).map { $1.key.timeIntervalSince($0.key) }.sorted()
            if let largest = gaps.last {
                let median = (gaps[(gaps.count - 1) / 2] + gaps[gaps.count / 2]) / 2
                print("    Интервал между показаниями в секундах: медиана \(String(format: "%.1f", median)), максимум \(String(format: "%.1f", largest)).")
            }
        }
        print("    Первое: \(timestamp.string(from: first.key)) = \(first.value) \(unit). Последнее: \(timestamp.string(from: last.key)) = \(last.value) \(unit).")
        // All intersected hours appear. A dash indicates a missing bucket; zero is a real value.
        for midnight in Array(Set(clockHours.map { ChartHistory.calendar.startOfDay(for: $0) })).sorted() {
            let row = clockHours.filter { ChartHistory.calendar.isDate($0, inSameDayAs: midnight) }.map { time -> String in
                let mark = hour.string(from: time)
                guard let values = groups[time] else { return "\(mark)=—" }
                if hourly {
                    if values.count > 1 { return "\(mark)=(\(values.count) записей)" }
                    return "\(mark)=\(String(format: "%g", values[0].value))"
                }
                return "\(mark)=\(values.count)"
            }
            print("    \(day.string(from: midnight)) [час=\(hourly ? unit : "число показаний")] " + row.joined(separator: " "))
        }
    }
}
