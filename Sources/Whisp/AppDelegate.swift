import AppKit
import WhispCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var hotkey: HotkeyMonitor?
    private let recorder = AudioRecorder()
    private let hud = HUDWindow()
    private var pipeline: SpeechPipeline?
    private var config = WhispConfig.defaults
    private var recording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Paths.ensureSeeded()
            config = try Paths.loadConfig()
        } catch {
            NSLog("Whisp seed/config error: \(error)")
        }

        setupMenuBar()
        setupPipeline()

        // The audio tap fires `level` on CoreAudio's thread, so hop to the main
        // actor before touching the @MainActor HUD.
        recorder.level = { [weak self] lvl in
            Task { @MainActor in self?.hud.setLevel(lvl) }
        }

        // HotkeyMonitor is @MainActor; its callbacks fire on the main actor, but
        // they're typed @Sendable, so we keep the capture weak and clean.
        hotkey = HotkeyMonitor(
            onPress: { [weak self] in
                Task { @MainActor in self?.startRecording() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.stopAndProcess() }
            })
        hotkey?.start()
    }

    // MARK: - Pipeline

    private func setupPipeline() {
        do {
            let snippets = try Paths.loadSnippets()
            let transcriber = try WhisperTranscriber(modelPath: Paths.modelPath(config.whisperModel))
            let cleaner = DeepSeekCleaner(apiKey: config.deepseekKey)
            let inserter = PasteInserter()
            pipeline = SpeechPipeline(
                snippets: snippets,
                transcriber: transcriber,
                cleaner: cleaner,
                inserter: inserter,
                // `onStatus` runs inside the pipeline's async `process(...)`, which
                // is NOT guaranteed to be on the main actor. Hop before touching
                // the @MainActor HUD / status item.
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        self?.hud.show(status)
                        self?.updateStatusTitle(status)
                    }
                })
        } catch {
            NSLog("Whisp pipeline init failed: \(error)")
            setStatusTitle("Whisp — model error (open Settings)")
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard !recording, pipeline != nil else { return }
        recording = true
        do {
            try recorder.start()
            hud.show(.listening)
            setStatusTitle("Whisp — listening")
        } catch {
            recording = false
            hud.show(.error("Mic error"))
        }
    }

    private func stopAndProcess() {
        guard recording else { return }
        recording = false
        let samples = recorder.stop()
        guard let pipeline else { return }
        Task { await pipeline.process(samples: samples) }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Whisp — idle", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit Snippets…", action: #selector(openSnippets), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whisp", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusTitle(_ status: PipelineStatus) {
        switch status {
        case .idle:         setStatusTitle("Whisp — idle")
        case .listening:    setStatusTitle("Whisp — listening")
        case .transcribing: setStatusTitle("Whisp — transcribing")
        case .polishing:    setStatusTitle("Whisp — polishing")
        case .done:         setStatusTitle("Whisp — idle")
        case .error(let m): setStatusTitle("Whisp — \(m)")
        }
    }

    private func setStatusTitle(_ s: String) {
        statusMenuItem.title = s
    }

    @objc private func openSnippets() {
        SnippetsWindowController.shared.show(path: Paths.snippetsFile)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(configPath: Paths.configFile)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
