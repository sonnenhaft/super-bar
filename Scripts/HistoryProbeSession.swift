import Foundation
import Security
import LocalAuthentication

// Read one provider session from Super Bar’s Keychain. Refreshed tokens stay in memory.
final class HistoryProbeSession: CredentialVault {
    private var account: Data?
    let key: String
    var removesLegacyFiles: Bool { false }
    private static let lock = NSLock()
    private static var aggregate: Result<[String: Data], Error>?
    private static var refreshed: [String: Data] = [:]
    init(key: String, reason: String = "Чтение истории устройств из сохранённых аккаунтов Super Bar") throws {
        self.key = key
        let interactive = CommandLine.arguments.contains("--allow-keychain")
        guard interactive || UserDefaults(suiteName: "local.SuperBar")?.bool(forKey: "keychain.applicationConsent") == true else {
            throw CredentialStorageError.authorizationRequired
        }
        func keychainItem(_ name: String) throws -> Data? {
            let context = LAContext()
            context.interactionNotAllowed = !interactive
            context.localizedReason = reason
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.sonnenhaft.superbar", kSecAttrAccount as String: name,
                kSecUseAuthenticationContext as String: context, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true]
            var item: CFTypeRef?
            var status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecParam {
                // A command-line session can have a default Keychain but no usable search list.
                var login: SecKeychain?
                let lookup = SecKeychainCopyDefault(&login)
                guard lookup == errSecSuccess, let login else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(lookup)) }
                query[kSecMatchSearchList as String] = [login]
                status = SecItemCopyMatching(query as CFDictionary, &item)
            }
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            guard let data = item as? Data else { throw CredentialStorageError.invalidData }
            return data
        }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if Self.aggregate == nil {
            // Super Bar stores its current accounts in one Keychain item. Share a
            // single read (including cancellation) for all providers in this run.
            Self.aggregate = Result {
                guard let data = try keychainItem("accounts-v1") else { return [:] }
                return try JSONDecoder().decode([String: Data].self, from: data)
            }
        }
        account = try Self.refreshed[key] ?? Self.aggregate?.get()[key]
        if account == nil { account = try keychainItem(key) }
        guard account != nil else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound)) }
    }
    func read(_ key: String) throws -> Data? { key == self.key ? account : nil }
    func write(_ data: Data, key: String) throws {
        guard key == self.key else { throw CredentialStorageError.invalidData }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        account = data
        Self.refreshed[key] = data
    }
}
