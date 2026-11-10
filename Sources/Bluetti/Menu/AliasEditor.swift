import AppKit

final class BlueBarAliasEditor: NSTextField, NSTextFieldDelegate {
    private var completion: ((String?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        font = .systemFont(ofSize: 12)
        isHidden = true
        setAccessibilityLabel("Station name")
    }

    required init?(coder: NSCoder) { nil }

    func begin(alias: String, placeholder: String, completion: @escaping (String?) -> Void) {
        stringValue = alias
        placeholderString = placeholder
        self.completion = completion
        isHidden = false
        guard window?.makeFirstResponder(self) == true else { cancel(); return }
        // selectText(_:) ends the existing field editor session before starting another.
        // Keep this session active so its end-editing callback cannot cancel the rename.
        currentEditor()?.selectAll(nil)
    }

    func cancel() { finish(nil) }

    private func finish(_ alias: String?) {
        guard let callback = completion else { return }
        completion = nil
        abortEditing()
        isHidden = true
        callback(alias)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            finish(textView.string)
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { cancel() }
}
