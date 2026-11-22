import Foundation
import Security
import CryptoKit

// LG's Connect SDK uses wss on port 3001. TVs have local certificates. Learn
// the leaf only when the user pairs; reconnects and the pointer socket pin it.
private final class TVTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    private let lock = NSLock()
    private var fingerprint: Data?
    init(host: String, expected: Data?) { self.host = host; fingerprint = expected }
    var pinned: Data? { lock.withLock { fingerprint } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == host,
              let trust = space.serverTrust,
              let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data))
        let accepts = lock.withLock {
            if let fingerprint { return digest == fingerprint }
            fingerprint = digest
            return true
        }
        completionHandler(accepts ? .useCredential : .cancelAuthenticationChallenge, accepts ? URLCredential(trust: trust) : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol WebOSTVSocket: AnyObject {
    var state: URLSessionTask.State { get }
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

extension URLSessionWebSocketTask: WebOSTVSocket {
    func close() { cancel(with: .goingAway, reason: nil) }
}

protocol WebOSTVSession: AnyObject {
    var certificate: Data? { get }
    func open(_ url: URL) -> any WebOSTVSocket
    func close()
}

final class SecureTVSession: WebOSTVSession {
    private let trust: TVTrust
    private let session: URLSession
    var certificate: Data? { trust.pinned }

    init(host: String, expected: Data?) {
        trust = TVTrust(host: host, expected: expected)
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }
    func open(_ url: URL) -> any WebOSTVSocket {
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 256 * 1024
        socket.resume()
        return socket
    }
    func close() { session.invalidateAndCancel() }
}

