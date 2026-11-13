import Foundation

enum PhoneKeychain {
    static func read(_ key: String) throws -> String? { try TokenCredentialStore(key: key).read() }
    static func save(_ value: String, key: String) throws { try TokenCredentialStore(key: key).save(value) }
}
