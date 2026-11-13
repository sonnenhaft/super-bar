import Foundation

let defaults = UserDefaults.standard
struct LGError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
func object(_ value: Any) -> [String: Any] { value as? [String: Any] ?? [:] }
func find(_ key: String, in value: Any) -> Any? {
  if let d = value as? [String: Any] {
    if let v = d[key] { return v }
    for v in d.values { if let r = find(key, in: v) { return r } }
  }
  if let a = value as? [Any] { for v in a { if let r = find(key, in: v) { return r } } }
  return nil
}
func celsius(_ value: Any) -> [String: Any] {
  if let a = value as? [[String: Any]] { return a.first { ($0["unit"] as? String) == "C" } ?? [:] }
  let d = object(value)
  return (d["unit"] as? String) == "F" ? [:] : d
}
func equal(_ a: Any, _ b: Any) -> Bool {
  if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
  return String(describing: a) == String(describing: b)
}
func lgNumber(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
func degree(_ value: Double?) -> String {
  guard let v = value else { return "—" }
  return v == v.rounded() ? String(format: "%.0f°", v) : String(format: "%.1f°", v)
}
enum TokenFile {
  private static var store: TokenCredentialStore {
    #if os(macOS)
    TokenCredentialStore(key: "lg-token", legacyFile: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LGBar/token.txt"))
    #else
    TokenCredentialStore(key: "lg-token")
    #endif
  }
  static func readSecure() throws -> String {
    var source: URL?
    #if os(macOS)
    source = PrivateJSONFile.importFile("lg")
    // An explicitly local checkout can import, but never delete a CLI-owned token.
    let dist = Bundle.main.bundleURL.deletingLastPathComponent()
    if source == nil && dist.lastPathComponent == "dist" {
      source = dist.deletingLastPathComponent().appendingPathComponent("token.txt")
    }
    #endif
    return try store.read(importFile: source) ?? ""
  }
  static func read() -> String { (try? readSecure()) ?? "" }
  static func save(_ token: String) throws { CredentialAccess.retry(); try store.save(token) }
}

final class API {
  private let network: URLSession
  private let ownsSession: Bool
  private let readToken: () throws -> String
  deinit { if ownsSession { network.invalidateAndCancel() } }
  private(set) var needsSignIn = false
  let country: String, region: String, client: String
  init(network: URLSession? = nil, readToken: @escaping () throws -> String = TokenFile.readSecure,
       preferences: UserDefaults = defaults, country: String? = nil, region: String? = nil) {
    self.ownsSession = network == nil
    self.network = network ?? CloudRedirects.session()
    self.readToken = readToken
    self.country = country ?? preferences.string(forKey: "country") ?? "PH"
    self.region = region ?? preferences.string(forKey: "region") ?? "kic"
    client = preferences.string(forKey: "client") ?? UUID().uuidString
    preferences.set(client, forKey: "client")
  }
  static func validateCredentials(token: String, country: String, region: String, network: URLSession? = nil) async throws {
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          country.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil,
          ["kic", "eic", "aic"].contains(region) else {
      throw LGError(message: "Enter a token, two-letter country and a valid region.")
    }
    // A candidate client must not change the saved token or regional preferences.
    let candidate = API(network: network, readToken: { token }, country: country.uppercased(), region: region)
    _ = try await candidate.request("devices")
  }
  static func deviceComponent(_ id: String) throws -> String {
    guard !id.isEmpty, id.utf8.count <= 512, id != ".", id != "..",
          let value = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
      throw LGError(message: "Invalid LG device identifier")
    }
    return value
  }
  static func checkedURL(region: String, path: String) throws -> URL {
    guard ["kic", "eic", "aic"].contains(region),
          path == "devices" || path.hasPrefix("devices/"),
          let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil,
          relative.user == nil, relative.password == nil, relative.fragment == nil,
          !relative.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw LGError(message: "Invalid LG API address or region")
    }
    var endpoint = URLComponents()
    endpoint.scheme = "https"
    endpoint.host = "api-" + region + ".lgthinq.com"
    endpoint.percentEncodedPath = "/" + relative.percentEncodedPath
    endpoint.percentEncodedQuery = relative.percentEncodedQuery
    guard let url = endpoint.url else { throw LGError(message: "Invalid LG API address") }
    return url
  }
  func request(_ path: String, payload: [String: Any]? = nil) async throws -> Any {
    // Validate persisted preferences at the boundary before reading/attaching the PAT.
    let url = try Self.checkedURL(region: region, path: path)
    // Do not mistake a locked Keychain for a missing account. Retry after unlock.
    let token = try readToken()
    needsSignIn = token.isEmpty
    guard !needsSignIn else { throw LGError(message: "No token configured") }
    var r = URLRequest(url: url)
    r.timeoutInterval = 20
    r.httpMethod = payload == nil ? "GET" : "POST"
    var uuid = UUID().uuid
    let message = withUnsafeBytes(of: &uuid) { Data($0) }.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let headers = [
      "Authorization": "Bearer \(token)", "x-country": country, "x-client-id": client,
      "x-message-id": message, "x-service-phase": "OP",
      "x-api-key": "ZkVkqP9jq44HuWkbNX9EKzZmmn7ToPY3A4vQ4tY8", "Content-Type": "application/json",
    ]
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    if let p = payload {
      r.setValue("true", forHTTPHeaderField: "x-conditional-control")
      r.httpBody = try JSONSerialization.data(withJSONObject: p)
    }
    let data: Data, response: URLResponse
    do {
      (data, response) = try await CloudResponse.data(for: r, using: network)
    } catch let error as URLError {
      switch error.code {
      case .cannotFindHost, .dnsLookupFailed: throw LGError(message: "DNS lookup failed")
      case .notConnectedToInternet: throw LGError(message: "No internet connection")
      case .timedOut: throw LGError(message: "ThinQ timed out")
      case .cancelled: throw CancellationError()
      default: throw LGError(message: "Network error (\(error.code.rawValue))")
      }
    }
    guard let h = response as? HTTPURLResponse else {
      throw LGError(message: "No response from LG")
    }
    guard (200..<300).contains(h.statusCode) else {
      throw LGError(message: "LG HTTP \(h.statusCode). Check token, country and region.")
    }
    if data.isEmpty { return [:] as [String: Any] }
    guard let json = try? JSONSerialization.jsonObject(with: data) else { throw LGError(message: "LG returned invalid JSON") }
    if let e = object(json)["error"] {
      let code = object(e)["code"] as? String ?? "error"
      let safe = code.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil ? code : "error"
      throw LGError(message: "LG: \(safe)")
    }
    return object(json)["response"] ?? json
  }
}
struct Device {
  let id: String
  let name: String
}

func liveWatts(_ value: Any) -> Double? {
  for key in ["currentPower", "instantaneousPower", "powerConsumptionW", "currentPowerConsumption"]
  {
    guard let raw = find(key, in: value) else { continue }
    let reading = object(raw)
    let quantity = reading["value"] ?? raw
    guard let n = lgNumber(quantity) ?? (quantity as? String).flatMap(Double.init), n.isFinite, n >= 0
    else { continue }
    switch (reading["unit"] as? String ?? "W").lowercased() {
    case "w", "watt", "watts": return n
    case "kw", "kilowatt", "kilowatts": return 1000 * n
    default: continue
    }
  }
  return nil
}
func formatEnergy(_ wattHours: Double) -> String {
  DisplayUnits.energy(wattHours)
}

func energyTotal(_ value: Any) -> Double? {
  let result = object(object(value)["result"] ?? value)
  if let n = lgNumber(result["total"]) { return n }
  if let n = lgNumber(result["energyUsage"]) { return n }
  if let n = lgNumber(result["value"]) { return n }
  for key in ["dataList", "usage", "data", "values", "energyUsage", "details"] {
    if let a = result[key] as? [Any], !a.isEmpty {
      let readings = a.compactMap { v -> Double? in
        if let n = lgNumber(v) { return n }
        let d = object(v)
        return lgNumber(d["value"] ?? d["energyUsage"] ?? d["usage"])
      }
      if readings.count == a.count { return readings.reduce(0, +) }
    }
  }
  return nil
}
