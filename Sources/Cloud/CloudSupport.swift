import Foundation
import CoreFoundation
import Darwin

// Shared by native cloud clients. Authenticated redirects never carry credentials away.
final class CloudRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config, delegate: CloudRedirects(), delegateQueue: nil)
    }
}

// Bound decoded bytes while they arrive, before JSON can expand them further.
// data(for:) buffers the complete response before a caller can inspect its size.
enum CloudResponse {
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "The cloud response exceeded the supported size." }
    }
    static let maximumBytes = 8 * 1024 * 1024
    static func data(for request: URLRequest, using session: URLSession,
                     maximumBytes: Int = maximumBytes) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw Failure.tooLarge }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw Failure.tooLarge }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 64 * 1024))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw Failure.tooLarge }
                data.append(byte)
                if data.count % (16 * 1024) == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}
enum PrivateJSONFile {
    static let maximumCredentialBytes = 1024 * 1024
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    struct Snapshot { let data: Data; let identity: Identity }

    private static func validate(_ info: stat, privateFile: Bool) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumCredentialBytes,
              !privateFile || info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    static func identityIfPresent(at file: URL) throws -> Identity? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        try validate(info, privateFile: false)
        return Identity(info)
    }
    static func snapshotIfPresent(from file: URL) throws -> Snapshot? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw CocoaError(.fileReadUnknown) }
        try validate(before, privateFile: true)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumCredentialBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if count == 0 { break }
            guard data.count + count <= maximumCredentialBytes else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Identity(before) == Identity(after) else {
            throw CocoaError(.fileReadUnknown)
        }
        return Snapshot(data: data, identity: Identity(after))
    }
    static func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T {
        try JSONDecoder().decode(type, from: readData(from: file))
    }
    static func readData(from file: URL) throws -> Data {
        guard let snapshot = try snapshotIfPresent(from: file) else { throw CocoaError(.fileNoSuchFile) }
        return snapshot.data
    }
    static func removeLegacy(at file: URL, matching expected: Identity?) throws {
        guard let expected else { return } // A file created during the save was never migrated.
        guard let current = try identityIfPresent(at: file) else { return }
        guard current == expected else { throw CocoaError(.fileWriteUnknown) }
        // unlink never recursively deletes a directory or follows a symlink target.
        guard unlink(file.path) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }
    }
    static func appFile(_ relative: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Super Bar/" + relative)
    }
    static func importFile(_ service: String) -> URL? {
        Bundle.main.url(forResource: service + "-session-path", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
enum CloudValue {
    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    static func object(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        if let string = value as? String, let data = string.data(using: .utf8) { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        return [:]
    }
    static func date(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
    }
}
