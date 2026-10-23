import AppKit

/// Dictation stays on the clipboard for manual recovery after automatic paste.
/// Publish once: no delayed restoration or refresh may overwrite a newer copy.
@MainActor
enum ClipboardTransaction {
    @discardableResult
    static func publish(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        // A spoken deletion has no replacement text and must not erase a copy.
        guard !text.isEmpty else { return true }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
