import Foundation
import Darwin
import CoreFoundation

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
enum PrivateJSONFile {
    static func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pending = directory.appendingPathComponent(".session-" + UUID().uuidString)
        let fd = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: pending) }
        try handle.write(contentsOf: JSONEncoder().encode(value))
        try handle.synchronize()
        guard rename(pending.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
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
