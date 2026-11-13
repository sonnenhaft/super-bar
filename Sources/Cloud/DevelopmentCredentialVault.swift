#if SUPER_BAR_DEV_CREDENTIALS && os(macOS)
import Foundation
import Darwin

// Compiled only by an explicit local-development build. No Keychain access,
// export, or fallback occurs here. Each account keeps its existing data format.
struct DevelopmentCredentialVault: CredentialVault {
    private let directory: URL?
    var removesLegacyFiles: Bool { false }

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    init(resource: URL? = Bundle.main.url(forResource: "development-credentials-path", withExtension: "txt")) {
        directory = Self.configuredDirectory(from: resource)
    }

    // The dev build embeds only this non-secret absolute path, never token data.
    // A missing/malformed resource must not silently select another directory.
    private static func configuredDirectory(from resource: URL?) -> URL? {
        guard let resource else { return nil }
        let descriptor = open(resource.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 4096,
              let data = try? handle.read(upToCount: Int(info.st_size) + 1), data.count <= 4096,
              let path = String(data: data, encoding: .utf8), path.hasPrefix("/"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private enum Failure: LocalizedError {
        case missingConfiguration, unsafeStorage, io, verification
        var errorDescription: String? {
            switch self {
            case .missingConfiguration: return "Development credential storage is not configured. Rebuild from this checkout with SUPER_BAR_DEV_CREDENTIALS=1."
            case .unsafeStorage: return "Development credentials require an owned 0700 directory and regular 0600 files."
            case .io: return "Could not read or write development credentials."
            case .verification: return "Could not verify the saved development credentials."
            }
        }
    }

    private func name(_ key: String) throws -> String {
        guard key.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw CredentialStorageError.invalidData
        }
        return key + (key == "lg-token" ? ".txt" : ".json")
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard let directory else { throw Failure.missingConfiguration }
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw Failure.unsafeStorage }
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw Failure.unsafeStorage
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(descriptor); throw Failure.unsafeStorage
        }
        return descriptor
    }

    private func validate(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size >= 0,
              info.st_size <= PrivateJSONFile.maximumCredentialBytes else { throw Failure.unsafeStorage }
    }

    private func openFile(_ name: String, in directory: Int32) throws -> Int32? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unsafeStorage
        }
        return descriptor
    }

    private func identity(_ name: String, in directory: Int32) throws -> PrivateJSONFile.Identity? {
        guard let descriptor = try openFile(name, in: directory) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.io }
        try validate(info)
        return PrivateJSONFile.Identity(info)
    }

    private func read(_ name: String, in directory: Int32) throws -> Data? {
        guard let descriptor = try openFile(name, in: directory) else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw Failure.io }
        try validate(before)
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer,
                min(buffer.count, PrivateJSONFile.maximumCredentialBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io
            }
            if count == 0 { break }
            guard data.count + count <= PrivateJSONFile.maximumCredentialBytes else { throw Failure.unsafeStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, PrivateJSONFile.Identity(before) == PrivateJSONFile.Identity(after) else {
            throw Failure.io
        }
        return data
    }

    func read(_ key: String) throws -> Data? {
        let name = try name(key)
        guard let descriptor = try openDirectory(create: false) else { return nil }
        defer { close(descriptor) }
        return try read(name, in: descriptor)
    }

    func write(_ data: Data, key: String) throws {
        let name = try name(key)
        guard data.count <= PrivateJSONFile.maximumCredentialBytes else { throw CredentialStorageError.invalidData }
        guard let directory = try openDirectory(create: true) else { throw Failure.io }
        defer { close(directory) }
        let previous = try identity(name, in: directory)
        let pending = ".pending-" + UUID().uuidString
        let descriptor = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io }
        defer { close(descriptor); unlinkat(directory, pending, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.io }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, try identity(name, in: directory) == previous,
              renameat(directory, pending, directory, name) == 0 else { throw Failure.io }
        guard try read(name, in: directory) == data else { throw Failure.verification }
    }
}
#endif
