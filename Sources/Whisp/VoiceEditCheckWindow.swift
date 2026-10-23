import AppKit
import WhispCore

/// Explicit local QA fixture. It only edits its own visible scratch document
/// and is available with --voice-edit-check --no-hotkeys --data-dir <temp>.
@MainActor
final class VoiceEditCheckWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let document = NSTextView()
    private let utterance = NSTextField(string: "The proposal is ready. The budget is tentative.")
    private let result = NSTextField(wrappingLabelWithString: "Enter a synthetic dictation, then run it.")
    private let run = NSButton(title: "Run dictation", target: nil, action: nil)
    private let inserter = PasteInserter()
    private var pipeline: SpeechPipeline?
    private var task: Task<Void, Never>?

    private struct NoAudio: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String { throw CancellationError() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Whisp")
        appMenu.addItem(withTitle: "Quit Whisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Whisp voice edit check"
        window.isReleasedWhenClosed = false
        document.isRichText = false
        document.font = .systemFont(ofSize: 17)
        document.isAutomaticQuoteSubstitutionEnabled = false
        document.isAutomaticDashSubstitutionEnabled = false
        document.setAccessibilityLabel("Scratch document")
        document.autoresizingMask = [.width]
        document.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        utterance.setAccessibilityLabel("Synthetic dictation")
        run.target = self
        run.action = #selector(process)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Scratch document"), scroll,
            NSTextField(labelWithString: "Synthetic dictation"), utterance, run, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
                utterance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            let config = try Paths.loadConfig()
            pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: NoAudio(),
                cleaner: OpenAICleaner(apiKey: config.openaiKey, model: config.textModel),
                inserter: inserter, editor: inserter, cleanupMode: config.cleanupMode,
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        switch status {
                        case .error(let error): self?.result.stringValue = "Error: \(error)"
                        case .done: self?.result.stringValue = "Done. Document and cursor verified."
                        case .polishing: self?.result.stringValue = "Interpreting with OpenAI…"
                        default: break
                        }
                    }
                })
        } catch { result.stringValue = error.localizedDescription }
    }

    @objc private func process() {
        guard task == nil, let pipeline else { return }
        let speech = utterance.stringValue
        run.isEnabled = false
        result.stringValue = "Processing…"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(document)
        task = Task {
            try? await Task.sleep(for: .milliseconds(100))
            inserter.beginSession()
            await pipeline.process(transcript: speech)
            run.isEnabled = true
            task = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { task?.cancel() }
}
