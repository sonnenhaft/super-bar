import Foundation

// Exact IDs precede exact names, then partial names; selection is never arbitrary.
func bluettiChooseDevice(_ devices: [BluettiNativeDevice], selector: String?) throws -> BluettiNativeDevice {
    let eligible = devices.filter { ($0.json["model"] as? String) == "AC50P" }
    let matches: [BluettiNativeDevice]
    if let value = selector {
        let ids = eligible.filter { $0.id.caseInsensitiveCompare(value) == .orderedSame }
        if !ids.isEmpty { matches = ids }
        else {
            let names = eligible.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
            matches = names.isEmpty ? eligible.filter { $0.name.lowercased().contains(value.lowercased()) } : names
        }
    } else { matches = eligible }
    guard !matches.isEmpty else {
        throw BluettiNativeFailure.failed(code: "not_found", message: "No matching AC50P found. Enable Bluetooth on the station, stay nearby, and fully close the BLUETTI phone app.")
    }
    guard matches.count == 1 else {
        throw BluettiNativeFailure.failed(code: "ambiguous", message: "Multiple AC50P stations match: \(matches.map { $0.name }.joined(separator: ", ")). Run bluetti scan and pass --device with one full name or ID.")
    }
    let chosen = matches[0]
    // The native driver connects directly to the selected peripheral's ID.
    // Even identical advertised names are safe when a station row supplied its ID.
    if let selector, chosen.id.caseInsensitiveCompare(selector) == .orderedSame { return chosen }
    guard eligible.filter({ $0.name.contains(chosen.name) }).count == 1 else {
        throw BluettiNativeFailure.failed(code: "ambiguous", message: "Nearby stations have indistinguishable Bluetooth names. Keep only the intended station in range.")
    }
    return chosen
}
