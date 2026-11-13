import SwiftUI

// Both application shells display this exact history and accounting view.
struct EnergyDetails: View {
    @ObservedObject var deye: DeyeStore
    @ObservedObject var tuya: TuyaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if deye.reading?.days.contains(where: { $0.kwh != nil }) == true || tuya.chartHistory != nil {
                EnergyCharts(days: (deye.reading?.days ?? []).map {
                    EnergyDayPoint(key: $0.day, label: String($0.day.suffix(2)), wattHours: $0.kwh.map { $0 * 1000 })
                }, power: deye.reading?.curve ?? [], color: sunlight,
                             consumptionDays: tuya.chartHistory?.days ?? [],
                             consumptionHours: tuya.chartHistory?.hours ?? [],
                             consumptionEnergyIntervals: tuya.chartHistory?.energyIntervals ?? [], showConsumption: true,
                             consumptionPower: tuya.samples)
                if let problem = tuya.historyProblem {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                } else if tuya.historyRefreshing && tuya.chartHistory == nil {
                    Text("Loading consumption…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(deye.refreshing ? "Loading 30 days…" : "No generation history yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reading = deye.reading {
                EnergyValueView(reading: reading, consumptionDays: tuya.chartHistory?.days ?? [])
            }
        }
    }
}
