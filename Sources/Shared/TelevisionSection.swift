import SwiftUI

struct TelevisionInput: Identifiable, Equatable {
    let id: String
    let name: String
}

struct TelevisionItem: Identifiable, Equatable {
    let id: String
    var name: String
    var online: Bool? = nil
    var power: Bool? = nil
    var powerDate: Date? = nil
    var volume: Int? = nil
    var brightness: Int? = nil
    var liveVolume = false
    var pointerAvailable = true
    var connected = false
    var canPair = false
    var canWake = false
    var sources: [TelevisionInput] = []
    var selectedSourceID: String? = nil
    var apps: [TelevisionInput] = []
    var foregroundApp: String? = nil
    var services: Set<String> = []
    var unsupportedCommands: Set<String> = []
    var featureMessage: String? = nil
    var busy = false
    var status: String? = nil

    var volumePercent: Int? {
        guard let volume, (0...100).contains(volume) else { return nil }
        return volume
    }
}

enum TelevisionAction: Equatable {
    case pair, unpair, configure, refreshSources
    case power(Bool), volumeUp, volumeDown
    case up, down, left, right, ok, home, back, menu, settings, exit
    case move(Int, Int), brightness(Int), click
    case command(WebOSTVCommand), refreshFeatures
    case source(String), rename(String)
}

struct TelevisionSection: View {
    let devices: [TelevisionItem]
    let selectedID: String?
    let expanded: Bool
    var showSummaries = true
    let select: (String) -> Void
    let send: (String, TelevisionAction) -> Void
    @AppStorage(DeviceVisibility.showOfflineKey) private var showOffline = false

    var body: some View {
        let visible = expanded ? devices : devices.filter {
            DeviceVisibility.includes(online: $0.online, showOffline: showOffline) || $0.canWake
        }
        VStack(alignment: .leading, spacing: 8) {
            if showSummaries && !visible.isEmpty {
                ClimateSummaryGrid {
                    ForEach(visible) { tv in
                        let selected = expanded && selectedID == tv.id
                        Button { select(tv.id) } label: {
                            TelevisionSummary(tv: tv, selected: selected)
                        }
                        .panelButtonStyle()
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if expanded, let tv = visible.first(where: { $0.id == selectedID }) {
                TelevisionRemote(tv: tv) { send(tv.id, $0) }
            }
        }
    }
}

struct TelevisionPairingForm: View {
    let submitting: Bool
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var code = ""

    private var valid: Bool { !code.isEmpty && code.utf8.allSatisfy { (48...57).contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the PIN shown on your TV").font(.subheadline.weight(.semibold))
            HStack {
                SecureField("TV PIN", text: $code)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(confirm)
                    .disabled(submitting)
                Button("Pair", action: confirm).disabled(!valid || submitting)
                Button("Cancel", action: cancel)
            }
        }.panelHistorySurface()
    }

    private func confirm() {
        guard valid, !submitting else { return }
        submit(code)
        code = ""
    }
}

struct TelevisionSummary: View {
    let tv: TelevisionItem
    let selected: Bool

    private var state: String {
        if tv.power == false { return "Off" }
        if tv.online == false { return "Offline" }
        if tv.power == true { return "On" }
        return tv.connected || tv.online == true ? "Online" : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "tv").accessibilityHidden(true)
                Text(tv.name).lineLimit(1).minimumScaleFactor(0.85)
            }.font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                if tv.connected || tv.online != nil || tv.power != nil {
                    Circle()
                        .fill(tv.power == true ? SuperBarPanelStyle.green : .gray)
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(state)
                Spacer(minLength: 4)
                if let percent = tv.volumePercent {
                    Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                    Text(verbatim: "\(percent)").monospacedDigit().opacity(tv.liveVolume ? 1 : 0.7)
                }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .deviceSummarySurface(selected: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tv.name)
        .accessibilityValue([state == "—" ? nil : state, tv.volumePercent.map { "Volume \($0)" }]
            .compactMap { $0 }.joined(separator: ", "))
    }
}
