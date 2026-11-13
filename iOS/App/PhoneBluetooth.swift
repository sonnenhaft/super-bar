import Foundation
import CoreBluetooth
import Combine

struct PhoneBattery: Codable, Identifiable {
    var id: String, name: String
    var percent: Int
    var acInput: Double?, dcInput: Double?, acOutput: Double?, dcOutput: Double?
    var remainingSeconds: Int?, chargeSeconds: Int?
    var date: Date
    var output: Double? { acOutput.flatMap { ac in dcOutput.map { ac + $0 } } }
}

// The protocol/crypto is shared with macOS; the iOS transport never spins a RunLoop
// or launches a helper process. All waits suspend and cancellation closes the link.
@MainActor final class PhoneBluetooth: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var discovered: [BluettiNativeDevice] = []
    @Published var readings: [PhoneBattery] = []
    @Published var busy = false
    @Published var message = "Looking for nearby BLUETTI stations…"
    @Published private(set) var scanning = false
    @Published private(set) var activeID: String?
    @Published private(set) var problems: [String: String] = [:]
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
    private var failure: Error?
    private var codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
    private var task: Task<Void, Never>?
    private static let maximumDiscovered = 64
    private static let maximumSavedReadings = 16

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "phone.batteries"), data.count <= 256 * 1024,
           let saved = try? JSONDecoder().decode([PhoneBattery].self, from: data) {
            readings = Array(saved.sorted { $0.date > $1.date }.prefix(Self.maximumSavedReadings))
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
        guard !foreground || task == nil else { return }
        foreground = true
        restart()
    }
    func scan() {
        foreground = true
        restart()
    }
    func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "phone.selectedBattery")
        scan()
    }
    private func restart() {
        let previous = task
        previous?.cancel()
        central?.stopScan()
        disconnect()
        let current = UUID()
        generation = current
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        task = Task {
            // Cancellation must finish before another operation uses the decoder.
            await previous?.value
            guard !Task.isCancelled, foreground, generation == current else { return }
            defer {
                if generation == current {
                    central?.stopScan(); disconnect()
                    busy = false; scanning = false; task = nil
                }
            }
            await monitor()
        }
    }
    private func monitor() async {
        while foreground && !Task.isCancelled {
            do {
                failure = nil; busy = true
                message = "Looking for nearby BLUETTI stations…"
                try await wait(seconds: 60) { self.central?.state == .poweredOn }
                scanning = true
                central?.scanForPeripherals(withServices: nil)
                try await Task.sleep(nanoseconds: 4_000_000_000)
                central?.stopScan(); scanning = false
                let devices = discovered.sorted {
                    if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
                    return $0.name < $1.name
                }
                if devices.isEmpty { message = "No AC50P nearby. Searching again automatically…" }
                for device in devices {
                    try Task.checkCancellation()
                    guard let target = peripherals[device.id] else { continue }
                    do {
                        try await readStation(device, target: target)
                        problems[device.id] = nil
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        problems[device.id] = (error as? BluettiNativeFailure)?.message ?? error.localizedDescription
                    }
                    disconnect()
                }
                if !devices.isEmpty {
                    message = problems.isEmpty ? "Readings update automatically while the app is open."
                        : "Some stations are unavailable. Retrying automatically…"
                }
                busy = false
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch is CancellationError { break }
            catch {
                central?.stopScan(); scanning = false; busy = false
                message = error.localizedDescription
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
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
    private func readStation(_ device: BluettiNativeDevice, target: CBPeripheral) async throws {
        failure = nil
        guard central?.state == .poweredOn else { throw ACError("Bluetooth is unavailable. Retrying when it is ready.") }
        // A previous cancellation of this peripheral may still be in flight.
        try await wait(seconds: 4) { target.state == .disconnected }
        try Task.checkCancellation()
        ready = false; writer = nil
        codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
        peripheral = target; target.delegate = self; activeID = device.id
        message = "Reading " + displayName(id: device.id, name: device.name) + "…"
        central?.connect(target)
        try await wait(seconds: 12) { self.ready && self.writer != nil }
        let challenge = try await key(1)
        try await write(codec.crypto.replyChallenge(challenge), preferResponse: true)
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
        let battery = PhoneBattery(id: device.id, name: device.name,
            percent: snapshot["battery_percent"] as? Int ?? 0,
            acInput: CloudValue.number(snapshot["ac_input_w"]), dcInput: CloudValue.number(snapshot["dc_input_w"]),
            acOutput: CloudValue.number(snapshot["ac_output_w"]), dcOutput: CloudValue.number(snapshot["dc_output_w"]),
            remainingSeconds: (snapshot["runtime"] as? [String: Any])?["remaining_seconds"] as? Int,
            chargeSeconds: snapshot["time_to_full_seconds"] as? Int, date: Date())
        readings.removeAll { $0.id == battery.id }; readings.append(battery)
        if readings.count > Self.maximumSavedReadings {
            readings = Array(readings.sorted { $0.date > $1.date }.prefix(Self.maximumSavedReadings))
        }
        if let data = try? JSONEncoder().encode(readings) { UserDefaults.standard.set(data, forKey: "phone.batteries") }
        changed?()
    }
    func stop() {
        foreground = false
        task?.cancel()
        central?.stopScan()
        disconnect()
        scanning = false; busy = false
        message = "Last readings saved. Bluetooth resumes when you return."
    }
    private func disconnect() {
        let previous = peripheral
        peripheral = nil; writer = nil; ready = false; activeID = nil
        previous?.delegate = nil
        if let previous { central?.cancelPeripheralConnection(previous) }
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
        guard let peripheral, let writer else { throw ACError("Station is disconnected.") }
        let response = preferResponse && writer.properties.contains(.write)
        guard response || writer.properties.contains(.writeWithoutResponse) else { throw ACError("Station does not support the required Bluetooth writes.") }
        let type: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
        let length = peripheral.maximumWriteValueLength(for: type)
        guard length > 0 else { throw ACError("Invalid Bluetooth packet length.") }
        for start in stride(from: 0, to: bytes.count, by: length) {
            try Task.checkCancellation()
            if !response { try await wait { peripheral.canSendWriteWithoutResponse } }
            writeComplete = false
            peripheral.writeValue(Data(bytes[start..<min(bytes.count, start + length)]), for: writer, type: type)
            if response { try await wait { self.writeComplete } }
            if let failure { throw failure }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn, .unknown, .resetting: break
        case .unauthorized: failure = ACError("Allow Bluetooth for Super Bar in Settings.")
        case .poweredOff: failure = ACError("Turn on Bluetooth in Settings.")
        default: failure = ACError("Bluetooth is unavailable on this device.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.uppercased().contains("AC50P") else { return }
        let id = peripheral.identifier.uuidString.lowercased()
        guard peripherals[id] != nil || peripherals.count < Self.maximumDiscovered else { return }
        peripherals[id] = peripheral
        if !discovered.contains(where: { $0.id == id }) {
            discovered.append(BluettiNativeDevice(id: id, name: name))
            directory.observe(deviceID: id, bluetoothName: name)
            objectWillChange.send()
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string: "FF00")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failure = error ?? ACError("Could not connect to the station.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { failure = error ?? ACError("Station disconnected.") }
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
        guard peripheral === self.peripheral else { return }
        failure = error; writeComplete = true
    }
    var widgetMetrics: [WidgetMetric] {
        readings.map { WidgetMetric(id: $0.id, name: displayName(id: $0.id, name: $0.name), value: "\($0.percent)%",
            detail: $0.output.map(DisplayUnits.power) ?? "Output unknown", symbol: "battery.100percent", updatedAt: $0.date) }
    }
}
