import AppKit

// Keep Deye to the left of the existing readout without changing its pins or icon order.
enum SolarReadout {
    static func prepend(_ prefix: String, to button: NSButton, size: CGFloat, color: NSColor = .systemYellow) {
        let text = NSAttributedString(string: prefix + "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color
        ])
        let title = button.attributedTitle.copy() as! NSAttributedString
        let icon = button.image
        let position = button.imagePosition
        let showTitle = position != .imageOnly
        let iconSize = icon?.size ?? .zero
        let titleSize = showTitle ? title.size() : .zero
        let prefixSize = text.size()
        let gap: CGFloat = icon != nil && titleSize.width > 0 ? 4 : 0
        let total = NSSize(width: ceil(prefixSize.width + iconSize.width + gap + titleSize.width),
                           height: max(22, ceil(max(prefixSize.height, max(iconSize.height, titleSize.height)))))
        let result = NSImage(size: total, flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - prefixSize.height) / 2))
            var x = prefixSize.width
            if position == .imageRight || position == .imageTrailing {
                title.draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2))
                x += titleSize.width + gap
                icon?.draw(in: NSRect(x: x, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            } else {
                icon?.draw(in: NSRect(x: x, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
                x += iconSize.width + gap
                if showTitle { title.draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2)) }
            }
            return true
        }
        result.isTemplate = false
        button.title = ""
        button.image = result
        button.imagePosition = .imageOnly
    }
}
