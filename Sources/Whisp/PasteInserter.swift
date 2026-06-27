import AppKit
import CoreGraphics
import WhispCore

final class PasteInserter: TextInserting {
    func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let snap = ClipboardPlan.snapshot(currentString: pb.string(forType: .string))

        pb.clearContents()
        pb.setString(text, forType: .string)

        try postCommandV()

        // Restore the previous clipboard shortly after the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pb.clearContents()
            if let prior = ClipboardPlan.restoreString(from: snap) {
                pb.setString(prior, forType: .string)
            }
        }
    }

    private func postCommandV() throws {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            throw NSError(domain: "Whisp.Inserter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No event source"])
        }
        let vKey: CGKeyCode = 9 // 'v'
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            throw NSError(domain: "Whisp.Inserter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not synthesize Cmd-V key events"])
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
