import Foundation
import Security
import Combine
import LocalAuthentication

protocol CredentialVault {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    var removesLegacyFiles: Bool { get }
    func readWithUserAuthorization(_ key: String) throws -> Data?
}

extension CredentialVault {
    var removesLegacyFiles: Bool { true }
    func readWithUserAuthorization(_ key: String) throws -> Data? { try read(key) }
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

    // Interactive reads are confined to this explicit action, never background
    // refresh. Call off the main thread: the system dialog may wait for the user.
    func authorizeAccess(keys: [String]) throws {
        lock.lock()
        guard !authorizationInProgress else { lock.unlock(); throw CredentialStorageError.authorizationInProgress }
        authorizationInProgress = true
        accessFailure = nil
        let cached = Set(entries.compactMap { key, value in if case .value = value { return key }; return nil })
        lock.unlock()
        defer { lock.lock(); authorizationInProgress = false; lock.unlock() }
        for key in keys {
            if cached.contains(key) { continue }
            do {
                let data = try backing.readWithUserAuthorization(key)
                lock.lock()
                entries[key] = data.map(Entry.value) ?? .missing
                lock.unlock()
            } catch { lock.lock(); accessFailure = error; lock.unlock(); throw error }
        }
    }
}

final class CredentialAccessStatus: ObservableObject {
    static let shared = CredentialAccessStatus()
    @Published var needsAuthorization = false
    @Published var authorizing = false
    static func requireAuthorization() {
        DispatchQueue.main.async { shared.needsAuthorization = true }
    }
}

enum CredentialAccess {
#if SUPER_BAR_DEV_CREDENTIALS && os(macOS)
    static let usesKeychain = false
    static let shared = SessionCredentialVault(backing: DevelopmentCredentialVault())
#else
    static let usesKeychain = true
    static let shared = SessionCredentialVault(backing: KeychainCredentialVault())
#endif
    static func retry() { shared.retryAccess() }
    @MainActor static func authorize() async {
        guard usesKeychain else { return }
        let status = CredentialAccessStatus.shared
        guard !status.authorizing else { return }
        status.authorizing = true
        defer { status.authorizing = false }
        let succeeded = await Task.detached {
            do {
                try shared.authorizeAccess(keys: ["deye-session", "tuya-session", "tcl-session", "lg-token"])
                return true
            } catch { return false }
        }.value
        status.needsAuthorization = !succeeded
    }
}

enum CredentialStorageError: LocalizedError {
    case invalidData, verificationFailed, authorizationInProgress
    var errorDescription: String? { "Could not read or securely save the account. Please try again." }
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
    func restore() {
        guard password.isEmpty,
              let data = try? vault.read(provider + "-session"), data.count <= PrivateJSONFile.maximumCredentialBytes,
              let saved = try? JSONDecoder().decode(Secret.self, from: data),
              let savedEmail = saved.email else { return }
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
        var attributes: [String: Any] = [kSecValueData as String: data]
#if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NSError {
        CredentialAccessStatus.requireAuthorization()
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Нажмите «Дать доступ к Keychain». Сохранённые показания доступны."])
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

// LG keeps its existing UTF-8 Keychain value format on both platforms.
struct TokenCredentialStore {
    let key: String
    var legacyFile: URL? = nil
    var vault: any CredentialVault = CredentialAccess.shared

    func read(importFile: URL? = nil) throws -> String? {
        if let data = try vault.read(key) {
            let token = try decode(data)
            if vault.removesLegacyFiles, let legacyFile {
                try PrivateJSONFile.removeLegacy(at: legacyFile, matching: PrivateJSONFile.identityIfPresent(at: legacyFile))
            }
            return token
        }
        let owned = try legacyFile.flatMap { try PrivateJSONFile.snapshotIfPresent(from: $0) }
        let source = try owned ?? importFile.flatMap { try PrivateJSONFile.snapshotIfPresent(from: $0) }
        guard let source else { return nil }
        let token = try decode(source.data)
        try write(token)
        if vault.removesLegacyFiles, let legacyFile { try PrivateJSONFile.removeLegacy(at: legacyFile, matching: owned?.identity) }
        return token
    }
    func save(_ token: String) throws {
        let legacy = vault.removesLegacyFiles ? try legacyFile.flatMap { try PrivateJSONFile.identityIfPresent(at: $0) } : nil
        try write(token)
        if vault.removesLegacyFiles, let legacyFile { try PrivateJSONFile.removeLegacy(at: legacyFile, matching: legacy) }
    }
    private func write(_ token: String) throws {
        let data = Data(try decode(Data(token.utf8)).utf8)
        try vault.write(data, key: key)
        guard try vault.read(key) == data else { throw CredentialStorageError.verificationFailed }
    }
    private func decode(_ data: Data) throws -> String {
        guard data.count <= PrivateJSONFile.maximumCredentialBytes,
              let value = String(data: data, encoding: .utf8) else { throw CredentialStorageError.invalidData }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CredentialStorageError.invalidData }
        return token
    }
}
