// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation

struct BluettiNativeDevice {
    let id: String
    let name: String
    var json: [String: Any]

    init(id: String, name: String, json: [String: Any]? = nil) {
        self.id = (UUID(uuidString: id)?.uuidString ?? id).lowercased()
        self.name = name
        self.json = json ?? ["id": self.id, "name": name, "model": "AC50P"]
    }
}

enum BluettiNativeFailure: Error {
    case failed(code: String, message: String)

    var code: String {
        switch self { case .failed(let code, _): return code }
    }
    var message: String {
        switch self { case .failed(_, let message): return message }
    }
}

#if os(macOS)
import Darwin

final class BluettiBluetooth {
    private static weak var active: BluettiCentral?

    /// Invoke on the main thread in the headless helper process. CoreBluetooth
    /// callbacks run on its main queue; the bounded driver pumps that RunLoop.
    static func scan(timeout: TimeInterval) throws -> [BluettiNativeDevice] {
        try validateInvocation(timeout)
        let driver = BluettiCentral(timeout: timeout, reserveCleanup: false)
        active = driver
        defer { driver.close(); active = nil }
        return try driver.scan(duration: min(6, timeout))
    }

    static func readSamples(device: String?, timeout: TimeInterval, interval: PollInterval?,
                            discovered: ([BluettiNativeDevice]) throws -> Void,
                            willRead: () throws -> Void, receive: ([String: Any]) throws -> Void) throws {
        try validateInvocation(timeout)
        let driver = BluettiCentral(timeout: timeout, reserveCleanup: true)
        active = driver
        defer { driver.close(); active = nil }
        let found = try driver.scan(duration: min(4, max(0.2, timeout - 3)))
        try discovered(found)
        let selected = try bluettiChooseDevice(found, selector: device)
        try driver.connect(selected)
        try driver.handshake()
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            try willRead()
            let registers = try driver.readRegisters()
            try receive(BluettiIoTProtocol.snapshot(registers: registers, device: selected))
            guard let interval = interval else { return }
            try driver.waitForNextRead(at: started + Double(interval.rawValue), timeout: timeout)
        }
    }

    static func requestImmediateRead() {
        active?.readRequested = true
    }

    static func cancelCurrentOperation() {
        if Thread.isMainThread { active?.cancel() }
        else { DispatchQueue.main.async { active?.cancel() } }
    }

    private static func validateInvocation(_ timeout: TimeInterval) throws {
        guard Thread.isMainThread else {
            throw BluettiNativeFailure.failed(code: "runtime", message: "Bluetooth must run on the helper's main thread.")
        }
        guard timeout.isFinite, timeout >= 1, timeout <= 120 else {
            throw BluettiNativeFailure.failed(code: "arguments", message: "Bluetooth timeout must be between 1 and 120 seconds.")
        }
    }
}

final class BluettiBluetoothLock {
    private(set) var descriptor: Int32 = -1

    init(directory: URL) throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700]) }
        catch { throw BluettiCommandError("filesystem", "Cannot create cache directory: \(error.localizedDescription)") }
        descriptor = directory.appendingPathComponent("bluetooth.lock").path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw BluettiCommandError("filesystem", "Cannot open Bluetooth lock: \(BluettiFiles.systemError())") }
        if fchmod(descriptor, mode_t(0o600)) != 0 {
            let reason = BluettiFiles.systemError()
            release()
            throw BluettiCommandError("filesystem", "Cannot protect Bluetooth lock: \(reason)")
        }
        if Self.tryExclusive(descriptor) != 0 {
            let number = errno
            release()
            if number == EWOULDBLOCK || number == EAGAIN {
                throw BluettiCommandError("busy", "Another BluettiBar Bluetooth read is already running. Use bluetti cached or wait for it to finish.")
            }
            throw BluettiCommandError("filesystem", "Cannot lock Bluetooth reader: \(BluettiFiles.systemError(number))")
        }
    }

    static func tryExclusive(_ descriptor: Int32) -> Int32 {
        return bluetti_flock(descriptor, LOCK_EX | LOCK_NB)
    }

    func release() {
        if descriptor >= 0 { _ = close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
#endif

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
