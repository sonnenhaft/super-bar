import Foundation
import Security
import Combine
import LocalAuthentication

protocol CredentialVault {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    var removesLegacyFiles: Bool { get }
    func readWithUserAuthorization(_ key: String) throws -> Data?
    func writeWithUserAuthorization(_ data: Data, key: String) throws
    func disallowAccess()
}

extension CredentialVault {
    var removesLegacyFiles: Bool { true }
    func readWithUserAuthorization(_ key: String) throws -> Data? { try read(key) }
    func writeWithUserAuthorization(_ data: Data, key: String) throws { try write(data, key: key) }
    func disallowAccess() {}
}

// One vault per app process: concurrent providers share both granted reads and
// a failed access attempt. Polling never reopens a dismissed Keychain dialog.
final class SessionCredentialVault: CredentialVault, @unchecked Sendable {
    private enum Entry { case missing, value(Data) }
    private let backing: any CredentialVault
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var accessFailure: Error?
    private var authorizationInProgress = false

    init(backing: any CredentialVault) { self.backing = backing }
    var removesLegacyFiles: Bool { backing.removesLegacyFiles }

    func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries[key] {
            switch entry { case .missing: return nil; case .value(let data): return data }
        }
        if let accessFailure { throw accessFailure }
        if authorizationInProgress { throw CredentialStorageError.authorizationInProgress }
        do {
            let data = try backing.read(key)
            entries[key] = data.map(Entry.value) ?? .missing
            return data
        } catch { accessFailure = error; throw error }
    }

    func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if case .value(let saved) = entries[key], saved == data { return }
        if authorizationInProgress { throw CredentialStorageError.authorizationInProgress }
        // A write may partially succeed. Never serve the previous value after
        // an unsuccessful save, or verify a write by reading our own cache.
        entries[key] = nil
        if let accessFailure { throw accessFailure }
        do {
            try backing.write(data, key: key)
            guard try backing.read(key) == data else { throw CredentialStorageError.verificationFailed }
            entries[key] = .value(data)
        } catch { accessFailure = error; throw error }
    }

    // Only an explicit user action retries a denied/locked Keychain operation.
    func retryAccess() {
        lock.lock(); defer { lock.unlock() }
        accessFailure = nil
    }

    func disallowAccess() {
        lock.lock(); defer { lock.unlock() }
        backing.disallowAccess()
        entries.removeAll()
        accessFailure = CredentialStorageError.authorizationRequired
    }

    // Interactive reads are confined to this explicit action, never background
    // refresh. Call off the main thread: the system dialog may wait for the user.
    @discardableResult func authorizeAccess(keys: [String]) throws -> Int {
        lock.lock()
        guard !authorizationInProgress else { lock.unlock(); throw CredentialStorageError.authorizationInProgress }
        authorizationInProgress = true
        accessFailure = nil
        let cached = Set(entries.compactMap { key, value in if case .value = value { return key }; return nil })
        lock.unlock()
        defer { lock.lock(); authorizationInProgress = false; lock.unlock() }
        var available = 0
        for key in keys {
            if cached.contains(key) { available += 1; continue }
            do {
                let data = try backing.readWithUserAuthorization(key)
                if data != nil { available += 1 }
                lock.lock()
                entries[key] = data.map(Entry.value) ?? .missing
                lock.unlock()
            } catch { lock.lock(); accessFailure = error; lock.unlock(); throw error }
        }
        return available
    }
}

final class CredentialAccessStatus: ObservableObject {
    static let shared = CredentialAccessStatus()
    @Published var needsAuthorization = false
    @Published var authorizing = false
    @Published var result: String?
    @Published var accountRevision = 0
    static func requireAuthorization() {
        DispatchQueue.main.async { shared.needsAuthorization = true }
    }
}

// Logout suspends the connection; saved passwords remain available for sign-in.
enum AccountConnection {
    static let providers = ["deye", "tuya", "tcl", "lg"]
    // Explicit Allow resumes saved sessions once. Regular polling never signs
    // accounts back in after Logout or changes this preference.
    static func resumeSaved(vault: any CredentialVault, preferences: UserDefaults = .standard) throws {
        for provider in providers {
            guard let data = try vault.read(provider + "-session"),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
            setConnected(true, provider: provider, preferences: preferences)
        }
    }
    static func signedOut(_ provider: String, preferences: UserDefaults = .standard) -> Bool {
        preferences.bool(forKey: provider + ".signedOut")
    }
    static func connected(_ provider: String, preferences: UserDefaults = .standard) -> Bool {
        !signedOut(provider, preferences: preferences) && preferences.bool(forKey: provider + ".connected")
    }
    static func setConnected(_ connected: Bool, provider: String, preferences: UserDefaults = .standard) {
        preferences.set(!connected, forKey: provider + ".signedOut")
        preferences.set(connected, forKey: provider + ".connected")
        DispatchQueue.main.async { CredentialAccessStatus.shared.accountRevision &+= 1 }
    }
}

enum CredentialAccess {
#if SUPER_BAR_DEV_CREDENTIALS && os(macOS)
    static let usesKeychain = false
    static let shared = SessionCredentialVault(backing: DevelopmentCredentialVault())
#else
    static let usesKeychain = true
    static let shared = SessionCredentialVault(backing: AppCredentialVault())
#endif
    static func retry() { shared.retryAccess() }
    @MainActor static func disallow() {
        guard usesKeychain, !CredentialAccessStatus.shared.authorizing else { return }
        shared.disallowAccess()
        let status = CredentialAccessStatus.shared
        status.needsAuthorization = true
        status.result = nil
        status.accountRevision &+= 1
    }
    @MainActor static func authorize() async -> Bool {
        guard usesKeychain else { return true }
        let status = CredentialAccessStatus.shared
        guard !status.authorizing else { return false }
        status.authorizing = true
        status.result = nil
        defer { status.authorizing = false }
        let outcome: Result<Int, Error> = await Task.detached {
            do {
                let keys = ["deye-session", "tuya-session", "tcl-session", "lg-session"]
                var count = try shared.authorizeAccess(keys: keys)
                // Explicit one-time import from the previous local dev build, only
                // after Allow Keychain. Existing Keychain accounts take precedence.
                for key in keys where try shared.read(key) == nil {
                    var data: Data?
                    if let resource = Bundle.main.url(forResource: "credential-import-path", withExtension: "txt"),
                       let path = try? String(contentsOf: resource, encoding: .utf8), path.hasPrefix("/") {
                        data = try PrivateJSONFile.snapshotIfPresent(from: URL(fileURLWithPath: path).appendingPathComponent(key + ".json"))?.data
                    }
                    // Legacy items are probed with all interaction disabled; never
                    // show a separate dialog for each old provider record.
                    if data == nil { data = try? KeychainCredentialVault().read(key) }
                    if let data, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                        try shared.write(data, key: key)
                        count += 1
                    }
                }
                try AccountConnection.resumeSaved(vault: shared)
                return .success(count)
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(let count):
            status.needsAuthorization = false
            // The vault is also available when a new device has no saved accounts.
            status.accountRevision &+= 1
            status.result = count == 0
                ? "Сохранённых аккаунтов на этом устройстве нет. Войдите в нужный сервис ниже."
                : "Доступ открыт. Сохранённые аккаунты загружены."
            return true
        case .failure(let error):
            status.needsAuthorization = true
            status.result = error.localizedDescription
            return false
        }
    }
}

enum CredentialStorageError: LocalizedError {
    case invalidData, verificationFailed, authorizationInProgress, authorizationRequired
    var errorDescription: String? { "Could not read or securely save the account. Please try again." }
}

// One Keychain item per app, not one access-control prompt per provider.
// The first access is explicitly allowed in Settings; later launches try only
// noninteractive reads and show Allow Keychain if macOS denies them.
final class AppCredentialVault: CredentialVault, @unchecked Sendable {
    private let backing: any CredentialVault
    private let preferences: UserDefaults
    private let lock = NSLock()
    private var loaded = false
    private var values: [String: Data] = [:]
    init(backing: any CredentialVault = KeychainCredentialVault(), preferences: UserDefaults = .standard) {
        self.backing = backing; self.preferences = preferences
    }
    func disallowAccess() {
        lock.lock(); defer { lock.unlock() }
        preferences.set(false, forKey: "keychain.applicationConsent")
        values.removeAll()
        loaded = false
    }
    private func load(interactive: Bool) throws {
        guard !loaded else { return }
        guard interactive || preferences.bool(forKey: "keychain.applicationConsent") else {
            CredentialAccessStatus.requireAuthorization()
            throw CredentialStorageError.authorizationRequired
        }
        let data = try interactive ? backing.readWithUserAuthorization("accounts-v1") : backing.read("accounts-v1")
        let decoded = try data.map { try JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        if interactive {
            // Allow grants usable storage, not just a temporary read. Verify the
            // same noninteractive access that login and the next launch will use.
            let encoded = try data ?? JSONEncoder().encode(decoded)
            try backing.writeWithUserAuthorization(encoded, key: "accounts-v1")
            guard try backing.read("accounts-v1") == encoded else { throw CredentialStorageError.verificationFailed }
        }
        values = decoded
        loaded = true
        if interactive { preferences.set(true, forKey: "keychain.applicationConsent") }
    }
    func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try load(interactive: false)
        return values[key]
    }
    func readWithUserAuthorization(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try load(interactive: true)
        return values[key]
    }
    func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        try load(interactive: false)
        var next = values; next[key] = data
        let encoded = try JSONEncoder().encode(next)
        guard encoded.count <= PrivateJSONFile.maximumCredentialBytes else { throw CredentialStorageError.invalidData }
        try backing.write(encoded, key: "accounts-v1")
        guard try backing.read("accounts-v1") == encoded else { throw CredentialStorageError.verificationFailed }
        values = next
    }
}

// Form lifetime is independent of its SwiftUI view. Email/server are preferences;
// A successful login saves the recoverable password with its provider session.
// Failed/unfinished input stays in this draft without replacing working credentials.
@MainActor final class LoginDraft: ObservableObject {
    private struct Secret: Decodable { let email: String?; let password: String?; let base: String? }
    private let provider: String
    private let preferences: UserDefaults
    private let vault: any CredentialVault
    private var editedEmail = false
    private var editedServer = false
    @Published var email: String {
        didSet { editedEmail = true; preferences.set(email, forKey: provider + ".loginEmail") }
    }
    @Published var password = ""
    @Published var server: String {
        didSet { editedServer = true; preferences.set(server, forKey: provider + ".loginServer") }
    }
    init(provider: String, preferences: UserDefaults = .standard, vault: any CredentialVault = CredentialAccess.shared) {
        self.provider = provider; self.preferences = preferences; self.vault = vault
        email = preferences.string(forKey: provider + ".loginEmail") ?? ""
        server = Self.formServer(preferences.string(forKey: provider + ".loginServer") ?? "https://deyecloud.com")
    }
    func restore(force: Bool = false) {
        guard force || password.isEmpty,
              let data = try? vault.read(provider + "-session"), data.count <= PrivateJSONFile.maximumCredentialBytes,
              let saved = try? JSONDecoder().decode(Secret.self, from: data),
              let savedEmail = saved.email else { return }
        if force {
            email = savedEmail; password = saved.password ?? ""
            if let base = saved.base { server = Self.formServer(base) }
            return
        }
        prefill(email: savedEmail, server: saved.base)
        if email.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(savedEmail) == .orderedSame {
            password = saved.password ?? ""
        }
    }
    func prefill(email saved: String, server savedServer: String? = nil) {
        guard !editedEmail, email.isEmpty, !saved.isEmpty else { return }
        email = saved
        if !editedServer, preferences.string(forKey: provider + ".loginServer") == nil, let savedServer { server = Self.formServer(savedServer) }
    }
    private static func formServer(_ value: String) -> String {
        value == "https://www.deyecloud.com" ? "https://deyecloud.com" : value
    }
}

// No iCloud synchronization. iOS uses device-only after-first-unlock protection.
// macOS uses the login Keychain and its code-signing access controls.
struct KeychainCredentialVault: CredentialVault {
    private static let interactionLock = NSLock()
    func query(_ key: String, interactive: Bool = false) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        // Also set the Security policy for existing macOS login-Keychain items;
        // background operations must fail instead of opening an authorization UI.
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sonnenhaft.superbar",
         kSecAttrAccount as String: key,
         kSecUseAuthenticationContext as String: context,
         kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
         kSecAttrSynchronizable as String: false]
    }
    func read(_ key: String) throws -> Data? {
        try read(key, interactive: false)
    }
    func readWithUserAuthorization(_ key: String) throws -> Data? {
        try read(key, interactive: true)
    }
    private func read(_ key: String, interactive: Bool) throws -> Data? {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(interactive)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        #endif
        var query = query(key, interactive: interactive)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data else { throw CredentialStorageError.invalidData }
        return data
    }
    func write(_ data: Data, key: String) throws {
        try write(data, key: key, interactive: false)
    }
    func writeWithUserAuthorization(_ data: Data, key: String) throws {
        try write(data, key: key, interactive: true)
    }
    private func write(_ data: Data, key: String, interactive: Bool) throws {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(interactive)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        #endif
        var attributes: [String: Any] = [kSecValueData as String: data]
#if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        let status = SecItemUpdate(query(key, interactive: interactive) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(key, interactive: interactive).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NSError {
        // Numeric diagnostics only; never persist account names or secret data.
        UserDefaults.standard.set(Int(status), forKey: "keychain.lastFailureStatus")
        let denied = [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
        if denied { CredentialAccessStatus.requireAuthorization() }
        let message = denied
            ? "Keychain access was not granted for this app. Open Settings → Allow Keychain; choose Always Allow in the macOS dialog to remember access."
            : "Could not save or read Keychain data (macOS error \(status)). Your previous credentials are preserved."
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// Production uses Keychain. The explicitly compiled Mac development vault
// preserves import sources; it never activates after a Keychain failure.
struct CloudCredentialStore {
    let file: URL
    let key: String
    let vault: any CredentialVault
    static var defaultVault: any CredentialVault {
        CredentialAccess.shared
    }
    init(file: URL, key: String, vault: any CredentialVault = Self.defaultVault) {
        self.file = file; self.key = key; self.vault = vault
    }
    func load<T: Codable>(_ type: T.Type, importFile: URL? = nil,
                          validate: (T) throws -> T = { $0 }) throws -> T? {
        if let data = try vault.read(key) {
            let value = try validate(decode(type, data: data))
            if vault.removesLegacyFiles {
                try PrivateJSONFile.removeLegacy(at: file, matching: PrivateJSONFile.identityIfPresent(at: file))
            }
            return value
        }
        let owned = try PrivateJSONFile.snapshotIfPresent(from: file)
        let source = try owned ?? importFile.flatMap { try PrivateJSONFile.snapshotIfPresent(from: $0) }
        guard let source else { return nil }
        let value = try validate(decode(type, data: source.data))
        try write(value)
        if vault.removesLegacyFiles { try PrivateJSONFile.removeLegacy(at: file, matching: owned?.identity) }
        return value
    }
    func save<T: Encodable>(_ value: T) throws {
        let legacy = vault.removesLegacyFiles ? try PrivateJSONFile.identityIfPresent(at: file) : nil
        try write(value)
        if vault.removesLegacyFiles { try PrivateJSONFile.removeLegacy(at: file, matching: legacy) }
    }
    private func write<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= PrivateJSONFile.maximumCredentialBytes else { throw CredentialStorageError.invalidData }
        try vault.write(data, key: key)
        guard try vault.read(key) == data else { throw CredentialStorageError.verificationFailed }
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        guard data.count <= PrivateJSONFile.maximumCredentialBytes else { throw CredentialStorageError.invalidData }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CredentialStorageError.invalidData }
    }
}
