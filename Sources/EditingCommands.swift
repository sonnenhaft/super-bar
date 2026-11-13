import AppKit

@MainActor enum EditingCommands {
    static func install(in application: NSApplication) {
        let menu = NSMenu(), edit = NSMenu(title: "Edit")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit; menu.addItem(item)
        for (title, action, key, shift) in [
            ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false)
        ] {
            let command = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            command.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
            edit.addItem(command)
        }
        application.mainMenu = menu
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A nonactivating panel can own the field editor while another app
        // still owns the menu bar. Route editing commands to our focused editor.
        if let editor = firstResponder as? NSTextView {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let action: Selector?
            switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "a"): action = #selector(NSText.selectAll(_:))
            case (.command, "c"): action = #selector(NSText.copy(_:))
            case (.command, "v"): action = #selector(NSText.paste(_:))
            case (.command, "x"): action = #selector(NSText.cut(_:))
            case (.command, "z"): action = Selector("undo:")
            case ([.command, .shift], "z"): action = Selector("redo:")
            default: action = nil
            }
            if let action, editor.tryToPerform(action, with: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
