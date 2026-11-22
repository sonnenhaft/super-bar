import Foundation
import Security

final class MockTuya: URLProtocol {
    static var actions: [String] = [], reads = 0, expire = false, rejectLogin = false
    static var dailyStarts: [String] = []
    static var powerPageEnds: [Int64] = []
    static var logMode = ""
    static var logEnd: Int64 = 0
    // Generate the mock server's transient key in memory for each test run.
    static let key = SecKeyCreateRandomKey([
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: 2048,
        kSecUseDataProtectionKeychain: true
    ] as CFDictionary, nil)!
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
            precondition(fields["v"] == "1.0" && (body["date"] as? String)?.count == 8 && body["auto"] as? Int == 2)
            result = body["date"] as? String == "20261111" ? ["2026111123": "0.8"] : ["2026111200": "0.90", "2026111201": "#", "2026111202": "0", "2026111203": "1.20", "2026111204": "0.30"]
        case TuyaCloud.powerLogAction:
            let body = CloudValue.object(fields["postData"])
            precondition(body["dpIds"] as? String == "6" && body["sortType"] as? String == "DESC")
            let end = Int64(body["endTime"] as! String)!
            Self.powerPageEnds.append(end)
            let value = Data([9,34,0,13,102,0,1,254]).base64EncodedString()
            result = ["dps": [["timeStamp": end / 1000 - 5, "dpId": "6", "value": value],
                              ["timeStamp": 1e300, "dpId": "6", "value": value]], "hasNext": Self.powerPageEnds.count == 1]
            if Self.logMode == "limited", Self.powerPageEnds.count == 2 { error = "FREQUENCY_LIMIT_ERROR" }
            if Self.logMode == "ascending" {
                let start = Int64(body["startTime"] as! String)!
                let rows: [[String: Any]] = (0..<201).map { Self.logEnd - Int64($0 * 300_000) }
                    .filter { $0 >= start && $0 <= end }.sorted().map {
                        ["timeStamp": $0, "dpId": "6", "value": value]
                    }
                result = ["dps": Array(rows.prefix(100)), "hasNext": rows.count > 100]
            }
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
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockTuya.self]
        let vault = MemoryCredentialVault()
        let client = TuyaCloud(file: own, source: source, network: URLSession(configuration: config), vault: vault)
        let first = try await client.snapshot()
        precondition(first.meter?.watts == 510 && first.meter?.voltage == 233.8 && first.meter?.current == 3.430 && first.meter?.energyKWh == 962.46)
        let checkedAt = first.meter!.measuredAt ?? first.fetchedAt
        let fresh = TuyaSnapshot(devices: first.devices, meterID: first.meterID, fetchedAt: checkedAt)
        precondition(fresh.gridVoltage(now: checkedAt) == 233.8)
        precondition(fresh.gridVoltage(now: checkedAt.addingTimeInterval(90)) == nil,
                     "Stale voltage must not appear as a current grid measurement")
        var timedRow = MockTuya.row
        timedRow["dpMaxTime"] = checkedAt.timeIntervalSince1970 * 1000
        let timedMeter = TuyaDevice.decode(timedRow, schema: ["schema": MockTuya.schema])!
        let oldMeasurement = TuyaSnapshot(devices: [timedMeter], meterID: first.meterID, fetchedAt: checkedAt.addingTimeInterval(601))
        precondition(oldMeasurement.gridVoltage(now: oldMeasurement.fetchedAt) == nil)
        precondition(TuyaSnapshot(devices: first.devices, meterID: "missing", fetchedAt: checkedAt).gridVoltage(now: checkedAt) == nil)
        let voltageSchema: [String: Any] = ["schema": [["id": 20, "code": "cur_voltage", "property": ["scale": 1, "unit": "V"]]]]
        func voltageMeter(_ id: String, raw: Int?, online: Bool) -> TuyaDevice {
            TuyaDevice.decode(["devId": id, "isOnline": online, "dps": raw.map { ["20": $0] } ?? [:]], schema: voltageSchema)!
        }
        let voltageOnly = [voltageMeter("zero", raw: 0, online: true), voltageMeter("second", raw: 2294, online: true),
                           voltageMeter("offline", raw: 2338, online: false), voltageMeter("unknown", raw: nil, online: true)]
        func voltage(_ id: String) -> Double? {
            TuyaSnapshot(devices: voltageOnly, meterID: id, fetchedAt: checkedAt).gridVoltage(now: checkedAt)
        }
        precondition(voltage("zero") == 0 && voltage("second") == 229.4,
                     "Respect schema scale, selected meter and measured zero even without wattage")
        precondition(voltage("offline") == nil && voltage("unknown") == nil)
        precondition(MockTuya.actions.count == 3)
        _ = try await client.snapshot()
        precondition(MockTuya.actions.count == 4, "Homes and schemas must be reused")
        let now = ISO8601DateFormatter().date(from: "2026-11-11T20:30:00Z")! // 04:30 Manila, still Nov 11 in Warsaw.
        let history = try await client.history(for: first.meter!, previous: nil, now: now)
        precondition(history.power?.map(\.watts) == [510, 510] && MockTuya.powerPageEnds.count == 3 &&
                     MockTuya.powerPageEnds[2] < MockTuya.powerPageEnds[0], "Split full time windows without trusting provider sort order")
        MockTuya.powerPageEnds = []; MockTuya.logMode = "limited"
        let partial = try await client.history(for: first.meter!, previous: nil, now: now)
        precondition(partial.power?.count == 1 && partial.problem != nil && partial.hours.count == 4,
                     "A late rate limit must preserve earlier power readings and hourly totals")
        MockTuya.powerPageEnds = []; MockTuya.logMode = "ascending"
        MockTuya.logEnd = Int64(now.timeIntervalSince1970 * 1000) - 5000
        let ascending = try await client.history(for: first.meter!, previous: nil, now: now)
        precondition(ascending.power?.count == 201 && ascending.logsCoveredFrom == now.addingTimeInterval(-86400),
                     "Keep every report even when the server ignores DESC and offset")
        MockTuya.logMode = ""; MockTuya.powerPageEnds = []
        precondition(history.days.count == 30 && MockTuya.dailyStarts.last == "20261014", "Request a full 30-day history")
        precondition(history.days.first { $0.key == "20261111" }?.wattHours == 30440, "API statistics are already scaled kWh")
        precondition(history.days.first { $0.key == "20261110" }?.wattHours == nil, "Missing days cannot become zero")
        precondition(history.hours.sorted { $0.start < $1.start }.map(\.watts) == [800, 900, 0, 1200], "Load yesterday and today, skipping missing and incomplete bins")
        precondition(history.hours.first?.start == ISO8601DateFormatter().date(from: "2026-11-11T15:00:00Z"), "Use meter timezone, not Mac timezone")
        precondition(history.hours[2].start.timeIntervalSince(history.hours[1].end) == 3600, "Keep the missing hour as a gap")
        var legacy = first.meter!
        legacy.powerDP = nil
        let statsOnly = try await client.history(for: legacy, previous: history, now: now.addingTimeInterval(5))
        precondition(statsOnly.power?.map(\.time) == history.power?.map(\.time) &&
                     statsOnly.logsFetchedAt == history.logsFetchedAt && statsOnly.logsCoveredFrom == history.logsCoveredFrom,
                     "A cached meter missing its power schema keeps the same meter's timestamped reports and cursor")
        let scaling = TuyaPowerDP(id: 3, wattsPerUnit: 1000)
        precondition(scaling.watts(1e308) == nil && scaling.watts(0) == 0,
                     "Reject overflow after applying the meter's units and retain actual zero power")
        try await refreshLegacyMeter(legacy, client: client)
        let invalid = TuyaHistory.hourly(["2026111225": "1", "2026111200": "NaN", "2026111201": -1, "2026111202": true], zone: ChartHistory.calendar.timeZone, now: now)
        precondition(invalid.isEmpty)
        var other = first.meter!
        other.timeZoneID = "Europe/Warsaw"
        let beforeTimezone = MockTuya.actions.count
        for zone: String? in ["Europe/Warsaw", nil] {
            other.timeZoneID = zone
            let utc = try await client.history(for: other, previous: history, now: now)
            precondition(utc.days.isEmpty && utc.hours.isEmpty && utc.problem != nil && utc.power?.isEmpty == false,
                         "Read absolute-time power reports without mixing calendar totals from incompatible timezones")
        }
        precondition(Array(MockTuya.actions.dropFirst(beforeTimezone)) == [TuyaCloud.powerLogAction, TuyaCloud.powerLogAction])
        other.powerDP = nil
        let beforeUnsupported = MockTuya.actions.count
        do { _ = try await client.history(for: other, previous: history, now: now); fatalError("Missing timezone accepted for daily statistics") } catch TuyaError.message {}
        precondition(MockTuya.actions.count == beforeUnsupported)
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
        precondition(EnergyBalance(production: lowPV, consumption: first).text == "-410 W ⚡️")
        let noPV = DeyeReading(id: 1, name: "PV", power_w: 0, today_kwh: 2, status: "NORMAL", measured_at: Date().timeIntervalSince1970, days: [])
        let sleepingPV = DeyeReading(id: 1, name: "PV", power_w: 1200, today_kwh: 2, status: "OFFLINE", measured_at: Date().addingTimeInterval(-7200).timeIntervalSince1970, days: [])
        for production in [noPV, sleepingPV, nil] {
            let balance = EnergyBalance(production: production, consumption: first)
            precondition(balance.text == "510 W ⚡️" && balance.watts == -510,
                         "Zero or unavailable generation must show live household consumption without a minus or placeholder")
            precondition(balance.color == EnergyBalance(production: lowPV, consumption: first).color)
        }
        precondition(EnergyBalance(production: noPV, consumption: stale).text == "—", "Never present stale household consumption as live")
        precondition(DisplayUnits.energy(28200) == "28,2 kWh ⚡️" && DisplayUnits.energy(799) == "799 Wh ⚡️")
        let missing = TuyaSnapshot(devices: first.devices, meterID: "not-this-meter", fetchedAt: Date())
        precondition(missing.consumption() == nil, "Never substitute another consumption meter")
        MockTuya.expire = true
        _ = try await client.snapshot()
        precondition(MockTuya.actions.filter { $0 == "thing.m.user.email.password.login" }.count == 1)
        let account = try vault.saved(TuyaCloud.Session.self, key: "tuya-session")
        precondition(account.sid == "renewed" && account.meter_id == "main" && account.password_md5 == TuyaCrypto.md5("password"))
        precondition(try! PrivateJSONFile.read(TuyaCloud.Session.self, from: source).sid == "original")
        precondition(!FileManager.default.fileExists(atPath: own.path), "Session renewal must never write a plaintext account file")
        let before = MockTuya.actions.count
        do { _ = try await client.request("tuya.m.device.dp.publish"); fatalError("Control method accepted") } catch TuyaError.message {}
        precondition(MockTuya.actions.count == before)
        for url in ["http://a1.tuyaeu.com", "https://evil.example/api.json", "https://a1.tuyaeu.com.evil.example/api.json", "https://user:pass@a1.tuyaeu.com"] {
            do { _ = try TuyaCloud.endpoint(url); fatalError("Unsafe origin accepted") } catch TuyaError.message {}
        }
        precondition(try! TuyaCrypto.decimalBytes("65537") == [1,0,1])
        let beforeAccountChange = MockTuya.actions.count
        do { try await client.signIn(email: "other@example.test", password: ""); fatalError("A new account reused the old password") }
        catch TuyaError.message { }
        precondition(MockTuya.actions.count == beforeAccountChange)
        MockTuya.rejectLogin = true
        let beforeFailedLogin = try vault.read("tuya-session")
        do { try await client.signIn(email: "other@example.test", password: "password"); fatalError("Rejected login accepted") }
        catch TuyaError.message { }
        let preserved = try vault.saved(TuyaCloud.Session.self, key: "tuya-session")
        let preservedEmail = await client.savedEmail()
        let afterFailedLogin = try vault.read("tuya-session")
        precondition(beforeFailedLogin == afterFailedLogin, "Rejected credentials must never replace the saved session")
        precondition(preserved.email == saved.email && preserved.sid == "renewed" && preserved.meter_id == "main")
        precondition(preservedEmail == saved.email, "A failed account switch must not relabel the previous SID")
        _ = try await client.snapshot()
        MockTuya.rejectLogin = false
        try await client.signIn(email: "other@example.test", password: "password")
        let changed = try vault.saved(TuyaCloud.Session.self, key: "tuya-session")
        precondition(changed.email == "other@example.test" && changed.meter_id == nil && changed.password == "password")
        let homesBefore = MockTuya.actions.filter { $0 == "tuya.m.location.list" }.count
        _ = try await client.snapshot()
        precondition(MockTuya.actions.filter { $0 == "tuya.m.location.list" }.count == homesBefore + 1,
                     "A new account must not reuse cached homes or meter selection")
        print("Tuya Swift: real RSA login round-trip, session import/renewal, cached schemas, meter scaling, freshness and read-only allowlist passed.")
    }

    @MainActor private static func refreshLegacyMeter(_ legacy: TuyaDevice, client: TuyaCloud) async throws {
        let name = "SuperBar.tuya-history-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let snapshot = TuyaSnapshot(devices: [legacy], meterID: legacy.id, fetchedAt: Date())
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "tuya.readings")
        let store = TuyaStore(defaults: defaults, cloud: client)
        let initialPageCount = MockTuya.powerPageEnds.count
        store.showHistory(true)
        while store.historyRefreshing { await Task.yield() }
        precondition(store.history != nil && MockTuya.powerPageEnds.count == initialPageCount)
        await store.refreshAndWait(waitForHistory: true)
        precondition(store.history?.power?.isEmpty == false && MockTuya.powerPageEnds.count > initialPageCount,
                     "Discovering the meter's power schema must request detailed history within the current refresh")
    }
}
