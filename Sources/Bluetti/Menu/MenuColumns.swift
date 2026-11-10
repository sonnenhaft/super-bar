import AppKit

/// Two fixed columns keep controls aligned as the native menu changes width.
final class MenuColumns: NSView {
    private let left: NSView
    private let right: NSView
    private let leadingInset: CGFloat

    init(left: NSView, right: NSView, height: CGFloat, leadingInset: CGFloat = 0) {
        self.left = left
        self.right = right
        self.leadingInset = leadingInset
        super.init(frame: NSRect(x: 0, y: 0, width: 264, height: height))
        autoresizingMask = [.width]
        addSubview(left)
        addSubview(right)
        resizeSubviews(withOldSize: bounds.size)
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let middle = bounds.midX
        left.frame = NSRect(x: bounds.minX + leadingInset, y: bounds.minY,
                            width: max(0, middle - bounds.minX - leadingInset), height: bounds.height)
        right.frame = NSRect(x: middle, y: bounds.minY,
                             width: bounds.maxX - middle, height: bounds.height)
    }
}
