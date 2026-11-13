#if DEBUG && targetEnvironment(simulator)
import Foundation

// Explicit local development import; never compiled into device or release builds.
enum PhoneSimulatorSessions {
    private struct Credentials: Decodable {
        let token: String
        let country: String
        let region: String
    }

    static func importLG() {
        let file = PrivateJSONFile.appFile("simulator-lg-import.json")
        do {
            guard let snapshot = try PrivateJSONFile.snapshotIfPresent(from: file) else { return }
            let value = try JSONDecoder().decode(Credentials.self, from: snapshot.data)
            guard !value.token.isEmpty, value.country.count == 2,
                  ["kic", "eic", "aic"].contains(value.region) else { return }
            try PhoneKeychain.save(value.token, key: "lg-token")
            defaults.set(value.country, forKey: "country")
            defaults.set(value.region, forKey: "region")
            try PrivateJSONFile.removeLegacy(at: file, matching: snapshot.identity)
        } catch {
            // Never include credential data or decoding errors in logs.
            NSLog("Super Bar: simulator LG import failed; use Settings to connect.")
        }
    }
}
#endif
