// Run on the Mac with `swift Scripts/check-bluetti.swift`.
// Use the installed app's read-only helper and its normal Bluetooth lock.
import Foundation
import Security
import LocalAuthentication

let home = FileManager.default.homeDirectoryForCurrentUser
let executable = home.appendingPathComponent("Applications/Super Bar.app/Contents/MacOS/SuperBar")
let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
let now = Date()

func preferenceData(_ domain: String, _ key: String) -> Data? {
    let url = preferences.appendingPathComponent(domain + ".plist")
    if let data = try? Data(contentsOf: url),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let value = plist[key] as? Data { return value }
    return UserDefaults(suiteName: domain)?.data(forKey: key)
}

func decoded(_ data: Data?) -> [String: Any] {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

func run(_ arguments: [String]) -> [String: Any] {
    let process = Process(), output = Pipe()
    process.executableURL = executable
    process.arguments = ["--bluetti-helper"] + arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["code": "launch_failure"] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = decoded(data)
    return result.isEmpty ? ["code": "invalid_reply"] : result
}

func failure(_ result: [String: Any]) -> String {
    let known = ["arguments", "busy", "filesystem", "bluetooth", "permission", "not_found",
                 "timeout", "stale", "invalid_data", "launch_failure", "invalid_reply"]
    let code = result["code"] as? String ?? ""
    let message = (result["error"] as? String ?? "").lowercased()
    if code == "bluetooth" {
        if message.contains("permission") || message.contains("allow bluetooth") || message.contains("unauthorized") { return "Bluetooth permission denied" }
        if message.contains("bluetooth is off") { return "Bluetooth radio off" }
        if message.contains("does not support") || message.contains("unavailable") { return "Bluetooth unavailable to this process" }
    }
    return known.contains(code) ? code : "unavailable"
}

func checkCloudAccount(allowInteraction: Bool) {
    let consent = UserDefaults(suiteName: "local.SuperBar")?.bool(forKey: "keychain.applicationConsent") == true
    guard allowInteraction || consent else {
        print("BLUETTI Keychain: access unavailable. Run with --allow-keychain to authorize.")
        return
    }
    func read(_ attributes: [String: Any], data: Bool = false) -> (OSStatus, Data?) {
        var query = attributes
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        query[(data ? kSecReturnData : kSecReturnRef) as String] = true
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecParam {
            // A command-line launch may not have a usable default search list.
            var keychain: SecKeychain?
            let lookup = SecKeychainCopyDefault(&keychain)
            guard lookup == errSecSuccess, let keychain else { return (lookup, nil) }
            query[kSecMatchSearchList as String] = [keychain]
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        return (status, data ? item as? Data : nil)
    }
    func label(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "present"
        case errSecItemNotFound: return "not found (\(status))"
        default: return "unavailable (\(status))"
        }
    }
    let service: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.sonnenhaft.superbar"]
    let account = kSecAttrAccount as String
    let (aggregate, data) = read(service.merging([account: "accounts-v1"]) { _, new in new }, data: true)
    if aggregate == errSecSuccess {
        // Inspect only the BLUETTI field in the app's aggregate record.
        struct Accounts: Decodable {
            let session: Data?
            enum CodingKeys: String, CodingKey { case session = "bluetti-session" }
        }
        if let data, let accounts = try? JSONDecoder().decode(Accounts.self, from: data) {
            print("Super Bar accounts-v1 / bluetti-session: " + (accounts.session?.isEmpty == false ? "present" : "not found"))
        } else { print("Super Bar accounts-v1: invalid record") }
    } else { print("Super Bar accounts-v1:", label(aggregate)) }
    let legacy = read(service.merging([account: "bluetti-session"]) { _, new in new })
    print("Super Bar separate bluetti-session:", label(legacy.0))
    // Exact official developer and SSO hosts. Only test for existence of a
    // website login. It does not provide Open Platform developer signing keys.
    for host in ["open.bluetti.com", "sso.bluettipower.com"] {
        let login = read([kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: host])
        print("Website login for \(host):", label(login.0))
    }
    print("Cloud archive: no documented AC50P history endpoint verified. No cloud request sent.")
}

checkCloudAccount(allowInteraction: CommandLine.arguments.contains("--allow-keychain"))
if CommandLine.arguments.contains("--keychain-only") { exit(0) }

let registry = decoded(preferenceData("com.local.bluebar.aliases", "stationDirectory.v1"))
let records = registry["stations"] as? [[String: Any]] ?? []
var ids = Set(records.compactMap { ($0["deviceID"] as? String).flatMap(UUID.init(uuidString:)) })
let scan = run(["scan", "--timeout", "8"])
if scan["ok"] as? Bool == true {
    let nearby = scan["devices"] as? [[String: Any]] ?? []
    ids.formUnion(nearby.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
    print("BLE scan: \(nearby.count) nearby AC50P")
} else {
    print("BLE scan: " + failure(scan))
}
let history = decoded(preferenceData("local.SuperBar", "bluetti.powerHistory"))
let cache = decoded(preferenceData("local.SuperBar", "retainedReadings.v1"))["readings"] as? [String: [String: Any]] ?? [:]
print("Known or discovered AC50P: \(ids.count)")
var recentlyRead: [String: (label: String, timestamp: Double)] = [:]
var confirmedLive = false
for (offset, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
    let key = "id:" + id.uuidString.lowercased()
    let power = history[key] as? [[String: Any]] ?? []
    let dates = power.compactMap { ($0["time"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) }
    let daily = dates.filter { (0...86_400).contains(now.timeIntervalSince($0)) }
    let hourly = daily.filter { now.timeIntervalSince($0) <= 3_600 }
    let stationAlias = records.first { ($0["deviceID"] as? String)?.lowercased() == id.uuidString.lowercased() }?["alias"] as? String
    // An advertisement may contain a full serial number. Print only plain
    // user-defined room names; otherwise use the anonymous station number.
    let label = stationAlias.flatMap { name in
        !name.isEmpty && name.count <= 48 && name.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" } ? name : nil
    } ?? "Station \(offset + 1)"
    print("\(label) local output history: \(hourly.count) samples in 60m, \(daily.count) in 24h")
    if let saved = cache[key], saved["demo"] as? Bool != true, let observed = saved["observed_at"] as? Double {
        if (0...180).contains(now.timeIntervalSince1970 - observed) {
            recentlyRead[key] = (label, observed)
        }
        print("\(label) retained sample: " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: observed)))
        if let percent = saved["battery_percent"] as? Int { print("  retained charge: \(percent)%") }
        if let ac = saved["ac_output_w"] as? Int, let dc = saved["dc_output_w"] as? Int {
            print("  retained output: \(ac + dc) W")
        }
    }
    guard scan["ok"] as? Bool == true else {
        print("\(label) live status: blocked by BLE scan (" + failure(scan) + ")")
        continue
    }
    let result = run(["status", "--device", id.uuidString, "--timeout", "20"])
    guard result["ok"] as? Bool == true, let percent = result["battery_percent"] as? Int else {
        print("\(label) live status: " + failure(result))
        continue
    }
    confirmedLive = true
    let measured = (result["observed_at"] as? Double).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? "unknown"
    print("\(label) live BLE: \(percent)% at \(measured)")
    for field in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w", "time_to_full_seconds"] {
        if let value = result[field] as? Int { print("  \(field): \(value)") }
    }
    if let seconds = (result["runtime"] as? [String: Any])?["remaining_seconds"] as? Int {
        print("  remaining_seconds: \(seconds)")
    }
    print("  temperature field: \(result.keys.contains { $0.contains("temp") })")
    print("  station history field: \(result.keys.contains { $0.contains("history") })")
}

// The running app owns the Bluetooth connection while streaming. Observe its
// next hardware timestamp without acquiring the radio or changing its selection.
if !confirmedLive && !recentlyRead.isEmpty {
    let began = Date()
    let deadline = began.addingTimeInterval(75)
    print("Observing the running Super Bar for its next Bluetooth sample…")
    repeat {
        Thread.sleep(forTimeInterval: 2)
        let fresh = decoded(preferenceData("local.SuperBar", "retainedReadings.v1"))["readings"] as? [String: [String: Any]] ?? [:]
        for (key, baseline) in recentlyRead {
            guard let row = fresh[key], row["demo"] as? Bool != true,
                  let timestamp = row["observed_at"] as? Double, timestamp > baseline.timestamp,
                  timestamp >= began.timeIntervalSince1970, timestamp <= Date().timeIntervalSince1970 + 2,
                  let percent = row["battery_percent"] as? Int, (0...100).contains(percent) else { continue }
            let measured = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
            var values = ["\(percent)%"]
            if let ac = row["ac_output_w"] as? Int, let dc = row["dc_output_w"] as? Int {
                values.append("\(ac + dc) W output")
            }
            print("\(baseline.label) NEW Bluetooth reading from the running Super Bar at \(measured): " + values.joined(separator: ", "))
            confirmedLive = true
        }
    } while !confirmedLive && Date() < deadline
    if !confirmedLive { print("No new Bluetooth measurement observed during the check.") }
}
print("Native AC50P profile: live holding registers; no mapped battery-temperature or on-device daily archive request")
if !confirmedLive { exit(1) }
