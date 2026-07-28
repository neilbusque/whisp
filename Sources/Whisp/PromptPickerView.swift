import AppKit
import SwiftUI
import WhispCore

/// A small panel listing practice prompts, shown the moment recording starts.
/// The mic is ALREADY HOT when this appears — picking only tags the in-flight
/// session, so nothing said in the first seconds is lost while choosing.
@MainActor
final class PromptPickerPanel {
    private var window: NSWindow?
    private let prompts: [PracticePrompt]
    private let onPick: (PracticePrompt?) -> Void

    init(prompts: [PracticePrompt], onPick: @escaping (PracticePrompt?) -> Void) {
        self.prompts = prompts
        self.onPick = onPick
    }

    func present() {
        dismiss()
        let view = PromptPickerView(prompts: prompts) { [weak self] picked in
            self?.onPick(picked)
            self?.dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "What are you practising?"
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

struct PromptPickerView: View {
    let prompts: [PracticePrompt]
    let onPick: (PracticePrompt?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording has already started.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(prompts) { p in
                    Button {
                        onPick(p)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.body)
                            Text(p.text).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Free-form (Esc)") { onPick(nil) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
