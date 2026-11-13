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
    static func main() async throws {
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
