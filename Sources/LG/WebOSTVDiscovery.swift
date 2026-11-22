import Foundation
import Darwin
import Network

struct WebOSTVEndpoint: Identifiable, Equatable {
    let id: String
    let host: String
    let name: String
    let macAddress: String?
}

enum WebOSTVDiscovery {
    static func discover() async throws -> [WebOSTVEndpoint] {
        #if os(macOS)
        async let ssdp = discoverSSDP()
        #endif
        var byHost: [String: WebOSTVEndpoint] = [:]
        var bonjourFailure: Error?
        do {
            for tv in try await TVBonjour().discover() { byHost[tv.host] = tv }
        } catch { bonjourFailure = error }
        #if os(macOS)
        for tv in await ssdp {
            if let other = byHost[tv.host] {
                byHost[tv.host] = WebOSTVEndpoint(id: tv.id, host: tv.host, name: other.name, macAddress: other.macAddress)
            } else { byHost[tv.host] = tv }
        }
        #endif
        try Task.checkCancellation()
        if byHost.isEmpty, let bonjourFailure { throw bonjourFailure }
        return byHost.values.sorted { ($0.name, $0.host) < ($1.name, $1.host) }
    }

    enum BonjourService: String, CaseIterable {
        case airPlay = "_airplay._tcp"
        case homeKit = "_hap._tcp"
    }

    static func bonjourTV(service: BonjourService, name: String, txt: [String: Data], host: String) -> WebOSTVEndpoint? {
        guard WebOSTVRemote.isLocalHost(host) else { return nil }
        func value(_ key: String) -> String {
            let data = txt.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            return data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        let manufacturer = value("manufacturer").lowercased().filter { $0.isLetter }
        let lg = ["lg", "lge", "lgelectronics", "lgelectronicsinc"].contains(manufacturer)
        guard manufacturer.isEmpty || lg else { return nil }
        let model = value(service == .homeKit ? "md" : "model").lowercased()
        guard !["appletv", "audioaccessory", "samsung"].contains(where: model.hasPrefix) else { return nil }
        let label = name.lowercased().replacingOccurrences(of: "[lg]", with: "lg")
        let brandedTV = [label, model].contains { text in
            let compact = text.filter { $0.isLetter || $0.isNumber }
            return ["lgwebostv", "lgetv", "lgtv", "lgsmarttv"].contains(where: compact.hasPrefix)
        }
        // Examples of LG's model numbers are OLED55C8PUA and 65QNED85TUA.
        let lgTVModel = model.range(of: #"^(oled[0-9]{2}[bcergwmz][0-9x]|[0-9]{2}(qned|nano)[0-9]{2})[a-z0-9]{2,6}$"#, options: .regularExpression) != nil
        if service == .homeKit {
            let lgName = label == "lg" || label.hasPrefix("lg ") || model.hasPrefix("lg ")
            guard value("ci") == "31", lg || brandedTV || lgTVModel || lgName else { return nil }
            // HomeKit's accessory ID can look like a MAC. It is not a Wake-on-LAN address.
            let id = value("id")
            return WebOSTVEndpoint(id: id.isEmpty ? host : "hap:" + id.uppercased(), host: host, name: name, macAddress: nil)
        }
        let tvLabel = model.hasPrefix("tv") || label.contains("tv") || model.contains("webos")
        guard brandedTV || lgTVModel || (lg && tvLabel) else { return nil }
        // AirPlay can advertise a virtual deviceid even when it looks exactly
        // like an interface MAC. Use it for discovery identity only.
        let deviceID = value("deviceid").uppercased()
        let pairingID = value("pi")
        let identifier = [deviceID, pairingID].first { !$0.isEmpty } ?? host
        return WebOSTVEndpoint(id: identifier, host: host, name: name, macAddress: nil)
    }
}

// Browse named services through Bonjour, including on iPhone. Control and pairing use webOS.
@MainActor private final class TVBonjour: NSObject, @preconcurrency NetServiceDelegate {
    typealias Service = WebOSTVDiscovery.BonjourService
    private var browsers: [Service: NWBrowser] = [:]
    private var ready: Set<Service> = []
    private var denied: Set<Service> = []
    private var services: [NWEndpoint: NetService] = [:]
    private var televisions: [String: WebOSTVEndpoint] = [:]
    private var airPlayHosts: Set<String> = []
    private var completion: CheckedContinuation<[WebOSTVEndpoint], Error>?
    private var timeout: Task<Void, Never>?

    func discover() async throws -> [WebOSTVEndpoint] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                for service in Service.allCases {
                    let browser = NWBrowser(for: .bonjour(type: service.rawValue, domain: "local."), using: .tcp)
                    browsers[service] = browser
                    browser.stateUpdateHandler = { [weak self] state in
                        MainActor.assumeIsolated { self?.update(state, for: service) }
                    }
                    browser.browseResultsChangedHandler = { [weak self] results, _ in
                        MainActor.assumeIsolated { self?.resolve(results) }
                    }
                    browser.start(queue: .main)
                }
                scheduleTimeout(seconds: 15)
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func update(_ state: NWBrowser.State, for service: Service) {
        guard completion != nil else { return }
        switch state {
        case .ready:
            denied.remove(service)
            if ready.isEmpty { scheduleTimeout(seconds: 4) }
            ready.insert(service)
        case .waiting(let error), .failed(let error):
            ready.remove(service)
            if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied { denied.insert(service) }
            if case .failed = state {
                browsers.removeValue(forKey: service)?.cancel()
                if browsers.isEmpty { completeSearch() }
            }
        default: break
        }
    }

    private func scheduleTimeout(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            completeSearch()
        }
    }

    private func completeSearch() {
        if !televisions.isEmpty || !ready.isEmpty {
            finish(.success(Array(televisions.values)))
        } else {
            let message = denied.isEmpty ? "TV discovery is unavailable. Check your Wi-Fi connection and try again."
                : "Allow Local Network access for Super Bar in Settings, then search again."
            finish(.failure(WebOSTVError(message)))
        }
    }

    private func finish(_ result: Result<[WebOSTVEndpoint], Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        for browser in browsers.values { browser.cancel() }
        browsers.removeAll()
        services.values.forEach { $0.delegate = nil; $0.stop() }
        services.removeAll()
        completion.resume(with: result)
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        guard completion != nil else { return }
        for result in results where services[result.endpoint] == nil && services.count < 96 {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let service = NetService(domain: domain, type: type, name: name)
            services[result.endpoint] = service
            service.delegate = self
            service.resolve(withTimeout: 3)
        }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let type = Service(rawValue: sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        for address in sender.addresses ?? [] {
            guard address.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let host: String? = address.withUnsafeBytes { buffer in
                let addr = buffer.loadUnaligned(as: sockaddr_in.self)
                guard addr.sin_family == AF_INET else { return nil }
                return String(cString: inet_ntoa(addr.sin_addr))
            }
            if let host, let television = WebOSTVDiscovery.bonjourTV(service: type, name: sender.name, txt: txt, host: host) {
                if type == .airPlay { airPlayHosts.insert(host) }
                else if airPlayHosts.contains(host) { continue }
                televisions[host] = television
            }
        }
    }
}

#if os(macOS)
private struct TVAdvertisement {
    let endpoint: WebOSTVEndpoint
    let descriptionURL: URL?
}

extension WebOSTVDiscovery {
    private static let serviceType = "urn:lge-com:service:webos-second-screen:1"
    fileprivate static func advertisement(_ data: String, from host: String) -> TVAdvertisement? {
        guard WebOSTVRemote.isLocalHost(host) else { return nil }
        let lines = data.components(separatedBy: "\r\n")
        guard lines.first?.uppercased().hasPrefix("HTTP/1.1 200 ") == true else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["st"]?.lowercased() == serviceType else { return nil }
        let uuid = headers["usn"]?.components(separatedBy: "::").first?.lowercased()
        let identity = uuid.flatMap { $0.hasPrefix("uuid:") ? String($0.dropFirst(5)) : nil }
        let tv = WebOSTVEndpoint(id: identity.flatMap { $0.isEmpty ? nil : $0 } ?? host, host: host, name: "LG TV · " + host, macAddress: nil)
        let url = headers["location"].flatMap(URL.init(string:))
        let valid = url?.host == host && ["http", "https"].contains(url?.scheme) && url?.user == nil && url?.password == nil
        return TVAdvertisement(endpoint: tv, descriptionURL: valid ? url : nil)
    }

    // M-SEARCH only the LG second-screen service. Listen on the ephemeral
    // sending socket for unicast replies; do not enumerate IP addresses.
    private static func ssdpReplies() -> [TVAdvertisement] {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
        let query = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(serviceType)\r\n\r\n".utf8)
        let wrote = withUnsafePointer(to: &target) { target in
            target.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                query.withUnsafeBytes { Darwin.sendto(fd, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard wrote == query.count else { return [] }
        var found: [String: TVAdvertisement] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled, found.count < 32 {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0, poll(&descriptor, 1, Int32(left * 1000)) > 0 else { break }
            var sender = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bytes = withUnsafeMutablePointer(to: &sender) { sender in
                sender.withMemoryRebound(to: sockaddr.self, capacity: 1) { sender in
                    buffer.withUnsafeMutableBytes { Darwin.recvfrom(fd, $0.baseAddress, $0.count, 0, sender, &length) }
                }
            }
            guard bytes > 0, sender.sin_family == AF_INET else { break }
            let host = String(cString: inet_ntoa(sender.sin_addr))
            if let reply = advertisement(String(decoding: buffer.prefix(bytes), as: UTF8.self), from: host) { found[host] = reply }
        }
        return Array(found.values)
    }

    fileprivate static func discoverSSDP() async -> [WebOSTVEndpoint] {
        let replies = await Task.detached { ssdpReplies() }.value
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpShouldSetCookies = false; config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config, delegate: TVDescription(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: WebOSTVEndpoint.self) { group in
            for reply in replies {
                group.addTask {
                    let tv = reply.endpoint
                    guard let url = reply.descriptionURL, let (bytes, response) = try? await session.bytes(from: url),
                          let http = response as? HTTPURLResponse, http.statusCode == 200 else { return tv }
                    var data = Data()
                    do {
                        for try await byte in bytes {
                            guard data.count < 64 * 1024 else { return tv }
                            data.append(byte)
                        }
                    } catch { return tv }
                    let description = TVDescription()
                    let parser = XMLParser(data: data)
                    parser.delegate = description; parser.shouldResolveExternalEntities = false
                    guard parser.parse(), let name = description.name else { return tv }
                    return WebOSTVEndpoint(id: tv.id, host: tv.host, name: name, macAddress: tv.macAddress)
                }
            }
            var result: [WebOSTVEndpoint] = []
            for await tv in group { result.append(tv) }
            return result
        }
    }
}

private final class TVDescription: NSObject, XMLParserDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    fileprivate var name: String?
    private var text: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "friendlyName", self.name == nil { text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text?.append(string) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "friendlyName", let text {
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { self.name = String(title.prefix(150)) }
            self.text = nil
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
