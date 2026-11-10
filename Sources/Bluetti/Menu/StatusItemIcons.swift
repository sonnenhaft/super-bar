import AppKit

/// The status item has a single image slot. Compose the selected icons once
/// and reuse that image while readings change within the same battery level.
final class StatusItemIcons {
    private struct Style: Equatable {
        let battery: String?
        let brand: NSImage?
        let indicator: String?
        let fontSize: CGFloat
        let hasReading: Bool
        let customColor: NSColor?
        let appearance: NSAppearance.Name
    }

    private var lastStyle: Style?
    private var lastImage: NSImage?

    func image(battery: Int?, brand: NSImage?, hasReading: Bool, loading: Bool, offline: Bool,
               fontSize: CGFloat, customColor: NSColor?, appearance: NSAppearance) -> NSImage? {
        var indicator: String?
        if hasReading && loading { indicator = "arrow.clockwise" }
        else if hasReading && offline { indicator = "wifi.slash" }
        let style = Style(battery: battery.map(MenuPresentation.batterySymbol), brand: brand,
                          indicator: indicator, fontSize: fontSize, hasReading: hasReading,
                          customColor: customColor, appearance: appearance.name)
        if style != lastStyle {
            appearance.performAsCurrentDrawingAppearance { lastImage = compose(style) }
            lastStyle = style
        }
        return lastImage
    }

    private func compose(_ style: Style) -> NSImage? {
        let scale = style.fontSize / 11
        var parts: [(image: NSImage, size: NSSize, tint: NSColor?)] = []
        func appendSymbol(_ name: String, width: CGFloat, opacity: CGFloat) {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  symbol.size.width > 0 else { return }
            let height = width * symbol.size.height / symbol.size.width
            let tint = (style.customColor ?? .labelColor).withAlphaComponent(opacity)
            parts.append((symbol, NSSize(width: width, height: height), tint))
        }

        if let battery = style.battery { appendSymbol(battery, width: 18 * scale, opacity: 1) }
        if let brand = style.brand {
            let side = min(22, (style.hasReading ? 16 : 18) * scale).rounded()
            parts.append((brand, NSSize(width: side, height: side), nil))
        }
        if let indicator = style.indicator {
            appendSymbol(indicator, width: 6 * scale, opacity: indicator == "wifi.slash" ? 0.45 : 0.65)
        }
        guard let height = parts.map({ $0.size.height }).max() else { return nil }
        let gap = 2 * scale
        let width = parts.reduce(CGFloat(0)) { $0 + $1.size.width } + CGFloat(parts.count - 1) * gap
        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)))
        image.lockFocus()
        var x: CGFloat = 0
        for part in parts {
            let rect = NSRect(x: x, y: (image.size.height - part.size.height) / 2,
                              width: part.size.width, height: part.size.height)
            part.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            if let tint = part.tint {
                tint.setFill()
                rect.fill(using: .sourceIn)
            }
            x += part.size.width + gap
        }
        image.unlockFocus()
        image.isTemplate = style.brand == nil && style.customColor == nil
        return image
    }
}
