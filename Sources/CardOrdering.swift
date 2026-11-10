import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class CardOrder: ObservableObject {
    static let shared = CardOrder()
    @Published private var orders: [String:[String]]
    var dragging: (group:String,id:String)?
    var lastTarget: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orders = defaults.dictionary(forKey:"cardOrder") as? [String:[String]] ?? [:]
    }
    func sorted<T>(_ items:[T], group:String, id:(T)->String) -> [T] {
        let order = orders[group] ?? []
        let ranks = Dictionary(order.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:{ first,_ in first })
        return items.enumerated().sorted {
            let a = ranks[id($0.element)] ?? order.count + $0.offset
            let b = ranks[id($1.element)] ?? order.count + $1.offset
            return a < b
        }.map(\.element)
    }
    func move(_ id:String, before target:String, group:String, known:[String]) {
        guard id != target, known.contains(id), known.contains(target) else { return }
        var order = sorted(known,group:group,id:{$0})
        guard let from = order.firstIndex(of:id), let to = order.firstIndex(of:target) else { return }
        order.remove(at:from); order.insert(id,at:to)
        orders[group] = order
        defaults.set(orders,forKey:"cardOrder")
    }
}
struct CardDrop: DropDelegate {
    let group:String
    let target:String
    let known:[String]
    func validateDrop(info:DropInfo) -> Bool { CardOrder.shared.dragging?.group == group }
    func dropEntered(info:DropInfo) {
        let state = CardOrder.shared
        guard let drag = state.dragging, drag.group == group, state.lastTarget != target else { return }
        state.lastTarget = target
        state.move(drag.id,before:target,group:group,known:known)
    }
    func dropUpdated(info:DropInfo) -> DropProposal? { DropProposal(operation:.move) }
    func performDrop(info:DropInfo) -> Bool {
        CardOrder.shared.dragging = nil; CardOrder.shared.lastTarget = nil
        return true
    }
}
class HoldDragButton: NSButton, NSDraggingSource {
    var dragID = ""
    var dragGroup = ""
    private var hold: DispatchWorkItem?
    private var armed = false
    private var cursorPushed = false
    private var originalEvent: NSEvent?
    private static let moveCursor: NSCursor = {
        let image = NSImage(systemSymbolName:"arrow.up.and.down.and.arrow.left.and.right",accessibilityDescription:"Move")!
        image.size = NSSize(width:20,height:20)
        return NSCursor(image:image,hotSpot:NSPoint(x:10,y:10))
    }()
    override func mouseDown(with event:NSEvent) {
        guard isEnabled else { return }
        if let action { _ = sendAction(action,to:target) }
        armDrag(event)
    }
    func armDrag(_ event:NSEvent) {
        finishHold()
        guard !dragID.isEmpty else { return }
        originalEvent = event
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.originalEvent != nil else { return }
            self.armed = true
            Self.moveCursor.push(); self.cursorPushed = true
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7,execute:work)
    }
    override func mouseDragged(with event:NSEvent) {
        guard armed, !dragID.isEmpty, let originalEvent else { return }
        armed = false
        CardOrder.shared.dragging = (dragGroup,dragID)
        CardOrder.shared.lastTarget = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setString("superbar-card:" + dragGroup + ":" + dragID,forType:.string)
        let item = NSDraggingItem(pasteboardWriter:pasteboard)
        let image = NSImage(size:bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in:bounds) {
            cacheDisplay(in:bounds,to:bitmap); image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds,contents:image)
        beginDraggingSession(with:[item],event:originalEvent,source:self)
    }
    override func mouseUp(with event:NSEvent) { finishHold() }
    private func finishHold() {
        hold?.cancel(); hold = nil; armed = false; originalEvent = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
        finishHold(); CardOrder.shared.dragging = nil; CardOrder.shared.lastTarget = nil
    }
}
