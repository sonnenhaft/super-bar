import AppKit

extension BlueBarDelegate {
    func addVisibilityItems(to menu: NSMenu) {
        for (button, label, action) in [
            (iconVisibilityItem, "Icon", #selector(toggleBrandIcon)),
            (percentVisibilityItem, "Battery percentage", #selector(togglePercent)),
            (outputVisibilityItem, "Output power", #selector(toggleOutput)),
            (timeVisibilityItem, "Battery runtime", #selector(toggleTime))
        ] {
            if button === iconVisibilityItem || button === outputVisibilityItem {
                button.cell = MenuCheckboxCell()
            }
            button.setButtonType(.switch)
            button.alignment = .left
            button.controlSize = .small
            button.font = fixedMenuFont
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }

        for (left, right) in [(iconVisibilityItem, percentVisibilityItem),
                              (outputVisibilityItem, timeVisibilityItem)] {
            let item = NSMenuItem()
            item.view = MenuColumns(left: left, right: right, height: 22)
            menu.addItem(item)
        }

        if let badge = brandBadge {
            let attachment = NSTextAttachment()
            attachment.image = badge
            attachment.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
            iconVisibilityItem.attributedTitle = NSAttributedString(attachment: attachment)
        } else { iconVisibilityItem.title = "Icon" }
    }

    func setTimeVisibilityHidden(_ hidden: Bool) {
        timeVisibilityItem.isHidden = hidden
    }
}

private final class MenuCheckboxCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        super.draw(withFrame: frame.insetBy(dx: 12, dy: 0), in: controlView)
    }
}
