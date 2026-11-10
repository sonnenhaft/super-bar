import Foundation
import CoreFoundation

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
