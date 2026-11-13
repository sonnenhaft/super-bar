import AppKit

// Synthetic paste leaves the user's clipboard untouched.
private final class TestEditor: NSTextView {
    override func paste(_ sender: Any?) { insertText("synthetic paste", replacementRange: selectedRange()) }
}
@main enum EditingCommandsCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        EditingCommands.install(in: app)
        let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let editor = TestEditor(frame: panel.contentView!.bounds)
        panel.contentView!.addSubview(editor)
        precondition(panel.makeFirstResponder(editor))
        editor.string = "existing text"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: panel.windowNumber, context: nil, characters: character,
                            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        precondition(panel.performKeyEquivalent(with: key("a", code: 0)))
        precondition(editor.selectedRange() == NSRange(location: 0, length: 13))
        precondition(panel.performKeyEquivalent(with: key("v", code: 9)))
        precondition(editor.string == "synthetic paste", "Paste must replace the selection in this panel")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        _ = panel.performKeyEquivalent(with: key("a", code: 0, modifiers: [.command, .option]))
        precondition(editor.selectedRange().length == 0)
        precondition(app.mainMenu!.items.first!.submenu!.items.contains { $0.action == #selector(NSText.paste(_:)) && $0.target == nil })
        print("Editing shortcuts: Cmd+A selects text; Cmd+V replaces selection in a nonactivating panel; clipboard untouched.")
    }
}
