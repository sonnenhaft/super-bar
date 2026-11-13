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
    @Published var message = "Allow Bluetooth to find nearby AC50P stations."
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
    private var selected: BluettiNativeDevice?
    private static let maximumDiscovered = 64
    private static let maximumSavedReadings = 16

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "phone.batteries"), data.count <= 256 * 1024,
           let saved = try? JSONDecoder().decode([PhoneBattery].self, from: data) {
            readings = Array(saved.sorted { $0.date > $1.date }.prefix(Self.maximumSavedReadings))
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
    func scan() {
        guard !busy else { return }
        busy = true; failure = nil
        message = "Looking for AC50P stations…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        task = Task {
            defer { central?.stopScan(); busy = false; task = nil }
            do {
                try await wait { self.central?.state == .poweredOn }
                discovered = []; peripherals = [:]
                central?.scanForPeripherals(withServices: nil)
                try await Task.sleep(nanoseconds: 5_000_000_000)
                message = discovered.isEmpty ? "No AC50P found nearby." : "Choose a station to connect."
            } catch { message = error.localizedDescription }
        }
    }
    func connect(_ device: BluettiNativeDevice) {
        guard !busy, let target = peripherals[device.id] else { return }
        busy = true; failure = nil; ready = false; writer = nil; selected = device
        codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
        peripheral = target; target.delegate = self
        // The selected peripheral is sufficient during a connection. Do not
        // retain every advertisement discovered during the preceding scan.
        peripherals = [device.id: target]
        message = "Connecting to " + device.name + "…"
        task = Task {
            defer { disconnect(); busy = false; task = nil }
            do {
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
                while !Task.isCancelled {
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
                    message = "Connected · " + device.name; changed?()
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                }
            } catch is CancellationError { message = "Disconnected. Last readings are saved." }
            catch { message = (error as? BluettiNativeFailure)?.message ?? error.localizedDescription }
        }
    }
    func stop() {
        task?.cancel()
        central?.stopScan()
        disconnect()
        peripherals.removeAll(); discovered.removeAll(); selected = nil
    }
    private func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral); peripheral.delegate = nil }
        peripheral = nil; writer = nil; ready = false
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
        if !discovered.contains(where: { $0.id == id }) { discovered.append(BluettiNativeDevice(id: id, name: name)) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "FF00")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failure = error ?? ACError("Could not connect to the station.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { failure = error ?? ACError("Station disconnected.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failure = error; return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FF00") }) else {
            failure = ACError("AC50P service not found."); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "FF01"), CBUUID(string: "FF02")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { failure = error; return }
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "FF02") }
        guard let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "FF01") }) else {
            failure = ACError("Station notifications not found."); return
        }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error } else { ready = characteristic.isNotifying }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error; return }
        if let data = characteristic.value { do { try codec.append(Array(data)) } catch { failure = error } }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        failure = error; writeComplete = true
    }
    var widgetMetrics: [WidgetMetric] {
        readings.map { WidgetMetric(id: $0.id, name: $0.name, value: "\($0.percent)%",
            detail: $0.output.map(DisplayUnits.power) ?? "Output unknown", symbol: "battery.100percent", updatedAt: $0.date) }
    }
}
