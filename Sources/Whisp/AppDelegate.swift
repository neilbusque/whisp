import AppKit
import WhispCore
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = WorkspaceState()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var copyLastItem: NSMenuItem!
    private var lastTranscript: String?
    private var hotkey: HotkeyMonitor?
    private let recorder = AudioRecorder()
    private let hud = HUDWindow()
    private var pipeline: SpeechPipeline?
    private var speculativeCleaner: SpeculativeCleaner?
    private var partialTask: Task<Void, Never>?
    private var activeSpeculationID: UUID?
    private var startingRecording = false
    private var config = WhispConfig.defaults
    private var recording = false
    private var fnHeld = false
    private var processing = false
    private var loadingModel = false
    private var pendingReload = false
    private var recordingLimit: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var pendingSamples: [Float] = []
    private var processingStarted = Date()
    private let inserter = PasteInserter()
    private lazy var learning = LearningModel()
    private var transcriber: LazyWhisperTranscriber?
    private var realtime: OpenAIRealtimeTranscriber?
    private var pendingResult: DictationResult?
    private var resultModel = ""
    private var historyTask: Task<Void, Never>?
    private var practiceLoading = false
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

        workspace.loadPractice = { [weak self] in self?.preparePractice() }
        workspace.recordPractice = { [weak self] in self?.togglePractice() }
        workspace.openContext = { [weak self] in self?.openContext() }
        setupMenuBar()
        setupApplicationMenu()
        learning.onRulesChanged = { [weak self] rules in
            guard let transcriber = self?.transcriber else { return }
            let vocabulary = rules.filter(\.enabled).map(\.intended) + Paths.loadVocabulary()
            Task { await transcriber.updateVocabulary(vocabulary) }
        }
        setupPipeline()
        NotificationCenter.default.addObserver(self, selector: #selector(openLearning),
                                               name: .whispOpenLearning, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: .whispConfigChanged, object: nil)

        // The audio tap fires `level` on CoreAudio's thread, so hop to the main
        // actor before touching the @MainActor HUD.
        recorder.level = { [weak self] lvl in
            Task { @MainActor in self?.hud.setLevel(lvl) }
        }

        // HotkeyMonitor is @MainActor; its callbacks fire on the main actor, but
        // they're typed @Sendable, so we keep the capture weak and clean.
        hotkey = HotkeyMonitor(
            onPress: { [weak self] in
                Task { @MainActor in
                    self?.fnHeld = true
                    await self?.startRecording()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.fnHeld = false
                    self?.stopAndProcess()
                }
            })
        if !CommandLine.arguments.contains("--no-hotkeys") { hotkey?.start() }
        if CommandLine.arguments.contains("--show-learning") { openLearning() }
        if CommandLine.arguments.contains("--show-workspace") { openWorkspace() }
        if CommandLine.arguments.contains("--show-settings") { openSettings() }
    }

    // MARK: - Pipeline

    private func setupPipeline() {
        guard !startingRecording, !recording, !processing, practice?.isRecording != true, practice?.isProcessing != true, !practiceLoading, !loadingModel else {
            pendingReload = true
            return
        }
        loadingModel = true
        setStatusTitle("Whisp — loading speech model")
        Task { @MainActor in
        defer { loadingModel = false; applyPendingReload() }
        do {
            let nextConfig = try Paths.loadConfig().validated()
            let snippets = try SnippetStore.load(from: Data(contentsOf: URL(fileURLWithPath: NSString(string: nextConfig.snippetsPath).expandingTildeInPath)))
            let vocab = Paths.loadVocabulary()
            let profileContext = Paths.loadContext()
            let hints = learning.data.rules.filter(\.enabled).map(\.intended) + vocab
            let local: LazyWhisperTranscriber
            if let resident = self.transcriber, config.whisperModel == nextConfig.whisperModel {
                local = resident
                await local.updateVocabulary(hints)
            } else {
                local = LazyWhisperTranscriber(modelPath: Paths.modelPath(nextConfig.whisperModel), vocabulary: hints)
            }
            self.transcriber = local
            config = nextConfig
            workspace.recognition = config.transcriptionMode == .openai ? "OpenAI streaming" : "On this Mac"
            let cleaner = SpeculativeCleaner(
                cleaner: OpenAICleaner(apiKey: config.openaiKey, model: config.textModel),
                onReuse: { Diag.log("reused exact live polish") })
            speculativeCleaner = cleaner
            let inserter = self.inserter
            pipeline = SpeechPipeline(
                snippets: snippets,
                transcriber: local,
                cleaner: cleaner,
                inserter: inserter,
                selectionReader: inserter,
                editor: inserter,
                vocabulary: vocab,
                profileContext: profileContext,
                cleanupMode: config.cleanupMode,
                corrections: { [weak self] in await self?.learning.data.rules ?? [] },
                onResult: { [weak self] result in await self?.remember(result) },
                // `onStatus` runs inside the pipeline's async `process(...)`, which
                // is NOT guaranteed to be on the main actor. Hop before touching
                // the @MainActor HUD / status item.
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        self?.hud.show(status)
                        self?.updateStatusTitle(status)
                    }
                })
            Diag.log("pipeline OK (recognition=\(config.transcriptionMode.rawValue), model=\(config.transcriptionMode == .openai ? config.transcriptionModel : config.whisperModel), cleanup=\(config.cleanupMode.rawValue), vocab=\(vocab.count) terms, key=\(config.openaiKey.isEmpty ? "none" : "set"))")

            if config.hotkey.lowercased() != "fn" {
                Diag.log("config: hotkey '\(config.hotkey)' is not supported — dictation is Fn-only; using Fn")
            }

            // Only local dictation needs the model ready at startup.
            // Cloud dictation loads it later if practice or offline recovery needs it.
            let hadPractice = practice != nil
            practice = nil
            workspace.practice = nil
            PracticeWindow.shared.invalidate()
            if config.transcriptionMode == .local || hadPractice {
                let model = try await local.load()
                configurePractice(model: model)
            }

            // Fall back to the default if the config value is malformed, so a typo
            // degrades to a working hotkey instead of a silently dead feature.
            let spec = HotkeySpec.parse(config.practiceHotkey)
                ?? HotkeySpec.parse(WhispConfig.defaults.practiceHotkey)!
            if HotkeySpec.parse(config.practiceHotkey) == nil {
                Diag.log("config: practiceHotkey '\(config.practiceHotkey)' is malformed — using \(spec.display)")
            }
            practiceHotkey?.unregister()
            let practiceHK = PracticeHotkey(spec: spec) { [weak self] in
                MainActor.assumeIsolated { self?.togglePractice() }
            }
            if !CommandLine.arguments.contains("--no-hotkeys") { practiceHK.register() }
            practiceHotkey = practiceHK
            setStatusTitle("Whisp — ready")
        } catch {
            Diag.log("pipeline FAIL: \(error)")
            NSLog("Whisp pipeline init failed: \(error)")
            setStatusTitle("Whisp — model error (open Settings)")
            learning.error = error.localizedDescription
        }
        }
    }

    private func configurePractice(model: WhisperTranscriber) {
        let promptStore = (try? Paths.loadPrompts()) ?? PromptStore(prompts: PromptStore.seed)
        let sessionStore = (try? Paths.loadSessions()) ?? PracticeStore(sessions: [])
        let controller = PracticeController(recorder: recorder, transcriber: model,
                                cleaner: OpenAICleaner(apiKey: config.openaiKey, model: config.textModel), config: config,
                                store: sessionStore, prompts: promptStore)
        controller.onStatus = { [weak self] text, done, error in
            MainActor.assumeIsolated {
                guard let self, !self.recording, !self.processing else { return }
                // Older practice work can finish during a new recording.
                if done && !error && self.practice?.isRecording == true { return }
                self.hud.showPracticeStatus(text, done: done, error: error)
                self.workspace.status = done ? "Ready" : text
            }
        }
        controller.onBackgroundWorkFinished = { [weak self] in
            self?.workspace.status = "Ready"
            self?.applyPendingReload()
        }
        controller.onRecordingStopped = { [weak self] in
            self?.practiceTimer?.invalidate()
            self?.practiceTimer = nil
            self?.promptPicker?.dismiss()
            self?.promptPicker = nil
            self?.applyPendingReload()
        }
        practice = controller
        workspace.practice = controller
        PracticeWindow.shared.refresh(controller: controller)

    }

    private func loadPractice(then action: @escaping @MainActor () -> Void) {
        guard !practiceLoading, !startingRecording, !recording, !processing, let transcriber else { return }
        practiceLoading = true
        workspace.practiceLoading = true
        workspace.practiceError = nil
        hud.showPracticeStatus("Loading local practice model", done: false)
        Task { @MainActor in
            defer { practiceLoading = false; workspace.practiceLoading = false; applyPendingReload() }
            do {
                let model = try await transcriber.load()
                configurePractice(model: model)
                guard !startingRecording, !recording, !processing else { return }
                hud.showPracticeStatus("Practice ready", done: true)
                action()
            } catch {
                learning.error = error.localizedDescription
                workspace.practiceError = error.localizedDescription
                hud.showPracticeStatus("Local practice model unavailable", done: true, error: true)
            }
        }
    }

    @objc private func configChanged() {
        pendingReload = false
        setupPipeline()
    }

    private func applyPendingReload() {
        if pendingReload { pendingReload = false; setupPipeline() }
    }

    private func remember(_ result: DictationResult) async {
        lastTranscript = result.output
        copyLastItem.isEnabled = true
        pendingResult = result
    }

    private func savePendingHistory() {
        guard config.keepHistory, let result = pendingResult else { pendingResult = nil; return }
        let samples = pendingSamples
        let model = resultModel
        let seconds = Date().timeIntervalSince(processingStarted)
        let saveAudio = config.saveVoiceExamples
        let previous = historyTask
        pendingResult = nil
        historyTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.learning.remember(result, samples: samples, model: model,
                seconds: seconds, saveAudio: saveAudio)
        }
    }

    // MARK: - Recording flow

    private func startRecording() async {
        guard fnHeld, !recording, !startingRecording else { return }
        startingRecording = true
        defer { startingRecording = false; applyPendingReload() }
        if processing { hud.show(.error("Finishing previous dictation")); return }
        if loadingModel { hud.show(.error("Loading speech model")); return }
        guard pipeline != nil else { hud.show(.error("Check Whisp Settings")); return }
        guard practice?.isRecording != true else { hud.show(.error("Finish practice first")); return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard fnHeld, !recording, !processing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.show(.error("Enable microphone in Settings"))
            learning.error = "Enable Whisp under System Settings → Privacy & Security → Microphone."
            return
        }
        let speculationID = await speculativeCleaner?.begin()
        activeSpeculationID = speculationID
        guard fnHeld, !recording, !processing else {
            await speculativeCleaner?.cancel()
            activeSpeculationID = nil
            return
        }
        inserter.beginSession()
        do {
            if config.transcriptionMode == .openai {
                let hints = learning.data.rules.filter(\.enabled).map(\.intended) + Paths.loadVocabulary()
                let previewPipeline = pipeline
                let previewCleaner = speculativeCleaner
                let live = OpenAIRealtimeTranscriber(apiKey: config.openaiKey, vocabulary: hints,
                    model: config.transcriptionModel, onPartial: { [weak self] text in
                        Task { @MainActor in
                            guard let self, let pipeline = previewPipeline,
                                  let cleaner = previewCleaner, let speculationID,
                                  self.activeSpeculationID == speculationID else { return }
                            self.partialTask?.cancel()
                            self.partialTask = Task {
                                let messages = await pipeline.previewMessages(for: text)
                                guard !Task.isCancelled else { return }
                                await cleaner.offer(messages, session: speculationID)
                            }
                        }
                    })
                realtime = live
                live.begin()
                try recorder.start(onPCM24k: { live.append($0) }, onPCMError: { _ in live.abort() })
            } else {
                try recorder.start()
            }
            recording = true
            hud.show(.listening)
            setStatusTitle("Whisp — listening")
            updateMenuIcon("mic.fill")
            recordingLimit?.cancel()
            recordingLimit = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.stopAndProcess()
            }
        } catch {
            realtime?.abort(); realtime = nil
            partialTask?.cancel()
            await speculativeCleaner?.cancel()
            activeSpeculationID = nil
            recording = false
            hud.show(.error("Microphone unavailable"))
            learning.error = error.localizedDescription
            updateMenuIcon("exclamationmark.triangle")
        }
    }

    private func stopAndProcess() {
        guard recording else { return }
        recording = false
        processing = true
        processingStarted = Date()
        resultModel = config.transcriptionMode == .openai ? config.transcriptionModel : config.whisperModel
        recordingLimit?.cancel()
        hud.show(.transcribing)
        workTask = Task { @MainActor in
            defer {
                realtime?.abort(); realtime = nil
                partialTask?.cancel(); partialTask = nil
                activeSpeculationID = nil
                savePendingHistory()
                pendingSamples = []
                processing = false
                applyPendingReload()
            }
            do {
                let stopped = await recorder.stopForStreaming()
                defer { stopped.samples.cancel() }
                if let activeSpeculationID {
                    await speculativeCleaner?.release(session: activeSpeculationID)
                }
                guard stopped.hasAudio else {
                    hud.show(.error("No audio captured"))
                    learning.error = "No microphone audio arrived. Check the input device in Sound settings and try again."
                    await speculativeCleaner?.cancel()
                    return
                }
                if let realtime {
                    do {
                        let raw = try await realtime.finish(timeout: 8)
                        try Task.checkCancellation()
                        Diag.log("live transcript ready after release in \(Date().timeIntervalSince(processingStarted))s")
                        await pipeline?.process(transcript: raw)
                    } catch {
                        try Task.checkCancellation()
                        Diag.log("OpenAI transcription unavailable; using local recovery: \(error.localizedDescription)")
                        learning.notice = "OpenAI unavailable. This dictation is being recovered on this Mac."
                        realtime.abort()
                        resultModel = config.whisperModel
                        let samples = try await stopped.samples.value
                        await pipeline?.process(samples: samples)
                    }
                } else {
                    let samples = try await stopped.samples.value
                    await pipeline?.process(samples: samples)
                }
                Diag.log("dictation finished in \(Date().timeIntervalSince(processingStarted))s")
                // Conversion is only needed here for history; it never holds up
                // finalization or pasting on the normal OpenAI path.
                if config.keepHistory {
                    do { pendingSamples = try await stopped.samples.value }
                    catch { Diag.log("Optional history audio unavailable") }
                }
            } catch {
                hud.show(.error("Audio conversion failed"))
                learning.error = error.localizedDescription
            }
            await speculativeCleaner?.cancel()
        }
    }

    // MARK: - Practice Mode

    private func togglePractice() {
        guard let practice else {
            loadPractice { [weak self] in self?.togglePractice() }
            return
        }
        // Only blocks STARTING a practice recording while dictation is in
        // progress. Never blocks stopping one that's already running — the
        // recorder is shared, and dictation can only be active if practice
        // isn't (see the mirror-image guard in `startRecording()`).
        if practice.isRecording != true, startingRecording || recording || processing || loadingModel {
            Diag.log("practice: ignored, dictation is in progress")
            hud.showPracticeStatus("Finish dictating first", done: true, error: true)
            return
        }
        let wasRecording = practice.isRecording
        practice.toggle()

        if !wasRecording && practice.isRecording {
            workspace.status = "Practice recording"
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
        menu.addItem(NSMenuItem(title: "Open Whisp…", action: #selector(openWorkspace), keyEquivalent: "1"))
        menu.addItem(NSMenuItem(title: "Corrections…", action: #selector(openLearning), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Recent Dictations…", action: #selector(openHistory), keyEquivalent: "h"))
        copyLastItem = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLastDictation), keyEquivalent: "")
        copyLastItem.isEnabled = false
        menu.addItem(copyLastItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit Snippets…", action: #selector(openSnippets), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Edit Writing Context…", action: #selector(openContext), keyEquivalent: ""))
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
        workspace.status = s.replacingOccurrences(of: "Whisp — ", with: "").prefix(1).uppercased()
            + s.replacingOccurrences(of: "Whisp — ", with: "").dropFirst()
    }

    /// Template SF Symbol so the menu-bar icon adapts to light/dark automatically.
    private func updateMenuIcon(_ symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisp")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    @objc private func copyLastDictation() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openLearning() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .corrections)
    }

    @objc private func openHistory() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .history)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWorkspace()
        return true
    }

    @objc private func openSnippets() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .snippets)
    }

    @objc private func openContext() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.contextFile))
    }

    @objc private func openSettings() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .settings)
    }

    @objc private func openWorkspace() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .home)
    }

    @objc private func openPractice() {
        WorkspaceWindow.shared.show(model: learning, state: workspace, route: .practice)
    }

    private func preparePractice() {
        guard practice == nil else { workspace.practice = practice; return }
        guard !recording, !processing, !loadingModel else {
            workspace.practiceError = "Finish the current dictation, then open practice."
            return
        }
        loadPractice { }
    }

    private func setupApplicationMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Whisp")
        appMenu.addItem(NSMenuItem(title: "Open Whisp", action: #selector(openWorkspace), keyEquivalent: "1"))
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Whisp", action: #selector(quit), keyEquivalent: "q"))
        for item in appMenu.items { item.target = self }
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        editItem.submenu = edit
        bar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        bar.addItem(windowItem)
        NSApp.mainMenu = bar
    }

    @objc private func quit() {
        recordingLimit?.cancel()
        workTask?.cancel()
        partialTask?.cancel()
        realtime?.abort()
        Task { @MainActor in
            await speculativeCleaner?.cancel()
            await workTask?.value
            await historyTask?.value
            NSApplication.shared.terminate(nil)
        }
    }
}
