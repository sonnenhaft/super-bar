import SwiftUI

enum PanelLayout {
    static let width = SuperBarPanelStyle.maximumWidth
    static let logoColumn = SuperBarPanelStyle.logoColumn
}
struct DeviceChoice<Content: View>: View {
    var selected = false
    var compact = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content().padding(.horizontal, 10).padding(.vertical, compact ? 5 : 9)
                .frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
        }.panelButtonStyle().deviceSurface(selected: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: BarTheme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.16),lineWidth:0.5))
            .shadow(color:.black.opacity(0.12),radius:2,y:1)
    }
}
struct SectionName: View {
    let title: String, icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
    }
}
extension View {
    func overviewSurface(selected: Bool) -> some View {
        self.foregroundStyle(.white).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .deviceSurface(selected: selected)
    }

}
