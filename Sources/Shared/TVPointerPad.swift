import SwiftUI

enum TVShortcut: String, CaseIterable {
    case youtube, netflix, prime = "prime-video", disney = "disney-plus"

    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .netflix: "Netflix"
        case .prime: "Prime Video"
        case .disney: "Disney+"
        }
    }

    func resolve(_ apps: [TelevisionInput]) -> TelevisionInput? {
        let aliases: [String]
        switch self {
        case .youtube: aliases = ["youtube.leanback.v4", "youtube"]
        case .netflix: aliases = ["netflix", "netflixglobal"]
        case .prime: aliases = ["amazon", "amazon.global", "primevideo", "amazonprimevideo"]
        case .disney: aliases = ["com.disney.disneyplus-prod", "disneyplus", "disney+"]
        }
        func key(_ input: String) -> String {
            input.lowercased().replacingOccurrences(of: " ", with: "")
        }
        return apps.first { aliases.contains(key($0.id)) } ?? apps.first { aliases.contains(key($0.name)) }
    }
}

struct TVPointerPad: View {
    let send: (TelevisionAction) -> Void
    @State private var previous = CGSize.zero
    @State private var moved = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.black.opacity(0.42))
            .overlay { Image(systemName: "hand.draw").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, minHeight: 94)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { event in
                    let size = event.translation
                    guard moved || hypot(size.width, size.height) > 4 else { return }
                    moved = true
                    let dx = Int(((size.width - previous.width) * 2).rounded())
                    let dy = Int(((size.height - previous.height) * 2).rounded())
                    previous = size
                    if dx != 0 || dy != 0 { send(.move(dx, dy)) }
                }.onEnded { event in
                    if !moved && hypot(event.translation.width, event.translation.height) <= 4 { send(.click) }
                    previous = .zero
                    moved = false
                })
            .accessibilityLabel("TV touchpad")
            .accessibilityHint("Move the pointer or tap to select")
            .accessibilityAction { send(.click) }
    }
}
