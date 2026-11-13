import SwiftUI

struct PhoneSettings: View {
    @ObservedObject var model: PhoneModel
    @State private var provider = "Deye"
    @ObservedObject private var deyeDraft: LoginDraft
    @ObservedObject private var tuyaDraft: LoginDraft
    @State private var climateEmail = ""
    @State private var climatePassword = ""
    @State private var token = ""
    @State private var country = UserDefaults.standard.string(forKey: "country") ?? "PH"
    @State private var region = UserDefaults.standard.string(forKey: "region") ?? "kic"
    @State private var busy = false
    @State private var notice: String?
    init(model: PhoneModel) {
        self.model = model; deyeDraft = model.deye.loginDraft; tuyaDraft = model.tuya.loginDraft
    }
    private var currentDraft: LoginDraft? { provider == "Deye" ? deyeDraft : provider == "Smart Life" ? tuyaDraft : nil }
    private var email: String {
        get { currentDraft?.email ?? climateEmail }
        nonmutating set { if let currentDraft { currentDraft.email = newValue } else { climateEmail = newValue } }
    }
    private var password: String {
        get { currentDraft?.password ?? climatePassword }
        nonmutating set { if let currentDraft { currentDraft.password = newValue } else { climatePassword = newValue } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connections").font(.title3.bold())
            KeychainAccessButton(alwaysVisible: true) { currentDraft?.restore(); Task { await model.refresh() } }
            Picker("Account", selection: $provider) {
                ForEach(["Deye", "Smart Life", "TCL Home", "LG ThinQ"], id: \.self) { Text($0) }
            }.disabled(busy || model.deye.refreshing || model.tuya.refreshing)
            if provider == "Deye" {
                CloudLoginForm(draft: deyeDraft, provider: "Deye", unavailable: model.deye.refreshing, hasServer: true) { email, password, server in
                    guard await model.deye.signIn(email: email, password: password, server: server) else {
                        return model.deye.problem ?? "Deye is busy. Try again shortly."
                    }
                    await model.deye.refreshAndWait(); model.saveWidgets()
                    return nil
                }
            } else if provider == "Smart Life" {
                CloudLoginForm(draft: tuyaDraft, provider: "Smart Life", unavailable: model.tuya.refreshing) { email, password, _ in
                    model.tuya.email = email
                    guard await model.tuya.signIn(password: password) else {
                        return model.tuya.problem ?? "Smart Life is busy. Try again shortly."
                    }
                    await model.tuya.refreshAndWait(); model.saveWidgets()
                    return nil
                }
            } else {
            if provider == "LG ThinQ" {
                SecureField("ThinQ personal access token", text: $token)
                TextField("Country code", text: $country).textInputAutocapitalization(.characters)
                Picker("Region", selection: $region) { Text("Asia / Pacific").tag("kic"); Text("Europe").tag("eic"); Text("Americas").tag("aic") }
                Link("Get a ThinQ token", destination: URL(string: "https://connect-pat.lgthinq.com/tokens")!)
            } else {
                TextField("Email", text: Binding(get: { email }, set: { email = $0 })).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never)
                PasswordEntry(text: Binding(get: { password }, set: { password = $0 }))
            }
            Button { Task { await connect() } } label: {
                HStack { if busy { ProgressView() }; Text("Connect " + provider) }.frame(maxWidth: .infinity, minHeight: 30)
            }.buttonStyle(.borderedProminent).disabled(busy || (provider == "LG ThinQ" ? token.isEmpty : email.isEmpty || password.isEmpty))
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder).autocorrectionDisabled().phoneCard()
        .onAppear { currentDraft?.restore() }
        .onChange(of: provider) { _, _ in token = ""; notice = nil; currentDraft?.restore() }
        .onDisappear { token = "" }
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
        let enteredPassword = password, enteredToken = token, enteredEmail = email
        token = ""
        busy = true; notice = nil
        defer { busy = false }
        do {
            switch provider {
            case "LG ThinQ": try await model.lg.configure(token: enteredToken, country: country, region: region)
            case "TCL Home":
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    model.tcl.signIn(email: enteredEmail, password: enteredPassword) { message in
                        if let message { continuation.resume(throwing: ACError(message)) }
                        else { continuation.resume() }
                    }
                }
            default:
                return
            }
            token = ""; notice = "Account connected. Readings will appear as they arrive."
            model.saveWidgets()
        } catch { notice = error.localizedDescription }
    }
}
