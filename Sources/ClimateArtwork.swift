import SwiftUI

#if os(macOS)
struct ClimateArtwork: View {
    let brand: Brand
    var body: some View { ClimateHousing(windowUnit: brand == .lg) }
}
#endif

/// Shared by the Mac menu, iPhone panel and widgets.
struct ClimateHousing: View {
    let windowUnit: Bool
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 56, size.height / 40)
            context.translateBy(x: (size.width - 56 * scale) / 2, y: (size.height - 40 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let casing = Color(red: 0.83, green: 0.87, blue: 0.88)
            let shade = Color(red: 0.27, green: 0.33, blue: 0.35)
            let shell = CGRect(x: 1, y: windowUnit ? 2 : 8, width: 54, height: windowUnit ? 36 : 25)
            let outline = Path(roundedRect: shell, cornerRadius: windowUnit ? 2 : 5)
            context.fill(outline, with: .linearGradient(Gradient(colors: [.white, casing]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 40)))
            context.stroke(outline, with: .color(.white.opacity(0.7)), lineWidth: 0.8)
            if windowUnit {
                let grille = CGRect(x: 5, y: 6, width: 34, height: 28)
                context.fill(Path(grille), with: .color(shade))
                for row in 0..<10 {
                    var line = Path(); line.move(to: CGPoint(x: 5, y: 7 + row * 3)); line.addLine(to: CGPoint(x: 39, y: 7 + row * 3))
                    context.stroke(line, with: .color(casing), lineWidth: 1)
                }
                for x in [13, 22, 31] {
                    context.stroke(Path(CGRect(x: CGFloat(x), y: 6, width: 0.7, height: 28)), with: .color(casing.opacity(0.5)), lineWidth: 0.5)
                }
                context.fill(Path(CGRect(x: 43, y: 6, width: 8, height: 11)), with: .color(shade))
                context.fill(Path(ellipseIn: CGRect(x: 45, y: 21, width: 5, height: 5)), with: .color(shade))
                context.fill(Path(ellipseIn: CGRect(x: 45, y: 29, width: 5, height: 5)), with: .color(shade))
            } else {
                context.fill(Path(roundedRect: CGRect(x: 6, y: 24, width: 44, height: 5), cornerRadius: 1), with: .color(shade))
                context.fill(Path(CGRect(x: 6, y: 20, width: 44, height: 1)), with: .color(shade.opacity(0.4)))
                context.fill(Path(ellipseIn: CGRect(x: 45, y: 14, width: 2, height: 2)), with: .color(SuperBarPanelStyle.green))
            }
        }.accessibilityHidden(true)
    }
}
