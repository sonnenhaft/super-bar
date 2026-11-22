import Foundation
import Darwin
import AppKit
import Combine

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

private final class SlowTCL {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var writes = 0
    private var row: JSONObject = ["id": "synthetic-queued-tcl", "name": "Test", "online": true,
        "power": true, "target": 22, "reported": ["powerSwitch": 1, "targetTemperature": 22]]
    var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func fetch() -> [JSONObject] {
        lock.lock(); defer { lock.unlock() }
        return [row, ["id": "synthetic-other-tcl", "name": "Other", "online": true,
                      "power": false, "target": 25, "reported": ["powerSwitch": 0, "targetTemperature": 25]]]
    }
    func apply(_ edits: [(String, Int)]) -> JSONObject {
        lock.lock(); writes += 1; let first = writes == 1; lock.unlock()
        if first { release.wait() }
        lock.lock(); defer { lock.unlock() }
        var report = row["reported"] as! JSONObject
        for (key, value) in edits { report[key] = value }
        row["reported"] = report; row["target"] = report["targetTemperature"]
        return row
    }
}

@main enum MemoryLifecycle {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let end = now.timeIntervalSince1970
        let points = (0..<12_000).map { WattSample(timestamp: end - Double($0), watts: Double($0)) }
        let invalid = [WattSample(timestamp: end - 90_000, watts: 1),
                       WattSample(timestamp: end + 1, watts: 1),
                       WattSample(timestamp: end, watts: -.infinity)]
        let clipped = EnergyHistory.boundedSamples(["test": points + invalid], now: now)["test"]!
        precondition(clipped.count == 6_000 && clipped.last?.timestamp == end)
        precondition(clipped.allSatisfy { $0.watts.isFinite && $0.timestamp >= end - 86400 && $0.timestamp <= end })
        let manyDevices = Dictionary(uniqueKeysWithValues: (0..<100).map { (String($0), [WattSample(timestamp: end, watts: 1)]) })
        precondition(EnergyHistory.boundedSamples(manyDevices, now: now).count == EnergyHistory.maximumCachedDevices)

        let wattsFile = folder.appendingPathComponent("watts.json")
        try JSONEncoder().encode(["test": points]).write(to: wattsFile)
        var transient: EnergyHistory? = EnergyHistory(directory: folder)
        let reference = WeakReference(transient!)
        transient = nil
        precondition(reference.value == nil, "Queued cache hydration retained a discarded history model")
        let history = EnergyHistory(directory: folder)
        try await wait { history.watts(for: "test").count == 6_000 }

        let huge = folder.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: EnergyCache.maximumBytes + 1).write(to: huge)
        precondition(EnergyCache.readData(from: huge) == nil, "Oversized cache must be rejected before decoding")
        let link = folder.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wattsFile)
        precondition(EnergyCache.readData(from: link) == nil)
        let pipe = folder.appendingPathComponent("pipe.json")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        precondition(EnergyCache.readData(from: pipe) == nil, "FIFO cache must fail without blocking")

        let domain = "SuperBar.phone-memory-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let tv = LGAccountTelevision(id: "synthetic-tv", name: "Living TV", macAddress: nil, online: false)
        var dashboardReads = 0
        let televisionAPI = {
            API(request: { path, payload in
                precondition(path == "devices" && payload == nil, "TV-only households must never hit an AC endpoint")
                dashboardReads += 1
                return LGAccountDirectory(airConditioners: [], televisions: [tv])
            })
        }
        let tvPhone = PhoneLG(makeAPI: televisionAPI, preferences: preferences)
        await tvPhone.refresh()
        await tvPhone.refresh()
        precondition(tvPhone.televisions == [tv] && tvPhone.devices.isEmpty && tvPhone.problem == nil && dashboardReads == 1)
        tvPhone.logout()
        precondition(tvPhone.televisions.isEmpty)
        AccountConnection.setConnected(true, provider: "lg", preferences: preferences)
        let tvDesktop = LGStore()
        tvDesktop.api = televisionAPI()
        tvDesktop.refresh()
        await tvDesktop.pollTask?.value
        tvDesktop.refresh()
        await tvDesktop.pollTask?.value
        precondition(tvDesktop.televisions == [tv] && tvDesktop.devices.isEmpty && tvDesktop.message.isEmpty && dashboardReads == 2)
        tvDesktop.stop()
        var savedEmails: [String] = []
        var holdState = false
        var stateStarted = false
        var stateReads = 0
        let phone = PhoneLG(makeAPI: {
            API(request: { path, _ in
                if path == "devices" {
                    return [["deviceId": "new-account-device", "deviceInfo": ["deviceType": "DEVICE_AIR_CONDITIONER", "alias": "Synthetic room"]]]
                }
                if path.hasSuffix("/state") {
                    stateStarted = true
                    stateReads += 1
                    while holdState { try await Task.sleep(nanoseconds: 10_000_000) }
                }
                return [:] as [String: Any]
            })
        }, preferences: preferences, connect: { email, _, _ in
            if email == "rejected@example.test" { throw LGError(message: "Synthetic rejected login") }
            savedEmails.append(email)
        })
        let device = PhoneLGDevice(id: "old-account-device", name: "Synthetic old room")
        phone.devices = [device]
        do { try await phone.configureMobile(email: "rejected@example.test", password: "synthetic", country: "US"); fatalError("Rejected LG login accepted") }
        catch { }
        precondition(savedEmails.isEmpty && phone.devices.map(\.id) == [device.id])
        precondition(preferences.string(forKey: "country") == nil && !phone.busy)

        holdState = true
        let oldAccount = Task { await phone.refresh() }
        try await wait { stateStarted }
        let cancelledRead = Task { await phone.refreshAndWait() }
        let loggedOutRead = Task { await phone.refreshAndWait() }
        await Task.yield()
        cancelledRead.cancel()
        await cancelledRead.value
        precondition(phone.busy && stateReads == 1, "Cancelling a joined caller must leave the shared read running")
        phone.logout()
        await loggedOutRead.value
        holdState = false
        await oldAccount.value
        precondition(phone.devices.isEmpty, "A late device response must not repopulate a logged-out account")
        try await phone.configureMobile(email: "new@example.test", password: "synthetic", country: "PH")
        precondition(AccountConnection.connected("lg", preferences: preferences))
        precondition(savedEmails == ["new@example.test"] && phone.devices.map(\.id) == ["new-account-device"])
        // A slow cloud response must not drop rapid mobile edits or publish
        // optimistic targets to the widget as confirmed readings.
        var held = true
        var sent: [[String: Any]] = []
        var reported: [String: Any] = ["temperature": ["targetTemperature": 22.0, "unit": "C"],
            "operation": ["airConOperationMode": "POWER_ON"], "airFlow": ["windStrength": "MID"],
            "airConJobMode": ["currentJobMode": "COOL"]]
        var rejectNext = false
        var loseNextReply = false
        var confirmedReads = 0
        let controls = PhoneLG(makeAPI: { API(request: { path, payload in
            if let payload {
                sent.append(payload)
                while held { try await Task.sleep(nanoseconds: 1_000_000) }
                if rejectNext { rejectNext = false; throw LGError(message: "Synthetic write failure") }
                for (group, value) in payload { reported[group] = value }
                if loseNextReply { loseNextReply = false; throw LGError(message: "Synthetic lost acknowledgement") }
            } else if path.hasSuffix("/state") { confirmedReads += 1 }
            return reported
        }) }, preferences: preferences, confirmationDelay: 1_000_000)
        var unit = PhoneLGDevice(id: "controls", name: "Synthetic AC")
        unit.checked = Date(); unit.state = reported
        unit.profile = [
            "temperature": ["targetTemperature": ["writable": true, "min": 16, "max": 30]],
            "operation": ["airConOperationMode": ["writable": true, "writeValues": ["POWER_ON", "POWER_OFF"]]],
            "airFlow": ["windStrength": ["writable": true, "writeValues": ["LOW", "MID", "HIGH"]]],
            "airConJobMode": ["currentJobMode": ["writable": true, "writeValues": ["COOL", "ENERGY_SAVING"]]]]
        controls.devices = [unit]
        controls.send(unit, group: "temperature", key: "targetTemperature", value: 23.0)
        try await wait { sent.count == 1 }
        controls.send(unit, group: "temperature", key: "targetTemperature", value: 24.0)
        controls.send(unit, group: "temperature", key: "targetTemperature", value: 25.0)
        precondition(controls.displayDevice(controls.devices[0]).target == 25)
        precondition(controls.widgetMetrics[0].control?.target == 22)
        precondition(controls.hasPendingCommands, "Queued phone commands need time to publish their confirmation")
        let afterEdits = Task { await controls.refreshAndWait() }
        let sameRead = Task { await controls.refreshAndWait() }
        await Task.yield()
        held = false
        await afterEdits.value
        await sameRead.value
        precondition(!controls.hasPendingCommands, "Background execution can end after commands drain")
        precondition(confirmedReads == 3 && !controls.isPending(unit.id),
                     "Two command confirmations must be followed by a single shared manual read")
        precondition(sent.count == 2 && controls.devices[0].target == 25, "Only the latest unsent temperature should be sent")
        precondition(controls.presetAllowed(controls.devices[0], .high) && controls.presetAllowed(controls.devices[0], .low))
        controls.preset(controls.devices[0], .high)
        precondition(controls.isUpdating(unit.id) && !controls.isUpdating("other"))
        precondition(controls.displayDevice(controls.devices[0]).value("airFlow", "windStrength") as? String == "HIGH"
                     && controls.displayDevice(controls.devices[0]).target == 16 && controls.widgetMetrics[0].control?.target == 25)
        try await wait { !controls.isPending(unit.id) }
        precondition(controls.devices[0].target == 16 && controls.devices[0].value("airFlow", "windStrength") as? String == "HIGH")
        precondition(controls.ecoChoice(controls.devices[0]).enabled == false, "Mode-based Eco must be available without a powerSave flag")
        controls.toggleEco(controls.devices[0])
        try await wait { !controls.isPending(unit.id) }
        precondition(controls.ecoChoice(controls.devices[0]).enabled == true)
        controls.toggleEco(controls.devices[0])
        try await wait { !controls.isPending(unit.id) }
        precondition(controls.devices[0].value("airConJobMode", "currentJobMode") as? String == "COOL")
        rejectNext = true
        controls.send(controls.devices[0], group: "temperature", key: "targetTemperature", value: 19.0)
        try await wait { !controls.isPending(unit.id) }
        precondition(controls.displayDevice(controls.devices[0]).target == 16 && controls.commandErrors[unit.id] != nil
                     && controls.widgetMetrics[0].control?.target == 16,
                     "Rejecting a setting must retain the fresh readings and controls of an online LG")
        loseNextReply = true
        controls.send(controls.devices[0], group: "temperature", key: "targetTemperature", value: 21.0)
        try await wait { !controls.isPending(unit.id) }
        precondition(controls.devices[0].target == 21 && controls.commandErrors[unit.id] == nil,
                     "A readback confirming the edit wins over a lost write reply")
        controls.devices[0].checked = Date().addingTimeInterval(-360)
        reported["temperature"] = ["targetTemperature": 24.0, "unit": "C"]
        reported["airFlow"] = ["windStrength": "LOW"]
        let readsBeforeEco = confirmedReads
        controls.toggleEco(controls.devices[0])
        try await wait { !controls.isPending(unit.id) }
        precondition(confirmedReads == readsBeforeEco + 2 && controls.ecoChoice(controls.devices[0]).enabled == true)
        precondition(controls.devices[0].target == 24 && controls.devices[0].value("airFlow", "windStrength") as? String == "LOW",
                     "A stale Eco action must preserve the freshly read temperature and fan speed")
        controls.devices[0].checked = Date().addingTimeInterval(-360)
        reported["online"] = false
        let writesBeforeOffline = sent.count
        controls.send(controls.devices[0], group: "operation", key: "airConOperationMode", value: "POWER_OFF")
        try await wait { !controls.isPending(unit.id) }
        precondition(sent.count == writesBeforeOffline && controls.devices[0].online == false,
                     "A stale control must read the device first and stop if it is offline")
        print("Phone LG: rapid edits, coalescing, confirmed widget data, presets, mode-based Eco and failure rollback passed.")
        let priorLGSignOut = defaults.object(forKey: "lg.signedOut")
        let priorSelected = defaults.object(forKey: "selected")
        defer {
            defaults.set(priorLGSignOut, forKey: "lg.signedOut")
            defaults.set(priorSelected, forKey: "selected")
        }
        defaults.set(false, forKey: "lg.signedOut")
        let desktop = LGStore()
        desktop.selected = "synthetic-queued-lg"
        desktop.connected = true
        desktop.profile = unit.profile
        reported = unit.state
        desktop.state = reported
        sent = []; held = true
        desktop.api = API(request: { _, payload in
            if let payload {
                sent.append(payload)
                while held { try await Task.sleep(nanoseconds: 1_000_000) }
                for (group, value) in payload { reported[group] = value }
            }
            return reported
        })
        desktop.connected = false
        desktop.useCard(desktop.selected) { desktop.setDegrees(23) }
        precondition(desktop.displayedTarget == 23 && desktop.sending && desktop.current == 22,
                     "A cached device shows the target before the command's preflight read completes")
        try await wait { sent.count == 1 }
        precondition(desktop.sending && desktop.displayedTarget == 23)
        desktop.setDegrees(desktop.displayedTarget! + 1)
        desktop.setDegrees(desktop.displayedTarget! + 1)
        desktop.setDegrees(desktop.displayedTarget! - 1)
        precondition(desktop.displayedTarget == 24 && desktop.current == 22,
                     "Pending clicks must immediately update the displayed target, not the confirmed snapshot")
        held = false
        try await wait { !desktop.sending }
        precondition(sent.count == 2 && desktop.current == 24,
                     "Desktop LG must serialize requests and send the latest unsent temperature")
        desktop.stop()
        print("Desktop LG: slow response does not block +/-; immediate 23→24→25→24 display, two ordered writes, confirmed 24.")
        for supportsLow in [true, false] {
            let cold = LGStore()
            let id = "fixture-first-read"
            cold.selected = id
            cold.devices = [Device(id: id, name: "Cold start")]
            var coldState = unit.state
            var coldProfile = unit.profile
            if !supportsLow {
                coldProfile["airFlow"] = ["windStrength": ["writable": true, "writeValues": ["HIGH"]]]
            }
            var writes: [[String: Any]] = []
            cold.api = API(request: { path, payload in
                if path.hasSuffix("/profile") { return coldProfile }
                if let payload {
                    writes.append(payload)
                    for (group, values) in payload { coldState[group] = values }
                }
                return coldState
            })
            precondition(cold.canSelectPreset(.high, for: id))
            cold.selectPreset(.high, for: id)
            cold.selectPreset(.low, for: id)
            precondition(cold.polling && writes.isEmpty && cold.isSelectedPreset(.low, for: id)
                         && !cold.isSelectedPreset(.high, for: id) && !cold.isSelectedPreset(.low, for: "other"))
            try await wait { !cold.polling && !cold.sending }
            precondition(cold.isSelectedPreset(.low, for: id) == supportsLow)
            precondition(writes.contains { ($0["airFlow"] as? [String: String])?["windStrength"] == "LOW" } == supportsLow)
            precondition(!writes.contains { ($0["airFlow"] as? [String: String])?["windStrength"] == "HIGH" })
            if !supportsLow { precondition(writes.isEmpty && !cold.message.isEmpty) }
            cold.stop()
        }
        let multiLG = LGStore()
        multiLG.devices = ["primary", "recent", "stale"].map { Device(id: $0, name: $0) }
        multiLG.selected = "primary"
        multiLG.profile = unit.profile
        multiLG.checked["recent"] = Date()
        var readPaths: [String] = []
        var waitingForStale = true
        multiLG.api = API(request: { path, _ in
            readPaths.append(path)
            if path == "devices/primary/state" { throw LGError(message: "Primary offline") }
            if path == "devices/stale/state" {
                while waitingForStale { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            return reported
        })
        multiLG.panelOpened()
        try await wait { readPaths == ["devices/stale/state"] }
        multiLG.manualRefresh(allDevices: true)
        try await wait { !multiLG.polling }
        precondition(!multiLG.connected && multiLG.summaryTask != nil)
        waitingForStale = false
        try await wait { multiLG.summaryTask == nil }
        precondition(readPaths == ["devices/stale/state", "devices/primary/state", "devices/recent/state"],
                     "Manual refresh must join the current card read and fetch recently cached cards even if the selected device fails")
        multiLG.refreshOtherCards()
        precondition(multiLG.summaryTask == nil, "Automatic refresh must still honor the 60-second interval")
        readPaths = []
        multiLG.checked["recent"] = .distantPast
        multiLG.refresh()
        try await wait { !multiLG.polling && multiLG.summaryTask == nil }
        precondition(Set(readPaths) == ["devices/primary/state", "devices/recent/state"],
                     "Automatic polling of other LG cards must continue when the selected unit fails")
        while !multiLG.autoRetry.stopped { multiLG.autoRetry.fail() }
        readPaths = []
        multiLG.checked["recent"] = .distantPast
        multiLG.refresh()
        try await wait { multiLG.summaryTask == nil }
        precondition(readPaths == ["devices/recent/state"],
                     "Backoff for the selected LG must not stop other LG cards")
        multiLG.stop()
        let priorTCLSignOut = defaults.object(forKey: "tcl.signedOut")
        defer { defaults.set(priorTCLSignOut, forKey: "tcl.signedOut") }
        defaults.set(false, forKey: "tcl.signedOut")
        let slowTCL = SlowTCL()
        let tcl = ClimateStore(directory: folder.appendingPathComponent("queue-test"), batchingDelay: 0,
            fetch: { slowTCL.fetch() }, apply: { _, edits in slowTCL.apply(edits) })
        await tcl.refreshAndWait()
        tcl.select(tcl.devices.first { $0.id == "synthetic-queued-tcl" }!)
        precondition(tcl.selected != nil && !tcl.refreshing)
        let reportedRevision = tcl.reportedRevision
        let otherCheckedAt = tcl.reportedDate(id: "synthetic-other-tcl")
        var sawPerDeviceConfirmation = false
        let confirmations = tcl.$reportedRevision.dropFirst().sink { _ in
            if tcl.reportedDate(id: "synthetic-queued-tcl")! > otherCheckedAt!,
               tcl.reportedDate(id: "synthetic-other-tcl") == otherCheckedAt {
                sawPerDeviceConfirmation = true
            }
        }
        tcl.setTemperature(tcl.selected!, 23)
        try await wait { slowTCL.count == 1 }
        precondition(tcl.hasPendingCommands && tcl.reportedRevision == reportedRevision,
                     "Optimistic UI edits cannot publish a confirmed widget revision")
        tcl.setTemperature(tcl.selected!, 24)
        tcl.setTemperature(tcl.selected!, 25)
        tcl.setTemperature(tcl.selected!, 24)
        precondition(tcl.selected?.target == 24 && tcl.isPending(id: tcl.selected!.id))
        let tclAfterEdits = Task { await tcl.refreshAndWait() }
        await Task.yield()
        slowTCL.release.signal()
        await tclAfterEdits.value
        precondition(!tcl.isPending(id: tcl.selected!.id) && !tcl.refreshing)
        precondition(slowTCL.count == 2 && tcl.selected?.target == 24)
        precondition(!tcl.hasPendingCommands && tcl.reportedRevision >= reportedRevision + 2,
                     "Each completed command publishes a revision after reconciling the reported state")
        precondition(sawPerDeviceConfirmation, "Confirming one AC must not freshen another AC's older widget state")
        confirmations.cancel()
        print("TCL: slow response preserves optimistic target and coalesces queued temperature edits.")
        for accepted in [false, true] {
            try await checkTCLPresetReadback(in: folder, accepted: accepted)
        }
        print("TCL: immediate preset selection, device isolation, lost acknowledgement and readback rollback verified.")
        print("Memory lifecycle: 12,000 cached samples bounded to 6,000, device/file limits, nonblocking hydration, model release, LG cancellation and account isolation passed.")
    }

    @MainActor private static func checkTCLPresetReadback(in folder: URL, accepted: Bool) async throws {
        let original: JSONObject = ["powerSwitch": 1, "targetTemperature": 24, "workMode": 1,
            "windSpeed": 4, "turbo": 0, "silenceSwitch": 0, "ECO": 0,
            "verticalDirection": 9, "horizontalDirection": 9, "verticalSwitch": 0, "horizontalSwitch": 0]
        func row(_ id: String, _ report: JSONObject) -> JSONObject {
            ["id": id, "name": id, "power": true, "online": true, "target": report["targetTemperature"]!,
             "reported": report]
        }
        let release = DispatchSemaphore(value: 0)
        var didSend = false
        var actual = original
        let store = ClimateStore(directory: folder.appendingPathComponent(UUID().uuidString), batchingDelay: 0,
            fetch: {
                if didSend { release.wait() }
                return [row("first", actual), row("second", original)]
            }, apply: { id, edits in
                precondition(id == "first")
                didSend = true
                if accepted {
                    for (field, value) in try DeviceService.desired(edits, report: actual) { actual[field] = value }
                }
                throw ACError("Synthetic acknowledgement lost")
            })
        await store.refreshAndWait()
        store.selection = "first"
        let revision = store.reportedRevision
        store.preset(store.selected!, .quiet)
        precondition(TCLCoolingPreset.quiet.isSelected(on: store.selected!))
        store.preset(store.selected!, .turbo)
        precondition(TCLCoolingPreset.turbo.isSelected(on: store.selected!) && !TCLCoolingPreset.quiet.isSelected(on: store.selected!))
        store.selection = "second"
        precondition(store.selected?.target == 24 && !store.isPending(id: "second"))
        store.selection = "first"
        try await wait { store.refreshing }
        precondition(store.isPending(id: "first") && TCLCoolingPreset.turbo.isSelected(on: store.selected!),
                     "Losing the write response must preserve the tapped preset until the status read completes")
        precondition(store.reportedRevision == revision && store.reportedDevice(id: "first")?.target == 24)
        release.signal()
        try await wait { !store.refreshing && !store.hasPendingCommands }
        precondition(TCLCoolingPreset.turbo.isSelected(on: store.selected!) == accepted)
        precondition(store.selected?.target == (accepted ? 16 : 24) && (store.problem == nil) == accepted)
        precondition(store.reportedDevice(id: "first")?.target == store.selected?.target)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Synthetic asynchronous operation did not finish")
    }
}
