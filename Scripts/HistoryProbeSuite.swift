import Foundation

@main enum HistoryProbeSuite {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let requested = args.filter { ["tcl", "lg", "tuya"].contains($0) }
        let providers = requested.isEmpty ? ["tcl", "lg", "tuya"] : requested
        let intervals = args.contains("--48h") || !args.contains("--30d")
        let days = args.contains("--30d")
        print("Super Bar · Asia/Manila")
        if intervals {
            print("48 ч: \(HistoryProbeWindow.timestamp.string(from: HistoryProbeWindow.start)) — \(HistoryProbeWindow.timestamp.string(from: HistoryProbeWindow.end))")
        }
        if days {
            let format = ChartHistory.formatter("yyyy-MM-dd")
            print("30 календарных дней: \(format.string(from: HistoryProbeWindow.dayStart)) — \(format.string(from: HistoryProbeWindow.today)), включая сегодня.")
        }
        print("Только чтение истории провайдеров. macOS может запросить доступ к Связке ключей.")
        HistoryProbeWindow.beginExport()
        var completed = true
        for provider in providers {
            HistoryProbeWindow.provider = provider
            print("\n[\(provider.uppercased())]")
            if intervals {
                let ok: Bool
                switch provider {
                case "tcl": ok = TCLHistoryProbe.run48h()
                case "lg": ok = await LGHistoryProbe.run48h()
                case "tuya": ok = await TuyaHistoryProbe.run48h()
                default: continue
                }
                if !ok { completed = false }
            }
            if days {
                print("  Суточные значения за 30 дней")
                let ok: Bool
                switch provider {
                case "tcl": ok = TCLHistoryProbe.run30d()
                case "lg": ok = await LGHistoryProbe.run30d()
                case "tuya": ok = await TuyaHistoryProbe.run30d()
                default: continue
                }
                if !ok { completed = false }
            }
            if args.contains("--explore") {
                print("  Альтернативные запросы истории")
                let ok: Bool
                switch provider {
                case "tcl": ok = TCLHistoryProbe.runExplore()
                case "lg": ok = await LGHistoryProbe.runExplore()
                case "tuya": ok = await TuyaHistoryProbe.runExplore()
                default: continue
                }
                if !ok { completed = false }
            }
        }
        HistoryProbeWindow.finishExport()
        print(completed ? "\nПроверка завершена." : "\nПроверка завершена. Часть запросов недоступна, подробности выше.")
        if !completed { exit(1) }
    }
}
