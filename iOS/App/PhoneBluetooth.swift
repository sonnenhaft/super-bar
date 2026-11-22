import Foundation
import CoreBluetooth
import Combine
import UIKit

struct PhoneBattery: Codable, Identifiable {
    var id: String, name: String
    var percent: Int
    var acInput: Double?, dcInput: Double?, acOutput: Double?, dcOutput: Double?
    var remainingSeconds: Int?, chargeSeconds: Int?
    var date: Date
    var gridPresent: Bool?
    var output: Double? { acOutput.flatMap { ac in dcOutput.map { ac + $0 } } }
    var runtimeLabel: String {
        let input = AC50PAutonomy.externalInput(grid: gridPresent, acWatts: acInput.flatMap(Int.init(exactly:)),
                                                dcWatts: dcInput.flatMap(Int.init(exactly:)))
        return AC50PAutonomy.runtimeLabel(percent: percent, reported: remainingSeconds, externalInput: input,
                                          acWatts: acOutput.flatMap(Int.init(exactly:)), dcWatts: dcOutput.flatMap(Int.init(exactly:)))
    }
}

// The protocol/crypto is shared with macOS; the iOS transport never spins a RunLoop
// or launches a helper process. All waits suspend and cancellation closes the link.
@MainActor final class PhoneBluetooth: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum RefreshRequest: Equatable { case scan, station(String) }
    @Published private(set) var refreshRequest: RefreshRequest?
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var scanDevices: [BluettiNativeDevice] = []
    @Published private var connectedID: String? {
        didSet { if oldValue != connectedID { changed?() } }
    }
    // During a scan the transport visits each battery in turn. Releasing a
    // healthy link to visit the next station does not make the first unreachable.
    @Published private var availability: [String: Bool] = [:] {
        didSet { if oldValue != availability { changed?() } }
    }
    private var previousScan: Set<String>?
    private var discoveryRetry = BluettiDiscoveryRetry()
    func stationReachability(_ id: String) -> Bool? {
        if authorization == .denied || authorization == .restricted { return false }
        switch central?.state {
        case .poweredOff, .unsupported, .unauthorized: return false
        default: break
        }
        if availability[id] == false { return false }
        guard let reading = readings.first(where: { $0.id == id }) else { return nil }
        if !(-60...300).contains(Date().timeIntervalSince(reading.date)) { return false }
        return availability[id]
    }
    @Published private(set) var authorization = CBManager.authorization
    var needsBluetoothPermission: Bool { authorization != .allowedAlways }
    @Published var readings: [PhoneBattery] = []
    let outputHistory = DevicePowerHistory(provider: "bluetti", maximumGap: 180)
    @Published var busy = false
    @Published var message = "Looking for nearby BLUETTI stations…"
    @Published private(set) var scanning = false
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var failedRefreshID: String?
    @Published private(set) var selectedID: String?
    private let directory = BlueBarStationDirectory(defaults: .standard)
    private var foreground = false
    private var generation = UUID()
    var changed: (() -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var ready = false
    private var writeComplete = false
    private var writeError: Error?
    private var failure: Error?
    private var codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
    private var task: Task<Void, Never>?
    private static let maximumDiscovered = 64
    private static let maximumSavedReadings = 16

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "phone.batteries"), data.count <= 256 * 1024,
           let saved = try? JSONDecoder().decode([PhoneBattery].self, from: data) {
            readings = Array(saved.filter { (0...100).contains($0.percent) }
                .sorted { $0.date > $1.date }.prefix(Self.maximumSavedReadings))
        }
        selectedID = UserDefaults.standard.string(forKey: "phone.selectedBattery")
        for reading in readings { directory.observe(deviceID: reading.id, bluetoothName: reading.name) }
        #if DEBUG
        // Optional one-time transfer of display names for a development install.
        // No accounts, tokens or host-specific Bluetooth UUIDs are imported.
        if let value = ProcessInfo.processInfo.environment["SUPER_BAR_STATION_ALIASES"],
           let data = value.data(using: .utf8), data.count <= 16_384,
           let aliases = try? JSONDecoder().decode([String: String].self, from: data),
           UserDefaults.standard.dictionary(forKey: "phone.importedStationAliases") as? [String: String] != aliases {
            directory.importAliases(aliases)
            UserDefaults.standard.set(aliases, forKey: "phone.importedStationAliases")
        }
        #endif
    }
    var stations: [BlueBarKnownStation] { directory.stations }
    func displayName(id: String, name: String) -> String {
        if let alias = directory.station(deviceID: id, bluetoothName: name)?.alias { return alias }
        // The advertisement contains the serial number, not the user's name.
        return name.uppercased().hasPrefix("AC50P") ? "AC50P · " + String(name.suffix(4)) : name
    }
    func rename(id: String?, name: String, alias: String) {
        objectWillChange.send()
        directory.setAlias(alias, deviceID: id, bluetoothName: name)
        changed?()
    }
    func start() {
        foreground = true
        authorization = CBManager.authorization
        if !needsBluetoothPermission && task?.isCancelled != false { restart() }
    }
    func requestBluetoothPermission() {
        if CBManager.authorization == .denied {
            if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
        } else if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    func scan() {
        requestRefresh(.scan)
    }
    func select(_ id: String) {
        guard selectedID != id else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: "phone.selectedBattery")
    }
    func refreshStation(_ id: String) {
        guard stations.contains(where: { $0.deviceID == id }) else { return }
        requestRefresh(.station(id))
    }
    private func requestRefresh(_ request: RefreshRequest) {
        guard foreground, !needsBluetoothPermission else { return }
        if refreshRequest != nil {
            if request == .scan { refreshRequest = .scan }
            return
        }
        failedRefreshID = nil
        refreshRequest = request
        // An active pass owns the decoder through its handshake and reads.
        // During the polling delay, wake it without closing its open link.
        if !busy { restart(keepingConnection: true) }
    }
    func refreshNow() async {
        guard foreground, !needsBluetoothPermission, !Task.isCancelled else { return }
        // Whole-app refresh covers both batteries; opening a card never reconnects.
        scan()
        guard refreshRequest != nil else { return }
        await withCheckedContinuation { refreshWaiters.append($0) }
    }
    private func finishRefresh() {
        guard refreshRequest != nil else { return }
        refreshRequest = nil
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func restart(keepingConnection: Bool = false) {
        let previous = task
        previous?.cancel()
        stopScan()
        if !keepingConnection { disconnect() }
        let current = UUID()
        generation = current
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        task = Task {
            // Cancellation must finish before another operation uses the decoder.
            await previous?.value
            guard !Task.isCancelled, foreground, generation == current else { return }
            defer {
                if generation == current {
                    stopScan(); disconnect()
                    busy = false; scanning = false; finishRefresh(); task = nil
                }
            }
            await monitor()
        }
    }
    private func monitor() async {
        while foreground && !needsBluetoothPermission && !Task.isCancelled {
            do {
                if peripheral == nil { failure = nil }
                busy = true
                let devices: [BluettiNativeDevice]
                let stationPass: Bool
                if case .station(let id) = refreshRequest {
                    stationPass = true
                    try await waitForBluetooth()
                    if peripherals[id] == nil { retrieveStation(id) }
                    guard peripherals[id] != nil else {
                        problems[id] = "Station disconnected before it could be refreshed."
                        failedRefreshID = id
                        finishRefresh()
                        continue
                    }
                    devices = [BluettiNativeDevice(id: id, name: stationName(id))]
                } else {
                    stationPass = false
                    devices = try await discoverStations()
                }
                if devices.isEmpty { message = "No AC50P nearby. Searching again automatically…" }
                for device in devices {
                    try Task.checkCancellation()
                    guard let target = peripherals[device.id] else { continue }
                    do {
                        message = "Reading " + displayName(id: device.id, name: device.name) + "…"
                        if target !== peripheral || connectedID != device.id || failure != nil {
                            disconnect()
                            try await connectStation(target)
                        }
                        try await readStation(device)
                        availability[device.id] = true
                        problems[device.id] = nil
                        if failedRefreshID == device.id { failedRefreshID = nil }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        problems[device.id] = (error as? BluettiNativeFailure)?.message ?? error.localizedDescription
                        availability[device.id] = false
                        if refreshRequest == .scan || refreshRequest == .station(device.id) { failedRefreshID = device.id }
                        disconnect()
                    }
                    if refreshRequest == .station(device.id) { finishRefresh() }
                }
                if !devices.isEmpty {
                    message = problems.isEmpty ? "Readings update automatically while the app is open."
                        : "Some stations are unavailable. Retrying automatically…"
                }
                busy = false
                // A whole-app request during a single-station read must reach
                // the next discovery pass before its waiter completes.
                if !stationPass && refreshRequest == .scan { finishRefresh() }
                // A request for a station already visited by this pass still needs a read.
                if refreshRequest == nil {
                    try await RefreshPreferences.wait(.bluetti, since: ProcessInfo.processInfo.systemUptime)
                }
            } catch is CancellationError { break }
            catch {
                guard !Task.isCancelled else { break }
                stopScan(); disconnect(); busy = false
                if case .station(let id) = refreshRequest {
                    problems[id] = error.localizedDescription
                    failedRefreshID = id
                }
                finishRefresh()
                message = error.localizedDescription
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
    private func stationName(_ id: String) -> String {
        directory.stations.first { $0.deviceID == id }?.bluetoothName ?? peripheral?.name ?? "AC50P"
    }
    private func waitForBluetooth() async throws {
        try await wait {
            guard let state = self.central?.state else { return false }
            return state != .unknown && state != .resetting
        }
        switch central?.state {
        case .poweredOn: break
        case .unauthorized: throw ACError("Allow Bluetooth for Super Bar in Settings.")
        case .poweredOff: throw ACError("Turn on Bluetooth in Settings.")
        default: throw ACError("Bluetooth is unavailable on this device.")
        }
    }
    private func retrieveStation(_ id: String) {
        guard central?.state == .poweredOn, let uuid = UUID(uuidString: id),
              let known = central?.retrievePeripherals(withIdentifiers: [uuid]).first,
              (known.name ?? stationName(id)).uppercased().contains("AC50P"),
              peripherals[id] != nil || peripherals.count < Self.maximumDiscovered else { return }
        peripherals[id] = known
    }
    private func stopScan() {
        if central?.state == .poweredOn { central?.stopScan() }
        scanning = false
    }
    private func discoverStations() async throws -> [BluettiNativeDevice] {
        message = "Looking for nearby BLUETTI stations…"
        try await waitForBluetooth()
        scanDevices.removeAll(keepingCapacity: true)
        scanning = true
        central?.scanForPeripherals(withServices: nil)
        defer { stopScan() }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try Task.checkCancellation()
        try await waitForBluetooth()
        // A lost link must not discard other stations from this scan.
        // Radio and permission failures were handled above.
        if failure != nil { disconnect(); failure = nil }
        let advertised = Set(scanDevices.map(\.id))
        // A connected station may stop advertising.
        if let id = connectedID, !scanDevices.contains(where: { $0.id == id }) {
            scanDevices.append(BluettiNativeDevice(id: id, name: stationName(id)))
        }
        // Retry successfully read stations without requiring a fresh advert.
        // Retrieving an object alone never marks its station online.
        var knownIDs: [String] = []
        for id in readings.sorted(by: { $0.date > $1.date }).map(\.id) + stations.compactMap(\.deviceID)
            where !knownIDs.contains(id) && knownIDs.count < Self.maximumSavedReadings {
            knownIDs.append(id)
        }
        var found = Set(scanDevices.map(\.id))
        for id in knownIDs where availability[id] == true && peripherals[id] != nil && !found.contains(id) {
            scanDevices.append(BluettiNativeDevice(id: id, name: stationName(id)))
            found.insert(id)
        }
        for id in discoveryRetry.candidates(knownIDs: knownIDs, found: found, now: ProcessInfo.processInfo.systemUptime) {
            retrieveStation(id)
            if peripherals[id] != nil {
                scanDevices.append(BluettiNativeDevice(id: id, name: stationName(id)))
            }
        }
        let nearby = Set(scanDevices.map(\.id))
        // A station may miss a short advertisement window after link handoff.
        // Two completed scans without it confirm absence. A failed read is immediate.
        if let previousScan {
            var next = availability
            for station in stations {
                let id = station.deviceID ?? station.key
                if !nearby.contains(id) && !previousScan.contains(id) { next[id] = false }
            }
            if next != availability { availability = next }
        }
        previousScan = nearby
        let known = Set(knownIDs)
        peripherals = peripherals.filter { nearby.contains($0.key) || known.contains($0.key) }
        let activeStationID = connectedID
        let lastAvailability = availability
        func priority(_ device: BluettiNativeDevice) -> Int {
            if device.id == activeStationID { return 0 }
            if lastAvailability[device.id] == true { return 1 }
            return advertised.contains(device.id) ? 2 : 3
        }
        return scanDevices.sorted {
            // Read the open link first and hand it off only to read another station.
            let left = priority($0), right = priority($1)
            if left != right { return left < right }
            return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
    }
    private func wait(seconds: TimeInterval = 6, until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard ProcessInfo.processInfo.systemUptime < end else { throw ACError("Bluetooth timed out. Keep the station nearby and close other BLUETTI clients.") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    private func connectStation(_ target: CBPeripheral) async throws {
        failure = nil
        guard central?.state == .poweredOn else { throw ACError("Bluetooth is unavailable. Retrying when it is ready.") }
        // A previous cancellation of this peripheral may still be in flight.
        try await wait(seconds: 4) { target.state == .disconnected }
        try Task.checkCancellation()
        ready = false; writer = nil
        codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
        peripheral = target; target.delegate = self
        central?.connect(target)
        try await wait(seconds: 12) { self.ready && self.writer != nil }
        let challenge = try await key(1)
        let reply = try codec.crypto.replyChallenge(challenge)
        do { try await write(reply, preferResponse: true) }
        catch {
            try Task.checkCancellation()
            if let failure { throw failure }
            // Same bounded ATT fallback as the Mac handshake, with identical bytes.
            try await write(reply)
        }
        let peer = try await key(4)
        let response = try codec.crypto.replyPeer(peer)
        try await write(response)
        let accepted: [UInt8]
        do { accepted = try await key(6, timeout: 2.5) }
        catch {
            try Task.checkCancellation()
            if let failure { throw failure }
            try await write(response)
            accepted = try await key(6, timeout: 2)
        }
        try codec.crypto.acceptPeer(accepted)
        try await write(codec.crypto.encrypt([1]))
    }
    private func readStation(_ device: BluettiNativeDevice) async throws {
        var registers: [UInt16: UInt16] = [:]
        for (address, quantity) in BluettiIoTProtocol.pollWindows {
            try await write(codec.crypto.encrypt(BluettiIoTProtocol.readHolding(address: address, quantity: quantity)))
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            var values: [UInt16]?
            while values == nil {
                if case .application(let bytes) = try await next(deadline: deadline), !bytes.isEmpty, bytes != [1] {
                    values = try BluettiIoTProtocol.parseHolding(bytes, quantity: quantity)
                }
            }
            for (offset, value) in values!.enumerated() { registers[address + UInt16(offset)] = value }
        }
        let snapshot = try BluettiIoTProtocol.snapshot(registers: registers, device: device)
        guard let percent = snapshot["battery_percent"] as? Int, (0...100).contains(percent) else {
            throw ACError("Station did not return a valid battery percentage.")
        }
        let battery = PhoneBattery(id: device.id, name: device.name,
            percent: percent,
            acInput: CloudValue.number(snapshot["ac_input_w"]), dcInput: CloudValue.number(snapshot["dc_input_w"]),
            acOutput: CloudValue.number(snapshot["ac_output_w"]) ?? (snapshot["ac_on"] as? Bool == false ? 0 : nil),
            dcOutput: CloudValue.number(snapshot["dc_output_w"]) ?? (snapshot["dc_on"] as? Bool == false ? 0 : nil),
            remainingSeconds: (snapshot["runtime"] as? [String: Any])?["remaining_seconds"] as? Int,
            chargeSeconds: snapshot["time_to_full_seconds"] as? Int, date: Date(), gridPresent: snapshot["grid_present"] as? Bool)
        readings.removeAll { $0.id == battery.id }; readings.append(battery)
        outputHistory.record(battery.output, for: battery.id, at: battery.date)
        if readings.count > Self.maximumSavedReadings {
            readings = Array(readings.sorted { $0.date > $1.date }.prefix(Self.maximumSavedReadings))
        }
        if let data = try? JSONEncoder().encode(readings) { UserDefaults.standard.set(data, forKey: "phone.batteries") }
        changed?()
    }
    func stop() {
        foreground = false
        previousScan = nil
        discoveryRetry = BluettiDiscoveryRetry()
        task?.cancel()
        stopScan()
        disconnect()
        scanning = false; busy = false; finishRefresh()
        message = "Last readings saved. Bluetooth resumes when you return."
    }
    private func disconnect() {
        let previous = peripheral
        peripheral = nil; writer = nil; ready = false
        if connectedID != nil { connectedID = nil }
        previous?.delegate = nil
        if let previous, central?.state == .poweredOn, previous.state != .disconnected {
            central?.cancelPeripheralConnection(previous)
        }
        codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
    }
    private func next(deadline: TimeInterval) async throws -> BluettiFrame {
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            if let frame = try codec.next() { return frame }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ACError("Station reply timed out.") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    private func key(_ type: UInt8, timeout: TimeInterval = 6) async throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if case .keyExchange(let bytes) = try await next(deadline: deadline),
               try BluettiIoTProtocol.parseKeyExchange(bytes).type == type { return bytes }
        }
    }
    private func write(_ bytes: [UInt8], preferResponse: Bool = false) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard central?.state == .poweredOn, let peripheral, peripheral.state == .connected,
              let writer else { throw ACError("Station is disconnected.") }
        let response = preferResponse && writer.properties.contains(.write)
        guard response || writer.properties.contains(.writeWithoutResponse) else { throw ACError("Station does not support the required Bluetooth writes.") }
        let type: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
        let length = peripheral.maximumWriteValueLength(for: type)
        guard length > 0 else { throw ACError("Invalid Bluetooth packet length.") }
        for start in stride(from: 0, to: bytes.count, by: length) {
            try Task.checkCancellation()
            if !response { try await wait { peripheral.canSendWriteWithoutResponse } }
            writeComplete = false
            writeError = nil
            peripheral.writeValue(Data(bytes[start..<min(bytes.count, start + length)]), for: writer, type: type)
            if response { try await wait { self.writeComplete } }
            if let failure { throw failure }
            if let writeError { throw writeError }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        authorization = CBManager.authorization
        switch central.state {
        case .poweredOn:
            failure = nil
            if foreground && !needsBluetoothPermission && task == nil { restart() }
            return
        case .unknown, .resetting:
            if peripheral != nil { failure = ACError("Bluetooth is restarting.") }
        case .unauthorized: failure = ACError("Allow Bluetooth for Super Bar in Settings.")
        case .poweredOff: failure = ACError("Turn on Bluetooth in Settings.")
        default: failure = ACError("Bluetooth is unavailable on this device.")
        }
        previousScan = nil
        if central.state == .unauthorized || central.state == .poweredOff || central.state == .unsupported {
            availability = Dictionary(uniqueKeysWithValues: stations.map { ($0.deviceID ?? $0.key, false) })
        }
        if let failure { message = failure.localizedDescription }
        if connectedID != nil { connectedID = nil }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard foreground, scanning, central.state == .poweredOn else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.uppercased().contains("AC50P") else { return }
        let id = peripheral.identifier.uuidString.lowercased()
        guard peripherals[id] != nil || peripherals.count < Self.maximumDiscovered else { return }
        peripherals[id] = peripheral
        if !scanDevices.contains(where: { $0.id == id }) {
            scanDevices.append(BluettiNativeDevice(id: id, name: name))
            if directory.station(deviceID: id, bluetoothName: name)?.bluetoothName == name { return }
            directory.observe(deviceID: id, bluetoothName: name)
            objectWillChange.send()
            changed?()
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard foreground, peripheral === self.peripheral, central.state == .poweredOn else { return }
        connectedID = peripheral.identifier.uuidString.lowercased()
        peripheral.discoverServices([CBUUID(string: "FF00")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failure = error ?? ACError("Could not connect to the station.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        availability[peripheral.identifier.uuidString.lowercased()] = false
        if connectedID != nil { connectedID = nil }
        failure = error ?? ACError("Station disconnected.")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { failure = error; return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FF00") }) else {
            failure = ACError("AC50P service not found."); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "FF01"), CBUUID(string: "FF02")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { failure = error; return }
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "FF02") }
        guard let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "FF01") }) else {
            failure = ACError("Station notifications not found."); return
        }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { failure = error } else { ready = characteristic.isNotifying }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { failure = error; return }
        if let data = characteristic.value { do { try codec.append(Array(data)) } catch { failure = error } }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === writer else { return }
        // An ATT acknowledgement must never clear a simultaneous link failure.
        writeError = error; writeComplete = true
    }
    var widgetMetrics: [WidgetMetric] {
        stations.map { station in
            let id = station.deviceID ?? station.key
            let reading = readings.first { $0.id == id }
            return WidgetMetric(id: id, name: station.alias ?? displayName(id: id, name: station.bluetoothName),
                value: reading.map { "\($0.percent)%" } ?? "—", detail: reading?.output.map(DisplayUnits.power) ?? "—",
                symbol: DeviceDisplayName.batterySymbol(percent: reading?.percent), updatedAt: reading?.date,
                online: stationReachability(id), batteryRuntime: reading?.runtimeLabel)
        }
    }
}
