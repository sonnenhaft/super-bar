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
// Shared adapter for the mobile ThinQ account API. There is no PAT fallback.
final class API {
  private let network: URLSession?
  private let mobile: LGMobileClient?
  @MainActor lazy var history = LGCloudHistory()
  private let ownsSession: Bool
  private let requestBody: (String, [String: Any]?) async throws -> Any?
  private(set) var needsSignIn = false
  deinit { if ownsSession { network?.invalidateAndCancel() } }
  init(network: URLSession? = nil, vault: any CredentialVault = CredentialAccess.shared) {
    let connection = network ?? CloudRedirects.session()
    self.network = connection; ownsSession = network == nil
    let mobile = LGMobileClient(network: connection, vault: vault)
    self.mobile = mobile
    requestBody = { try await mobile.requestIfConfigured($0, payload: $1) }
  }
  init(request: @escaping (String, [String: Any]?) async throws -> Any?) {
    network = nil; mobile = nil; ownsSession = false; requestBody = request
  }
  func energyHistory(_ id: String, _ query: LGHistoryQuery) async throws -> LGHistoryPage {
    guard let mobile else { throw LGError(message: "LG history unavailable.") }
    return try await mobile.energyHistory(id, query: query)
  }
  static func deviceComponent(_ id: String) throws -> String {
    guard !id.isEmpty, id.utf8.count <= 512, id != ".", id != "..",
          let value = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
      throw LGError(message: "Invalid LG device identifier")
    }
    return value
  }
  static func validatePath(_ path: String) throws {
    guard path == "devices" || path.hasPrefix("devices/"),
          let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil,
          relative.user == nil, relative.password == nil, relative.fragment == nil,
          relative.query == nil,
          !relative.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw LGError(message: "Invalid LG request path")
    }
  }
  @MainActor private var nextDirectoryRead: Date?
  @MainActor func accountDirectoryIfNeeded(hasDevices: Bool) async throws -> LGAccountDirectory? {
    let now = Date()
    if hasDevices && (nextDirectoryRead ?? .distantFuture) > now { return nil }
    // Device membership changes much less often than readings. A failed background
    // inventory refresh must not interrupt reads for devices we already know.
    nextDirectoryRead = now.addingTimeInterval(15 * 60)
    do { return try await accountDirectory() }
    catch is CancellationError { throw CancellationError() }
    catch { if hasDevices { return nil }; throw error }
  }
  private func accountDirectory() async throws -> LGAccountDirectory {
    if let mobile {
      return try requireSession(try await mobile.accountDirectoryIfConfigured())
    }
    let response = try await request("devices")
    if let directory = response as? LGAccountDirectory { return directory }
    let rows = response as? [[String: Any]] ?? find("devices", in: response) as? [[String: Any]] ?? []
    let conditioners = rows.compactMap { item -> Device? in
      let info = object(item["deviceInfo"] ?? item)
      guard info["deviceType"] as? String == "DEVICE_AIR_CONDITIONER",
            let id = item["deviceId"] as? String ?? info["deviceId"] as? String else { return nil }
      return Device(id: id, name: info["alias"] as? String ?? "LG")
    }
    return LGAccountDirectory(airConditioners: conditioners, televisions: [])
  }
  static func connectHistoryAPIKey(vault: any CredentialVault) throws -> String {
    if let value = ProcessInfo.processInfo.environment["SUPER_BAR_LG_CONNECT_API_KEY"], !value.isEmpty { return value }
    if let data = try vault.read("lg-connect-api-key"), let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
    throw LGError(message: "ThinQ Connect history API key is not configured.")
  }
  func request(_ path: String, payload: [String: Any]? = nil) async throws -> Any {
    try Self.validatePath(path)
    return try requireSession(try await requestBody(path, payload))
  }
  private func requireSession<T>(_ result: T?) throws -> T {
    guard let result else {
      needsSignIn = true
      throw LGError(message: "Sign in to LG ThinQ in Settings with your email and password.")
    }
    needsSignIn = false
    return result
  }
}
struct Device {
  let id: String
  let name: String
}
struct LGAccountTelevision: Identifiable, Equatable {
  let id: String
  let name: String
  let macAddress: String?
  let online: Bool?
  static func cloudOnline(_ raw: Any?) -> Bool? {
    if let number = raw as? NSNumber {
      if number.doubleValue == 1 { return true }
      if number.doubleValue == 0 { return false }
      return nil
    }
    switch (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "y", "online": return true
    case "false", "0", "n", "offline": return false
    default: return nil
    }
  }
}
struct LGAccountDirectory {
  let airConditioners: [Device]
  let televisions: [LGAccountTelevision]
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
