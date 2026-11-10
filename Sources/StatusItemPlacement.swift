import AppKit

// System screen coordinates are in points, with Y increasing upward.
@MainActor func statusItemPlacement(_ item: NSStatusItem) -> [String: Any] {
    var result: [String: Any] = ["itemVisible": item.isVisible, "itemLength": item.length]
    guard let button = item.button else { return result }
    result["buttonTitle"] = button.title
    result["imageWidth"] = button.image?.size.width ?? 0
    result["imageHeight"] = button.image?.size.height ?? 0
    result["buttonHidden"] = button.isHiddenOrHasHiddenAncestor
    guard let window = button.window else { return result }
    let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
    result["buttonFrame"] = NSStringFromRect(rect)
    result["windowFrame"] = NSStringFromRect(window.frame)
    result["windowVisible"] = window.isVisible
    let display = NSScreen.screens.first { !$0.frame.intersection(rect).isEmpty && $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    guard let display else {
        result["insideMenuBar"] = false
        return result
    }
    result["displayFrame"] = NSStringFromRect(display.frame)
    let height = max(NSStatusBar.system.thickness, display.safeAreaInsets.top)
    let menuBand = NSRect(x: display.frame.minX, y: display.frame.maxY - height,
                          width: display.frame.width, height: height)
    let withinBand = !rect.isEmpty && menuBand.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    if let left = display.auxiliaryTopLeftArea, let right = display.auxiliaryTopRightArea {
        result["insideMenuBar"] = withinBand && (rect.maxX <= left.maxX || rect.minX >= right.minX)
    } else {
        result["insideMenuBar"] = withinBand
    }
    return result
}
