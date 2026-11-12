import Foundation
import Security

final class MockTuya: URLProtocol {
    static var actions: [String] = [], reads = 0, expire = false, rejectLogin = false
    static var dailyStarts: [String] = []
    static var key: SecKey!
    static let row: [String: Any] = ["devId": "main", "name": "Main meter", "productId": "i5mqmxkho1vahdt2", "category": "dlq", "isOnline": true, "timezoneId": "Asia/Manila",
                                     "dps": ["6": Data([9,34,0,13,102,0,1,254]).base64EncodedString(), "1": 96246]]
    static let schema: [[String: Any]] = [["id":6,"code":"phase_a","property": [:]], ["id":1,"code":"total_forward_energy","property":["unit":"kWh","scale":2]]]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(string: "https://example.test/?" + String(decoding: bytes, as: UTF8.self))!.queryItems!.map { ($0.name, $0.value ?? "") })
        let action = fields["a"]!; Self.actions.append(action)
        precondition(TuyaCloud.allowed.contains(action), "Device-control request escaped read-only client")
        precondition(fields["sign"] == TuyaCrypto.signature(fields))
        var result: Any = []
        var error: String?
        switch action {
        case "thing.m.user.username.token.get":
            precondition(fields["v"] == "2.0" && fields["sid"] == nil)
            let pub = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(Self.key)!, nil)! as Data
            result = ["token": "one-use", "pbKey": pub.base64EncodedString()]
        case "thing.m.user.email.password.login":
            precondition(fields["v"] == "3.0" && fields["sid"] == nil)
            let body = CloudValue.object(fields["postData"])
            let raw = body["passwd"] as! String
            let chars = Array(raw)
            let data = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
            let plain = SecKeyCreateDecryptedData(Self.key, .rsaEncryptionPKCS1, data as CFData, nil)! as Data
            precondition(String(decoding: plain, as: UTF8.self) == TuyaCrypto.md5("password"))
            if Self.rejectLogin { error = "USER_PASSWD_WRONG" }
            result = ["sid": "renewed", "domain": ["mobileApiUrl": "https://a1.tuyaeu.com/api.json"]]
        case "tuya.m.location.list": result = [["groupId": 42]]
        case "tuya.m.my.group.device.list":
            Self.reads += 1
            if Self.expire && fields["sid"] != "renewed" { error = "USER_SESSION_EXPIRED" }
            result = [Self.row]
        case "tuya.m.device.ref.info.my.list": result = [["id": "i5mqmxkho1vahdt2", "schemaInfo": ["schema": Self.schema]]]
        case "tuya.m.dp.rang.stat.day.list":
            let body = CloudValue.object(fields["postData"])
            precondition(fields["v"] == "2.0" && body["type"] as? String == "minux" && body["dpId"] as? Int == 1)
            precondition(body["devId"] as? String == "main")
            Self.dailyStarts.append(body["startDay"] as! String)
            result = ["min": "20261106", "result": ["20261111": "30.44", "20261112": "2.40"]]
        case "tuya.m.dp.rang.stat.hour.list":
            let body = CloudValue.object(fields["postData"])
            precondition(fields["v"] == "1.0" && body["date"] as? String == "20261112" && body["auto"] as? Int == 2)
            result = ["2026111200": "0.90", "2026111201": "#", "2026111202": "0", "2026111203": "1.20", "2026111204": "0.30", "2026111123": "8"]
        default: fatalError("Unexpected request")
        }
        let object: [String: Any] = error.map { ["success": false, "errorCode": $0] } ?? ["success": true, "result": result]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum TuyaNativeCheck {
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json"), own = dir.appendingPathComponent("native/session.json")
        var saved = TuyaCloud.Session(); saved.email = "test@example.com"; saved.password_md5 = TuyaCrypto.md5("password"); saved.sid = "original"; saved.meter_id = "main"
        try PrivateJSONFile.write(saved, to: source)
        let keyData = try Data(contentsOf: URL(fileURLWithPath: ".build/tuya-test-key.der"))
        MockTuya.key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary, nil)!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockTuya.self]
        let client = TuyaCloud(file: own, source: source, network: URLSession(configuration: config))
        let first = try await client.snapshot()
        precondition(first.meter?.watts == 510 && first.meter?.voltage == 233.8 && first.meter?.current == 3.430 && first.meter?.energyKWh == 962.46)
        precondition(MockTuya.actions.count == 3)
        _ = try await client.snapshot()
        precondition(MockTuya.actions.count == 4, "Homes and schemas must be reused")
        let now = ISO8601DateFormatter().date(from: "2026-11-11T20:30:00Z")! // 04:30 Manila, still Nov 11 in Warsaw.
        let history = try await client.history(for: first.meter!, previous: nil, now: now)
        precondition(history.days.count == 30 && MockTuya.dailyStarts.last == "20261014", "Request a full 30-day history")
        precondition(history.days.first { $0.key == "20261111" }?.wattHours == 30440, "API statistics are already scaled kWh")
        precondition(history.days.first { $0.key == "20261110" }?.wattHours == nil, "Missing days cannot become zero")
        precondition(history.hours.map(\.watts) == [900, 0, 1200], "Skip missing, past-day and incomplete-hour bins")
        precondition(history.hours.first?.start == ISO8601DateFormatter().date(from: "2026-11-11T16:00:00Z"), "Use meter timezone, not Mac timezone")
        precondition(history.hours[1].start.timeIntervalSince(history.hours[0].end) == 3600, "Keep the missing hour as a gap")
        let invalid = TuyaHistory.hourly(["2026111225": "1", "2026111200": "NaN", "2026111201": -1, "2026111202": true], zone: TuyaHistory.calendar.timeZone, now: now)
        precondition(invalid.isEmpty)
        var other = first.meter!
        other.timeZoneID = "Europe/Warsaw"
        let beforeTimezone = MockTuya.actions.count
        do { _ = try await client.history(for: other, previous: history, now: now); fatalError("Mixed timezone history accepted") } catch TuyaError.message {}
        precondition(MockTuya.actions.count == beforeTimezone)
        let yesterdayCache = TuyaHistory(meterID: "main", timeZoneID: "Asia/Manila",
                            days: TuyaHistory.keys(now: now).dropLast().map { EnergyDayPoint(key: $0, label: "", wattHours: 1000) },
                            hours: [], fetchedAt: now.addingTimeInterval(-86400))
        _ = try await client.history(for: first.meter!, previous: yesterdayCache, now: now)
        precondition(MockTuya.dailyStarts.last == "20261111", "Finalize yesterday's partial total after midnight")
        _ = try await client.history(for: first.meter!, previous: TuyaHistory(meterID: "main", timeZoneID: "Asia/Manila", days: yesterdayCache.days, hours: [], fetchedAt: now), now: now)
        precondition(MockTuya.dailyStarts.last == "20261112", "Completed days should not be downloaded on every refresh")
        let stale = TuyaSnapshot(devices: first.devices, meterID: "main", fetchedAt: Date().addingTimeInterval(-120))
        precondition(stale.consumption() == nil && first.consumption() == 510)
        let pv = DeyeReading(id: 1, name: "PV", power_w: 1200, today_kwh: 2, status: "NORMAL", measured_at: Date().timeIntervalSince1970, days: [])
        precondition(EnergyBalance(production: pv, consumption: first).watts == 690)
        precondition(EnergyBalance(production: pv, consumption: stale).watts == nil)
        let lowPV = DeyeReading(id: 1, name: "PV", power_w: 100, today_kwh: 2, status: "NORMAL", measured_at: Date().timeIntervalSince1970, days: [])
        precondition(EnergyBalance(production: lowPV, consumption: first).text == "-410 W")
        precondition(DisplayUnits.energy(28200) == "28,2 kWh" && DisplayUnits.energy(799) == "799 Wh")
        let missing = TuyaSnapshot(devices: first.devices, meterID: "not-this-meter", fetchedAt: Date())
        precondition(missing.consumption() == nil, "Never substitute another consumption meter")
        MockTuya.expire = true
        _ = try await client.snapshot()
        precondition(MockTuya.actions.filter { $0 == "thing.m.user.email.password.login" }.count == 1)
        let account = try PrivateJSONFile.read(TuyaCloud.Session.self, from: own)
        precondition(account.sid == "renewed" && account.meter_id == "main")
        precondition(try! PrivateJSONFile.read(TuyaCloud.Session.self, from: source).sid == "original")
        precondition(try! FileManager.default.attributesOfItem(atPath: own.path)[.posixPermissions] as? Int == 0o600)
        let before = MockTuya.actions.count
        do { _ = try await client.request("tuya.m.device.dp.publish"); fatalError("Control method accepted") } catch TuyaError.message {}
        precondition(MockTuya.actions.count == before)
        for url in ["http://a1.tuyaeu.com", "https://evil.example/api.json", "https://a1.tuyaeu.com.evil.example/api.json", "https://user:pass@a1.tuyaeu.com"] {
            do { _ = try TuyaCloud.endpoint(url); fatalError("Unsafe origin accepted") } catch TuyaError.message {}
        }
        precondition(try! TuyaCrypto.decimalBytes("65537") == [1,0,1])
        print("Tuya Swift: real RSA login round-trip, session import/renewal, cached schemas, meter scaling, freshness and read-only allowlist passed.")
    }
}
