import SwiftUI
#if os(iOS)
import Network
import WidgetKit
#endif

/// Account IDs and local service IDs come from different namespaces.
struct TelevisionLink: Codable, Equatable {
    let id: String
    var name: String
    var host: String
    var mac: String?
    var discoveryID: String?
    var pairingID: String?
    var wakeAddressConfirmed: Bool? = nil
    var networkMACs: [String]? = nil
    var customName: String? = nil
}

@MainActor final class LGTelevisionStore: ObservableObject {
    @Published private(set) var links: [String: TelevisionLink]
    @Published private(set) var nearby: [WebOSTVEndpoint] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanMessage: String?
    @Published var selectedID: String?
    enum Connection: Equatable {
        case disconnected, connecting, awaitingPIN, awaitingApproval, connected
    }
    @Published private(set) var connection: Connection = .disconnected
    private(set) var connected: Bool {
        get { connection == .connected }
        set { connection = newValue ? .connected : .disconnected }
    }
    @Published private(set) var volume: Int?
    @Published private(set) var inputs: [WebOSTVInput] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var busy = false
    @Published private(set) var pinTV: String?
    @Published private(set) var submittingPIN = false
    @Published private(set) var status: String?
    @Published private(set) var wakeDiagnostics: [String: String] = [:]
    @Published private var observedPower: [String: Bool] = [:]
    @Published private(set) var applications: [WebOSTVApplication] = []
    @Published private(set) var foregroundApp: String?
    @Published private(set) var services: Set<String> = []
    @Published private(set) var featureMessage: String?
    private var unsupportedCommands: Set<String> = []
    private var lastVolume: [String: Int]
    private var powerDate: [String: Date] = [:]
    private var pointerTask: Task<Void, Never>?
    private var pointerDelta = (x: 0, y: 0)
    @Published private var brightness: Int?
    private var pointerFailed = false

    private static let linkKey = "lg.tv.localLinks.v1"
    private let defaults: UserDefaults
    private var remote: WebOSTVRemote?
    private var remoteID: String?
    private var queue: [TelevisionAction] = []
    private var sending: Task<Void, Never>?
    private var volumeRevision = 0
    private var scanID: UUID?
    private var preservingWakeResult = false
    private var retryRestore = true
    private var restoreAfter = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastVolume = defaults.dictionary(forKey: "lg.tv.lastVolume.v1") as? [String: Int] ?? [:]
        wakeDiagnostics = defaults.dictionary(forKey: "lg.tv.wakeDiagnostics.v1") as? [String: String] ?? [:]
        let stored = defaults.data(forKey: Self.linkKey).flatMap {
            try? JSONDecoder().decode([String: TelevisionLink].self, from: $0)
        } ?? [:]
        links = stored.mapValues { old in
            var link = old
            guard link.wakeAddressConfirmed == nil else { return link }
            // Older builds copied Bonjour device IDs into the wake address.
            if let address = Self.normalizedMAC(link.mac), link.discoveryID != nil,
               address == Self.normalizedMAC(link.discoveryID) || UInt8(address.prefix(2), radix: 16).map({ $0 & 2 != 0 }) == true {
                link.mac = nil
            }
            link.wakeAddressConfirmed = link.mac != nil
            return link
        }
        if links != stored, let data = try? JSONEncoder().encode(links) { defaults.set(data, forKey: Self.linkKey) }
        #if os(iOS)
        for tv in WidgetCache.read().televisions ?? [] where links[tv.id] != nil && lastVolume[tv.id] == nil {
            if let value = tv.volume, (0...100).contains(value) { lastVolume[tv.id] = value }
        }
        #endif
        selectedID = defaults.string(forKey: "lg.tv.selectedID")

    }

    static func accountID(_ device: LGAccountTelevision) -> String { "account." + device.id }
    private static func normalizedMAC(_ value: String?) -> String? {
        guard let value, WebOSTVRemote.isValidMAC(value) else { return nil }
        return value.filter(\.isHexDigit).lowercased()
    }

    func linkedID(_ endpoint: WebOSTVEndpoint, accounts: [LGAccountTelevision]) -> String {
        let mac = Self.normalizedMAC(endpoint.macAddress)
        if let account = accounts.first(where: { account in
            let saved = links[Self.accountID(account)]
            return saved?.discoveryID == endpoint.id || (mac != nil && Self.normalizedMAC(account.macAddress) == mac)
        }) { return Self.accountID(account) }
        if let bound = links.values.first(where: { $0.discoveryID == endpoint.id }) { return bound.id }
        if let manual = links.values.first(where: { $0.discoveryID == nil && $0.host == endpoint.host }) { return manual.id }
        return "local." + endpoint.id
    }

    func items(_ accounts: [LGAccountTelevision]) -> [TelevisionItem] {
        var items: [TelevisionItem] = []
        func append(_ id: String, name: String, online: Bool?, mac: String?) {
            let link = links[id]
            let active = remoteID == id
            let live = active && connected
            let wake = link != nil && ([link?.mac ?? mac].compactMap { $0 } + (link?.networkMACs ?? [])).contains { Self.normalizedMAC($0) != nil }
            let power = live ? observedPower[id] : observedPower[id] == false ? false : nil
            items.append(TelevisionItem(id: id, name: link?.customName ?? name, online: live ? true : online,
                power: power, powerDate: powerDate[id], volume: (live ? volume : nil) ?? lastVolume[id], brightness: live ? brightness : nil, liveVolume: live && volume != nil, pointerAvailable: !pointerFailed,
                connected: live, canPair: link != nil, canWake: wake,
                sources: live ? inputs.map { TelevisionInput(id: $0.id, name: $0.name) } : [],
                selectedSourceID: live ? selectedSourceID : nil,
                apps: live ? applications.map { TelevisionInput(id: $0.id, name: $0.name) } : [],
                foregroundApp: live ? foregroundApp : nil,
                services: live ? services : [],
                unsupportedCommands: live ? unsupportedCommands : [], featureMessage: live ? featureMessage : nil, busy: active && busy, status: active ? status : nil))
        }
        for tv in accounts { append(Self.accountID(tv), name: tv.name, online: tv.online, mac: tv.macAddress) }
        let accountIDs = Set(accounts.map(Self.accountID))
        let local = links.values.filter { link in
            link.id.hasPrefix("local.") || (!accountIDs.contains(link.id) && nearby.contains { $0.id == link.discoveryID })
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        for link in local {
            let advertised = nearby.contains { $0.id == link.discoveryID || (link.discoveryID == nil && $0.host == link.host) }
            append(link.id, name: link.name, online: advertised ? true : nil, mac: link.mac)
        }
        return items
    }

    #if os(iOS)
    func refreshWidgetReadings() async {
        for link in links.values.sorted(by: { $0.id < $1.id }) {
            guard !Task.isCancelled else { return }
            // The visible remote already owns its connection and current reads.
            if remoteID == link.id { continue }
            let reader = WebOSTVRemote(host: link.host, credentialID: link.pairingID ?? link.id)
            do {
                if try await reader.hasSavedPairing() {
                    try await reader.restore(timeout: 3)
                    let state = try await reader.readPowerState()
                    if let state, links[link.id]?.host == link.host,
                       links[link.id]?.pairingID == link.pairingID {
                        powerDate[link.id] = Date()
                        observedPower[link.id] = state.isOn
                        if state.isOn, let value = try? await reader.readVolume() {
                            lastVolume[link.id] = value
                            defaults.set(lastVolume, forKey: "lg.tv.lastVolume.v1")
                        }
                    }
                }
            } catch {
                // Keep the last confirmed value and its original timestamp.
            }
            await reader.disconnect()
        }
    }

    func publishWidgetReadings(_ accounts: [LGAccountTelevision]) {
        let devices = items(accounts)
        let changed = try? WidgetCache.update { snapshot in
            let previous = snapshot.televisions ?? []
            snapshot.televisions = devices.map { tv in
                let old = previous.first { $0.id == tv.id }
                return WidgetTelevision(id: tv.id, name: tv.name,
                    power: observedPower[tv.id] ?? tv.power ?? old?.power, volume: tv.volume ?? old?.volume,
                    updatedAt: tv.powerDate ?? old?.updatedAt ?? .distantPast)
            }
        }
        if changed == true { WidgetCenter.shared.reloadTimelines(ofKind: "SuperBar.home") }
    }
    #endif

    func select(_ id: String) {
        selectedID = id
        defaults.set(id, forKey: "lg.tv.selectedID")
    }

    func scan() async {
        let ticket = UUID()
        scanID = ticket
        scanning = true
        scanMessage = nil
        defer { if scanID == ticket { scanning = false } }
        do {
            let found = try await WebOSTVDiscovery.discover()
            guard !Task.isCancelled, scanID == ticket else { return }
            nearby = found
        } catch {
            guard !Task.isCancelled, scanID == ticket else { return }
            nearby = []
            scanMessage = error.localizedDescription
        }
    }

    func scanWhileVisible() async {
        #if os(iOS)
        let monitor = NWPathMonitor()
        let changes = AsyncStream<NWPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in changes.continuation.yield(path) }
        changes.continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "SuperBar.TV.network"))
        defer { monitor.cancel(); changes.continuation.finish() }
        for await path in changes.stream {
            guard !Task.isCancelled else { return }
            if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                await scan()
            } else {
                nearby = []
                scanMessage = "Connect to the same Wi-Fi as your LG TV to find it."
            }
        }
        #else
        await scan()
        #endif
    }

    func reconcile(_ accounts: [LGAccountTelevision]) {
        var updated = links
        for device in nearby {
            let id = linkedID(device, accounts: accounts)
            let account = accounts.first { Self.accountID($0) == id }
            let previous = updated[id] ?? updated.values.first { $0.discoveryID == device.id }
            let wakeAddress = previous?.mac ?? account?.macAddress ?? device.macAddress
            updated[id] = TelevisionLink(id: id, name: account?.name ?? previous?.name ?? device.name,
                host: device.host, mac: wakeAddress, discoveryID: device.id,
                pairingID: previous?.pairingID ?? device.id, wakeAddressConfirmed: wakeAddress != nil,
                networkMACs: previous?.networkMACs, customName: previous?.customName)
            // If a later dashboard identifies a previously discovered TV, transfer its local link.
            if id.hasPrefix("account."), let old = updated.values.first(where: {
                $0.id.hasPrefix("local.") && $0.discoveryID == device.id
            }) {
                if lastVolume[id] == nil, let saved = lastVolume.removeValue(forKey: old.id) {
                    lastVolume[id] = saved
                    defaults.set(lastVolume, forKey: "lg.tv.lastVolume.v1")
                }
                updated.removeValue(forKey: old.id)
                if selectedID == old.id { select(id) }
            }
        }
        save(updated)
    }

    func configure(id: String?, name: String, host: String, mac: String?, endpoint: WebOSTVEndpoint?, accounts: [LGAccountTelevision]) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WebOSTVRemote.isLocalHost(host) else { return "Enter the TV’s local IPv4 address." }
        let mac = mac?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mac, !mac.isEmpty, Self.normalizedMAC(mac) == nil { return "Enter the TV’s six-byte MAC address." }
        let existing = links.values.first { $0.host == host }
        let hardware = Self.normalizedMAC(mac) ?? Self.normalizedMAC(endpoint?.macAddress)
        let matchedAccount = hardware.flatMap { address in accounts.first { Self.normalizedMAC($0.macAddress) == address } }
        let id = id ?? matchedAccount.map(Self.accountID) ?? existing?.id ?? "local." + UUID().uuidString
        if let match = accounts.first(where: { account in
            let accountID = Self.accountID(account)
            guard accountID != id else { return false }
            let saved = links[accountID]
            return saved?.host == host || (endpoint != nil && endpoint?.id == saved?.discoveryID)
                || (hardware != nil && hardware == Self.normalizedMAC(account.macAddress))
        }) { return "This TV is already linked to " + match.name + "." }
        let discoveryID = endpoint?.id ?? existing?.discoveryID
        let original = links[id]
        let sameHardware = original?.discoveryID != nil && original?.discoveryID == discoveryID
        let sameAddress = original?.host == host && (original?.discoveryID == nil || discoveryID == original?.discoveryID)
        let compatible = existing?.discoveryID == nil || discoveryID == existing?.discoveryID
        let pairingID = (compatible ? existing?.pairingID : nil) ?? ((sameAddress || sameHardware) ? original?.pairingID : nil)
            ?? discoveryID ?? UUID().uuidString
        var updated = links
        updated = updated.filter { key, entry in
            key == id || !key.hasPrefix("local.") || (entry.host != host && (discoveryID == nil || entry.discoveryID != discoveryID))
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wakeAddress = mac?.isEmpty == false ? mac : endpoint?.macAddress ?? ((sameAddress || sameHardware) ? original?.mac : nil)
        updated[id] = TelevisionLink(id: id, name: name.isEmpty ? "LG TV" : name,
            host: host, mac: wakeAddress, discoveryID: discoveryID,
            pairingID: pairingID, wakeAddressConfirmed: wakeAddress != nil,
            networkMACs: (sameAddress || sameHardware) ? original?.networkMACs : nil, customName: original?.customName)
        save(updated)
        select(id)
        return nil
    }

    private func save(_ updated: [String: TelevisionLink]) {
        guard updated != links, let data = try? JSONEncoder().encode(updated) else { return }
        links = updated
        defaults.set(data, forKey: Self.linkKey)
    }

    func watch(_ link: TelevisionLink?) async {
        guard !Task.isCancelled else { return }
        close()
        guard let link else { return }
        let remote = WebOSTVRemote(host: link.host, credentialID: link.pairingID ?? link.id)
        self.remote = remote
        remoteID = link.id
        defer { if self.remote === remote { close() } }
        while !Task.isCancelled {
            if !busy, sending == nil {
                if !connected, retryRestore, Date() >= restoreAfter {
                    do {
                        if try await remote.hasSavedPairing() {
                            try await remote.restore()
                            guard self.remote === remote, !Task.isCancelled else { return }
                            didConnect(link.id)
                            await loadSources(remote)
                            await loadFeatures(remote)
                        } else { retryRestore = false }
                    } catch {
                        guard self.remote === remote, !Task.isCancelled else { return }
                        if !busy, !preservingWakeResult { status = error.localizedDescription }
                        if (error as? WebOSTVError)?.requiresPairing == true { retryRestore = false }
                    }
                }
                if connected { await readPower(remote); await readVolume(remote); await readExtras(remote) }
            }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
        }
    }

    private func didConnect(_ id: String) {
        pinTV = nil
        submittingPIN = false
        connected = true
        if !preservingWakeResult { status = nil }
        retryRestore = true
        restoreAfter = .distantPast
    }

    private func movePointer(_ dx: Int, _ dy: Int, on remote: WebOSTVRemote) {
        guard connected, !pointerFailed, !busy else { return }
        pointerDelta.x = max(-256, min(256, pointerDelta.x + dx))
        pointerDelta.y = max(-256, min(256, pointerDelta.y + dy))
        guard pointerTask == nil else { return }
        pointerTask = Task {
            defer { if self.remote === remote { pointerTask = nil; pointerDelta = (0, 0) } }
            while !Task.isCancelled, self.remote === remote, connected {
                let delta = pointerDelta
                pointerDelta = (0, 0)
                guard delta.x != 0 || delta.y != 0 else { break }
                do {
                    try await remote.movePointer(x: delta.x, y: delta.y)
                    try await Task.sleep(nanoseconds: 33_000_000)
                } catch {
                    if !Task.isCancelled, self.remote === remote {
                        pointerFailed = true
                        status = "TV pointer unavailable. Use the directional pad."
                    }
                    break
                }
            }
        }
    }

    func close() {
        brightness = nil
        pointerTask?.cancel()
        pointerTask = nil
        pointerDelta = (0, 0)
        pointerFailed = false
        let old = remote
        sending?.cancel()
        queue.removeAll()
        sending = nil
        remote = nil
        remoteID = nil
        preservingWakeResult = false
        connected = false
        busy = false
        pinTV = nil
        submittingPIN = false
        volume = nil
        inputs = []
        applications = []; foregroundApp = nil
        services = []; unsupportedCommands = []; featureMessage = nil
        selectedSourceID = nil
        status = nil
        retryRestore = true
        restoreAfter = .distantPast
        volumeRevision &+= 1
        if let old { Task { await old.disconnect() } }
    }

    private func showChallenge(_ challenge: WebOSTVPairingChallenge, remote: WebOSTVRemote, id: String) {
        guard self.remote === remote, remoteID == id, !Task.isCancelled else { return }
        connection = challenge == .pin ? .awaitingPIN : .awaitingApproval
        pinTV = challenge == .pin ? id : nil
        submittingPIN = false
        status = challenge == .prompt ? "Allow Super Bar on your TV." : nil
    }

    func submitPIN(_ pin: String, id: String) async {
        guard let remote, remoteID == id, pinTV == id, !submittingPIN else { return }
        submittingPIN = true
        do {
            try await remote.submitPIN(pin)
        } catch {
            guard self.remote === remote, pinTV == id else { return }
            submittingPIN = false
            status = error.localizedDescription
        }
    }

    func cancelPIN(id: String) {
        guard remoteID == id, pinTV == id else { return }
        sending?.cancel()
        queue.removeAll()
        pinTV = nil
        submittingPIN = false
    }

    /// Capability discovery reads only. A failed optional service never disables the basic remote.
    private func loadFeatures(_ remote: WebOSTVRemote) async {
        await readPower(remote)
        guard self.remote === remote, !Task.isCancelled else { return }
        // Optional read: a TV that refuses this API still has a working remote and manual MAC entry.
        let addresses = try? await remote.networkMACAddresses()
        guard self.remote === remote, !Task.isCancelled else { return }
        if let addresses, !addresses.isEmpty, let id = remoteID, var link = links[id] {
            link.networkMACs = addresses
            var updated = links
            updated[id] = link
            save(updated)
        }
        do {
            let reported = try await remote.services()
            guard self.remote === remote, !Task.isCancelled else { return }
            services = reported
            let level = try? await remote.brightness()
            guard self.remote === remote, !Task.isCancelled else { return }
            brightness = level
            featureMessage = nil
        } catch {
            guard self.remote === remote, !Task.isCancelled else { return }
            featureMessage = "Extra controls are unavailable. Pair again if this TV needs additional permissions."
        }
        do {
            let apps = try await remote.applications()
            guard self.remote === remote, !Task.isCancelled else { return }
            applications = apps
        } catch {
            guard self.remote === remote else { return }
            featureMessage = "The TV did not allow access to its apps. Pair again to request permission."
        }
        await readExtras(remote)
    }

    @discardableResult private func readPower(_ remote: WebOSTVRemote) async -> WebOSTVPowerState? {
        let state = try? await remote.readPowerState()
        guard self.remote === remote, !Task.isCancelled else { return nil }
        if let id = remoteID, let state { observedPower[id] = state.isOn; powerDate[id] = Date() }
        return state
    }

    private func readExtras(_ remote: WebOSTVRemote) async {
        if !applications.isEmpty || services.contains("com.webos.applicationManager") {
            let app = try? await remote.foregroundApplication()
            guard self.remote === remote, !Task.isCancelled else { return }
            foregroundApp = app
            selectedSourceID = inputs.first { $0.appID == app }?.id
        }
    }

    private func loadSources(_ remote: WebOSTVRemote) async {
        do {
            let reported = try await remote.inputs()
            guard self.remote === remote else { return }
            inputs = reported
            await readInput(remote)
        } catch {
            if self.remote === remote { status = error.localizedDescription }
        }
    }

    private func readInput(_ remote: WebOSTVRemote) async {
        guard self.remote === remote else { return }
        let reported = try? await remote.currentInput(in: inputs)
        if self.remote === remote { selectedSourceID = reported }
    }

    private func readVolume(_ remote: WebOSTVRemote) async {
        guard self.remote === remote else { return }
        volumeRevision &+= 1
        let revision = volumeRevision
        do {
            let percent = try await remote.readVolume()
            guard self.remote === remote, revision == volumeRevision else { return }
            volume = percent
            if let remoteID, lastVolume[remoteID] != percent {
                lastVolume[remoteID] = percent
                defaults.set(lastVolume, forKey: "lg.tv.lastVolume.v1")
            }
        } catch {
            guard self.remote === remote, revision == volumeRevision else { return }
            volume = nil
            if !busy, !preservingWakeResult { status = error.localizedDescription }
            let stillConnected = await remote.isConnected
            guard self.remote === remote, revision == volumeRevision else { return }
            if !stillConnected { connected = false; inputs = []; selectedSourceID = nil }
        }
    }

    private func wakeProgress(_ message: String, id: String) {
        status = message
        wakeDiagnostics[id] = message
        defaults.set(wakeDiagnostics, forKey: "lg.tv.wakeDiagnostics.v1")
        recordPowerEvent(message, id: id)
    }

    private var powerEvents: [[String: String]] = []
    private func recordPowerEvent(_ message: String, id: String) {
        powerEvents.append(["time": ISO8601DateFormatter().string(from: Date()), "tv": id, "event": message])
        powerEvents = Array(powerEvents.suffix(40))
        // Keep the last attempt inspectable even before preferences flush to disk.
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("lg-tv-power-events.json")
        if let file, let data = try? JSONEncoder().encode(powerEvents) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func wake(_ link: TelevisionLink, accountMAC: String?, remote: WebOSTVRemote) async throws {
        let id = link.id
        busy = true
        let addresses = Array(Set(([link.mac ?? accountMAC].compactMap { $0 } + (link.networkMACs ?? []))
            .compactMap(Self.normalizedMAC)))
        wakeProgress(addresses.isEmpty ? "Checking the TV connection…" : "Sending wake packets to the saved TV network MAC…", id: id)
        var accepted = false
        var broadcastAccepted = false
        var broadcastDenied = false
        var wakeFailure: Error?
        var transportResults: [String] = []
        for address in addresses {
            try Task.checkCancellation()
            do {
                let report = try await WebOSTVRemote.wake(host: link.host, macAddress: address)
                transportResults.append(report.diagnostic)
                recordPowerEvent(report.diagnostic, id: id)
                accepted = report.accepted || accepted
                broadcastAccepted = report.acceptedBroadcast || broadcastAccepted
                broadcastDenied = report.broadcastDenied || broadcastDenied
            } catch {
                if Task.isCancelled { throw CancellationError() }
                wakeFailure = error
                recordPowerEvent("Wake send failed: " + error.localizedDescription, id: id)
            }
        }
        guard self.remote === remote else { return }
        if accepted { wakeProgress(broadcastAccepted ? "Wake broadcast accepted. Waiting for TV power confirmation…" : "Wake sent directly to TV. Broadcast was not accepted; waiting for TV…", id: id) }
        // Do not confuse a reachable standby socket with an active screen.
        if !connected, (try? await remote.hasSavedPairing()) == true {
            do {
                try await remote.restore(timeout: 3)
                guard self.remote === remote, !Task.isCancelled else { return }
                didConnect(id)
            } catch {
                recordPowerEvent("Connection after wake: " + error.localizedDescription, id: id)
                if Task.isCancelled { throw CancellationError() }
            }
        }
        guard self.remote === remote, !Task.isCancelled else { return }
        if connected {
            let power = await readPower(remote)
            guard self.remote === remote, !Task.isCancelled else { return }
            if power?.isOn == true { wakeProgress("TV reports that it is on.", id: id); return }
            do { try await remote.powerOn(power) }
            catch { if Task.isCancelled { throw CancellationError() } }
            // A command acknowledgement is not evidence of screen power.
            if await readPower(remote)?.isOn == true { wakeProgress("TV reports that it is on.", id: id); return }
        }
        guard accepted else {
            throw wakeFailure ?? WebOSTVError(addresses.isEmpty ? "Save the TV network MAC address to enable power on while the TV is offline." : "Could not send a wake request on this network.")
        }
        retryRestore = true
        restoreAfter = .distantPast
        var confirmedOn = false
        if (try? await remote.hasSavedPairing()) == true {
            for _ in 0..<3 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.remote === remote, !Task.isCancelled else { return }
                do {
                    try await remote.restore(timeout: 3)
                    guard self.remote === remote, !Task.isCancelled else { return }
                    didConnect(id)
                    if await readPower(remote)?.isOn == true {
                        confirmedOn = true
                        wakeProgress("TV reports that it is on.", id: id)
                        await readVolume(remote)
                        await loadSources(remote)
                        break
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if (error as? WebOSTVError)?.requiresPairing == true { retryRestore = false; break }
                }
            }
        }
        if !confirmedOn {
            if broadcastDenied && !broadcastAccepted {
                wakeProgress("TV power is not confirmed. The network denied the wake broadcast. " + transportResults.joined(separator: " "), id: id)
            } else {
                wakeProgress("TV power is not confirmed. Check TV On With Mobile / Turn on via Wi-Fi and the saved network MAC. " + transportResults.joined(separator: " "), id: id)
            }
        }
    }

    func send(_ action: TelevisionAction, id: String, accountMAC: String?) {
        if case .rename(let name) = action {
            guard var link = links[id] else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 80, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
            link.customName = trimmed.isEmpty ? nil : trimmed
            var updated = links
            updated[id] = link
            save(updated)
            return
        }
        if case .power(let on) = action {
            recordPowerEvent(on ? "Turn on tapped" : "Turn off tapped", id: id)
        }
        guard remoteID == id, let remote, let link = links[id] else {
            if case .power = action {
                wakeProgress("The TV connection is not ready. Select this TV and try again.", id: id)
            }
            return
        }
        if case .move(let x, let y) = action {
            movePointer(x, y, on: remote)
            return
        }
        guard !busy, queue.count < 32 else {
            if case .power = action { recordPowerEvent("Power command not started: another command is running.", id: id) }
            return
        }
        switch action {
        case .pair, .unpair, .power(true): break
        default: guard connected else { return }
        }
        // Text belongs to the selected TV and is never persisted or replayed on reconnect.
        queue.append(action)
        guard sending == nil else { return }
        sending = Task { [self] in
            defer { if self.remote === remote { sending = nil; busy = false } }
            while !queue.isEmpty, self.remote === remote, !Task.isCancelled {
                let next = queue.removeFirst()
                switch next {
                case .pair, .unpair, .power(true): break
                default:
                    guard connected else { queue.removeAll(); return }
                }
                preservingWakeResult = next == .power(true)
                status = nil
                do {
                    switch next {
                    case .unpair:
                        busy = true
                        queue.removeAll()
                        try await remote.unpair()
                        guard self.remote === remote else { return }
                        connected = false
                        retryRestore = false
                        pinTV = nil
                        submittingPIN = false
                        volume = nil
                        unsupportedCommands = []
                        applications = []; inputs = []
                        services = []; foregroundApp = nil; selectedSourceID = nil
                        status = "Pairing forgotten on this device. Choose Pair TV to connect again."
                    case .pair:
                        busy = true
                        connection = .connecting
                        status = "Connecting to your LG TV…"
                        defer { if self.remote === remote { pinTV = nil; submittingPIN = false } }
                        try await remote.pair { [weak self] challenge in
                            await self?.showChallenge(challenge, remote: remote, id: id)
                        }
                        guard self.remote === remote, !Task.isCancelled else { return }
                        didConnect(id)
                        await readVolume(remote)
                        await loadSources(remote)
                        await loadFeatures(remote)
                    case .power(true):
                        try await wake(link, accountMAC: accountMAC, remote: remote)
                    case .power(false):
                        busy = true
                        recordPowerEvent("Sending system/turnOff", id: id)
                        try await remote.powerOff()
                        guard self.remote === remote else { return }
                        connected = false
                        observedPower[id] = false
                        powerDate[id] = Date()
                        volume = nil
                        inputs = []
                        selectedSourceID = nil
                        restoreAfter = Date().addingTimeInterval(16)
                        await remote.disconnect()
                    case .brightness(let delta):
                        guard let brightness else { break }
                        do {
                            try await remote.setBrightness(max(0, min(100, brightness + delta)))
                            let level = try await remote.brightness()
                            if self.remote === remote { self.brightness = level }
                        } catch {
                            if self.remote === remote { self.brightness = nil }
                            throw error
                        }
                    case .volumeUp, .volumeDown:
                        try await remote.changeVolume(up: next == .volumeUp)
                        await readVolume(remote)
                    case .source(let input):
                        try await remote.selectInput(input)
                        await readInput(remote)
                    case .refreshSources: await loadSources(remote)
                    case .up: try await remote.navigate(.up)
                    case .down: try await remote.navigate(.down)
                    case .left: try await remote.navigate(.left)
                    case .right: try await remote.navigate(.right)
                    case .ok: try await remote.navigate(.ok)
                    case .click: try await remote.navigate(.click)
                    case .home: try await remote.navigate(.home)
                    case .back: try await remote.navigate(.back)
                    case .menu: try await remote.navigate(.menu)
                    case .settings: try await remote.navigate(.settings)
                    case .exit: try await remote.navigate(.exit)
                    case .refreshFeatures: await loadFeatures(remote)
                    case .command(let command):
                        guard connected, !unsupportedCommands.contains(command.uri) else {
                            throw WebOSTVError("This control is unavailable on this TV.")
                        }
                        if case .launch(let app) = command, !applications.contains(where: { $0.id == app }) {
                            throw WebOSTVError("Choose an app reported by this TV.")
                        }
                        do { try await remote.execute(command) }
                        catch {
                            if let rejection = (error as? WebOSTVError)?.unsupported,
                               rejection.hasPrefix("404") || rejection.hasPrefix("403") || rejection.hasPrefix("401") {
                                unsupportedCommands.insert(command.uri)
                            }
                            throw error
                        }
                        await readExtras(remote)
                        if case .launch(let id) = command, self.remote === remote, foregroundApp != id {
                            try await Task.sleep(nanoseconds: 850_000_000)
                            await readExtras(remote)
                            if self.remote === remote, foregroundApp != id { status = "Launch accepted. Waiting for the TV to report the app." }
                        }
                    case .configure, .rename, .move: break
                    }
                } catch {
                    guard self.remote === remote else { return }
                    status = Task.isCancelled ? nil : error.localizedDescription
                    if case .power = next, !Task.isCancelled { wakeProgress("Power command failed: " + error.localizedDescription, id: id) }
                    let live = await remote.isConnected
                    guard self.remote === remote else { return }
                    connected = live
                    if !live { queue.removeAll() }
                }
                if self.remote === remote { busy = false }
            }
        }
    }
}

