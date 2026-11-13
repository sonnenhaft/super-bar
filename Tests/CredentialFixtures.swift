import Foundation

// Test-only vault. Protocol fixtures never access the user's Keychain or persist
// newly issued credentials to disk.
final class MemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func saved<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let data = try read(key) else { throw CredentialStorageError.invalidData }
        return try JSONDecoder().decode(type, from: data)
    }
}

extension PrivateJSONFile {
    // Synthetic legacy files are needed only to exercise secure migration.
    // Production code has no credential-file writer.
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(value))
    }
}
