import Foundation
import SwiftUI

let tclModes = [(0, "Auto"), (1, "Cool"), (2, "Dry"), (3, "Fan"), (4, "Heat")]
let verticalStops = ["Up", "Upper middle", "Center", "Lower middle", "Down"]
let horizontalStops = ["Left", "Left of center", "Center", "Right of center", "Right"]
func number(_ value: Any?) -> Double? {
    let n: Double?
    if let x = value as? NSNumber { n = x.doubleValue } else if let s = value as? String { n = Double(s) } else { n = nil }
    return n.flatMap { $0.isFinite ? $0 : nil }
}
func whole(_ value: Any?) -> Int? {
    guard let n = number(value), n == n.rounded(), abs(n) < 1e8 else { return nil }
    return Int(n)
}
func tempText(_ n: Double?) -> String {
    guard let n = n else { return "—" }
    return n.formatted(.number.precision(.fractionLength(0...1))) + "°"
}

struct Aircon: Identifiable {
    let name: String
    let id: String
    let online: Bool?, power: Bool?
    let indoor: Double?, target: Double?
    let report: [String: Any]
    let modeName: String
    let sensorTime: Date?
    let failed: Bool
    init?(_ row: [String: Any]) {
        guard let name = row["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        id = (row["id"] as? String) ?? name
        online = row["online"] as? Bool; power = row["power"] as? Bool
        indoor = number(row["indoor"]); target = number(row["target"])
        report = row["reported"] as? [String: Any] ?? [:]
        let words = ["auto":"Auto", "cool":"Cool", "heat":"Heat", "dry":"Dry", "fan":"Fan"]
        let code = whole(report["workMode"])
        modeName = tclModes.first { $0.0 == code }?.1 ?? words[(row["mode"] as? String) ?? ""] ?? "—"
        sensorTime = (row["indoor_reported_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        failed = row["error"] is String
    }
    func has(_ key: String) -> Bool { report[key] != nil && !(report[key] is NSNull) && number(report[key]) != -1 }
    func code(_ key: String) -> Int? { whole(report[key]) }
    var setpoints: [Int] { Self.setpoints(in: report) }
    static func setpoints(in report: [String: Any]) -> [Int] {
        let low = whole(report["lowerTemperatureLimit"]).flatMap { (16...30).contains($0) ? $0 : nil } ?? 16
        let high = whole(report["upperTemperatureLimit"]).flatMap { (16...30).contains($0) ? $0 : nil } ?? 30
        return low <= high ? Array(low...high) : Array(16...30)
    }
    var fanField: String { has("windSpeed7Gear") ? "windSpeed7Gear" : "windSpeed" }
    var fanOptions: [(Int, String)] {
        fanField == "windSpeed7Gear" ? [(0,"Auto"),(1,"Minimum"),(2,"Low"),(3,"Medium-low"),(4,"Medium"),(5,"Medium-high"),(6,"High"),(7,"Turbo")] :
          [(0,"Auto"),(2,"Low"),(3,"Medium-low"),(4,"Medium"),(5,"Medium-high"),(6,"High")]
    }
    var fan: String {
        if code("turbo") == 1 { return "Turbo" }
        if code("silenceSwitch") == 1 { return "Silent" }
        if fanField == "windSpeed7Gear", code("windSpeedAutoSwitch") == 1 { return "Auto" }
        guard let n = code(fanField) else { return "—" }
        return fanOptions.first { $0.0 == n }?.1 ?? "Code " + String(n)
    }
    var manualFanCodes: [Int] {
        if fanField == "windSpeed7Gear" { return Array(1...7) }
        return (has("silenceSwitch") ? [1] : []) + Array(2...6) + (has("turbo") ? [7] : [])
    }
    var automaticFan: Bool {
        code(fanField) == 0 || (fanField == "windSpeed7Gear" && code("windSpeedAutoSwitch") == 1)
    }
    var manualFanCode: Int? {
        if code("turbo") == 1 { return 7 }
        if code("silenceSwitch") == 1 { return 1 }
        guard let level = code(fanField), manualFanCodes.contains(level) else { return nil }
        return level
    }
    func fanLabel(_ level: Int) -> String {
        if level == 1 && has("silenceSwitch") { return "Silent" }
        if level == 7 { return "Turbo" }
        return fanOptions.first { $0.0 == level }?.1 ?? "—"
    }
    // 0 is automatic. The classic fan protocol expresses quiet and turbo as
    // flags paired with low/high speed, whereas the seven-gear model has steps.
    func fanChanges(_ level: Int) -> [(String, Int)] {
        let seven = fanField == "windSpeed7Gear"
        let speed = seven || level == 0 ? level : min(6, max(2, level))
        var fields = [(fanField, speed)]
        if has("silenceSwitch") && (seven || level == 1) {
            fields.append(("silenceSwitch", level == 1 ? 1 : 0))
        }
        if has("turbo") && (seven || level == 7) {
            fields.append(("turbo", level == 7 ? 1 : 0))
        }
        return fields
    }
    var acTemperature: String {
        guard online == true, !failed else { return "—" }
        return power == false ? "OFF" : tempText(target)
    }
    var status: String {
        if online == false { return "Offline" }
        if failed { return "No readings" }
        return power.map { $0 ? "ON" : "OFF" } ?? "Unknown"
    }
    func vane(_ vertical: Bool) -> String {
        let prefix = vertical ? "vertical" : "horizontal"
        let code = self.code(prefix + "Direction")
        if let code = code, (1...4).contains(code), self.code(prefix + "Switch") == 0 { return "Stopped · angle unknown" }
        if let code = code, (9...13).contains(code) { return (vertical ? verticalStops : horizontalStops)[code - 9] }
        if code == 8 { return "Stopped · angle unknown" }
        let swing = vertical ? ["Up and down", "Upper zone", "Lower zone"] : ["Left to right", "Left zone", "Center zone", "Right zone"]
        if let code = code, (1...swing.count).contains(code) { return swing[code-1] }
        if self.code(prefix + "Switch") == 1 { return "Swing" }
        return code.map { "Code " + String($0) } ?? "—"
    }
}

enum CoolingPreset {
    case quiet, turbo

    var label: String { self == .quiet ? "22° · Quiet" : "16° · Turbo" }
    private var degrees: Int { self == .quiet ? 22 : 16 }

    func fields(for ac: Aircon) -> [(String, Int)]? {
        guard ac.has("powerSwitch"), ac.has("workMode"), ac.has("targetTemperature"),
              ac.setpoints.contains(degrees) else { return nil }
        var fields = [("powerSwitch", 1), ("workMode", 1), ("targetTemperature", degrees)]
        if ac.has("ECO") { fields.append(("ECO", 0)) }
        guard ac.has(ac.fanField), let level = self == .quiet ? ac.manualFanCodes.first : ac.manualFanCodes.last else { return nil }
        fields += ac.fanChanges(level)
        return fields
    }
    func isSelected(on ac: Aircon) -> Bool {
        guard let fields = fields(for: ac), let values = try? DeviceService.desired(fields, report: ac.report) else { return false }
        return values.allSatisfy { ac.code($0.key) == $0.value }
    }
    func details(for ac: Aircon) -> String {
        if fields(for: ac) == nil { return "This unit does not support this preset." }
        let mode: String
        if self == .quiet { mode = ac.has("silenceSwitch") ? "quiet mode" : "minimum fan" }
        else { mode = ac.has("turbo") || ac.has("windSpeed7Gear") ? "turbo" : "maximum fan" }
        return "Cool to " + String(degrees) + " °C, " + mode
    }
}

final class ClimateStore: ObservableObject {
    private struct Edit {
        let field: String
        let value: Int
        let label: String
    }

    private struct Batch {
        var deviceID: String
        let name: String
        var edits: [Edit]
        var fields: [(String, Int)] { edits.map { ($0.field, $0.value) } }

        mutating func add(_ edit: Edit) {
            // Order matters for related fields such as turbo and fan speed.
            edits.removeAll { $0.field == edit.field }
            edits.append(edit)
        }
    }

    @Published private(set) var devices: [Aircon] = []
    @Published var selection = UserDefaults.standard.string(forKey: "selectedAirconID") ?? UserDefaults.standard.string(forKey: "selectedAirconName") ?? ""
    @Published private(set) var needsSignIn = false
    @Published private(set) var refreshing = false
    @Published private(set) var command: String?
    @Published private(set) var statusDate: Date?
    @Published private(set) var problem: String?
    @Published private(set) var offline = true
    @Published private(set) var didRead = false

    let directory: URL
    let history: EnergyHistory
    private let worker = DispatchQueue(label: "ru.tclbar.cloud", qos: .userInitiated)
    private let session: DeviceService.ControlSession
    private let fetch: () throws -> [JSONObject]
    private let apply: (String, [(String, Int)]) throws -> JSONObject
    private let batchingDelay: TimeInterval
    // Only the main queue changes these. The worker gets an immutable batch.
    private var confirmedRows: [JSONObject] = []
    private var active: Batch?
    private var pending: [Batch] = []
    private var collecting = false
    private var refreshRequested = false
    private var commandError: String?
    private var lastManualFan: [String: Int] = [:]
    private var timer: Timer?

    var selected: Aircon? { devices.first { $0.id == selection } ?? devices.first { $0.name == selection } ?? devices.first }

    init(directory: URL = DeviceService.directory, batchingDelay: TimeInterval = 0.25,
         fetch: (() throws -> [JSONObject])? = nil,
         apply: ((String, [(String, Int)]) throws -> JSONObject)? = nil) {
        self.directory = directory
        let env = ProcessInfo.processInfo.environment
        let hasSSO = !(env["TCL_SSO_ID"] ?? "").isEmpty && !(env["TCL_SSO_TOKEN"] ?? "").isEmpty
        needsSignIn = !hasSSO && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".tcl-auth.json").path)
        history = EnergyHistory(directory: directory)
        self.batchingDelay = batchingDelay
        let session = DeviceService.ControlSession(directory: directory)
        self.session = session
        self.fetch = fetch ?? { try session.read() }
        self.apply = apply ?? { try session.apply(id: $0, fields: $1) }

        let file = directory.appendingPathComponent("tcl-status.json")
        worker.async {
            guard let data = try? Data(contentsOf: file),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [JSONObject] else { return }
            let timestamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            DispatchQueue.main.async {
                if !self.didRead { self.accept(rows, at: timestamp) }
            }
        }
    }
    func signIn(email: String, password: String, completion: @escaping (String?) -> Void) {
        worker.async {
            let result = Result { try self.session.signIn(email: email, password: password) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.problem = nil
                    self.commandError = nil
                    self.needsSignIn = false
                    self.refresh()
                    completion(nil)
                case .failure(let error): completion(error.localizedDescription)
                }
            }
        }
    }
    func select(_ ac: Aircon) {
        guard selection != ac.id else { return }
        selection = ac.id
        UserDefaults.standard.set(ac.id, forKey: "selectedAirconID")
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func reportedDevice(id: String) -> Aircon? {
        confirmedRows.first { Self.id(of: $0) == id }.flatMap(Aircon.init)
    }
    func isPending(id: String) -> Bool {
        active?.deviceID == id || pending.contains { $0.deviceID == id }
    }
    private static func id(of row: JSONObject) -> String? {
        (row["id"] ?? row["name"]) as? String
    }
    private func accept(_ rows: [JSONObject], at timestamp: Date?) {
        // Early CLI snapshots had only a name. Resolve edits made during
        // the first refresh only when that name identifies a single unit.
        for index in pending.indices {
            let batch = pending[index]
            guard confirmedRows.contains(where: { $0["id"] == nil && $0["name"] as? String == batch.deviceID }) else { continue }
            let matches = rows.filter { $0["name"] as? String == batch.name }
            if matches.count == 1, let id = matches[0]["id"] as? String { pending[index].deviceID = id }
        }
        confirmedRows = rows
        didRead = true
        statusDate = timestamp
        history.ingest(rows)
        updateDisplay()
        if let resolved = selected, selection != resolved.id { selection = resolved.id }
    }

    private func updateDisplay() {
        let batches = [active].compactMap { $0 } + pending
        devices = confirmedRows.compactMap { original in
            var row = original
            var report = row["reported"] as? JSONObject ?? [:]
            for batch in batches where batch.deviceID == Self.id(of: row) {
                for edit in batch.edits {
                    let patch = (try? DeviceService.desired(edit.field, edit.value, report: report)) ?? [edit.field: edit.value]
                    for (key, value) in patch { report[key] = value }
                }
                row["reported"] = report
                if let power = DeviceService.flag(report["powerSwitch"]) { row["power"] = power }
                if let target = number(report["targetTemperature"]) { row["target"] = target }
            }
            return Aircon(row)
        }
        let queued = pending.reduce(0) { $0 + $1.edits.count }
        if let active {
            var seen = Set<String>()
            let labels = active.edits.map(\.label).filter { seen.insert($0).inserted }.joined(separator: ", ")
            command = active.name + " · " + labels + (queued > 0 ? " · queued " + String(queued) : " · sending")
        } else {
            command = pending.first.map { $0.name + " · queued " + String(queued) }
        }
    }
    func set(_ ac: Aircon, _ field: String, _ value: Int, _ description: String) {
        enqueue(ac, [(field, value)], label: description)
    }
    func setTemperature(_ ac: Aircon, _ degrees: Int) {
        var edits = [("targetTemperature", degrees)]
        if ac.power == false { edits.insert(("powerSwitch", 1), at: 0) }
        enqueue(ac, edits, label: "Temperature")
    }
    func preset(_ ac: Aircon, _ preset: CoolingPreset) {
        if let fields = preset.fields(for: ac) { enqueue(ac, fields, label: preset.label) }
    }
    func fanLevel(for ac: Aircon) -> Int {
        ac.manualFanCode ?? lastManualFan[ac.id] ?? 4
    }
    func setFan(_ ac: Aircon, level: Int) {
        guard ac.manualFanCodes.contains(level) else { return }
        lastManualFan[ac.id] = level
        enqueue(ac, ac.fanChanges(level), label: "Fan")
    }
    func autoFan(_ ac: Aircon, enabled: Bool) {
        if enabled {
            if let previous = ac.manualFanCode { lastManualFan[ac.id] = previous }
            enqueue(ac, ac.fanChanges(0), label: "Auto")
        } else {
            setFan(ac, level: fanLevel(for: ac))
        }
    }
    private func enqueue(_ ac: Aircon, _ fields: [(String, Int)], label: String) {
        guard ac.online == true, !ac.failed else { return }
        let index = pending.firstIndex { $0.deviceID == ac.id } ?? pending.count
        if index == pending.count { pending.append(Batch(deviceID: ac.id, name: ac.name, edits: [])) }
        for (field, value) in fields {
            pending[index].add(Edit(field: field, value: value, label: label))
        }
        commandError = nil
        problem = nil
        updateDisplay()
        guard !collecting else { return }
        collecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + batchingDelay) { [weak self] in
            self?.collecting = false
            self?.advance()
        }
    }
    func manualRefresh() { refreshRequested = true; advance() }
    func refresh() {
        if refreshing { return } // The current read already covers this request.
        refreshRequested = true
        advance()
    }
    private func advance() {
        guard active == nil, !refreshing else { return }
        if !pending.isEmpty {
            guard !collecting else { return }
            let batch = pending.removeFirst()
            active = batch
            updateDisplay()
            worker.async {
                let result = Result { try self.apply(batch.deviceID, batch.fields) }
                DispatchQueue.main.async { self.finish(batch, result: result) }
            }
        } else if refreshRequested {
            refreshRequested = false
            refreshing = true
            worker.async {
                let result = Result { try self.fetch() }
                DispatchQueue.main.async {
                    self.refreshing = false
                    switch result {
                    case .success(let rows):
                        self.needsSignIn = false
                        self.offline = false
                        self.accept(rows, at: Date())
                        self.problem = self.commandError
                    case .failure(let error):
                        if (error as? TCLCloudError)?.needsSignIn == true { self.needsSignIn = true }
                        self.offline = true
                        self.problem = self.commandError ?? error.localizedDescription
                    }
                    self.advance()
                }
            }
        }
    }
    private func finish(_ batch: Batch, result: Result<JSONObject, Error>) {
        active = nil
        switch result {
        case .success(let row):
            if let index = confirmedRows.firstIndex(where: { Self.id(of: $0) == batch.deviceID }) {
                confirmedRows[index] = row
            }
            offline = false
            statusDate = Date()
            history.ingest(confirmedRows)
            // Reconcile other TCL clients and save the snapshot once the burst finishes.
            refreshRequested = true
        case .failure(let error):
            commandError = batch.name + " · " + error.localizedDescription
            problem = commandError
            refreshRequested = true
        }
        updateDisplay()
        advance()
    }
}
