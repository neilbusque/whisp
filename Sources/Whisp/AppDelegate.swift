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
    private var practice: PracticeController?
    private var practiceHotkey: PracticeHotkey?
    private var promptPicker: PromptPickerPanel?
    private var practiceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("=== launch ===")
        do {
            try Paths.ensureSeeded()
            config = try Paths.loadConfig()
        } catch {
            Diag.log("seed/config error: \(error)")
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
            let vocab = Paths.loadVocabulary()
            let hint = vocab.isEmpty ? "" : "Vocabulary: " + vocab.joined(separator: ", ") + "."
            let transcriber = try WhisperTranscriber(
                modelPath: Paths.modelPath(config.whisperModel), initialPrompt: hint)
            let cleaner = DeepSeekCleaner(apiKey: config.deepseekKey)
            let inserter = PasteInserter()
            pipeline = SpeechPipeline(
                snippets: snippets,
                transcriber: transcriber,
                cleaner: cleaner,
                inserter: inserter,
                vocabulary: vocab,
                // `onStatus` runs inside the pipeline's async `process(...)`, which
                // is NOT guaranteed to be on the main actor. Hop before touching
                // the @MainActor HUD / status item.
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        self?.hud.show(status)
                        self?.updateStatusTitle(status)
                    }
                })
            Diag.log("pipeline OK (model=\(config.whisperModel), vocab=\(vocab.count) terms, key=\(config.deepseekKey.isEmpty ? "none" : "set"))")

            if config.hotkey.lowercased() != "fn" {
                Diag.log("config: hotkey '\(config.hotkey)' is not supported — dictation is Fn-only; using Fn")
            }

            // Practice Mode.
            let promptStore = (try? Paths.loadPrompts()) ?? PromptStore(prompts: PromptStore.seed)
            let sessionStore = (try? Paths.loadSessions()) ?? PracticeStore(sessions: [])
            let controller = PracticeController(recorder: recorder, transcriber: transcriber,
                                                cleaner: cleaner, config: config,
                                                store: sessionStore, prompts: promptStore)
            controller.onStatus = { [weak self] text, done in
                MainActor.assumeIsolated { self?.hud.showPracticeStatus(text, done: done) }
            }
            practice = controller

            // Fall back to the default if the config value is malformed, so a typo
            // degrades to a working hotkey instead of a silently dead feature.
            let spec = HotkeySpec.parse(config.practiceHotkey)
                ?? HotkeySpec.parse(WhispConfig.defaults.practiceHotkey)!
            if HotkeySpec.parse(config.practiceHotkey) == nil {
                Diag.log("config: practiceHotkey '\(config.practiceHotkey)' is malformed — using \(spec.display)")
            }
            let practiceHK = PracticeHotkey(spec: spec) { [weak self] in
                MainActor.assumeIsolated { self?.togglePractice() }
            }
            practiceHK.register()
            practiceHotkey = practiceHK
        } catch {
            Diag.log("pipeline FAIL: \(error)")
            NSLog("Whisp pipeline init failed: \(error)")
            setStatusTitle("Whisp — model error (open Settings)")
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
        Diag.log("startRecording called (recording=\(recording), pipeline=\(pipeline != nil))")
        guard !recording, pipeline != nil else { return }
        // The recorder is shared with Practice Mode. Refuse to steal it out
        // from under an in-progress practice recording rather than let
        // AudioRecorder.start() throw and silently drop the mic.
        guard practice?.isRecording != true else {
            Diag.log("dictation: ignored, a practice recording is in progress")
            return
        }
        recording = true
        do {
            try recorder.start()
            hud.show(.listening)
            setStatusTitle("Whisp — listening")
            updateMenuIcon("mic.fill")
        } catch {
            recording = false
            hud.show(.error("Mic error"))
            updateMenuIcon("exclamationmark.triangle")
        }
    }

    private func stopAndProcess() {
        Diag.log("stopAndProcess called (recording=\(recording))")
        guard recording else { return }
        recording = false
        let samples = recorder.stop()
        Diag.log("captured \(samples.count) samples")
        guard let pipeline else { return }
        Task { await pipeline.process(samples: samples) }
    }

    // MARK: - Practice Mode

    private func togglePractice() {
        guard let practice else { return }
        // Only blocks STARTING a practice recording while dictation is in
        // progress. Never blocks stopping one that's already running — the
        // recorder is shared, and dictation can only be active if practice
        // isn't (see the mirror-image guard in `startRecording()`).
        if practice.isRecording != true, recording {
            Diag.log("practice: ignored, dictation is in progress")
            hud.showPracticeStatus("Finish dictating first", done: true)
            return
        }
        practice.toggle()

        if practice.isRecording {
            let picker = PromptPickerPanel(prompts: practice.prompts.all) { [weak self] picked in
                self?.practice?.setPrompt(picked)
            }
            picker.present()
            promptPicker = picker

            // Ticks the elapsed timer. The waveform is already live: the
            // `recorder.level` handler assigned at startup (AppDelegate.swift:30)
            // feeds hud.setLevel for BOTH modes, which is why neither
            // PracticeController nor this method reassigns it.
            let started = Date()
            practiceTimer?.invalidate()
            practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.practice, p.isRecording else { return }
                    self.hud.showPractice(elapsed: Date().timeIntervalSince(started))
                }
            }
        } else {
            practiceTimer?.invalidate()
            practiceTimer = nil
            promptPicker?.dismiss()
            promptPicker = nil
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        updateMenuIcon("waveform")
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Whisp — idle", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit Snippets…", action: #selector(openSnippets), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Practice…", action: #selector(openPractice), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whisp", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusTitle(_ status: PipelineStatus) {
        switch status {
        case .idle:         setStatusTitle("Whisp — idle");          updateMenuIcon("waveform")
        case .listening:    setStatusTitle("Whisp — listening");     updateMenuIcon("mic.fill")
        case .transcribing: setStatusTitle("Whisp — transcribing");  updateMenuIcon("waveform")
        case .polishing:    setStatusTitle("Whisp — polishing");     updateMenuIcon("sparkles")
        case .done:         setStatusTitle("Whisp — idle");          updateMenuIcon("waveform")
        case .error(let m): setStatusTitle("Whisp — \(m)");          updateMenuIcon("exclamationmark.triangle")
        }
    }

    private func setStatusTitle(_ s: String) {
        statusMenuItem.title = s
    }

    /// Template SF Symbol so the menu-bar icon adapts to light/dark automatically.
    private func updateMenuIcon(_ symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisp")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    @objc private func openSnippets() {
        SnippetsWindowController.shared.show(path: Paths.snippetsFile)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(configPath: Paths.configFile)
    }

    @objc private func openPractice() {
        guard let practice else { return }
        PracticeWindow.shared.show(controller: practice)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
