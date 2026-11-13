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
