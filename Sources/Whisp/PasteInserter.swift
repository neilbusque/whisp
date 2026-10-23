import AppKit
import ApplicationServices
import WhispCore

/// Clipboard and focus access is main-actor isolated. A late result never
/// activates a different app or overwrites a newer clipboard item.
@MainActor
final class PasteInserter: TextInserting, SelectedTextReading, TextEditing {
    private struct FieldSnapshot {
        let pid: pid_t
        let element: AXUIElement
        let value: String
        let range: TextEditRange
        let selection: String?
    }

    private struct RecentInsertion {
        let pid: pid_t
        let element: AXUIElement
        let range: TextEditRange
        let text: String
    }

    private struct PreparedEdit {
        let target: TextEditTarget
        let snapshot: FieldSnapshot
        let range: TextEditRange
    }

    private var targetPID: pid_t?
    private var targetElement: AXUIElement?
    private var selectedText: String?
    private var initialSelection: String?
    private var initialRange: CFRange?
    private var initialValue: String?
    private var recentInsertion: RecentInsertion?
    private var preparedEdit: PreparedEdit?

    func beginSession() {
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetElement = focusedElement()
        selectedText = nil
        initialSelection = targetElement.flatMap { readSelection(of: $0) }
        initialRange = targetElement.flatMap { readSelectionRange(of: $0) }
        initialValue = targetElement.flatMap { readValue(of: $0) }
        preparedEdit = nil
    }

    func insert(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw failure("Enable Accessibility. Use Copy Last Dictation in Whisp.") }
        try checkOriginalFocus()
        try checkSelectionRange()
        if let initialSelection, !initialSelection.isEmpty, readSelection() != initialSelection {
            throw failure("Selection changed. Use Copy Last Dictation in Whisp.")
        }
        if let selectedText, readSelection() != selectedText {
            throw failure("Selection changed. Use Copy Last Dictation in Whisp.")
        }
        let before = fieldSnapshot()
        recentInsertion = nil
        preparedEdit = nil
        let transaction = ClipboardTransaction(text: text)
        do { try postKey(keyCode: 9, command: true) }
        catch { transaction.restoreIfUnchanged(); throw error }
        // Once a key event is posted, let the application consume it even if
        // this task is cancelled. Restore all clipboard types only while owned.
        await waitForConsumption(of: text, replacing: before?.range, in: before)
        transaction.restoreIfUnchanged()
        if let before {
            recordInsertion(text, replacing: before.range, in: before)
        }
    }

    func readSelectedText() async throws -> String? {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw failure("Enable Accessibility to rewrite selected text.") }
        guard targetPID != nil, targetElement != nil else {
            throw failure("Select the text and try again.")
        }
        try checkOriginalFocus()
        try checkSelectionRange()
        guard readSelection() == initialSelection else {
            throw failure("Selection changed. Select the text and try again.")
        }
        // Reading the focused element avoids Cmd-C races and preserves every
        // clipboard type. Unsupported selections fail without replacing text.
        let value = readSelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedText = readSelection()
        return value
    }

    func prepareEdit(preferRecent: Bool) async throws -> TextEditTarget? {
        try Task.checkCancellation()
        preparedEdit = nil
        guard AXIsProcessTrusted() else { throw failure("Enable Accessibility to edit text.") }
        try checkOriginalFocus()
        // Edits need stronger evidence than ordinary paste: the complete value,
        // selection and cursor must still match the start of this dictation.
        guard let snapshot = fieldSnapshot(), targetPID != nil, targetElement != nil,
              initialRange != nil, initialValue != nil else { return nil }
        guard matchesSession(snapshot) else {
            throw failure("Text or cursor changed. Select the text and try again.")
        }
        let selectedRange: TextEditRange? = {
            guard snapshot.range.length > 0,
                  let text = snapshot.range.text(in: snapshot.value),
                  text == snapshot.selection,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return snapshot.range
        }()
        let recentRange = verifiedRecentRange(in: snapshot)
        guard let range = preferRecent ? (recentRange ?? selectedRange) : (selectedRange ?? recentRange),
              let text = range.text(in: snapshot.value), !text.isEmpty else { return nil }
        let target = TextEditTarget(text: text, isExplicitSelection: selectedRange == range)
        preparedEdit = PreparedEdit(target: target, snapshot: snapshot, range: range)
        return target
    }

    func replace(_ target: TextEditTarget, with text: String) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw failure("Enable Accessibility to edit text.") }
        guard let prepared = preparedEdit, prepared.target == target else {
            throw failure("The edit expired. Select the text and try again.")
        }
        guard let current = fieldSnapshot(), sameSnapshot(current, prepared.snapshot),
              prepared.range.text(in: current.value) == target.text else {
            preparedEdit = nil
            throw failure("Text or cursor changed. Select the text and try again.")
        }
        // Consume the token before the first mutation. A delayed or retried AI
        // response can never apply this edit twice.
        preparedEdit = nil
        if text == target.text { return }
        try select(prepared.range, in: current.element)
        guard let selected = fieldSnapshot(), selected.pid == current.pid,
              CFEqual(selected.element, current.element), selected.value == current.value,
              selected.range == prepared.range, selected.selection == target.text else {
            restoreSelection(current)
            throw failure("Could not select that text safely. Select it and try again.")
        }
        recentInsertion = nil
        let transaction = text.isEmpty ? nil : ClipboardTransaction(text: text)
        do { try postKey(keyCode: text.isEmpty ? 51 : 9, command: !text.isEmpty) }
        catch {
            transaction?.restoreIfUnchanged()
            restoreSelection(current)
            throw error
        }
        await waitForConsumption(of: text, replacing: prepared.range, in: current)
        transaction?.restoreIfUnchanged()
        guard recordInsertion(text, replacing: prepared.range, in: current) else {
            throw failure("Could not verify the edit. Check the text before trying again.")
        }
    }

    private func matchesSession(_ snapshot: FieldSnapshot) -> Bool {
        guard let targetPID, let targetElement, let initialRange, let initialValue else { return false }
        return snapshot.pid == targetPID && CFEqual(snapshot.element, targetElement)
            && snapshot.value == initialValue && snapshot.selection == initialSelection
            && snapshot.range == TextEditRange(location: initialRange.location, length: initialRange.length)
    }

    private func verifiedRecentRange(in snapshot: FieldSnapshot) -> TextEditRange? {
        guard let recent = recentInsertion, recent.pid == snapshot.pid,
              CFEqual(recent.element, snapshot.element), snapshot.range.length == 0,
              snapshot.range.location == recent.range.upperBound,
              recent.range.text(in: snapshot.value) == recent.text else { return nil }
        return recent.range
    }

    /// Success requires the exact expected document and caret. Rich editors
    /// that do not expose enough Accessibility information simply cannot offer
    /// the recent-dictation shortcut; explicit selection remains available.
    @discardableResult
    private func recordInsertion(_ text: String, replacing range: TextEditRange, in before: FieldSnapshot) -> Bool {
        guard let expected = PasteConsumption.ExpectedChange(text: text, replacing: range, in: before.value),
              let after = fieldSnapshot(), after.pid == before.pid,
              CFEqual(after.element, before.element),
              expected.matches(value: after.value, selection: after.range) else { return false }
        recentInsertion = text.isEmpty ? nil : RecentInsertion(
            pid: after.pid, element: after.element, range: expected.insertedRange, text: text)
        return true
    }

    private func sameSnapshot(_ first: FieldSnapshot, _ second: FieldSnapshot) -> Bool {
        first.pid == second.pid && CFEqual(first.element, second.element)
            && first.value == second.value && first.range == second.range
            && first.selection == second.selection
    }

    private func fieldSnapshot() -> FieldSnapshot? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = focusedElement(), let value = readValue(of: element),
              let range = readSelectionRange(of: element) else { return nil }
        let textRange = TextEditRange(location: range.location, length: range.length)
        guard textRange.text(in: value) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let stillFocused = focusedElement(), CFEqual(element, stillFocused) else { return nil }
        return FieldSnapshot(pid: pid, element: element, value: value, range: textRange,
                             selection: readSelection(of: element))
    }

    private func checkOriginalFocus() throws {
        guard targetPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            throw failure("App changed. Use Copy Last Dictation in Whisp.")
        }
        if let targetElement {
            guard let focused = focusedElement(), CFEqual(targetElement, focused) else {
                throw failure("Text field changed. Use Copy Last Dictation in Whisp.")
            }
        }
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
              kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func readSelectionRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func checkSelectionRange() throws {
        if let before = initialRange {
            guard let focused = focusedElement(), let current = readSelectionRange(of: focused),
                  before.location == current.location, before.length == current.length else {
                throw failure("Cursor moved. Use Copy Last Dictation in Whisp.")
            }
        }
    }

    private func readSelection() -> String? {
        focusedElement().flatMap { readSelection(of: $0) }
    }

    private func readSelection(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func readValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func select(_ range: TextEditRange, in element: AXUIElement) throws {
        var selection = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw failure("This field cannot be edited safely. Select the text and try again.")
        }
    }

    private func restoreSelection(_ before: FieldSnapshot) {
        guard let current = fieldSnapshot(), current.pid == before.pid,
              CFEqual(current.element, before.element), current.value == before.value else { return }
        try? select(before.range, in: before.element)
    }

    private func waitForConsumption(of text: String, replacing range: TextEditRange?, in before: FieldSnapshot?) async {
        let started = ContinuousClock.now
        guard let before, let range,
              let expected = PasteConsumption.ExpectedChange(text: text, replacing: range, in: before.value) else {
            // Unsupported Accessibility fields keep the previous allowance.
            await PasteConsumption.wait(verify: nil)
            Diag.log("paste allowance used (field cannot acknowledge)")
            return
        }
        let verified = await PasteConsumption.wait(verify: {
            guard let after = self.fieldSnapshot(), after.pid == before.pid,
                  CFEqual(after.element, before.element) else { return false }
            return expected.matches(value: after.value, selection: after.range)
        })
        Diag.log("paste \(verified ? "verified" : "allowance used") in \(started.duration(to: .now))")
    }

    private func postKey(keyCode: CGKeyCode, command: Bool) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw failure("Could not paste. Use Copy Last Dictation in Whisp.")
        }
        down.flags = command ? .maskCommand : []; up.flags = command ? .maskCommand : []
        down.post(tap: .cgAnnotatedSessionEventTap); up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "Whisp.Paste", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Only an exact document and caret acknowledgement can shorten the clipboard
/// lifetime. Cancellation after posting Cmd-V must not shorten this wait.
@MainActor
enum PasteConsumption {
    struct ExpectedChange {
        let value: String
        let insertedRange: TextEditRange

        init?(text: String, replacing range: TextEditRange, in before: String) {
            guard let value = range.replacing(in: before, with: text) else { return nil }
            self.value = value
            insertedRange = TextEditRange(location: range.location, length: text.utf16.count)
        }

        func matches(value: String, selection: TextEditRange) -> Bool {
            value == self.value && selection.length == 0 && selection.location == insertedRange.upperBound
        }
    }

    @discardableResult
    static func wait(
        verify: (() -> Bool)?,
        timeout: TimeInterval = 0.35,
        interval: TimeInterval = 0.015,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @MainActor (TimeInterval) async -> Void = PasteConsumption.pause
    ) async -> Bool {
        guard let verify else {
            await pause(timeout)
            return false
        }
        let deadline = now() + timeout
        while true {
            if verify() { return true }
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            await pause(min(interval, remaining))
        }
    }

    private static func pause(_ duration: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { continuation.resume() }
        }
    }
}
