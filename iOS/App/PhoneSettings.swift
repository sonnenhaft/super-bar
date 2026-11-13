import SwiftUI

struct PhoneSettings: View {
    @ObservedObject var model: PhoneModel
    var body: some View {
        AccountConnections(deye: model.deye, tuya: model.tuya, tcl: model.tcl,
                           connectLG: model.lg.configureMobile) { Task { await model.refresh() } }
            .phoneCard()
        EnergyTariffSettings().phoneCard()
        VStack(alignment: .leading, spacing: 12) {
            Text("Widget").font(.title3.bold())
            Text("Add Super Bar from the Home Screen widget gallery. One large widget shows Climate, BLUETTI and Energy together, just like the app panel.")
            Text("The widget shows saved readings and their age. Open Super Bar to refresh; background refresh timing is decided by iOS.").foregroundStyle(.secondary)
            Button("Update shared readings") { model.saveWidgets() }
            if let problem = model.widgetProblem { Text(problem).foregroundStyle(.orange) }
        }.font(.callout).phoneCard()
        PhonePrivacyView().phoneCard()
    }
}

private struct PhonePrivacyView: View {
    private var policyURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SuperBarPrivacyPolicyURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    private func notice(_ name: String) -> String {
        guard let file = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return "Notice unavailable." }
        return text
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy & acknowledgements").font(.title3.bold())
            Text("When you connect an account, Super Bar communicates directly with that provider to sign in, read your devices and send the controls you choose. Account identifiers, authentication data and device requests are processed by the provider under its own policies.")
            Text("Account tokens, saved passwords and the password hashes needed to renew access are stored in this app’s device-only Keychain. They do not sync through iCloud or transfer to another device. Credentials are available after the first unlock following a restart so background refresh can work. Deye, Smart Life and TCL Home save a new password only after successful sign-in; their forms let you show or hide it.")
            Text("The widget receives device names, readings and update times from the app. It receives no account credentials and makes no cloud requests. Widget readings can be visible to anyone who can see your Home Screen.")
            Text("Bluetooth automatically finds nearby BLUETTI stations and refreshes their readings while the app is open. You can withdraw Bluetooth permission in iOS Settings. Super Bar includes no advertising or analytics SDK.")
            Text("To revoke cloud access, use your provider’s account or token controls. Removing Super Bar does not delete your provider account or its cloud records.")
            if let policyURL { Link("Privacy policy", destination: policyURL) }
            DisclosureGroup("Open-source licenses") {
                Text(notice("THIRD_PARTY_NOTICES") + "\n\n" + notice("TUYA-NOTICE"))
                    .font(.caption).textSelection(.enabled).padding(.top, 8)
            }
        }.font(.callout)
    }
}
