import Foundation
import Combine

struct PhoneLGDevice: Identifiable {
    let id: String, name: String
    var state: [String: Any] = [:]
    var profile: [String: Any] = [:]
    var checked: Date?
    var problem: String?
    private var sample: LGSample { LGSample(state) }
    func value(_ group: String, _ key: String) -> Any? {
        LGDeviceValues.value(group, key, in: state)
    }
    var target: Double? { sample.target }
    var room: Double? { sample.room }
    var windKey: String { LGDeviceValues.windKey(in: profile) }
    var power: Bool? { sample.powerOn }
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
    @Published var problem: String?
    @Published var busy = false
    @Published var history: [String: [EnergyDayPoint]] = [:]
    @Published var historyProblem: [String: String] = [:]
    private var historyAttempt: [String: Date] = [:]
    var changed: (() -> Void)?
    private var api: API
    private let makeAPI: () -> API
    private let saveToken: (String) throws -> Void
    private let validateCredentials: (String, String, String) async throws -> Void
    private let preferences: UserDefaults
    private var accountGeneration = 0

    init(makeAPI: @escaping () -> API = { API() },
         saveToken: @escaping (String) throws -> Void = TokenFile.save,
         preferences: UserDefaults = defaults,
         validateCredentials: @escaping (String, String, String) async throws -> Void = { try await API.validateCredentials(token: $0, country: $1, region: $2) }) {
        self.makeAPI = makeAPI; self.saveToken = saveToken; self.preferences = preferences
        self.validateCredentials = validateCredentials
        api = makeAPI()
    }

    func configureMobile(email: String, password: String, country: String) async throws {
        guard !busy else { throw ACError("Wait for LG to finish.") }
        busy = true
        do { try await LGMobileClient.connect(email: email, password: password, country: country) }
        catch { busy = false; throw error }
        preferences.set(country.uppercased(), forKey: "country")
        accountGeneration &+= 1
        api = makeAPI(); devices = []; history = [:]; historyAttempt = [:]; historyProblem = [:]
        busy = false
        await refresh()
    }

    func configure(token: String, country: String, region: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { throw ACError("Wait for LG to finish.") }
        guard ["kic", "eic", "aic"].contains(region),
              country.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil, !token.isEmpty else {
            throw ACError("Enter a token, two-letter country and a valid region.")
        }
        busy = true
        do {
            try await validateCredentials(token, country, region)
            try saveToken(token)
        } catch { busy = false; throw error }
        preferences.set(country.uppercased(), forKey: "country")
        preferences.set(region, forKey: "region")
        accountGeneration &+= 1
        api = makeAPI(); devices = []; history = [:]; historyAttempt = [:]; historyProblem = [:]
        busy = false
        await refresh()
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; changed?() }
        do {
            if devices.isEmpty {
                let response = try await api.request("devices")
                let list = response as? [[String: Any]] ?? find("devices", in: response) as? [[String: Any]] ?? []
                devices = list.compactMap { item in
                    let info = object(item["deviceInfo"] ?? item)
                    guard info["deviceType"] as? String == "DEVICE_AIR_CONDITIONER",
                          let id = item["deviceId"] as? String ?? info["deviceId"] as? String else { return nil }
                    return PhoneLGDevice(id: id, name: info["alias"] as? String ?? "LG")
                }
                if devices.isEmpty { throw ACError("No air conditioners in this LG account.") }
            }
            for index in devices.indices {
                try Task.checkCancellation()
                do {
                    if devices[index].profile.isEmpty {
                        devices[index].profile = object(try await api.request("devices/\(try API.deviceComponent(devices[index].id))/profile"))
                    }
                    devices[index].state = object(try await api.request("devices/\(try API.deviceComponent(devices[index].id))/state"))
                    devices[index].checked = Date(); devices[index].problem = nil
                } catch { devices[index].problem = error.localizedDescription }
            }
            problem = nil
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
    func send(_ device: PhoneLGDevice, group: String, key: String, value: Any) async {
        guard !busy, let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        guard device.allowed(group, key, value) else { problem = "This setting is not supported."; return }
        if group == "temperature", let n = lgNumber(value), !device.bounds.contains(n) { return }
        busy = true
        defer { busy = false; changed?() }
        do {
            var payload = [key: value]
            if group == "temperature" { payload["unit"] = "C" }
            _ = try await api.request("devices/\(try API.deviceComponent(device.id))/control", payload: [group: payload])
            var confirmed = false
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 800_000_000)
                devices[index].state = object(try await api.request("devices/\(try API.deviceComponent(device.id))/state"))
                devices[index].checked = Date()
                if let actual = devices[index].value(group, key), equal(actual, value) { confirmed = true; break }
            }
            devices[index].problem = confirmed ? nil : "LG has not confirmed this change."
            problem = nil
        } catch { devices[index].problem = error.localizedDescription }
    }
    var widgetMetrics: [WidgetMetric] {
        devices.map(\.widgetMetric)
    }

    func loadHistory(_ device: PhoneLGDevice) async {
        let now = Date()
        if let previous = historyAttempt[device.id], now.timeIntervalSince(previous) < 3600,
           Calendar.current.isDate(previous, inSameDayAs: now) { return }
        historyAttempt[device.id] = now
        let generation = accountGeneration
        let api = api
        defer {
            if Task.isCancelled, generation == accountGeneration, historyAttempt[device.id] == now {
                historyAttempt[device.id] = nil
            }
        }
        do {
            let component = try API.deviceComponent(device.id)
            let profile = try await api.request("devices/energy/\(component)/profile")
            guard generation == accountGeneration, !Task.isCancelled else { return }
            guard (find("property", in: profile) as? [String])?.contains("energyUsage") == true else {
                historyProblem[device.id] = "LG does not expose energy history for this device."; return
            }
            let calendar = Calendar.current
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
            let today = calendar.startOfDay(for: now)
            let dates = (-30 ... -1).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            let keys = dates.map(formatter.string)
            let response = try await api.request("devices/energy/\(component)/usage?property=energyUsage&period=DAILY&startDate=\(keys.first!)&endDate=\(keys.last!)")
            guard generation == accountGeneration, !Task.isCancelled else { return }
            var totals: [String: Double] = [:]
            for row in find("dataList", in: response) as? [[String: Any]] ?? [] {
                guard let wh = lgNumber(row["energyUsage"]), wh.isFinite, wh >= 0,
                      let raw = ["date", "usageDate", "usedDate", "useDate", "periodDate", "startDate", "dateTime"].compactMap({ row[$0] }).first else { continue }
                let key = String(String(describing: raw).filter(\.isNumber).prefix(8))
                guard keys.contains(key) else { continue }
                totals[key, default: 0] += wh
            }
            history[device.id] = keys.map { EnergyDayPoint(key: $0, label: String($0.suffix(2)), wattHours: totals[$0]) }
            historyProblem[device.id] = nil
        } catch {
            if generation == accountGeneration, !Task.isCancelled { historyProblem[device.id] = error.localizedDescription }
        }
    }
}
