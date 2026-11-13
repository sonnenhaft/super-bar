import Foundation

struct ACError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias JSONObject = [String: Any]

enum DeviceService {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["TCL_DATA_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TCLBar")
    }
    static func ensure(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func name(_ device: JSONObject) -> String {
        for key in ["nickName", "nick_name", "deviceName", "device_name"] {
            if let name = device[key] as? String, !name.isEmpty { return name }
        }
        return ""
    }
    static func id(_ device: JSONObject) throws -> String {
        guard let id = (device["deviceId"] ?? device["device_id"]) as? String, !id.isEmpty else { throw ACError("Device ID missing from TCL response.") }
        return id
    }
    static func flag(_ value: Any?) -> Bool? {
        if let v = whole(value), v == 0 || v == 1 { return v == 1 }
        switch (value as? String)?.lowercased() { case "true": return true; case "false": return false; default: return nil }
    }
    static func desired(_ field: String, _ value: Int, report r: JSONObject) throws -> [String: Int] {
        let supported: Bool
        switch field {
        case "powerSwitch", "ECO", "verticalSwitch", "horizontalSwitch", "turbo", "silenceSwitch": supported = (0...1).contains(value)
        case "targetTemperature": supported = (16...30).contains(value)
        case "workMode": supported = (0...4).contains(value)
        case "windSpeed": supported = [0,2,3,4,5,6].contains(value)
        case "windSpeed7Gear": supported = (0...7).contains(value)
        case "verticalDirection": supported = (1...3).contains(value) || (8...13).contains(value)
        case "horizontalDirection": supported = (1...4).contains(value) || (8...13).contains(value)
        default: supported = false
        }
        guard supported else { throw ACError("Invalid field value: " + field) }
        func has(_ k: String) -> Bool { r[k] != nil && !(r[k] is NSNull) && whole(r[k]) != -1 }
        guard has(field) else { throw ACError("Unit does not report field " + field + ".") }
        if field == "targetTemperature", !Aircon.setpoints(in: r).contains(value) {
            throw ACError("Temperature is outside the supported range.")
        }
        var other: [String:Int] = [:]
        switch field {
        case "verticalDirection", "horizontalDirection":
            other[field.replacingOccurrences(of: "Direction", with: "Switch")] = value < 8 ? 1 : 0
        case "verticalSwitch", "horizontalSwitch":
            let key = field.replacingOccurrences(of: "Switch", with: "Direction"), pos = whole(r[key]) ?? -1
            if value == 0 {
                other[key] = (9...13).contains(pos) ? pos : 8
            } else {
                let lastSwing = key == "verticalDirection" ? 3 : 4
                other[key] = (1...lastSwing).contains(pos) ? pos : 1
            }
        case "windSpeed7Gear": other["windSpeedAutoSwitch"] = value == 0 ? 1 : 0
        case "windSpeed": other = ["turbo":0, "silenceSwitch":0, "highTemperatureWind":0]
        case "turbo" where value == 1: other = ["windSpeed":6, "silenceSwitch":0, "highTemperatureWind":0]
        case "silenceSwitch" where value == 1: other = ["windSpeed":2, "turbo":0, "highTemperatureWind":0]
        default: break
        }
        var result = other.filter { has($0.key) }
        result[field] = value
        return result
    }
    static func desired(_ fields: [(String, Int)], report: JSONObject) throws -> [String: Int] {
        // Discard superseded clicks before calculating their effects on paired settings.
        var seen = Set<String>()
        let latest = fields.reversed().filter { seen.insert($0.0).inserted }
        var projected = report
        var result: [String: Int] = [:]
        for (field, value) in latest.reversed() {
            for (key, adjustment) in try desired(field, value, report: projected) {
                result[key] = adjustment
                projected[key] = adjustment
            }
        }
        return result
    }

    // Confine each session to one worker. A burst shares discovery, credentials
    // and the inventory, but each batch reads the device's latest shadow.
    final class ControlSession {
        private let directory: URL
        private let cloud: TCLCloud
        private var devices: [JSONObject] = []
        private var validUntil: TimeInterval = 0

        init(directory: URL) {
            self.directory = directory
            cloud = TCLCloud(directory: directory)
        }

        func signIn(email: String, password: String) throws {
            try DeviceService.ensure(directory)
            try cloud.storeLogin(email: email, password: password)
            devices.removeAll()
            validUntil = 0
        }

        func read() throws -> [JSONObject] {
            try DeviceService.ensure(directory)
            do {
                devices = try cloud.connect()
                validUntil = ProcessInfo.processInfo.systemUptime + 60
                return try DeviceService.read(devices, cloud: cloud, directory: directory, energy: true)
            } catch {
                validUntil = 0
                cloud.resetSession()
                throw error
            }
        }

        func apply(id: String, fields: [(String, Int)], checkCancellation: () throws -> Void = {}) throws -> JSONObject {
            try checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= validUntil {
                devices = try cloud.connect()
                try checkCancellation()
                validUntil = ProcessInfo.processInfo.systemUptime + 60
            }
            do {
                guard let device = devices.first(where: { (try? DeviceService.id($0)) == id }) else {
                    throw ACError("Unit missing from TCL device list.")
                }
                return try DeviceService.apply(fields, to: device, cloud: cloud, checkCancellation: checkCancellation)
            } catch {
                validUntil = 0
                cloud.resetSession()
                throw error
            }
        }
    }

    private static func apply(_ fields: [(String, Int)], to device: JSONObject, cloud: TCLCloud,
                              checkCancellation: () throws -> Void = {}) throws -> JSONObject {
        try checkCancellation()
        guard flag(device["isOnline"] ?? device["is_online"]) == true else { throw ACError("Unit is offline.") }
        let deviceID = try id(device)
        let initial = try cloud.shadow(id: deviceID)
        try checkCancellation()
        guard let report = reported(initial) else { throw ACError("TCL did not return unit status.") }
        let settings = try desired(fields, report: report)

        func confirmed(_ shadow: JSONObject) -> Bool {
            guard let actual = reported(shadow) else { return false }
            let state = shadow["state"] as? JSONObject
            let pending = state?["desired"] as? JSONObject
            return settings.allSatisfy { key, value in
                // An earlier timed-out command can still be pending even
                // though the unit currently reports the newly requested value.
                let outstanding = whole(pending?[key])
                return whole(actual[key]) == value && (outstanding == nil || outstanding == value)
            }
        }
        if confirmed(initial) { return normalize(device, shadow: initial) }
        try checkCancellation()
        try cloud.publish(id: deviceID, desired: settings)
        let deadline = ProcessInfo.processInfo.systemUptime + 32
        repeat {
            Thread.sleep(forTimeInterval: 2)
            try checkCancellation()
            let shadow = try cloud.shadow(id: deviceID)
            try checkCancellation()
            if confirmed(shadow) { return normalize(device, shadow: shadow) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw ACError(name(device) + ": TCL did not confirm the setting change.")
    }
    static func reported(_ shadow: JSONObject) -> JSONObject? { (shadow["state"] as? JSONObject)?["reported"] as? JSONObject }
    static func normalize(_ device: JSONObject, shadow: JSONObject) -> JSONObject {
        let report = reported(shadow), r = report ?? [:]
        let meta = (shadow["metadata"] as? JSONObject)?["reported"] as? JSONObject ?? [:]
        func stamp(_ k: String) -> Double? { number((meta[k] as? JSONObject)?["timestamp"]) }
        func optional(_ value: Any?) -> Any { value ?? NSNull() }
        func temp(_ key: String) -> Double? { number(r[key]).flatMap { $0 == -1 ? nil : $0 } }
        let modes = ["auto","cool","dry","fan","heat"]
        let mode = whole(r["workMode"]).flatMap { modes.indices.contains($0) ? modes[$0] : nil }
        let wattKey = EnergyHistory.wattFields.first { k in EnergyHistory.watts(in: [k:r[k] ?? NSNull()]) != nil }
        var row: JSONObject = ["name":name(device), "id":(try? id(device)) ?? "", "online":optional(flag(device["isOnline"] ?? device["is_online"])),
            "power": optional(flag(r["powerSwitch"])), "indoor":optional(temp("currentTemperature")), "target":optional(temp("targetTemperature")),
            "mode":optional(mode), "reported":optional(report), "watts_reported_at":optional(wattKey.flatMap(stamp)),
            "indoor_reported_at":optional(stamp("currentTemperature").map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970:$0)) })]
        if report == nil { row["error"] = "shadow unavailable" }
        return row
    }
    @discardableResult static func run(_ args: [String], directory: URL, energy: Bool) throws -> [JSONObject] {
        try ensure(directory)
        let cloud = TCLCloud(directory: directory)
        let devices = try cloud.connect()
        var changed: JSONObject?
        if !args.isEmpty {
            let fields: [(String, Int)]
            switch (args.first, args.count) {
            case ("off", 2): fields = [("powerSwitch",0)]
            case ("on", 3):
                guard let t = Int(args[2]), (16...30).contains(t) else { throw ACError("Temperature: 16…30 °C.") }
                fields = [("powerSwitch",1),("targetTemperature",t)]
            case ("set", 4):
                guard let n = Int(args[3]) else { throw ACError("Enter a whole number.") }
                fields = [(args[2],n)]
            default: throw ACError("Usage: TCL-status.command [off name | on name 16..30 | set name field value]")
            }
            let selected = devices.filter { name($0) == args[1] }
            guard selected.count == 1, let device = selected.first else { throw ACError("Enter one exact device name.") }
            changed = try apply(fields, to: device, cloud: cloud)
        }
        return try read(devices, cloud: cloud, directory: directory, energy: energy, changed: changed)
    }
    private static func read(_ devices: [JSONObject], cloud: TCLCloud, directory: URL, energy: Bool, changed: JSONObject? = nil) throws -> [JSONObject] {
        let rows = try devices.map { device -> JSONObject in
            let id = try id(device)
            if let changed, changed["id"] as? String == id { return changed }
            return normalize(device, shadow: (try? cloud.shadow(id: id)) ?? [:])
        }
        let online = rows.filter { flag($0["online"]) == true }
        guard online.isEmpty || !online.allSatisfy({ $0["error"] != nil }) else { throw ACError("TCL did not return connected unit status.") }
        let output = directory.appendingPathComponent("tcl-status.json")
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:output.path)
        if energy { EnergySync.refresh(devices: devices, cloud: cloud, directory: directory) }
        return rows
    }
}
