import Foundation
import Darwin

private struct DevelopmentSession: Codable, Equatable {
    let token: String, refreshToken: String, passwordHash: String
}

@main enum DevelopmentCredentialsCheck {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Development credential check failed",
                              file: StaticString = #file, line: UInt = #line) {
        do {
            let passed = try condition()
            precondition(passed, message, file: file, line: line)
        } catch { preconditionFailure("Unexpected failure in synthetic development credential check", file: file, line: line) }
    }
    private static func fails(_ operation: () throws -> Void, _ message: String) {
        do { try operation(); preconditionFailure(message) } catch { }
    }
    private static func privateFile(_ data: Data, at file: URL) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func main() throws {
        check(!CredentialAccess.shared.removesLegacyFiles, "The explicit dev build must select its file vault")
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("superbar-dev-vault-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let first = DevelopmentSession(token: "synthetic-access", refreshToken: "synthetic-refresh", passwordHash: "synthetic-hash")
        let second = DevelopmentSession(token: "synthetic-access-2", refreshToken: "synthetic-refresh-2", passwordHash: "synthetic-hash-2")
        let firstData = try JSONEncoder().encode(first), secondData = try JSONEncoder().encode(second)
        let pathResource = folder.appendingPathComponent("development-credentials-path.txt")
        let configuredPath = folder.appendingPathComponent(".build/dev-credentials")
        try Data(configuredPath.path.utf8).write(to: pathResource)
        let configured = DevelopmentCredentialVault(resource: pathResource)
        try configured.write(firstData, key: "test")
        check(try Data(contentsOf: configuredPath.appendingPathComponent("test.json")) == firstData)
        check(try DevelopmentCredentialVault(resource: pathResource).read("test") == firstData)
        fails({ _ = try DevelopmentCredentialVault(resource: nil).read("test") }, "Missing path resource must fail closed")
        fails({ try DevelopmentCredentialVault(resource: nil).write(firstData, key: "test") }, "Missing path resource must not choose another directory")
        for value in ["", ".build/dev-credentials", "/absolute\nsecond-path", "/absolute\0suffix", "/" + String(repeating: "a", count: 4096)] {
            try Data(value.utf8).write(to: pathResource)
            fails({ _ = try DevelopmentCredentialVault(resource: pathResource).read("test") }, "Invalid path resource must fail closed")
        }
        let directory = folder.appendingPathComponent("DevelopmentCredentials")
        let vault = DevelopmentCredentialVault(directory: directory)
        check(try vault.read("test") == nil)
        check(!manager.fileExists(atPath: directory.path), "A missing read should not create storage")
        try vault.write(firstData, key: "test")
        let file = directory.appendingPathComponent("test.json")
        let directoryMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        let fileMode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        check(directoryMode.intValue == 0o700 && fileMode.intValue == 0o600)
        check(try DevelopmentCredentialVault(directory: directory).read("test") == firstData)
        try vault.write(secondData, key: "test")
        check(try vault.read("test") == secondData)
        check(try manager.contentsOfDirectory(atPath: directory.path) == ["test.json"], "Atomic writes must not leave staging files")

        // Generic migration cleanup must never delete the active dev vault file.
        let sameFile = CloudCredentialStore(file: file, key: "test", vault: SessionCredentialVault(backing: vault))
        check(try sameFile.load(DevelopmentSession.self) == second)
        try sameFile.save(first)
        check(manager.fileExists(atPath: file.path))
        let persisted = try DevelopmentCredentialVault(directory: directory).read("test")!
        check(try JSONDecoder().decode(DevelopmentSession.self, from: persisted) == first)
        let ownedLegacy = folder.appendingPathComponent("old-owned.json")
        try privateFile(firstData, at: ownedLegacy)
        let imported = CloudCredentialStore(file: ownedLegacy, key: "imported", vault: SessionCredentialVault(backing: vault))
        check(try imported.load(DevelopmentSession.self) == first)
        try imported.save(second)
        check(try Data(contentsOf: ownedLegacy) == firstData, "Dev mode must preserve legacy import sources")
        let external = folder.appendingPathComponent("external.json")
        try privateFile(firstData, at: external)
        let externalStore = CloudCredentialStore(file: folder.appendingPathComponent("absent.json"), key: "external", vault: vault)
        check(try externalStore.load(DevelopmentSession.self, importFile: external) == first)
        check(try Data(contentsOf: external) == firstData)

        let lgFile = directory.appendingPathComponent("lg-token.txt")
        let lg = TokenCredentialStore(key: "lg-token", legacyFile: lgFile, vault: SessionCredentialVault(backing: vault))
        try lg.save("synthetic-lg")
        check(try lg.read() == "synthetic-lg" && manager.fileExists(atPath: lgFile.path))
        check(try DevelopmentCredentialVault(directory: directory).read("lg-token") == Data("synthetic-lg".utf8))

        for key in ["../escape", "/absolute", "", "line\nbreak", String(repeating: "a", count: 129)] {
            fails({ _ = try vault.read(key) }, "Unsafe account names must be rejected")
            fails({ try vault.write(firstData, key: key) }, "Unsafe account names must be rejected")
        }
        fails({ try vault.write(Data(repeating: 0, count: PrivateJSONFile.maximumCredentialBytes + 1), key: "large") },
              "Oversized values must be rejected before writing")

        for kind in ["public", "symlink", "hardlink", "directory", "fifo", "oversized"] {
            let path = directory.appendingPathComponent(kind + ".json")
            switch kind {
            case "symlink": try manager.createSymbolicLink(at: path, withDestinationURL: file)
            case "hardlink": check(link(file.path, path.path) == 0)
            case "directory": try manager.createDirectory(at: path, withIntermediateDirectories: false)
            case "fifo": check(mkfifo(path.path, 0o600) == 0)
            default:
                try privateFile(kind == "oversized" ? Data(repeating: 0, count: PrivateJSONFile.maximumCredentialBytes + 1) : firstData, at: path)
                if kind == "public" { try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
            }
            fails({ _ = try vault.read(kind) }, "Unsafe dev credential file must be rejected")
            fails({ try vault.write(secondData, key: kind) }, "Unsafe dev credential file must not be overwritten")
            try manager.removeItem(at: path)
        }
        let unsafeDirectory = folder.appendingPathComponent("public-directory")
        try manager.createDirectory(at: unsafeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let unsafeVault = DevelopmentCredentialVault(directory: unsafeDirectory)
        fails({ try unsafeVault.write(firstData, key: "test") }, "Public directories must not receive credentials")
        let directoryLink = folder.appendingPathComponent("linked-directory")
        try manager.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        fails({ _ = try DevelopmentCredentialVault(directory: directoryLink).read("test") }, "Linked directories must be rejected")
        fails({ try DevelopmentCredentialVault(directory: directoryLink).write(secondData, key: "test") }, "Linked directories must be rejected")
        check(try vault.read("test") == persisted)

        // The same process-wide failure latch applies without falling back to Keychain.
        let cached = SessionCredentialVault(backing: vault)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        fails({ _ = try cached.read("test") }, "Private permissions are required")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        fails({ _ = try cached.read("test") }, "Failures remain latched until explicit retry")
        cached.retryAccess()
        check(try cached.read("test") == persisted)

        try checkReleaseGuards(in: folder.appendingPathComponent("release-guards"))
        print("Development credentials: explicit selection, checkout path resource, private atomic files, bounded no-symlink reads, read-only imports, same-path preservation and release/publish guards passed.")
    }

    private static func checkReleaseGuards(in folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: manager.currentDirectoryPath)
        for script in ["build.command", "publish.command"] {
            try manager.copyItem(at: root.appendingPathComponent(script), to: folder.appendingPathComponent(script))
        }
        func run(_ script: String, development: String, release: String = "0") throws -> (Int32, String) {
            let task = Process(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [folder.appendingPathComponent(script).path]
            task.currentDirectoryURL = folder
            task.environment = ProcessInfo.processInfo.environment.merging([
                "SUPER_BAR_DEV_CREDENTIALS": development, "SUPER_BAR_RELEASE": release
            ]) { _, new in new }
            task.standardOutput = output; task.standardError = output
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let release = try run("build.command", development: "1", release: "1")
        check(release.0 != 0 && release.1.contains("Release builds cannot enable"))
        check(!manager.fileExists(atPath: folder.appendingPathComponent(".build").path))
        let enabled = try run("publish.command", development: "1")
        check(enabled.0 != 0 && enabled.1.contains("Publishing is disabled"))
        let bundle = folder.appendingPathComponent("dist/Super Bar.app/Contents")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let marker = try PropertyListSerialization.data(fromPropertyList: ["SuperBarDevCredentials": true], format: .xml, options: 0)
        try marker.write(to: bundle.appendingPathComponent("Info.plist"))
        let marked = try run("publish.command", development: "0")
        check(marked.0 != 0 && marked.1.contains("development-credentials build"))
    }
}
