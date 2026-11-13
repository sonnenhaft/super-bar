import AppIntents
import Foundation
import WidgetKit

private enum WidgetClimateIntentError: LocalizedError {
    case unavailableDevice
    case unavailableTemperatureControl
    case requiresAppExecution

    var errorDescription: String? {
        switch self {
        case .unavailableDevice:
            return String(localized: "This air conditioner is no longer available. Open Super Bar to refresh it.")
        case .unavailableTemperatureControl:
            return String(localized: "Temperature control is unavailable for this air conditioner.")
        case .requiresAppExecution:
            return String(localized: "This command could not run in Super Bar. Open the app and try again.")
        }
    }
}

private func widgetClimateMetric(brand: String, deviceID: String) throws -> WidgetMetric {
    guard let metric = WidgetCache.read().climate.first(where: {
        $0.brand == brand && $0.id == deviceID
    }) else { throw WidgetClimateIntentError.unavailableDevice }
    return metric
}

private func saveWidgetClimateSelection(_ selection: WidgetClimateSelection) throws {
    try WidgetClimateSelection.write(selection)
    WidgetCenter.shared.reloadTimelines(ofKind: "SuperBar.home")
}

private func requireContainingAppExecution() throws {
    throw WidgetClimateIntentError.requiresAppExecution
}

struct SelectWidgetClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Air Conditioner"
    static let isDiscoverable = false

    @Parameter(title: "Brand") var brand: String
    @Parameter(title: "Device") var deviceID: String

    init() {}
    init(brand: String, deviceID: String) {
        self.brand = brand
        self.deviceID = deviceID
    }

    func perform() async throws -> some IntentResult {
        _ = try widgetClimateMetric(brand: brand, deviceID: deviceID)
        var selection = WidgetClimateSelection.read()
        selection.brand = brand
        selection.deviceID = deviceID
        selection.pickingTemperature = false
        selection.message = nil
        try saveWidgetClimateSelection(selection)
        return .result()
    }
}

struct ToggleWidgetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose Air Conditioner Temperature"
    static let isDiscoverable = false

    @Parameter(title: "Brand") var brand: String
    @Parameter(title: "Device") var deviceID: String

    init() {}
    init(brand: String, deviceID: String) {
        self.brand = brand
        self.deviceID = deviceID
    }

    func perform() async throws -> some IntentResult {
        let metric = try widgetClimateMetric(brand: brand, deviceID: deviceID)
        guard let control = metric.control, !control.temperatures.isEmpty else {
            throw WidgetClimateIntentError.unavailableTemperatureControl
        }
        var selection = WidgetClimateSelection.read()
        let alreadyPicking = selection.brand == brand && selection.deviceID == deviceID
            && selection.pickingTemperature
        selection.brand = brand
        selection.deviceID = deviceID
        selection.pickingTemperature = !alreadyPicking
        selection.message = nil
        try saveWidgetClimateSelection(selection)
        return .result()
    }
}

// Only display state is shared with the widget. Commands execute in the app,
// where the provider clients and their private Keychain credentials live.
struct SetWidgetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Air Conditioner Temperature"
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Brand") var brand: String
    @Parameter(title: "Device") var deviceID: String
    @Parameter(title: "Temperature") var temperature: Int

    init() {}
    init(brand: String, deviceID: String, temperature: Int) {
        self.brand = brand
        self.deviceID = deviceID
        self.temperature = temperature
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try requireContainingAppExecution()
        #else
        try await WidgetClimateExecutor.shared.setTemperature(
            brand: brand, deviceID: deviceID, temperature: temperature)
        #endif
        return .result()
    }
}

struct SetWidgetPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Air Conditioner Power"
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Brand") var brand: String
    @Parameter(title: "Device") var deviceID: String
    @Parameter(title: "Power On") var powerOn: Bool

    init() {}
    init(brand: String, deviceID: String, powerOn: Bool) {
        self.brand = brand
        self.deviceID = deviceID
        self.powerOn = powerOn
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try requireContainingAppExecution()
        #else
        try await WidgetClimateExecutor.shared.setPower(
            brand: brand, deviceID: deviceID, powerOn: powerOn)
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
// iOS 17–25 use this conformance to route widget commands to the app process.
// Newer systems use supportedModes and, on iOS 27, allowedExecutionTargets.
@available(iOS, introduced: 16.4, deprecated: 26.0)
extension SetWidgetTemperatureIntent: ForegroundContinuableIntent {}

@available(iOS, introduced: 16.4, deprecated: 26.0)
extension SetWidgetPowerIntent: ForegroundContinuableIntent {}
#endif
