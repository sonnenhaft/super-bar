import Foundation
import Darwin
import Security
import LocalAuthentication

// Synthetic credentials only. These checks never access the system Keychain.
private struct SavedSession: Codable, Equatable {
    var token: String
    var passwordHash: String
}
private enum VaultFailure: Error { case unavailable, rejected, invalidSession }
private final class TestVault: CredentialVault {
    var values: [String: Data] = [:]
    var readFailure = false
    var writeFailure = false
    var failAfterWrite = false
    var corruptAfterWrite = false
    var reads = 0
    var writeAttempts = 0
    var writes = 0
    var afterWrite: (() throws -> Void)?
    var authorizationReads = 0
    var authorizationFailure = false
    var duringAuthorization: (() -> Void)?
    func readWithUserAuthorization(_ key: String) throws -> Data? {
        authorizationReads += 1
        duringAuthorization?()
        if authorizationFailure { throw VaultFailure.rejected }
        return values[key]
    }
    func read(_ key: String) throws -> Data? {
        reads += 1
        if readFailure || (failAfterWrite && writes > 0) { throw VaultFailure.unavailable }
        return values[key]
    }
    func write(_ data: Data, key: String) throws {
        writeAttempts += 1
        if writeFailure { throw VaultFailure.rejected }
        writes += 1
        values[key] = corruptAfterWrite ? Data("{}".utf8) : data
        try afterWrite?()
    }
}

// Tracks overlapping backing calls independently of the session vault's lock.
private final class ConcurrentVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private let shouldFail: Bool
    private var calls = 0
    private var active = 0
    private var peak = 0
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    var counts: (calls: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (calls, peak)
    }
    func read(_ key: String) throws -> Data? {
        lock.lock()
        calls += 1; active += 1; peak = max(peak, active)
        lock.unlock()
        defer {
            lock.lock(); active -= 1; lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.005)
        if shouldFail { throw VaultFailure.unavailable }
        return Data(key.utf8)
    }
    func write(_ data: Data, key: String) throws { throw VaultFailure.rejected }
}

@main enum CredentialStorageCheck {
    private static let old = SavedSession(token: "synthetic-old-token", passwordHash: "synthetic-old-hash")
    private static let current = SavedSession(token: "synthetic-new-token", passwordHash: "synthetic-new-hash")
    private static let key = "test-provider-session"

    private static func expectFailure(_ operation: () throws -> Void, _ description: String) {
        do { try operation(); preconditionFailure(description) }
        catch { }
    }
    private static func fixture(_ value: SavedSession, at file: URL) throws {
        try JSONEncoder().encode(value).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    @MainActor static func main() throws {
        // Forms retain unfinished input; only provider authentication writes sessions.
        let suite = "login-draft-test-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let formVault = TestVault()
        formVault.values["deye-session"] = Data(#"{"email":"saved@example.test","password":"  synthetic password  ","base":"https://eu1.deyecloud.com"}"#.utf8)
        let draft = LoginDraft(provider: "deye", preferences: prefs, vault: formVault)
        precondition(formVault.reads == 0, "Creating a form must not access Keychain")
        draft.restore()
        precondition(draft.email == "saved@example.test" && draft.password == "  synthetic password  " && draft.server == "https://eu1.deyecloud.com")
        draft.email = "new@example.test"; draft.password = "  unsuccessful draft  "
        draft.restore(); draft.prefill(email: "saved@example.test")
        precondition(draft.email == "new@example.test" && draft.password == "  unsuccessful draft  " && formVault.writes == 0)
        precondition(!prefs.dictionaryRepresentation().values.contains { String(describing: $0).contains("synthetic password") || String(describing: $0).contains("unsuccessful draft") })
        let restarted = LoginDraft(provider: "deye", preferences: prefs, vault: formVault)
        restarted.restore()
        precondition(restarted.email == "new@example.test" && restarted.password.isEmpty, "Do not attach the old account password to a new email")
        let separate = LoginDraft(provider: "tuya", preferences: prefs, vault: formVault)
        separate.restore()
        precondition(separate.email.isEmpty && separate.password.isEmpty)
        prefs.removePersistentDomain(forName: suite)
        let edited = LoginDraft(provider: "deye", preferences: prefs, vault: formVault)
        edited.server = "https://us1.deyecloud.com"
        edited.prefill(email: "saved@example.test", server: "https://eu1.deyecloud.com")
        precondition(edited.server == "https://us1.deyecloud.com", "Late prefill must preserve the user's region")
        prefs.set("https://www.deyecloud.com", forKey: "deye.loginServer")
        let publicServer = LoginDraft(provider: "deye", preferences: prefs, vault: formVault)
        precondition(publicServer.server == "https://deyecloud.com", "Legacy www origin must select Automatic")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("superbar-credential-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }
        func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

        // Verify query policy without calling the real Keychain or opening UI.
        for interactive in [false, true] {
            let query = KeychainCredentialVault().query("synthetic", interactive: interactive)
            precondition(query[kSecUseAuthenticationContext as String] is LAContext)
            precondition(query[kSecUseAuthenticationUI as String] as! String == (interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail) as String)
        }
        do {
            let backing = TestVault()
            let session = SessionCredentialVault(backing: backing)
            backing.values["granted"] = Data("cached".utf8)
            backing.values["locked"] = Data("authorized".utf8)
            _ = try session.read("granted")
            backing.readFailure = true
            expectFailure({ _ = try session.read("locked") }, "Silent access must report denial")
            precondition(backing.authorizationReads == 0)
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            backing.duringAuthorization = { entered.signal(); resume.wait() }
            DispatchQueue.global().async {
                try! session.authorizeAccess(keys: ["granted", "locked"])
                finished.signal()
            }
            precondition(entered.wait(timeout: .now() + 2) == .success)
            let cached = try session.read("granted")
            precondition(cached == Data("cached".utf8))
            expectFailure({ _ = try session.read("other") }, "Polling must not wait for the dialog")
            expectFailure({ try session.write(Data(), key: "other") }, "Background writes must not wait for the dialog")
            resume.signal()
            precondition(finished.wait(timeout: .now() + 2) == .success)
            precondition(backing.authorizationReads == 1)
            let authorized = try session.read("locked")
            precondition(authorized == Data("authorized".utf8))
            backing.duringAuthorization = nil; backing.authorizationFailure = true
            expectFailure({ try session.authorizeAccess(keys: ["denied"]) }, "User denial must be recoverable")
            let reads = backing.reads
            expectFailure({ _ = try session.read("denied") }, "Polling must not retry authorization")
            precondition(backing.reads == reads)
        }

        // File descriptors bind validation to the bytes read, never a later path target.
        for kind in ["public", "oversized", "directory", "symlink", "fifo"] {
            let source = file("unsafe-" + kind), vault = TestVault()
            switch kind {
            case "directory": try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            case "fifo": precondition(mkfifo(source.path, 0o600) == 0)
            case "symlink":
                let target = file("link-target")
                try fixture(old, at: target)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            default:
                try fixture(old, at: source)
                if kind == "public" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }
                else { try Data(repeating: 32, count: PrivateJSONFile.maximumCredentialBytes + 1).write(to: source) }
            }
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Unsafe legacy files must be rejected before migration")
            precondition(vault.writes == 0 && exists(source))
        }
        for kind in ["directory", "symlink", "modified"] {
            let source = file("changed-" + kind), vault = TestVault(), target = file("preserve-" + kind)
            try fixture(old, at: source)
            try fixture(current, at: target)
            vault.afterWrite = {
                if kind == "modified" { try Data("changed after read".utf8).write(to: source) }
                else {
                    try FileManager.default.removeItem(at: source)
                    if kind == "directory" {
                        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                        try Data("keep".utf8).write(to: source.appendingPathComponent("keep"))
                    } else { try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target) }
                }
            }
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Migration must preserve a replaced/changed legacy path")
            precondition(exists(source) && exists(target))
            if kind == "directory" { precondition(exists(source.appendingPathComponent("keep"))) }
        }
        do {
            let source = file("late-import"), destination = file("created-during-save"), vault = TestVault()
            try fixture(old, at: source)
            vault.afterWrite = { try fixture(current, at: destination) }
            _ = try CloudCredentialStore(file: destination, key: key, vault: vault).load(SavedSession.self, importFile: source)
            precondition(exists(source) && exists(destination), "An import must not delete a file created after it began")
        }
        do {
            let source = file("directory-cleanup"), vault = TestVault()
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep"))
            vault.values[key] = try JSONEncoder().encode(current)
            expectFailure({ _ = try CloudCredentialStore(file: source, key: key, vault: vault).load(SavedSession.self) },
                          "Keychain cleanup must never recursively remove a legacy-path directory")
            precondition(exists(source.appendingPathComponent("keep")))
        }

        // Granted and missing reads are shared; explicit retry keeps known-good values.
        do {
            let backing = TestVault(), data = Data("synthetic-cached-token".utf8)
            backing.values[key] = data
            let vault = SessionCredentialVault(backing: backing)
            for _ in 0..<20 {
                let value = try vault.read(key), missing = try vault.read("missing")
                precondition(value == data && missing == nil)
            }
            precondition(backing.reads == 2)
            backing.readFailure = true
            vault.retryAccess()
            let value = try vault.read(key), missing = try vault.read("missing")
            precondition(value == data && missing == nil && backing.reads == 2)
            backing.readFailure = false
            try vault.write(data, key: "missing")
            let created = try vault.read("missing")
            precondition(created == data, "A save must replace a cached absence")
        }

        // One failed access stops uncached reads and writes across every provider.
        do {
            let backing = TestVault(), data = Data("synthetic-known-token".utf8)
            backing.values["known"] = data
            let vault = SessionCredentialVault(backing: backing)
            _ = try vault.read("known")
            backing.readFailure = true
            for name in [key, "another-provider", key] {
                expectFailure({ _ = try vault.read(name) }, "Denied reads must stay denied until explicit retry")
            }
            expectFailure({ try vault.write(data, key: "new-provider") }, "A latched failure must also stop writes")
            let known = try vault.read("known")
            precondition(known == data && backing.reads == 2 && backing.writeAttempts == 0)
            backing.readFailure = false
            backing.values[key] = data
            expectFailure({ _ = try vault.read(key) }, "Backend recovery alone must not reopen a prompt")
            vault.retryAccess()
            let recovered = try vault.read(key), preserved = try vault.read("known")
            precondition(recovered == data && preserved == data && backing.reads == 3)
        }

        // Cache only backend-verified writes, and avoid unchanged secure saves.
        do {
            let backing = TestVault(), vault = SessionCredentialVault(backing: backing)
            let first = Data("synthetic-first-token".utf8), second = Data("synthetic-second-token".utf8)
            try vault.write(first, key: key)
            let restored = try vault.read(key)
            try vault.write(first, key: key)
            precondition(restored == first && backing.writeAttempts == 1 && backing.reads == 1)
            try vault.write(second, key: key)
            let changed = try vault.read(key)
            precondition(changed == second && backing.writeAttempts == 2 && backing.reads == 2)
        }
        for behavior in ["write-failure", "readback-failure", "readback-mismatch"] {
            let backing = TestVault(), vault = SessionCredentialVault(backing: backing)
            let first = Data("synthetic-first-token".utf8), second = Data("synthetic-second-token".utf8)
            backing.values[key] = first; backing.values["other"] = first
            _ = try vault.read(key); _ = try vault.read("other")
            backing.writeFailure = behavior == "write-failure"
            backing.failAfterWrite = behavior == "readback-failure"
            backing.corruptAfterWrite = behavior == "readback-mismatch"
            expectFailure({ try vault.write(second, key: key) }, "Unverified writes must fail")
            let reads = backing.reads
            expectFailure({ _ = try vault.read(key) }, "Failed writes must invalidate stale cached data")
            expectFailure({ try vault.write(second, key: key) }, "Failed writes must not automatically retry")
            let other = try vault.read("other")
            precondition(other == first && backing.reads == reads && backing.writeAttempts == 1)
            backing.writeFailure = false; backing.failAfterWrite = false; backing.corruptAfterWrite = false
            vault.retryAccess()
            try vault.write(second, key: key)
            let recovered = try vault.read(key)
            precondition(recovered == second && backing.writeAttempts == 2 && backing.reads == reads + 1)
        }

        // The session layer must preserve migration verification and never fall back.
        for behavior in ["read-failure", "write-failure", "readback-failure", "readback-mismatch"] {
            let source = file("cached-" + behavior), backing = TestVault()
            try fixture(old, at: source)
            backing.readFailure = behavior == "read-failure"
            backing.writeFailure = behavior == "write-failure"
            backing.failAfterWrite = behavior == "readback-failure"
            backing.corruptAfterWrite = behavior == "readback-mismatch"
            let vault = SessionCredentialVault(backing: backing)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Cached migration must verify raw backend content")
            let retained = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: source))
            let reads = backing.reads, writes = backing.writeAttempts
            let another = CloudCredentialStore(file: source, key: "another-provider", vault: vault)
            expectFailure({ _ = try another.load(SavedSession.self) }, "Another store must share the failure latch")
            precondition(retained == old && backing.reads == reads && backing.writeAttempts == writes)
        }

        // Concurrent polling coalesces reads and serializes different providers.
        do {
            let backing = ConcurrentVault(), vault = SessionCredentialVault(backing: backing)
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                let value = try! vault.read("shared")
                precondition(value == Data("shared".utf8))
            }
            precondition(backing.counts.calls == 1 && backing.counts.peak == 1)
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                let name = "provider-\(index)"
                let value = try! vault.read(name)
                precondition(value == Data(name.utf8))
            }
            precondition(backing.counts.calls == 17 && backing.counts.peak == 1)
        }
        do {
            let backing = ConcurrentVault(shouldFail: true), vault = SessionCredentialVault(backing: backing)
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                expectFailure({ _ = try vault.read("provider-\(index)") }, "Concurrent denied reads must fail")
            }
            precondition(backing.counts.calls == 1 && backing.counts.peak == 1,
                         "Queued providers must not show another prompt after a failure")
        }

        // A complete migration saves exact credential content and removes its owned file.
        do {
            let source = file("migration"), vault = TestVault()
            try fixture(old, at: source)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            let restored = try store.load(SavedSession.self)
            precondition(restored == old && !exists(source))
            let stored = try JSONDecoder().decode(SavedSession.self, from: vault.values[key]!)
            precondition(stored == old)
            try store.save(current)
            precondition(!exists(source), "Secure saves must not recreate plaintext files")
            let again = try store.load(SavedSession.self)
            precondition(again == current)
        }

        // An unavailable Keychain must not be treated as an empty one or trigger fallback.
        do {
            let source = file("read-failure"), vault = TestVault()
            try fixture(old, at: source)
            vault.readFailure = true
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Keychain read errors must propagate")
            precondition(exists(source) && vault.writes == 0)
        }

        // Do not delete the only usable legacy session if writing or verification fails.
        for behavior in ["write-failure", "readback-failure", "readback-mismatch"] {
            let source = file(behavior), vault = TestVault()
            try fixture(old, at: source)
            vault.writeFailure = behavior == "write-failure"
            vault.failAfterWrite = behavior == "readback-failure"
            vault.corruptAfterWrite = behavior == "readback-mismatch"
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Failed migration must report failure")
            precondition(exists(source))
            let retained = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: source))
            precondition(retained == old)
        }

        // Malformed and semantically invalid legacy files never replace secure credentials.
        do {
            let source = file("malformed"), vault = TestVault()
            try Data("not-json".utf8).write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Malformed sessions must fail")
            precondition(exists(source) && vault.writes == 0)
        }
        do {
            let source = file("validation"), vault = TestVault()
            try fixture(old, at: source)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({
                _ = try store.load(SavedSession.self, validate: { _ in throw VaultFailure.invalidSession })
            }, "Validation must precede migration")
            precondition(exists(source) && vault.writes == 0)
        }

        // Keychain wins over a stale staging file; it must never be overwritten on restart.
        do {
            let source = file("authoritative"), vault = TestVault()
            try fixture(old, at: source)
            vault.values[key] = try JSONEncoder().encode(current)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            let restored = try store.load(SavedSession.self)
            precondition(restored == current && vault.writes == 0 && !exists(source))
        }
        do {
            let source = file("corrupt-secure"), vault = TestVault()
            try fixture(old, at: source)
            vault.values[key] = Data("not-json".utf8)
            let store = CloudCredentialStore(file: source, key: key, vault: vault)
            expectFailure({ _ = try store.load(SavedSession.self) }, "Corrupt secure data must not silently fall back")
            precondition(exists(source) && vault.writes == 0)
        }

        // An explicitly imported source belongs to its caller and is never removed.
        do {
            let source = file("external-source"), destination = file("import-destination"), vault = TestVault()
            try fixture(old, at: source)
            let store = CloudCredentialStore(file: destination, key: key, vault: vault)
            let restored = try store.load(SavedSession.self, importFile: source)
            precondition(restored == old && exists(source) && !exists(destination))
        }

        // Saving into a failed vault must not leave a plaintext fallback or mutate legacy data.
        do {
            let destination = file("save-failure"), vault = TestVault()
            vault.writeFailure = true
            let store = CloudCredentialStore(file: destination, key: key, vault: vault)
            expectFailure({ try store.save(current) }, "Secure save errors must propagate")
            precondition(!exists(destination))
        }
        do {
            let destination = file("empty"), vault = TestVault()
            let store = CloudCredentialStore(file: destination, key: key, vault: vault)
            let restored = try store.load(SavedSession.self)
            precondition(restored == nil && !exists(destination) && vault.writes == 0)
        }

        // An injected vault isolates protocol tests without a plaintext backend.
        do {
            let destination = file("mac"), source = file("mac-import")
            try fixture(old, at: source)
            let vault = TestVault()
            let store = CloudCredentialStore(file: destination, key: key, vault: vault)
            let imported = try store.load(SavedSession.self, importFile: source)
            precondition(imported == old && exists(source) && !exists(destination))
            try store.save(current)
            let restored = try store.load(SavedSession.self)
            precondition(restored == current && !exists(destination))
            let saved = try JSONDecoder().decode(SavedSession.self, from: vault.values[key]!)
            precondition(saved == current)
        }
        // LG's raw UTF-8 token format stays compatible with existing iPhone items.
        func tokenFixture(_ data: Data, at file: URL) throws {
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        do {
            let source = file("lg-migration"), vault = TestVault()
            try tokenFixture(Data("  synthetic-lg-token\n".utf8), at: source)
            let store = TokenCredentialStore(key: key, legacyFile: source, vault: vault)
            let restored = try store.read()
            precondition(restored == "synthetic-lg-token" && !exists(source))
            precondition(vault.values[key] == Data("synthetic-lg-token".utf8), "LG Keychain format must remain raw UTF-8")
            try store.save(" synthetic-new-lg-token ")
            precondition(!exists(source))
            let reloaded = try store.read()
            precondition(reloaded == "synthetic-new-lg-token")
        }
        for failure in ["read", "write", "verify-read", "verify-value"] {
            let source = file("lg-failure-" + failure), vault = TestVault()
            let legacy = Data("synthetic-lg-token".utf8)
            try tokenFixture(legacy, at: source)
            vault.readFailure = failure == "read"
            vault.writeFailure = failure == "write"
            vault.failAfterWrite = failure == "verify-read"
            vault.corruptAfterWrite = failure == "verify-value"
            let store = TokenCredentialStore(key: key, legacyFile: source, vault: vault)
            expectFailure({ _ = try store.read() }, "Failed LG migration must propagate")
            let retained = try Data(contentsOf: source)
            precondition(retained == legacy, "Failed LG migration must preserve legacy bytes")
        }
        for invalid in [Data([0xff]), Data("  \n".utf8)] {
            let source = file("lg-invalid-" + UUID().uuidString), vault = TestVault()
            try tokenFixture(Data("synthetic-lg-token".utf8), at: source)
            vault.values[key] = invalid
            let store = TokenCredentialStore(key: key, legacyFile: source, vault: vault)
            expectFailure({ _ = try store.read() }, "Invalid secure token must not fall back to legacy")
            precondition(exists(source) && vault.writes == 0)
        }
        do {
            let source = file("lg-external"), destination = file("lg-owned"), vault = TestVault()
            try tokenFixture(Data("synthetic-lg-token".utf8), at: source)
            let store = TokenCredentialStore(key: key, legacyFile: destination, vault: vault)
            let restored = try store.read(importFile: source)
            precondition(restored == "synthetic-lg-token" && exists(source) && !exists(destination))
        }
        do {
            let source = file("lg-authoritative"), vault = TestVault()
            try tokenFixture(Data("synthetic-old-lg-token".utf8), at: source)
            vault.values[key] = Data("synthetic-new-lg-token".utf8)
            let store = TokenCredentialStore(key: key, legacyFile: source, vault: vault)
            let restored = try store.read()
            precondition(restored == "synthetic-new-lg-token" && !exists(source) && vault.writes == 0)
        }
        print("Credential storage: session cache, concurrent access, explicit retry, verified writes, JSON/token migration, failure preservation, secure precedence, no plaintext fallback, import ownership and isolated file fixtures passed.")
    }
}
