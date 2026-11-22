import Foundation
import Security
import CryptoKit
import Darwin

struct WebOSTVInput: Identifiable, Equatable {
    let id: String
    let name: String
    var appID: String? = nil
}

enum WebOSTVPairingChallenge: String, Sendable {
    case pin = "PIN"
    case prompt = "PROMPT"
}

enum WebOSTVKey: String {
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", ok = "ENTER", click = "CLICK"
    case home = "HOME", back = "BACK", menu = "MENU", settings = "QMENU", exit = "EXIT"

    var message: String {
        self == .click ? "type:click\n\n" : "type:button\nname:\(rawValue)\n\n"
    }
}

enum WebOSTVPowerState: String {
    case active = "Active", standby = "Active Standby", suspend = "Suspend"
    case off = "Power Off", screenOff = "Screen Off", screenSaver = "Screen Saver"

    var isOn: Bool { self == .active || self == .screenSaver }
}

struct WebOSTVWakeReport {
    var acceptedUnicast = false
    var acceptedBroadcast = false
    var unicastFailureCodes: Set<Int32> = []
    var broadcastFailureCodes: Set<Int32> = []
    var failureCodes: Set<Int32> { unicastFailureCodes.union(broadcastFailureCodes) }

    var accepted: Bool { acceptedUnicast || acceptedBroadcast }
    var diagnostic: String {
        func result(_ accepted: Bool, _ errors: Set<Int32>) -> String {
            if accepted { return "accepted" }
            return errors.isEmpty ? "not sent" : "failed (errno " + errors.sorted().map { String($0) }.joined(separator: ", ") + ")"
        }
        return "Direct UDP: " + result(acceptedUnicast, unicastFailureCodes)
            + "; broadcast UDP: " + result(acceptedBroadcast, broadcastFailureCodes) + "."
    }
    var broadcastDenied: Bool {
        !acceptedBroadcast && (broadcastFailureCodes.contains(EACCES) || broadcastFailureCodes.contains(EPERM))
    }
}

struct WebOSTVError: LocalizedError {
    let message: String
    let requiresPairing: Bool
    let unsupported: String?
    init(_ message: String, requiresPairing: Bool = false, unsupported: String? = nil) {
        self.unsupported = unsupported
        self.message = message
        self.requiresPairing = requiresPairing
    }
    var errorDescription: String? { message }
}

actor WebOSTVRemote {
    private let host: String
    private let pairingStore: WebOSTVPairingStore
    private let makeSession: (String, Data?) -> any WebOSTVSession
    private var session: (any WebOSTVSession)?
    private var socket: (any WebOSTVSocket)?
    private var pointer: (any WebOSTVSocket)?
    private var registered = false
    private var pairingChallenge: WebOSTVPairingChallenge?
    private var pinRequestID: String?
    private var rejectedKey: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0

    private static var pairingVault: any CredentialVault {
        if CredentialAccess.usesKeychain { return CredentialAccess.shared }
        return KeychainCredentialVault()
    }

    init(host: String, credentialID: String, vault: (any CredentialVault)? = nil,
         makeSession: @escaping (String, Data?) -> any WebOSTVSession = { SecureTVSession(host: $0, expected: $1) }) {
        self.host = host
        self.pairingStore = WebOSTVPairingStore(id: credentialID, vault: vault ?? Self.pairingVault)
        self.makeSession = makeSession
    }

    static func isLocalHost(_ host: String) -> Bool {
        var parsed = in_addr()
        guard inet_pton(AF_INET, host, &parsed) == 1 else { return false }
        let ip = UInt32(bigEndian: parsed.s_addr)
        return ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8 || ip >> 16 == 0xA9FE
    }

    private static func macBytes(_ mac: String) -> [UInt8]? {
        let address = mac.replacingOccurrences(of: "-", with: ":").uppercased()
        let pieces: [Substring]
        if address.utf8.count == 12, address.allSatisfy(\.isHexDigit) {
            pieces = stride(from: 0, to: 12, by: 2).map { offset in
                address.dropFirst(offset).prefix(2)
            }
        } else {
            pieces = address.split(separator: ":", omittingEmptySubsequences: false)
        }
        guard pieces.count == 6, pieces.allSatisfy({ $0.utf8.count == 2 }) else { return nil }
        let bytes = pieces.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes[0] & 1 == 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes
    }

    static func isValidMAC(_ mac: String) -> Bool { macBytes(mac) != nil }
    static func wakePacket(_ mac: String) -> Data? {
        guard let bytes = macBytes(mac) else { return nil }
        var data = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { data.append(contentsOf: bytes) }
        return data
    }

    static func wake(host: String, macAddress: String) async throws -> WebOSTVWakeReport {
        guard isLocalHost(host), let packet = wakePacket(macAddress) else {
            throw WebOSTVError("Enter the TV’s local IPv4 address and network MAC address.")
        }
        try Task.checkCancellation()
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.ENETDOWN) }
        defer { Darwin.close(fd) }
        var enabled: Int32 = 1
        let broadcastsAllowed = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
        let broadcastOptionError: Int32? = broadcastsAllowed ? nil : errno
        var destinations: Set<String> = [host]
        if broadcastsAllowed {
            destinations.insert("255.255.255.255")
            var list: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&list) == 0 {
                defer { freeifaddrs(list) }
                var target = in_addr()
                inet_pton(AF_INET, host, &target)
                for current in sequence(first: list, next: { $0?.pointee.ifa_next }).prefix(while: { $0 != nil }) {
                    guard let interface = current?.pointee,
                          interface.ifa_flags & UInt32(IFF_UP) != 0,
                          interface.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                          let addr = interface.ifa_addr, addr.pointee.sa_family == AF_INET,
                          let mask = interface.ifa_netmask else { continue }
                    let ip = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                    let bits = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                    guard ip & bits == target.s_addr & bits else { continue }
                    var broadcast = in_addr(s_addr: ip | ~bits)
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(buffer.count)) != nil {
                        destinations.insert(String(cString: buffer))
                    }
                }
            }
        }
        var report = WebOSTVWakeReport()
        if let broadcastOptionError { report.broadcastFailureCodes.insert(broadcastOptionError) }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            for destination in destinations {
                for port: UInt16 in [9, 7] {
                    var peer = sockaddr_in()
                    peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    peer.sin_family = sa_family_t(AF_INET)
                    peer.sin_port = port.bigEndian
                    inet_pton(AF_INET, destination, &peer.sin_addr)
                    let delivered = withUnsafePointer(to: &peer) { dest in
                        dest.withMemoryRebound(to: sockaddr.self, capacity: 1) { dest in
                            packet.withUnsafeBytes { Darwin.sendto(fd, $0.baseAddress, $0.count, 0, dest, socklen_t(MemoryLayout<sockaddr_in>.size)) == packet.count }
                        }
                    }
                    if delivered {
                        if destination == host { report.acceptedUnicast = true }
                        else { report.acceptedBroadcast = true }
                    } else {
                        let failure = errno
                        if destination == host { report.unicastFailureCodes.insert(failure) }
                        else { report.broadcastFailureCodes.insert(failure) }
                    }
                }
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard report.accepted else {
            if report.broadcastDenied { throw WebOSTVError("The network denied the wake broadcast. Check local network access and the app’s multicast signing permission.") }
            throw WebOSTVError("The wake request could not be sent. Check local network permission and Wi-Fi.")
        }
        return report
    }

    var isConnected: Bool { registered && socket?.state == .running }
    func hasSavedPairing() throws -> Bool {
        guard let pairing = try savedPairing() else { return false }
        return pairing.revoked != true && rejectedKey != pairing.key
    }
    private func savedPairing() throws -> WebOSTVPairingRecord? { try pairingStore.read() }

    private func revoke(_ saved: WebOSTVPairingRecord?) {
        guard let saved else { return }
        rejectedKey = saved.key
        pairingStore.revoke(saved)
    }

    func unpair() throws {
        disconnect()
        try pairingStore.forget()
        rejectedKey = nil
    }

    func disconnect() {
        generation &+= 1
        closeSocket()
    }

    private func closeSocket() {
        pairingChallenge = nil
        pinRequestID = nil
        pointer?.close()
        socket?.close()
        session?.close()
        pointer = nil; socket = nil; session = nil; registered = false
    }

    // Each SSAP request consumes one matching reply. Keep button/refresh callers
    // FIFO even when an await yields this actor to the next button press.
    private func serial<T>(_ action: () async throws -> T) async throws -> T {
        let epoch = generation
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        return try await action()
    }

    func pair(onChallenge: @escaping @Sendable (WebOSTVPairingChallenge) async -> Void = { _ in }) async throws {
        try await serial {
            closeSocket()
            try await connect(onChallenge: onChallenge)
        }
    }
    func restore(timeout: UInt64 = 10) async throws {
        try await serial { try await connect(restoreTimeout: min(max(timeout, 2), 10)) }
    }

    // Registration owns the socket reader. Send the PIN on that same connection
    // without queuing behind the registration that's waiting for it.
    func submitPIN(_ pin: String) async throws {
        guard pairingChallenge == .pin, pinRequestID == nil, let socket, socket.state == .running else {
            throw WebOSTVError("The TV is not waiting for a code.")
        }
        let digits = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw WebOSTVError("Enter the digits shown on the TV.")
        }
        let id = UUID().uuidString
        pinRequestID = id
        do {
            try await Self.send(["id": id, "type": "request", "uri": "ssap://pairing/setPin",
                                 "payload": ["pin": digits]], on: socket)
        } catch {
            if self.socket === socket { closeSocket() }
            throw error
        }
    }

    private func connect(onChallenge: (@Sendable (WebOSTVPairingChallenge) async -> Void)? = nil,
                         restoreTimeout: UInt64 = 10) async throws {
        let explicitPairing = onChallenge != nil
        if isConnected { return }
        if socket != nil { closeSocket() }
        guard Self.isLocalHost(host), let url = URL(string: "wss://\(host):3001/") else {
            throw WebOSTVError("Enter the TV’s local IPv4 address.")
        }
        // An explicit new pairing sends no previous key. This can recover from
        // an unreadable local record or a changed certificate.
        let previous: WebOSTVPairingRecord?
        if explicitPairing {
            previous = nil
        } else {
            guard let saved = try savedPairing(), saved.revoked != true, saved.key != rejectedKey else {
                throw WebOSTVError("Pair Super Bar with this TV first.", requiresPairing: true)
            }
            previous = saved
        }
        let session = makeSession(host, previous?.certificate)
        let channel = session.open(url)
        self.session = session; socket = channel
        let deadline = Self.deadline(channel, seconds: explicitPairing ? 45 : restoreTimeout)
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await register(on: channel, previous: previous, onChallenge: onChallenge)
            } onCancel: {
                channel.close()
            }
        } catch {
            let disconnected = socket !== channel
            if !disconnected { closeSocket() }
            if Task.isCancelled || disconnected { throw CancellationError() }
            throw error
        }
    }

    private func register(on channel: any WebOSTVSocket, previous: WebOSTVPairingRecord?,
                          onChallenge: (@Sendable (WebOSTVPairingChallenge) async -> Void)?) async throws {
        let id = UUID().uuidString
        let permissions = ["CONTROL_AUDIO", "CONTROL_POWER", "CONTROL_INPUT_TV", "READ_INPUT_DEVICE_LIST",
                           "CONTROL_MOUSE_AND_KEYBOARD", "READ_RUNNING_APPS", "LAUNCH",
                           "READ_INSTALLED_APPS", "CONTROL_INPUT_TEXT"]
        var payload: [String: Any] = [
            "manifest": ["manifestVersion": 1, "permissions": permissions],
            "pairingType": onChallenge == nil ? "PROMPT" : "PIN"
        ]
        if let previous { payload["client-key"] = previous.key }
        try await Self.send(["type": "register", "id": id, "payload": payload], on: channel)
        while true {
            let message = try await Self.receive(on: channel)
            try Task.checkCancellation()
            guard socket === channel else { throw CancellationError() }
            let type = message["type"] as? String
            let info = message["payload"] as? [String: Any] ?? [:]
            if let pinRequestID, message["id"] as? String == pinRequestID {
                if type == "error" || info["returnValue"] as? Bool == false {
                    throw WebOSTVError("The TV refused the code. Choose Pair to try again.", requiresPairing: true)
                }
                // A successful setPin response is not the registration.
                continue
            }
            // Some webOS versions omit the ID on the socket's final
            // registration event. Every other message must echo our ID.
            let terminalEvent = type == "registered" && message["id"] == nil
            guard terminalEvent || message["id"] as? String == id else { continue }
            if type == "error" {
                if onChallenge == nil { revoke(previous) }
                throw WebOSTVError("Pairing was refused. Choose Pair and approve Super Bar on the TV.", requiresPairing: true)
            }
            if type == "response", info["pairingType"] != nil {
                guard let onChallenge else {
                    revoke(previous)
                    throw WebOSTVError("Pairing expired. Choose Pair to reconnect this TV.", requiresPairing: true)
                }
                guard let method = info["pairingType"] as? String,
                      let challenge = WebOSTVPairingChallenge(rawValue: method.uppercased()) else {
                    throw WebOSTVError("This TV requested an unsupported pairing method.", requiresPairing: true)
                }
                if pairingChallenge != challenge {
                    pairingChallenge = challenge
                    await onChallenge(challenge)
                }
                guard socket === channel else { throw CancellationError() }
                continue
            }
            guard type == "registered" else { continue }
            guard let key = (info["client-key"] as? String) ?? previous?.key, !key.isEmpty,
                  let certificate = session?.certificate else { throw WebOSTVError("The TV did not return a complete pairing.") }
            if key != previous?.key || certificate != previous?.certificate {
                try pairingStore.save(WebOSTVPairingRecord(key: key, certificate: certificate))
            }
            rejectedKey = nil
            pairingChallenge = nil
            pinRequestID = nil
            registered = true
            return
        }
    }

    private static func deadline(_ channel: any WebOSTVSocket, seconds: UInt64) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            channel.close()
        }
    }

    private static func send(_ json: [String: Any], on socket: any WebOSTVSocket) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private static func receive(on socket: any WebOSTVSocket) async throws -> [String: Any] {
        let data: Data
        switch try await socket.receive() {
        case .data(let bytes): data = bytes
        case .string(let string): data = Data(string.utf8)
        @unknown default: throw WebOSTVError("Unexpected TV response.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WebOSTVError("Invalid TV response.") }
        return json
    }

    private func request(_ uri: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        try await connect()
        guard let socket else { throw WebOSTVError("TV is disconnected.") }
        let id = UUID().uuidString
        let deadline = Self.deadline(socket, seconds: 8)
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await Self.send(["id": id, "type": "request", "uri": "ssap://" + uri, "payload": payload], on: socket)
                while true {
                    let message = try await Self.receive(on: socket)
                    try Task.checkCancellation()
                    guard self.socket === socket else { throw CancellationError() }
                    guard message["id"] as? String == id else { continue }
                    guard message["type"] as? String == "response", let reply = message["payload"] as? [String: Any], reply["returnValue"] as? Bool != false else {
                        throw WebOSTVError("This TV could not perform that remote command.", unsupported: message["error"] as? String)
                    }
                    return reply
                }
            } onCancel: { socket.close() }
        } catch {
            if self.socket === socket, !(error is WebOSTVError) { closeSocket() }
            throw error
        }
    }

    static func volume(from reply: [String: Any]) throws -> Int {
        let status = reply["volumeStatus"] as? [String: Any]
        let raw = reply["volume"] ?? status?["volume"]
        let volume: Int?
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == Double(value.intValue) {
            volume = value.intValue
        } else { volume = (raw as? String).flatMap(Int.init) }
        guard let volume, (0...100).contains(volume) else { throw WebOSTVError("The TV did not report its volume.") }
        return volume
    }
    func execute(_ command: WebOSTVCommand) async throws {
        try await serial {
            try command.validate()
            _ = try await request(command.uri, command.payload)
        }
    }

    /// Read real network interface addresses after registration; Bonjour IDs are not wake addresses.
    func networkMACAddresses() async throws -> [String] {
        try await serial {
            let info = try? await request("com.webos.service.connectionmanager/getinfo")
            try Task.checkCancellation()
            let interfaces = info.map(Self.networkMACAddresses(from:)) ?? []
            if !interfaces.isEmpty { return interfaces }
            let firmware = try await request("com.webos.service.update/getCurrentSWInformation")
            guard let id = firmware["device_id"] as? String, let bytes = Self.macBytes(id) else { return [] }
            return [bytes.map { String(format: "%02X", $0) }.joined(separator: ":")]
        }
    }

    static func networkMACAddresses(from reply: [String: Any]) -> [String] {
        var seen = Set<String>()
        return ["wiredInfo", "wifiInfo"].compactMap { interface in
            guard let info = reply[interface] as? [String: Any], let address = info["macAddress"] as? String,
                  let bytes = macBytes(address) else { return nil }
            let canonical = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    private var exposesBrightnessSetter = false

    func brightness() async throws -> Int? {
        guard exposesBrightnessSetter else { return nil }
        return try await serial {
            let reply = try await request("settings/getSystemSettings", ["category": "picture", "keys": ["brightness"]])
            let value = (reply["settings"] as? [String: Any])?["brightness"]
            let level = value as? Int ?? (value as? String).flatMap(Int.init)
            return level.flatMap { (0...100).contains($0) ? $0 : nil }
        }
    }

    func setBrightness(_ level: Int) async throws {
        guard exposesBrightnessSetter, (0...100).contains(level) else { throw WebOSTVError("Brightness unavailable.") }
        try await serial {
            _ = try await request("settings/setSystemSettings", ["category": "picture", "settings": ["brightness": level]])
        }
    }

    func services() async throws -> Set<String> {
        try await serial {
            let reply = try await request("api/getServiceList")
            guard let rows = reply["services"] as? [[String: Any]] else {
                throw WebOSTVError("The TV did not report its services.")
            }
            let settings = rows.first { $0["name"] as? String == "settings" }
            let methods = (settings?["methods"] as? [String]) ?? (settings?["methods"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            exposesBrightnessSetter = methods.contains("setSystemSettings")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    func applications() async throws -> [WebOSTVApplication] {
        try await serial {
            var rows: [[String: Any]] = []
            for (method, field) in [("listApps", "apps"), ("listLaunchPoints", "launchPoints")] {
                do {
                    let reply = try await request("com.webos.applicationManager/" + method)
                    rows = reply[field] as? [[String: Any]] ?? []
                    if !rows.isEmpty { break }
                } catch let error as WebOSTVError where method == "listApps" && error.unsupported != nil {
                    continue
                }
            }
            guard !rows.isEmpty else { throw WebOSTVError("The TV did not report its installed apps.") }
            var seen = Set<String>()
            return rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
                return WebOSTVApplication(id: id, name: row["title"] as? String ?? id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func foregroundApplication() async throws -> String? {
        try await serial {
            let reply = try await request("com.webos.applicationManager/getForegroundAppInfo")
            return reply["appId"] as? String
        }
    }

    func readVolume() async throws -> Int { try await serial { try Self.volume(from: await request("audio/getVolume")) } }
    func changeVolume(up: Bool) async throws {
        try await serial { _ = try await request(up ? "audio/volumeUp" : "audio/volumeDown") }
    }
    static func powerState(from payload: [String: Any]) -> WebOSTVPowerState? {
        (payload["state"] as? String).flatMap(WebOSTVPowerState.init(rawValue:))
    }

    func readPowerState() async throws -> WebOSTVPowerState? {
        try await serial {
            Self.powerState(from: try await request("com.webos.service.tvpower/power/getPowerState"))
        }
    }

    /// Some webOS versions retain SSAP in standby; a fully sleeping TV still needs WOL.
    func powerOn(_ state: WebOSTVPowerState?) async throws {
        try await serial {
            guard state?.isOn != true else { return }
            let uri = state == .screenOff ? "com.webos.service.tvpower/power/turnOnScreen" : "system/turnOn"
            _ = try await request(uri)
        }
    }

    func powerOff() async throws {
        try await serial { _ = try await request("system/turnOff"); closeSocket() }
    }
    func inputs() async throws -> [WebOSTVInput] {
        try await serial {
            let reply = try await request("tv/getExternalInputList")
            guard let rows = reply["devices"] as? [[String: Any]] else { throw WebOSTVError("The TV did not report its inputs.") }
            var seen = Set<String>()
            return rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
                let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return WebOSTVInput(id: id, name: label.flatMap { $0.isEmpty ? nil : $0 } ?? id, appID: row["appId"] as? String)
            }
        }
    }
    func selectInput(_ id: String) async throws {
        try await serial { _ = try await request("tv/switchInput", ["inputId": id]) }
    }
    func currentInput(in inputs: [WebOSTVInput]) async throws -> String? {
        guard inputs.contains(where: { $0.appID?.isEmpty == false }) else { return nil }
        return try await serial {
            let reply = try await request("com.webos.applicationManager/getForegroundAppInfo")
            guard let appID = reply["appId"] as? String, !appID.isEmpty else { return nil }
            let matches = inputs.filter { $0.appID == appID }
            return matches.count == 1 ? matches[0].id : nil
        }
    }
    func navigate(_ key: WebOSTVKey) async throws {
        try await sendPointer(key.message)
    }

    func movePointer(x: Int, y: Int) async throws {
        try await sendPointer("type:move\ndx:\(x)\ndy:\(y)\ndown:0\n\n")
    }

    private func sendPointer(_ message: String) async throws {
        try await serial {
            guard isConnected else { throw WebOSTVError("TV disconnected.") }
            if pointer == nil {
                let reply = try await request("com.webos.service.networkinput/getPointerInputSocket")
                guard let path = reply["socketPath"] as? String, let url = URL(string: path), url.scheme == "wss", url.host == host,
                      url.user == nil, url.password == nil, let session else { throw WebOSTVError("The TV did not provide a secure remote-control connection.") }
                pointer = session.open(url)
            }
            guard let pointer else { throw WebOSTVError("TV is disconnected.") }
            let deadline = Self.deadline(pointer, seconds: 8)
            defer { deadline.cancel() }
            do { try Task.checkCancellation(); try await pointer.send(.string(message)) }
            catch { pointer.close(); self.pointer = nil; throw error }
        }
    }
}
