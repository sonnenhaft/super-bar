import Foundation

/// Persisted format and Keychain key stay compatible with existing installations.
struct WebOSTVPairingRecord: Codable {
    let key: String
    let certificate: Data
    var revoked: Bool?
}

struct WebOSTVPairingStore {
    private let key: String
    private let vault: any CredentialVault

    init(id: String, vault: any CredentialVault) {
        key = "lg-tv-pairing-" + id
        self.vault = vault
    }
    func read() throws -> WebOSTVPairingRecord? {
        guard let data = try vault.read(key) else { return nil }
        return try JSONDecoder().decode(WebOSTVPairingRecord.self, from: data)
    }
    func save(_ record: WebOSTVPairingRecord) throws {
        try vault.write(JSONEncoder().encode(record), key: key)
    }
    func forget() throws {
        // The vault abstraction supports replacement. A revoked tombstone removes
        // both secrets while retaining a backwards-compatible, non-restorable record.
        try save(WebOSTVPairingRecord(key: "", certificate: Data(), revoked: true))
    }
    func revoke(_ record: WebOSTVPairingRecord) {
        var revoked = record
        revoked.revoked = true
        // In-memory rejection also protects this process when Keychain is unavailable.
        try? save(revoked)
    }
}
