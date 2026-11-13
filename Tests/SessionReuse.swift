import Foundation

// Only the injected URLSession is used; no account or real device is accessed.
private final class MockCloud: URLProtocol {
    static var paths: [String] = []
    static var rejectNextList = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.paths.append(path)
        var status = 200
        let body: [String: Any]
        switch path {
        case "/v3/global/cloud_url_get":
            body = ["data":["cloud_url":"https://auth.tcljd.com","device_url":"https://device.tcljd.com","cloud_region":"ap-southeast-1"]]
        case "/v3/auth/refresh_tokens":
            let claims = Data(#"{"sub":"test"}"#.utf8).base64EncodedString()
            body = ["data":["saasToken":"fixture","cognitoToken":"x." + claims + ".x"]]
        case "/v3/user/get_things":
            if Self.rejectNextList { status = 401; Self.rejectNextList = false }
            body = ["data":[["deviceName":"Air Conditioner", "nickName":"unit-\(Self.paths.count)"]]]
        case "", "/":
            precondition(url.host!.hasPrefix("cognito-identity."))
            body = ["Credentials":["AccessKeyId":"test","SecretKey":"fixture","SessionToken":"test"]]
        default: fatalError("Unexpected endpoint")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main enum SessionReuse {
    static func main() throws {
        let vault = MemoryCredentialVault()
        let account: [String: Any] = ["id": "fixture", "token": "fixture", "saved": Date().timeIntervalSince1970]
        try vault.write(JSONSerialization.data(withJSONObject: account), key: "tcl-session")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockCloud.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cloud = TCLCloud(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), session: session, vault: vault)
        let first = try cloud.connect()
        precondition(MockCloud.paths.count == 4)
        let second = try cloud.connect()
        precondition(MockCloud.paths.count == 5 && MockCloud.paths.last == "/v3/user/get_things")
        precondition((first.first?["nickName"] as? String) != (second.first?["nickName"] as? String))
        MockCloud.rejectNextList = true
        _ = try cloud.connect()
        precondition(MockCloud.paths.count == 10)
        print("TCL: cold discovery 4 requests, warm discovery 1; rejected session renewed once.")
    }
}
