import SwiftUI
#if os(macOS)
import AppKit
#endif

// One sRGB palette for SwiftUI and the remaining AppKit views.
enum PanelPalette: UInt32, CaseIterable {
    case backgroundTop = 0x1F3238
    case background = 0x1B2D34
    case backgroundBottom = 0x192C33
    case panel = 0x293A40
    case selected = 0x284E63
    case ocean = 0x294952
    case yellow = 0xFFD100
    case cyan = 0x00E6F2
    case outline = 0x67DFFF
    case green = 0x8CBD9C

    private var red: Double { Double((rawValue >> 16) & 255) / 255 }
    private var green: Double { Double((rawValue >> 8) & 255) / 255 }
    private var blue: Double { Double(rawValue & 255) / 255 }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    #if os(macOS)
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    #endif
}

enum SuperBarPanelStyle {
    static let backgroundTop = PanelPalette.backgroundTop.color
    static let backgroundBottom = PanelPalette.backgroundBottom.color
    static let panel = PanelPalette.panel.color
    static let selected = PanelPalette.selected.color
    static let cyan = PanelPalette.cyan.color
    static let yellow = PanelPalette.yellow.color
    static let green = PanelPalette.green.color
    static let outline = PanelPalette.outline.color
    static let maximumWidth: CGFloat = 460
    static let brandWidth: CGFloat = 48
    static let logoColumn: CGFloat = 56
    static let appInset: CGFloat = 14
    static let widgetInset: CGFloat = 10
    static let gap: CGFloat = 8
    static let radius: CGFloat = 9
    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, PanelPalette.background.color, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }
}

let cobalt = SuperBarPanelStyle.cyan
let ice = SuperBarPanelStyle.cyan
let sunlight = SuperBarPanelStyle.yellow
let leafGreen = SuperBarPanelStyle.green

// The symbol is sized independently of the surrounding button's hit area.
struct RefreshGlyph: View {
    let isRefreshing: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if isRefreshing {
                if #available(iOS 18, macOS 15, *) {
                    Image(systemName: "progress.indicator")
                        .resizable().scaledToFit()
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                        .scaleEffect(size / 16)
                }
            } else {
                Image(systemName: "arrow.clockwise").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    func panelHistorySurface() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    @ViewBuilder func panelButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(PanelPointerButtonStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    @ViewBuilder func panelPointer() -> some View {
        #if os(macOS)
        modifier(PanelPointer())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct PanelPointer: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(enabled ? .link : .default)
        } else { content }
    }
}

private struct PanelPointerButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.plain).panelPointer()
    }
}
#endif
