import Foundation

// All requests terminate in URLProtocol. Never contacts a provider or reads secrets.
private final class ResponseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started: Set<String> = []
    private static var stopped: Set<String> = []
    static func saw(_ path: String, stopped: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped ? Self.stopped.contains(path) : started.contains(path)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.started.insert(path); Self.lock.unlock()
        let length = path == "/declared-large" ? "9999999" : nil
        let headers = length.map { ["Content-Length": $0] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        switch path {
        case "/small":
            client?.urlProtocol(self, didLoad: Data("safe response".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/exact":
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 128))
            client?.urlProtocolDidFinishLoading(self)
        case "/chunked-large":
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 64 * 1024))
            // Remain open so the test proves the capped consumer cancels the task.
        case "/declared-large", "/cancel":
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 64 * 1024))
        default: preconditionFailure("Unexpected test endpoint")
        }
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stopped.insert(request.url!.path); Self.lock.unlock()
    }
}

@main enum CloudResponseCheck {
    static func waitFor(_ path: String, stopped: Bool = false) async throws {
        for _ in 0..<500 {
            if ResponseProtocol.saw(path, stopped: stopped) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Expected test transport event did not arrive")
    }
    static func checkTraffic() throws {
        let start = Date(timeIntervalSince1970: 0)
        let traffic = CloudTraffic(startedAt: start)
        func after(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        traffic.record(incoming: 90000, outgoing: 17, at: start, history: true)
        precondition(traffic.snapshot(at: after(8)).coveredSeconds == 0)
        let first = traffic.snapshot(at: after(60))
        precondition(first.total.incoming == 90000 && first.total.chartIn == 90000)
        precondition(first.averageIncomingBytesPerMinute == 90000)
        traffic.record(incoming: 300, outgoing: 30, at: after(90))
        precondition(traffic.snapshot(at: after(95)) == first, "Do not republish between minute boundaries")
        let warm = traffic.snapshot(at: after(120))
        precondition(warm.coveredSeconds == 120 && warm.total.incoming == 90300 && warm.total.outgoing == 47)
        precondition(warm.averageIncomingBytesPerMinute == 45150 && warm.averageOutgoingBytesPerMinute == 23.5)
        for index in (1...150).reversed() {
            traffic.record(incoming: 100, outgoing: 20, at: after(200 + Double(index)))
        }
        let busy = traffic.snapshot(at: after(360))
        precondition(busy.total.incoming == 105300 && busy.total.outgoing == 3047)
        precondition(busy.total.chartIn == 90000 && busy.total.chartOut == 17)
        precondition(busy.averageIncomingBytesPerMinute * 6 == Double(busy.total.incoming))
        precondition(traffic.snapshot(at: after(3950)).total.incoming == 5100, "The window ends at the last completed minute")
        let idle = traffic.snapshot(at: after(4020))
        precondition(idle.coveredSeconds == 3600 && idle.total.incoming == 0 && idle.averageIncomingBytesPerMinute == 0)

        let partial = CloudTraffic(startedAt: after(30))
        partial.record(incoming: 600, outgoing: 60, at: after(31))
        let halfMinute = partial.snapshot(at: after(60))
        precondition(halfMinute.coveredSeconds == 30 && halfMinute.total.incoming == 600)
        precondition(halfMinute.averageIncomingBytesPerMinute == 1200, "Normalize the first partial minute by actual coverage")

        let boundary = CloudTraffic(startedAt: start)
        boundary.record(incoming: 1000, outgoing: 100, at: after(59))
        boundary.record(incoming: 2000, outgoing: 200, at: after(60))
        precondition(boundary.snapshot(at: after(60)).total.incoming == 1000)
        precondition(boundary.snapshot(at: after(120)).total.incoming == 3000)
        boundary.record(incoming: 500, outgoing: 50, at: after(30)) // A late metrics callback.
        precondition(boundary.snapshot(at: after(125)).total.incoming == 3000)
        precondition(boundary.snapshot(at: after(180)).total.incoming == 3500)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-check-" + UUID().uuidString)
        let file = directory.appendingPathComponent("traffic-minutes.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = CloudTraffic(startedAt: start, storageURL: file)
        saved.record(incoming: 6000, outgoing: 600, at: after(5))
        _ = saved.snapshot(at: after(60))
        let bytes = try Data(contentsOf: file)
        saved.record(incoming: 12000, outgoing: 1200, at: after(65))
        _ = saved.snapshot(at: after(90))
        let unchanged = try Data(contentsOf: file)
        precondition(unchanged == bytes, "No disk write for each request or view redraw")
        let closed = saved.snapshot(at: after(120))
        let restored = CloudTraffic(startedAt: after(130), storageURL: file)
        precondition(restored.snapshot(at: after(140)) == closed, "Restore the same unrounded totals and averages")
        // Restoring a full ledger one minute later expires only the oldest bucket.
        _ = saved.snapshot(at: after(3600))
        let later = CloudTraffic(startedAt: after(3665), storageURL: file).snapshot(at: after(3665))
        precondition(later.coveredSeconds == 3600 && later.total.incoming == 12000)
        precondition(later.averageIncomingBytesPerMinute == 200)

        let brands = CloudTraffic(startedAt: start, storageURL: directory.appendingPathComponent("brands.json"))
        brands.record(incoming: 6000, outgoing: 600, at: after(1), provider: .tcl)
        brands.record(incoming: 3000, outgoing: 300, at: after(2), history: true, provider: .lg)
        brands.record(incoming: 12000, outgoing: 1200, at: after(3), provider: .tuya)
        brands.record(incoming: 9000, outgoing: 900, at: after(4), provider: .deye)
        let byBrand = brands.snapshot(at: after(120))
        precondition(byBrand.forProvider(.tcl).averageIncomingBytesPerMinute == 3000)
        precondition(byBrand.forProvider(.lg).total.chartIn == 3000)
        precondition(byBrand.forProvider(.tuya).averageOutgoingBytesPerMinute == 600)
        precondition(byBrand.forProvider(.deye).coveredSeconds == byBrand.coveredSeconds)
        var sum = CloudTraffic.Volume()
        for provider in CloudTraffic.Provider.allCases { sum.add(byBrand.forProvider(provider).total) }
        precondition(sum == byBrand.total, "Each transfer belongs to one brand and enters the total once")
        precondition(CloudTraffic(startedAt: after(125), storageURL: directory.appendingPathComponent("brands.json"))
            .snapshot(at: after(125)) == byBrand, "Restore brand counters with the same minute window")
        precondition(restored.snapshot(at: after(140)).forProvider(.tcl).total.incoming == 0,
                     "Never guess a provider for earlier unattributed bytes")
    }
    static func main() async throws {
        try checkTraffic()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config, delegate: CloudRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://fixture.invalid" + path)!) }
        let (small, _) = try await CloudResponse.data(for: request("/small"), using: session, maximumBytes: 128)
        precondition(small == Data("safe response".utf8))
        let (exact, _) = try await CloudResponse.data(for: request("/exact"), using: session, maximumBytes: 128)
        precondition(exact.count == 128)
        for path in ["/declared-large", "/chunked-large"] {
            do {
                _ = try await CloudResponse.data(for: request(path), using: session, maximumBytes: 128)
                preconditionFailure("Oversized response was accepted")
            } catch CloudResponse.Failure.tooLarge { }
            try await waitFor(path, stopped: true)
        }
        let task = Task { try await CloudResponse.data(for: request("/cancel"), using: session, maximumBytes: 1024 * 1024) }
        try await waitFor("/cancel")
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled response was accepted") }
        catch is CancellationError { }
        catch let error as URLError { precondition(error.code == .cancelled) }
        try await waitFor("/cancel", stopped: true)
        print("Cloud transport: decoded response cap, early length rejection, exact bounds and underlying task cancellation passed.")
    }
}
