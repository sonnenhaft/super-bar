import SwiftUI

/// One screen composition for the app and its graph-free widget snapshot.
struct PanelSections<ClimateHeading: View, Climate: View, BatteryHeading: View, Battery: View,
                     EnergyHeading: View, Energy: View, Footer: View, Settings: View>: View {
    var maximumWidth: CGFloat? = SuperBarPanelStyle.maximumWidth
    @ViewBuilder let climateHeading: () -> ClimateHeading
    @ViewBuilder let climate: () -> Climate
    @ViewBuilder let batteryHeading: () -> BatteryHeading
    @ViewBuilder let battery: () -> Battery
    @ViewBuilder let energyHeading: () -> EnergyHeading
    @ViewBuilder let energy: () -> Energy
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        VStack(alignment: .leading, spacing: SuperBarPanelStyle.gap) {
            climateHeading()
            climate()
            Divider().padding(.vertical, 3)
            batteryHeading().padding(.vertical, 2)
            battery()
            Divider().padding(.vertical, 3)
            energyHeading().padding(.vertical, 2)
            energy()
            Divider().padding(.top, 6)
            footer()
            settings()
        }
        .padding(SuperBarPanelStyle.appInset)
        .frame(maxWidth: maximumWidth ?? .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13)).foregroundStyle(.white).tint(SuperBarPanelStyle.cyan)
        .environment(\.locale, Locale(identifier: "en_US"))
    }
}

struct ClimateSummaryGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .topLeading)],
                  alignment: .leading, spacing: 8, content: content)
    }
}
