import Foundation
import CoreFoundation

enum RuntimeState: String {
    case estimating, discharging, charging, steady, unavailable, empty
}

enum RuntimeSource: String {
    case station, power
    case socHistory = "soc_history"
}

struct RuntimeEstimate {
    var state: RuntimeState
    var source: RuntimeSource?
    var backup: Bool
    var remainingSeconds: Int?
    var windowSeconds: Int?
    var dropPercent: Int?

    static let unavailable = RuntimeEstimate(state: .unavailable, source: nil, backup: false,
                                              remainingSeconds: nil, windowSeconds: nil, dropPercent: nil)

    static func atLoad(percent: Int, acWatts: Int?, dcWatts: Int?, backup: Bool) -> RuntimeEstimate {
        let seconds = AC50PAutonomy.seconds(percent: percent, acWatts: acWatts, dcWatts: dcWatts)
        let state: RuntimeState
        if seconds != nil { state = percent == 0 ? .empty : .discharging }
        else if acWatts == 0 && dcWatts == 0 { state = .steady }
        else { state = .unavailable }
        return RuntimeEstimate(state: state, source: .power, backup: backup, remainingSeconds: seconds)
    }

    // A failed read preserves the entire last reading. A successful read may
    // reuse an older discharge estimate only while it still fits this sample.
    func canCarry(_ older: RuntimeEstimate, percent: Int) -> Bool {
        guard remainingSeconds == nil, !backup, !older.backup,
              state != .steady || source != .power else { return false }
        return older.remainingSeconds != nil && older.state == (percent == 0 ? .empty : .discharging)
    }

    var json: [String: Any] {
        var value: [String: Any] = ["state": state.rawValue]
        if let source = source { value["source"] = source.rawValue }
        if backup { value["backup"] = true }
        if let seconds = remainingSeconds { value["remaining_seconds"] = seconds }
        if let seconds = windowSeconds { value["window_seconds"] = seconds }
        if let drop = dropPercent { value["drop_percent"] = drop }
        return value
    }

    static func parse(_ value: Any?, percent: Int) -> RuntimeEstimate? {
        guard let object = value as? [String: Any],
              let name = object["state"] as? String,
              let state = RuntimeState(rawValue: name) else { return nil }
        let backup: Bool
        if let raw = object["backup"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            backup = flag.boolValue
        } else { backup = false }
        func integer(_ key: String, maximum: Int) -> Int? {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0,
                  number.doubleValue <= Double(maximum) else { return nil }
            return number.intValue
        }
        // Accept the station's own hours estimate as well as calculated values;
        // keep a finite bound so malformed JSON is always safe to format.
        let remaining = integer("remaining_seconds", maximum: 7 * 24 * 60 * 60)
        if state == .discharging && remaining == nil { return nil }
        if state == .empty && (remaining != 0 || percent != 0) { return nil }
        let source = (object["source"] as? String).flatMap(RuntimeSource.init(rawValue:))
        return RuntimeEstimate(state: state, source: source, backup: backup, remainingSeconds: remaining,
                               windowSeconds: integer("window_seconds", maximum: 900),
                               dropPercent: integer("drop_percent", maximum: 100))
    }
}

struct Reading {
    var percent: Int
    var device: String
    var deviceID: String?
    var measuredAt: Date
    var acInput: Double?
    var dcInput: Double?
    var acOutput: Double?
    var dcOutput: Double?
    var outputPowerRetainedAt: Date?
    var outputWatts: Double? {
        guard outputPowerRetainedAt == nil, let ac = acOutput, let dc = dcOutput,
              (ac + dc).isFinite else { return nil }
        return ac + dc
    }

    var runtime: RuntimeEstimate
    var runtimeMeasuredAt: Date
    var runtimePercent: Int
    var runtimeCarriedForward: Bool
    var timeToFullSeconds: Int? = nil
}

private struct InvalidReading: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension Reading {
    func matchesStation(id: String?, name: String) -> Bool {
        switch (deviceID, id) {
        case let (old?, new?): return old.caseInsensitiveCompare(new) == .orderedSame
        case (nil, nil): return device == name
        default: return false
        }
    }

    static func decode(_ snapshot: [String: Any], previous: Reading?, now: Date,
                       maximumAge: TimeInterval?) throws -> Reading {
        guard snapshot["ok"] as? Bool == true,
              let number = snapshot["battery_percent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              (0.0...100.0).contains(number.doubleValue),
              snapshot["model"] as? String == "AC50P",
              let device = snapshot["device"] as? String, !device.isEmpty,
              let timestamp = snapshot["observed_at"] as? NSNumber,
              CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              timestamp.doubleValue.isFinite, timestamp.doubleValue >= 0 else {
            throw InvalidReading("Reader returned an invalid battery percentage, station identity or timestamp.")
        }
        let measuredAt = Date(timeIntervalSince1970: timestamp.doubleValue)
        let age = now.timeIntervalSince(measuredAt)
        guard age >= -30, maximumAge.map({ age <= $0 }) ?? true else {
            throw InvalidReading("Reader returned an old or invalid timestamp; waiting for a fresh sample.")
        }
        func nonnegativeNumber(_ key: String) -> Double? {
            guard let value = snapshot[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        func flag(_ key: String) -> Bool? {
            guard let value = snapshot[key] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        func wholeWatts(_ value: Double?) -> Int? {
            guard let value, let watts = UInt16(exactly: value.rounded()) else { return nil }
            return Int(watts)
        }
        let deviceID = (snapshot["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let previous = previous.flatMap { $0.matchesStation(id: deviceID, name: device) ? $0 : nil }
        let acInput = nonnegativeNumber("ac_input_w"), dcInput = nonnegativeNumber("dc_input_w")
        let acOutput = nonnegativeNumber("ac_output_w") ?? (flag("ac_on") == false ? 0 : nil)
        let dcOutput = nonnegativeNumber("dc_output_w") ?? (flag("dc_on") == false ? 0 : nil)
        let outputRetained = (acOutput == nil && previous?.acOutput != nil)
            || (dcOutput == nil && previous?.dcOutput != nil)
        let external = AC50PAutonomy.externalInput(grid: flag("grid_present"),
                                                  acWatts: wholeWatts(acInput), dcWatts: wholeWatts(dcInput))
        let percent = number.intValue
        let reported = RuntimeEstimate.parse(snapshot["runtime"], percent: percent) ?? .unavailable
        // Older snapshots used a single runtime field for both directions.
        let seconds = nonnegativeNumber("time_to_full_seconds").flatMap { Int(exactly: $0) }
            ?? (reported.state == .charging && reported.source == .station ? reported.remainingSeconds : nil)
        let chargeTime = AC50PChargeTime.seconds(reported: seconds, percent: percent,
            acIn: wholeWatts(acInput), dcIn: wholeWatts(dcInput),
            acOut: wholeWatts(acOutput), dcOut: wholeWatts(dcOutput))
        let runtime: RuntimeEstimate
        let noLoad = acOutput == 0 && dcOutput == 0 && reported.remainingSeconds == nil
        if external != false || reported.state == .charging || reported.backup || noLoad {
            // Old snapshots may include the station's time to full charge.
            // Rebuild autonomy from this observation's load before restoring it.
            runtime = .atLoad(percent: percent, acWatts: wholeWatts(acOutput),
                              dcWatts: wholeWatts(dcOutput), backup: external != false)
        } else { runtime = reported }
        let retainedRuntime = previous.flatMap { runtime.canCarry($0.runtime, percent: percent) ? $0 : nil }
        return Reading(percent: percent,
                           device: device, deviceID: deviceID,
                           measuredAt: measuredAt,
                           acInput: acInput, dcInput: dcInput,
                           acOutput: acOutput ?? previous?.acOutput, dcOutput: dcOutput ?? previous?.dcOutput,
                           outputPowerRetainedAt: outputRetained ? (previous?.outputPowerRetainedAt ?? previous?.measuredAt) : nil,
                           runtime: retainedRuntime?.runtime ?? runtime,
                           runtimeMeasuredAt: retainedRuntime?.runtimeMeasuredAt ?? measuredAt,
                           runtimePercent: retainedRuntime?.runtimePercent ?? percent,
                           runtimeCarriedForward: retainedRuntime != nil, timeToFullSeconds: chargeTime)
    }
}
