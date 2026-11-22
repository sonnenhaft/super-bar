import Foundation
import Combine

struct PhoneLGDevice: Identifiable {
    let id: String, name: String
    var state: [String: Any] = [:]
    var profile: [String: Any] = [:]
    var checked: Date?
    var problem: String?
    var desired: [String: [String: Any]] = [:]
    private var sample: LGSample { LGSample(state) }
    func value(_ group: String, _ key: String) -> Any? {
        desired[group]?[key] ?? LGDeviceValues.value(group, key, in: state)
    }
    var target: Double? { lgNumber(value("temperature", "targetTemperature")) }
    var roomReading: String { sample.roomReading }
    var windKey: String { LGDeviceValues.windKey(in: profile) }
    var power: Bool? {
        switch value("operation", "airConOperationMode") as? String {
        case "POWER_ON": return true
        case "POWER_OFF": return false
        default: return nil
        }
    }
    var online: Bool? { sample.online }
    private func capability(_ group: String, _ key: String) -> LGCapability {
        LGCapability(profile: profile, group: group, key: key)
    }
    func writable(_ group: String, _ key: String) -> Bool { capability(group, key).writable }
    func allowed(_ group: String, _ key: String, _ value: Any) -> Bool { capability(group, key).allows(value) }
    func options(_ group: String, _ key: String) -> [String] { capability(group, key).options }
    var bounds: ClosedRange<Double> {
        let (low, high) = LGDeviceValues.temperatureBounds(
            temperatures: celsius(find("temperature", in: state) ?? [:]),
            capability: capability("temperature", "targetTemperature").details)
        return min(low, high)...max(low, high)
    }

}

@MainActor final class PhoneLG: ObservableObject {
    @Published var devices: [PhoneLGDevice] = []
    @Published private(set) var televisions: [LGAccountTelevision] = []
    // A cold start may use the widget's last list; a different account may not.
    private(set) var mayRestoreWidgetList = true
    @Published var problem: String?
    @Published var busy = false
    var changed: (() -> Void)?
    private(set) var api: API
    private let makeAPI: () -> API
    private let preferences: UserDefaults
    private var accountGeneration = 0
    private let finishedReads = CurrentValueSubject<Int, Never>(0)
    private var reading = false
    @Published private var readingDeviceID: String?
    @Published private(set) var commandErrors: [String: String] = [:]

    private struct Edit {
        let id: String
        let group: String
        let key: String
        var value: Any
        let preserveCurrent: Bool
    }
    @Published private var pending: [Edit] = []
    @Published private var active: [Edit] = []
    private var commandTask: Task<Void, Never>?
    private let confirmationDelay: UInt64

    func displayDevice(_ device: PhoneLGDevice) -> PhoneLGDevice {
        var shown = device
        for edit in active + pending where edit.id == device.id {
            shown.desired[edit.group, default: [:]][edit.key] = edit.value
        }
        return shown
    }
    func isPending(_ id: String) -> Bool { (active + pending).contains { $0.id == id } }
    func isUpdating(_ id: String) -> Bool { readingDeviceID == id || isPending(id) }
    var hasPendingCommands: Bool { commandTask != nil || !pending.isEmpty || !active.isEmpty }
    func ecoChoice(_ device: PhoneLGDevice) -> EcoChoice {
        let flag = LGCapability(profile: device.profile, group: "powerSave", key: "powerSaveEnabled")
        return EcoChoice(flag: device.value("powerSave", "powerSaveEnabled"), flagWrites: flag.details["writeValues"] as? [Any],
            writableFlag: flag.writable, mode: device.value("airConJobMode", "currentJobMode") as? String,
            modes: device.options("airConJobMode", "currentJobMode"), returnMode: "COOL")
    }
    func toggleEco(_ device: PhoneLGDevice) {
        guard let current = devices.first(where: { $0.id == device.id }) else { return }
        let device = displayDevice(current)
        let choice = ecoChoice(device)
        guard let change = choice.change else { return }
        var changes = [change]
        if let target = device.target, device.allowed("temperature", "targetTemperature", target) {
            changes.append(("temperature", "targetTemperature", target))
        }
        if let speed = device.value("airFlow", device.windKey), device.allowed("airFlow", device.windKey, speed) {
            changes.append(("airFlow", device.windKey, speed))
        }
        enqueue(device, changes: changes, preserveFollowingValues: true)
    }
    func presetChanges(_ device: PhoneLGDevice, _ preset: LGCoolingPreset) -> [ControlChange] {
        preset.changes(windKey: device.windKey)
    }
    func presetAllowed(_ device: PhoneLGDevice, _ preset: LGCoolingPreset) -> Bool {
        device.bounds.contains(Double(preset.degrees)) && presetChanges(device, preset).allSatisfy { device.allowed($0.0, $0.1, $0.2) }
    }
    func preset(_ device: PhoneLGDevice, _ preset: LGCoolingPreset) {
        guard presetAllowed(device, preset) else { return }
        enqueue(device, changes: presetChanges(device, preset))
    }

    private let connect: (String, String, String) async throws -> Void
    init(makeAPI: @escaping () -> API = { API() }, preferences: UserDefaults = defaults, confirmationDelay: UInt64 = 800_000_000,
         connect: @escaping (String, String, String) async throws -> Void = {
             try await LGMobileClient.connect(email: $0, password: $1, country: $2)
         }) {
        self.makeAPI = makeAPI; self.preferences = preferences; self.connect = connect
        self.confirmationDelay = confirmationDelay
        api = makeAPI()
    }

    func configureMobile(email: String, password: String, country: String) async throws {
        guard !busy else { throw ACError("Wait for LG to finish.") }
        busy = true
        do { try await connect(email, password, country) }
        catch { busy = false; throw error }
        AccountConnection.setConnected(true, provider: "lg", preferences: preferences)
        preferences.set(country.uppercased(), forKey: "country")
        accountGeneration &+= 1
        pending = []; active = []; commandErrors.removeAll()
        api = makeAPI(); devices = []; televisions = []; mayRestoreWidgetList = false
        busy = false
        await refresh()
    }

    func refreshAndWait() async {
        guard !Task.isCancelled, !AccountConnection.signedOut("lg", preferences: preferences) else { return }
        let generation = accountGeneration
        let expected = finishedReads.value + (reading && !pending.isEmpty ? 2 : 1)
        // Join an active read, or read once after queued commands release the client.
        for await _ in $busy.combineLatest(finishedReads).values {
            guard !Task.isCancelled, generation == accountGeneration, finishedReads.value < expected else { return }
            if !busy { await refresh(); return }
        }
    }

    func refresh() async {
        guard !AccountConnection.signedOut("lg", preferences: preferences) else { return }
        guard !busy else { return }
        let generation = accountGeneration
        reading = true
        busy = true
        defer {
            reading = false
            readingDeviceID = nil
            finishedReads.send(finishedReads.value + 1)
            busy = false
            changed?()
            startCommands()
        }
        do {
            let directory = try await api.accountDirectoryIfNeeded(hasDevices: !devices.isEmpty || !televisions.isEmpty)
            try Task.checkCancellation()
            guard generation == accountGeneration else { return }
            if let directory {
                mayRestoreWidgetList = false
                if televisions != directory.televisions { televisions = directory.televisions }
                if devices.isEmpty {
                    devices = directory.airConditioners.map { PhoneLGDevice(id: $0.id, name: $0.name) }
                }
            }
            if devices.isEmpty && televisions.isEmpty { throw ACError("No air conditioners in this LG account.") }
            for index in devices.indices {
                try Task.checkCancellation()
                readingDeviceID = devices[index].id
                do {
                    if devices[index].profile.isEmpty {
                        let profile = object(try await api.request("devices/\(try API.deviceComponent(devices[index].id))/profile"))
                        guard generation == accountGeneration else { return }
                        devices[index].profile = profile
                    }
                    try await readState(index: index, generation: generation)
                    guard generation == accountGeneration else { return }
                    commandErrors.removeValue(forKey: devices[index].id)
                } catch {
                    guard generation == accountGeneration else { return }
                    devices[index].problem = error.localizedDescription
                }
                changed?() // Publish this device without waiting for the rest of the account.
            }
            problem = nil
        } catch { if !Task.isCancelled && generation == accountGeneration { problem = error.localizedDescription } }
    }
    func send(_ device: PhoneLGDevice, group: String, key: String, value: Any) {
        enqueue(device, changes: [(group, key, value)])
    }
    private func readState(index: Int, generation: Int) async throws {
        guard generation == accountGeneration else { throw CancellationError() }
        let id = devices[index].id
        let state = object(try await api.request("devices/\(try API.deviceComponent(id))/state"))
        guard generation == accountGeneration else { throw CancellationError() }
        guard !state.isEmpty else { throw ACError("LG returned no current readings.") }
        devices[index].state = state
        devices[index].checked = Date()
        devices[index].problem = nil
        DevicePowerHistory.lg.record(liveWatts(state), for: id)
    }
    private func enqueue(_ device: PhoneLGDevice, changes: [ControlChange], preserveFollowingValues: Bool = false) {
        guard !AccountConnection.signedOut("lg", preferences: preferences),
              let current = devices.first(where: { $0.id == device.id }), current.online != false,
              current.checked != nil else { return }
        guard changes.allSatisfy({ group, key, value in
            current.allowed(group, key, value)
                && (group != "temperature" || lgNumber(value).map(current.bounds.contains) == true)
        }) else {
            problem = "This setting is not supported."; return
        }
        for (offset, change) in changes.enumerated() {
            let (group, key, value) = change
            pending.removeAll { $0.id == device.id && $0.group == group && $0.key == key }
            pending.append(Edit(id: device.id, group: group, key: key, value: value,
                                preserveCurrent: preserveFollowingValues && offset > 0))
        }
        problem = nil
        commandErrors.removeValue(forKey: device.id)
        startCommands()
    }
    private func startCommands() {
        guard !busy, commandTask == nil, !pending.isEmpty else { return }
        busy = true
        commandTask = Task { await drainCommands() }
    }
    private func drainCommands() async {
        let generation = accountGeneration
        busy = true
        defer { active = []; busy = false; commandTask = nil; changed?(); startCommands() }
        while let first = pending.first, generation == accountGeneration {
            var batch = pending.filter { $0.id == first.id }
            active = batch
            pending.removeAll { $0.id == first.id }
            guard let index = devices.firstIndex(where: { $0.id == first.id }) else { active = []; continue }
            var writeInFlight = false
            do {
                let path = "devices/" + (try API.deviceComponent(first.id))
                guard devices[index].online != false else { throw ACError("LG is offline.") }
                if devices[index].checked.map({ !(0...300).contains(Date().timeIntervalSince($0)) }) ?? true {
                    try await readState(index: index, generation: generation)
                    guard generation == accountGeneration else { return }
                    let latest = devices[index]
                    guard latest.online != false else { throw ACError("LG is offline.") }
                    // Eco preserves the current temperature and fan. Re-read those
                    // values so another controller's recent changes aren't undone.
                    batch = batch.compactMap { edit in
                        guard edit.preserveCurrent else { return edit }
                        guard let value = latest.value(edit.group, edit.key),
                              latest.allowed(edit.group, edit.key, value) else { return nil }
                        var updated = edit
                        updated.value = value
                        return updated
                    }
                    guard batch.allSatisfy({ edit in
                        latest.allowed(edit.group, edit.key, edit.value) &&
                            (edit.group != "temperature" || lgNumber(edit.value).map(latest.bounds.contains) == true)
                    }) else { throw ACError("This setting is not supported.") }
                    active = batch
                    changed?()
                }
                for edit in batch {
                    var payload = [edit.key: edit.value]
                    if edit.group == "temperature" { payload["unit"] = "C" }
                    writeInFlight = true
                    _ = try await api.request(path + "/control", payload: [edit.group: payload])
                    guard generation == accountGeneration else { return }
                    writeInFlight = false
                }
                var confirmed = false
                for _ in 0..<5 {
                    try await Task.sleep(nanoseconds: confirmationDelay)
                    guard generation == accountGeneration else { return }
                    try await readState(index: index, generation: generation)
                    guard generation == accountGeneration else { return }
                    changed?() // Reported state only; never publish the desired-value overlay.
                    guard devices[index].online != false else { throw ACError("LG is offline.") }
                    confirmed = batch.allSatisfy { edit in
                        let superseded = pending.contains { $0.id == edit.id && $0.group == edit.group && $0.key == edit.key }
                        return superseded || (devices[index].value(edit.group, edit.key).map { equal($0, edit.value) } ?? false)
                    }
                    if confirmed { break }
                }
                commandErrors[first.id] = confirmed ? nil : "LG has not confirmed this change."
            } catch {
                guard generation == accountGeneration else { return }
                var applied = false
                if writeInFlight {
                    // A lost write response doesn't tell us what reached the unit.
                    if (try? await readState(index: index, generation: generation)) != nil {
                        guard generation == accountGeneration else { return }
                        applied = devices[index].online != false && batch.allSatisfy { edit in
                            devices[index].value(edit.group, edit.key).map { equal($0, edit.value) } ?? false
                        }
                    }
                    guard generation == accountGeneration else { return }
                }
                commandErrors[first.id] = applied ? nil : error.localizedDescription
            }
            active = []
            changed?()
        }
    }
    var widgetMetrics: [WidgetMetric] {
        devices.map(\.widgetMetric)
    }
    func logout() {
        AccountConnection.setConnected(false, provider: "lg", preferences: preferences)
        accountGeneration &+= 1
        problem = "Logged out"
        mayRestoreWidgetList = false
        pending = []; active = []; commandErrors.removeAll()
        devices = []; televisions = []; changed?()
        finishedReads.send(finishedReads.value + 1)
    }

}
