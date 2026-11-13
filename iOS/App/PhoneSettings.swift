import SwiftUI

struct PhoneSettings: View {
    @ObservedObject var model: PhoneModel
    @State private var provider = "Deye"
    @State private var email = ""
    @State private var password = ""
    @State private var token = ""
    @State private var country = UserDefaults.standard.string(forKey: "country") ?? "PH"
    @State private var region = UserDefaults.standard.string(forKey: "region") ?? "kic"
    @State private var server = "https://deyecloud.com"
    @State private var busy = false
    @State private var notice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connections").font(.title3.bold())
            Button("Retry Keychain access") {
                CredentialAccess.retry()
                Task { await model.refresh() }
            }
            Picker("Account", selection: $provider) {
                ForEach(["Deye", "Smart Life", "TCL Home", "LG ThinQ"], id: \.self) { Text($0) }
            }
            if provider == "LG ThinQ" {
                SecureField("ThinQ personal access token", text: $token)
                TextField("Country code", text: $country).textInputAutocapitalization(.characters)
                Picker("Region", selection: $region) { Text("Asia / Pacific").tag("kic"); Text("Europe").tag("eic"); Text("Americas").tag("aic") }
                Link("Get a ThinQ token", destination: URL(string: "https://connect-pat.lgthinq.com/tokens")!)
            } else {
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never)
                SecureField("Password", text: $password).textContentType(.password)
                if provider == "Deye" {
                    Picker("Deye server", selection: $server) {
                        Text("Automatic").tag("https://deyecloud.com")
                        Text("Europe").tag("https://eu1.deyecloud.com")
                        Text("US").tag("https://us1.deyecloud.com")
                        Text("India").tag("https://india.deyecloud.com")
                    }
                }
                if provider == "Smart Life" { Text("Smart Life · country 63 · EU server, matching the Mac client.").font(.caption).foregroundStyle(.secondary) }
            }
            Button { Task { await connect() } } label: {
                HStack { if busy { ProgressView() }; Text("Connect " + provider) }.frame(maxWidth: .infinity, minHeight: 30)
            }.buttonStyle(.borderedProminent).disabled(busy || (provider == "LG ThinQ" ? token.isEmpty : email.isEmpty || password.isEmpty))
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }.textFieldStyle(.roundedBorder).autocorrectionDisabled().disabled(busy).phoneCard()
        .onChange(of: provider) { _, _ in password = ""; token = ""; notice = nil }
        .onDisappear { password = ""; token = "" }
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
    private func connect() async {
        let enteredPassword = password, enteredToken = token
        password = ""; token = ""
        busy = true; notice = nil
        defer { busy = false }
        do {
            switch provider {
            case "LG ThinQ": try await model.lg.configure(token: enteredToken, country: country, region: region)
            case "TCL Home":
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    model.tcl.signIn(email: email, password: enteredPassword) { message in
                        if let message { continuation.resume(throwing: ACError(message)) }
                        else { continuation.resume() }
                    }
                }
            case "Deye":
                guard await model.deye.signIn(email: email, password: enteredPassword, server: server) else {
                    throw ACError(model.deye.problem ?? "Deye is busy. Try again shortly.")
                }
                await model.deye.refreshAndWait()
            default:
                model.tuya.email = email
                guard await model.tuya.signIn(password: enteredPassword) else {
                    throw ACError(model.tuya.problem ?? "Smart Life is busy. Try again shortly.")
                }
                await model.tuya.refreshAndWait()
            }
            password = ""; token = ""; notice = "Account connected. Readings will appear as they arrive."
            model.saveWidgets()
        } catch { notice = error.localizedDescription }
    }
}
