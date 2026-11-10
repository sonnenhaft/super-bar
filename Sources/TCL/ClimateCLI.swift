import Darwin
import Foundation

enum ClimateCLI {
    static func run(_ args: [String]) -> Int32 {
        do {
            if args == ["--version"] {
                print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
                return 0
            }
            let dir = DeviceService.directory
            try DeviceService.ensure(dir)
            if args == ["--login"] || (!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".tcl-auth.json").path) && isatty(STDIN_FILENO) == 1) {
                guard isatty(STDIN_FILENO) == 1 else { throw ACError("Sign in from the TCL panel.") }
                FileHandle.standardError.write(Data("Email TCL Home: ".utf8))
                guard let email = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty,
                      let p = getpass("TCL Home password: ") else { throw ACError("Sign-in canceled.") }
                let password = String(cString:p)
                memset_s(p, strlen(p), 0, strlen(p))
                guard !password.isEmpty else { throw ACError("Password required.") }
                try TCLCloud(directory:dir).storeLogin(email:email, password:password)
                if args == ["--login"] { print("TCL Home session saved."); return 0 }
            }
            let rows = try DeviceService.run(args, directory: dir, energy: false)
            if rows.isEmpty { print("No air conditioners found."); return 0 }
            printTable(rows.compactMap(Aircon.init))
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
    static func printTable(_ units: [Aircon]) {
        func val(_ v: Any?) -> String {
            if v == nil || v is NSNull { return "—" }
            if let v = v as? String { return v }
            if let n = v as? NSNumber { return n.stringValue }
            if let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options:.sortedKeys) { return String(decoding:d,as:UTF8.self) }
            return "—"
        }
        func row(_ title: String, _ render: (Aircon)->String) -> [String] { [title] + units.map(render) }
        var table = [
            row("Field",{ $0.name }), row("Online",{ $0.online.map { $0 ? "yes" : "no" } ?? "—" }),
            row("Power",{ $0.status }), row("Room",{ tempText($0.indoor) }), row("Target",{ tempText($0.target) }),
            row("Mode",{ $0.modeName }), row("Fan",{ $0.fan }), row("ECO",{ $0.has("ECO") ? ($0.code("ECO")==1 ? "ON" : "OFF") : "—" }),
            row("Position ↕",{ $0.vane(true) }),row("Position ↔",{ $0.vane(false) }),
            row("Power, W",{ EnergyHistory.watts(in:$0.report).map { $0.formatted() } ?? "—" })
        ]
        let keys = Set(units.flatMap { $0.report.keys }).sorted()
        for k in keys { table.append(row(k, { val($0.report[k]) })) }
        let widths = table[0].indices.map { col in table.map { $0[col].count }.max() ?? 0 }
        for r in table {
            print(r.enumerated().map { i,s in i == r.count-1 ? s : s + String(repeating:" ",count:max(2,widths[i]-s.count+2)) }.joined())
        }
    }
}
