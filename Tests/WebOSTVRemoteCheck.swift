import Foundation

// Native socket transcript. Never opens a port, reads Keychain or sends to a TV.
private final class FixtureSocket: WebOSTVSocket {
    var state: URLSessionTask.State = .running
    var sent: [String] = []
    var responses: [[String: Any]] = []
    var request: (([String: Any]) -> [[String: Any]])?
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message else { preconditionFailure() }
        sent.append(text)
        if let request {
            let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            for var response in request(frame) {
                // The fixture otherwise echoes the request ID as a normal TV does.
                if response.removeValue(forKey: "_omitID") == nil, response["id"] == nil {
                    response["id"] = frame["id"]
                }
                responses.append(response)
            }
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        precondition(!responses.isEmpty, "unexpected read")
        return .data(try JSONSerialization.data(withJSONObject: responses.removeFirst()))
    }
    func close() { state = .completed }
}

private final class FixtureSession: WebOSTVSession {
    let main = FixtureSocket(), pointer = FixtureSocket()
    let certificate: Data? = Data([1, 2, 3])
    var opened: [URL] = []
    func open(_ url: URL) -> any WebOSTVSocket {
        opened.append(url)
        let socket = url.path == "/input" ? pointer : main
        socket.state = .running
        return socket
    }
    func close() { main.close(); pointer.close() }
}

@main struct WebOSTVRemoteCheck {
    private static func expectRejectedPIN(_ pin: String, by remote: WebOSTVRemote) async {
        do {
            try await remote.submitPIN(pin)
            preconditionFailure("Unexpected PIN submission")
        } catch is WebOSTVError {} catch { preconditionFailure("Unexpected socket error") }
    }

    private static func checkPINPairing() async throws {
        let tv = FixtureSession(), vault = MemoryCredentialVault()
        let remote = WebOSTVRemote(host: "192.168.1.42", credentialID: "pin-test", vault: vault) { _, _ in tv }
        var registerID = ""
        var acceptPIN = false
        var allowRegistration = false
        tv.main.request = { frame in
            let body = frame["payload"] as! [String: Any]
            if frame["type"] as? String == "register" {
                registerID = frame["id"] as! String
                precondition(body["pairingType"] as? String == "PIN" && body["client-key"] == nil)
                return [["type": "response", "payload": ["pairingType": "pin"]]]
            }
            precondition(frame["uri"] as? String == "ssap://pairing/setPin")
            precondition(frame["id"] as? String != registerID)
            precondition(body["pin"] as? String == "00123456")
            if !acceptPIN { return [["type": "error", "error": "invalid PIN"]] }
            let terminal: [String: Any] = allowRegistration
                ? ["type": "registered", "id": registerID, "payload": ["client-key": "paired-key"]]
                : ["type": "error", "id": registerID]
            return [
                ["type": "response", "payload": ["returnValue": true]],
                terminal
            ]
        }
        do {
            try await remote.pair { _ in await remote.disconnect() }
            preconditionFailure("Closing the pairing sheet must cancel registration")
        } catch is CancellationError {}

        let enterPIN: @Sendable (WebOSTVPairingChallenge) async -> Void = { challenge in
            precondition(challenge == .pin)
            await expectRejectedPIN("12x", by: remote)
            do { try await remote.submitPIN("00123456") } catch { preconditionFailure("PIN submission failed") }
            await expectRejectedPIN("00123456", by: remote)
            let connected = await remote.isConnected
            precondition(!connected && (try? vault.read("lg-tv-pairing-pin-test")) == nil)
        }
        do { try await remote.pair(onChallenge: enterPIN); preconditionFailure() }
        catch let error as WebOSTVError { precondition(error.requiresPairing) }
        let savedAfterDenial = try await remote.hasSavedPairing()
        precondition(!savedAfterDenial)

        acceptPIN = true
        do { try await remote.pair(onChallenge: enterPIN); preconditionFailure("PIN acknowledgement allowed remote control") }
        catch let error as WebOSTVError { precondition(error.requiresPairing) }
        let savedAfterAck = try await remote.hasSavedPairing()
        precondition(!savedAfterAck)

        allowRegistration = true
        try await remote.pair(onChallenge: enterPIN)
        let savedAfterRegistration = try await remote.hasSavedPairing()
        precondition(savedAfterRegistration)
        let stored = try vault.read("lg-tv-pairing-pin-test")!
        precondition(!String(decoding: stored, as: UTF8.self).contains("00123456"))
        await expectRejectedPIN("00123456", by: remote)
    }

    static func main() async throws {
        try await checkPINPairing()
        let tv = FixtureSession(), vault = MemoryCredentialVault()
        let host = "192.168.1.42"
        var pins: [Data?] = [], volume = 23, selected = "HDMI_1", poweredOff = false, revoked = false
        var pointerURL = "wss://\(host):3001/input"
        tv.main.request = { frame in
            let body = frame["payload"] as! [String: Any]
            if frame["type"] as? String == "register" {
                let prompt = ["type": "response", "payload": ["pairingType": "PROMPT"]] as [String: Any]
                let registered = ["type": "registered", "payload": ["client-key": "example-key"]] as [String: Any]
                if body["client-key"] as? String == "example-key" { return revoked ? [prompt] : [registered] }
                let unrelatedError: [String: Any] = ["type": "error", "id": "unrelated"]
                let unrelatedRegistration: [String: Any] = ["type": "registered", "id": "unrelated", "payload": ["client-key": "wrong"]]
                let missingIDError: [String: Any] = ["type": "error", "_omitID": true]
                var terminalWithoutID = registered
                terminalWithoutID["_omitID"] = true
                return [prompt, unrelatedError, missingIDError, unrelatedRegistration, terminalWithoutID]
            }
            var reply: [String: Any] = ["returnValue": true]
            switch frame["uri"] as? String {
            case "ssap://audio/getVolume": reply["volumeStatus"] = ["volume": volume]
            case "ssap://audio/volumeUp": volume += 1
            case "ssap://audio/volumeDown": volume -= 1
            case "ssap://tv/getExternalInputList": reply["devices"] = [["id": "HDMI_1", "label": "Console", "appId": "app1"], ["id": "HDMI_2", "label": "PC", "appId": "app2"]]
            case "ssap://tv/switchInput": selected = body["inputId"] as! String
            case "ssap://com.webos.applicationManager/getForegroundAppInfo": reply["appId"] = selected == "HDMI_2" ? "app2" : "app1"
            case "ssap://com.webos.service.networkinput/getPointerInputSocket": reply["socketPath"] = pointerURL
            case "ssap://system/turnOff": poweredOff = true
            default: preconditionFailure("Unexpected SSAP request")
            }
            return [["type": "response", "payload": reply]]
        }
        let remote = WebOSTVRemote(host: host, credentialID: "test", vault: vault) { _, pin in pins.append(pin); return tv }
        do { try await remote.restore(); preconditionFailure() } catch let error as WebOSTVError { precondition(error.requiresPairing) }
        precondition(pins.isEmpty, "Cold opening must not contact an unpaired TV")
        try vault.write(Data("old pairing format".utf8), key: "lg-tv-pairing-test")
        do { try await remote.restore(); preconditionFailure() } catch is DecodingError {}
        precondition(pins.isEmpty, "Invalid stored credentials must not reach the network")
        try await remote.pair { challenge in precondition(challenge == .prompt) }
        let initial = try await remote.readVolume()
        precondition(initial == 23)
        try await remote.changeVolume(up: true)
        let louder = try await remote.readVolume()
        precondition(louder == 24)
        try await remote.changeVolume(up: false)
        let inputs = try await remote.inputs()
        precondition(inputs.map(\.name) == ["Console", "PC"])
        try await remote.selectInput("HDMI_2")
        let active = try await remote.currentInput(in: inputs)
        precondition(active == "HDMI_2")
        for key in [WebOSTVKey.up, .down, .left, .right, .ok, .click] { try await remote.navigate(key) }
        precondition(tv.pointer.sent == ["type:button\nname:UP\n\n", "type:button\nname:DOWN\n\n", "type:button\nname:LEFT\n\n", "type:button\nname:RIGHT\n\n", "type:button\nname:ENTER\n\n", "type:click\n\n"])
        precondition(tv.opened.count == 2, "Reuse the pointer socket across navigation keys")
        try await remote.powerOff()
        let connected = await remote.isConnected
        precondition(poweredOff && !connected)
        try await remote.restore()
        precondition(pins.count == 2 && pins[0] == nil && pins[1] == tv.certificate)
        pointerURL = "wss://192.168.1.41:3001/input"
        do { try await remote.navigate(.ok); preconditionFailure() } catch is WebOSTVError { }
        precondition(tv.opened.count == 3, "Never follow a pointer address to a different TV")
        await remote.disconnect()
        revoked = true
        do { try await remote.restore(); preconditionFailure() } catch let error as WebOSTVError { precondition(error.requiresPairing) }
        let revokedRemote = WebOSTVRemote(host: host, credentialID: "test", vault: vault) { _, _ in preconditionFailure("Revoked keys cannot initiate pairing on relaunch") }
        do { try await revokedRemote.restore(); preconditionFailure() } catch let error as WebOSTVError { precondition(error.requiresPairing) }
        precondition(WebOSTVRemote.powerState(from: ["state": "Active"])?.isOn == true)
        precondition(WebOSTVRemote.powerState(from: ["state": "Active Standby"])?.isOn == false)
        precondition(WebOSTVRemote.powerState(from: ["state": "Screen Off"]) == .screenOff)
        precondition(WebOSTVRemote.powerState(from: ["state": "unknown"]) == nil)
        precondition(WebOSTVRemote.powerState(from: [:]) == nil)
        var wakeReport = WebOSTVWakeReport()
        wakeReport.acceptedUnicast = true
        wakeReport.broadcastFailureCodes.insert(13) // EACCES: unicast success must not hide denied broadcasts.
        precondition(wakeReport.accepted && wakeReport.broadcastDenied)
        var directFailure = WebOSTVWakeReport()
        directFailure.unicastFailureCodes.insert(13)
        precondition(!directFailure.broadcastDenied)
        wakeReport.acceptedBroadcast = true
        precondition(!wakeReport.broadcastDenied)
        precondition((try? WebOSTVRemote.volume(from: ["volume": 0])) == 0)
        precondition((try? WebOSTVRemote.volume(from: ["volume": true])) == nil)
        precondition((try? WebOSTVRemote.volume(from: [:])) == nil)
        precondition((try? WebOSTVRemote.volume(from: ["volume": 101])) == nil)
        precondition(!WebOSTVRemote.isLocalHost("1.2.3.4") && !WebOSTVRemote.isLocalHost("192.168.1.42.example.org"))
        precondition(WebOSTVRemote.networkMACAddresses(from: ["wiredInfo": ["macAddress": "80:AA:BB:CC:DD:EE"],
            "wifiInfo": ["macAddress": "80-aa-bb-cc-dd-ee"]]) == ["80:AA:BB:CC:DD:EE"])
        precondition(WebOSTVRemote.networkMACAddresses(from: ["deviceid": "80:AA:BB:CC:DD:EE"]).isEmpty)
        precondition(WebOSTVRemote.networkMACAddresses(from: ["wifiInfo": ["macAddress": "FF:FF:FF:FF:FF:FF"]]).isEmpty)
        let mac = "02:01:02:03:04:05"
        let wake = WebOSTVRemote.wakePacket(mac)!
        precondition(wake.count == 102 && wake.prefix(6) == Data(repeating: 0xff, count: 6))
        precondition(wake == WebOSTVRemote.wakePacket("020102030405"))
        precondition(!WebOSTVRemote.isValidMAC("FF:FF:FF:FF:FF:FF"))
        func discover(_ service: WebOSTVDiscovery.BonjourService, _ name: String, _ txt: [String: String], at address: String = "192.168.1.42") -> WebOSTVEndpoint? {
            WebOSTVDiscovery.bonjourTV(service: service, name: name, txt: txt.mapValues { Data($0.utf8) }, host: address)
        }
        let discovery = discover(.airPlay, "[LG] webOS TV", ["deviceid": mac])
        precondition(discovery?.id == mac && discovery?.macAddress == nil && discovery?.host == host)
        let hardwareLikeID = "80:aa:bb:cc:dd:ee"
        let moved = discover(.airPlay, "[LG] webOS TV", ["deviceid": hardwareLikeID], at: "192.168.1.43")
        precondition(moved?.id == hardwareLikeID.uppercased() && moved?.macAddress == nil)
        let pairingID = discover(.airPlay, "[LG] webOS TV", ["pi": "stable-pairing-id"])
        precondition(pairingID?.id == "stable-pairing-id" && pairingID?.macAddress == nil)
        precondition(discover(.airPlay, "[LG] webOS TV", [:])?.id == host)
        precondition(discover(.airPlay, "Living Room", ["Model": "OLED55C8PUA"])?.name == "Living Room")
        precondition(discover(.airPlay, "Bedroom", ["manufacturer": "LG Electronics, Inc.", "model": "TV-Model"]) != nil)
        precondition(discover(.airPlay, "[LG] webOS TV", ["manufacturer": "Samsung"]) == nil)
        precondition(discover(.airPlay, "Bedroom", ["model": "AppleTV6,2"]) == nil)
        precondition(discover(.airPlay, "LG TV", ["model": "AppleTV6,2"]) == nil)
        precondition(discover(.airPlay, "[LG] Soundbar", ["manufacturer": "LG Electronics"]) == nil)
        let hap = discover(.homeKit, "Den", ["ci": "31", "md": "65QNED85TUA", "id": mac])
        precondition(hap?.id == "hap:" + mac && hap?.macAddress == nil)
        precondition(discover(.homeKit, "Den", ["ci": "31", "md": "LG webOS TV"]) != nil)
        precondition(discover(.homeKit, "[LG] Kitchen", ["ci": "31"]) != nil)
        precondition(discover(.homeKit, "Den", ["ci": "31", "md": "Samsung TV"]) == nil)
        precondition(discover(.homeKit, "[LG] webOS TV", ["ci": "26"]) == nil)
        precondition(discover(.homeKit, "Den", ["ci": "31", "md": "LG webOS TV"], at: "8.8.8.8") == nil)
        // Pure command validation for later offline execution; never contacts a device.
        for command in [WebOSTVCommand.text(""), .text(String(repeating: "é", count: 2049)), .launch("")] {
            do { try command.validate(); preconditionFailure("Invalid payload accepted") } catch is WebOSTVError { }
        }
        try WebOSTVCommand.text("Hello 👋").validate()
        precondition(WebOSTVCommand.text("Hello 👋").payload["text"] as? String == "Hello 👋")
        precondition(WebOSTVCommand.text("x").payload["replace"] as? Bool == false)
        precondition(WebOSTVKey.home.message == "type:button\nname:HOME\n\n")
        precondition(WebOSTVKey.back.message == "type:button\nname:BACK\n\n")
        print("webOS fixtures passed: pairing, pinned restore, refusal, volume, inputs, power, five navigation keys, wake packet and LG-only discovery.")
    }
}
