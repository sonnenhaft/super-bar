import Foundation
import WidgetKit

// This executor is compiled only into the app. Provider clients read the app's
// Keychain; the extension shares only capabilities, readings and UI selection.
actor WidgetClimateExecutor {
    static let shared = WidgetClimateExecutor()
    private var busy = false
    private let tcl = TCLCommands()

    private init() {}

    func setTemperature(brand: String, deviceID: String, temperature: Int) async throws {
        try await execute(brand: brand, deviceID: deviceID, command: .temperature(temperature))
    }

    func setPower(brand: String, deviceID: String, powerOn: Bool) async throws {
        try await execute(brand: brand, deviceID: deviceID, command: .power(powerOn))
    }

    private enum Command: Sendable {
        case temperature(Int)
        case power(Bool)

        var tclFields: [(String, Int)] {
            switch self {
            case .temperature(let value): return [("targetTemperature", value)]
            case .power(let value): return [("powerSwitch", value ? 1 : 0)]
            }
        }
        var lgChange: (group: String, key: String, value: Any) {
            switch self {
            case .temperature(let value): return ("temperature", "targetTemperature", Double(value))
            case .power(let value): return ("operation", "airConOperationMode", value ? "POWER_ON" : "POWER_OFF")
            }
        }
    }

    private func execute(brand: String, deviceID: String, command: Command) async throws {
        guard !busy else {
            let error = ACError("Wait for the current conditioner change to finish.")
            await Self.report(error.localizedDescription, brand: brand, deviceID: deviceID)
            throw error
        }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            guard ["TCL", "LG"].contains(brand), !deviceID.isEmpty else {
                throw ACError("This conditioner is not supported.")
            }
            guard let cached = WidgetCache.read().climate.first(where: { $0.brand == brand && $0.id == deviceID }) else {
                throw ACError("Open Super Bar to refresh this conditioner.")
            }
            try Self.validate(cached, command: command)
            try await Self.setMessage("Sending…", brand: brand, deviceID: deviceID)
            let confirmed: WidgetMetric
            if brand == "TCL" {
                confirmed = try await tcl.apply(id: deviceID, command: command)
            } else {
                confirmed = try await sendLG(cached, command: command)
            }
            try await Self.saveConfirmed(confirmed)
        } catch {
            await Self.report(error is CancellationError ? "The change was interrupted. Refresh to check the conditioner." : error.localizedDescription,
                              brand: brand, deviceID: deviceID)
            throw error
        }
    }

    private static func validate(_ metric: WidgetMetric, command: Command) throws {
        guard let control = metric.control, control.enabled(at: Date()) else {
            throw ACError("Open Super Bar to refresh this conditioner's status.")
        }
        switch command {
        case .temperature(let value):
            guard control.validTemperature(value) else { throw ACError("This temperature is not supported by the conditioner.") }
            if metric.brand == "TCL", control.powerOn == false, !control.canSetPower {
                throw ACError("TCL cannot turn this conditioner on to set the temperature.")
            }
        case .power:
            guard control.canSetPower else { throw ACError("This conditioner does not support changing power here.") }
        }
    }

    private func sendLG(_ cached: WidgetMetric, command: Command) async throws -> WidgetMetric {
        let api = API()
        let path = "devices/" + (try API.deviceComponent(cached.id))
        var device = PhoneLGDevice(id: cached.id, name: cached.name)
        device.profile = object(try await api.request(path + "/profile"))
        device.state = object(try await api.request(path + "/state"))
        device.checked = Date()
        try Self.validate(device.widgetMetric, command: command)
        let change = command.lgChange
        guard device.allowed(change.group, change.key, change.value) else {
            throw ACError("LG does not support this setting.")
        }
        // A fresh matching state needs no publish and can immediately refresh
        // the widget. Otherwise accept only a later provider-confirmed state.
        if let actual = device.value(change.group, change.key), equal(actual, change.value) {
            return device.widgetMetric
        }
        try Task.checkCancellation()
        var payload = [change.key: change.value]
        if change.group == "temperature" { payload["unit"] = "C" }
        _ = try await api.request(path + "/control", payload: [change.group: payload])
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 800_000_000)
            device.state = object(try await api.request(path + "/state"))
            device.checked = Date()
            if let actual = device.value(change.group, change.key), equal(actual, change.value) {
                return device.widgetMetric
            }
        }
        throw ACError("LG has not confirmed this change. Refresh to check the conditioner.")
    }

    // Main-actor read/modify/write also serializes with PhoneModel.saveWidgets.
    @MainActor private static func saveConfirmed(_ metric: WidgetMetric) throws {
        var snapshot = WidgetCache.read()
        guard let index = snapshot.climate.firstIndex(where: { $0.brand == metric.brand && $0.id == metric.id }) else {
            throw ACError("The change was confirmed. Open Super Bar to refresh the widget.")
        }
        snapshot.climate[index] = metric
        try WidgetCache.write(snapshot)
        defer {
            WidgetCenter.shared.reloadAllTimelines()
            NotificationCenter.default.post(name: .init("SuperBarWidgetClimateChanged"), object: nil,
                                            userInfo: ["brand": metric.brand ?? "", "deviceID": metric.id])
        }
        var selection = WidgetClimateSelection.read()
        if let selected = selection.selected(in: snapshot), selected.brand == metric.brand, selected.id == metric.id {
            selection.pickingTemperature = false
            selection.message = nil
            try WidgetClimateSelection.write(selection)
        }
    }

    @MainActor private static func setMessage(_ message: String, brand: String, deviceID: String) throws {
        var selection = WidgetClimateSelection.read()
        guard let selected = selection.selected(in: WidgetCache.read()), selected.brand == brand, selected.id == deviceID else { return }
        selection.message = message
        try WidgetClimateSelection.write(selection)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @MainActor private static func report(_ message: String, brand: String, deviceID: String) {
        try? setMessage(message, brand: brand, deviceID: deviceID)
        // Even a sharing failure should clear a previously shown pending state
        // when the provider next refreshes the widget's timeline.
        WidgetCenter.shared.reloadAllTimelines()
    }

    // ControlSession performs synchronous network I/O and confirmation polling.
    // Its mutable state is confined to this queue, away from actor executors.
    private final class TCLCommands: @unchecked Sendable {
        private let queue = WidgetCommandQueue()

        func apply(id: String, command: Command) async throws -> WidgetMetric {
            try await queue.run(makeSession: { DeviceService.ControlSession(directory: DeviceService.directory) }) { session, cancellation in
                // Empty edits only fetch and normalize the current shadow;
                // ControlSession never publishes an empty desired state.
                let current = try session.apply(id: id, fields: [], checkCancellation: cancellation.check)
                guard let live = Aircon(current), live.id == id else { throw ACError("TCL did not return this conditioner's status.") }
                try WidgetClimateExecutor.validate(live.widgetMetric(checkedAt: Date()), command: command)
                var fields = command.tclFields
                let turnOn: Bool
                if case .temperature = command { turnOn = live.power == false } else { turnOn = false }
                if turnOn { fields.insert(("powerSwitch", 1), at: 0) }
                let row = try session.apply(id: id, fields: fields, checkCancellation: cancellation.check)
                guard let confirmed = Aircon(row), confirmed.id == id, !confirmed.failed,
                      confirmed.online == true else { throw ACError("TCL did not confirm this change.") }
                switch command {
                case .temperature(let value):
                    guard confirmed.target == Double(value) else { throw ACError("TCL did not confirm this temperature.") }
                    if turnOn, confirmed.power != true { throw ACError("TCL did not confirm the power change.") }
                case .power(let value):
                    guard confirmed.power == value else { throw ACError("TCL did not confirm the power change.") }
                }
                // A sensor's timestamp can precede a successful control
                // check; freshness here refers to this completed request.
                return confirmed.widgetMetric(checkedAt: Date())
            }
        }
    }
}
