import SwiftUI
import AppKit

struct DeviceSection: Identifiable {
    let title: String
    let symbol: String
    let items: [NSMenuItem]
    var id: String { title }
}

struct PanelControl: NSViewRepresentable {
    let control: NSView
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: control.bounds)
        control.frame.origin = .zero
        control.autoresizingMask = [.width, .height]
        container.addSubview(control)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if control.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            nsView.addSubview(control)
        }
        control.frame = nsView.bounds
        (control as? SuperFooter)?.sync()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 374, height: proposal.height ?? control.frame.height)
    }
}
