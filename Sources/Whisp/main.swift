import AppKit
import WhispCore

// Login-item management hooks (used by the installer/Settings to register the
// running .app bundle as a launch-at-login item). These exit before the app
// loop so they can be invoked headlessly, e.g.
//   Whisp.app/Contents/MacOS/Whisp --login-on
let args = CommandLine.arguments
if args.contains("--evaluate-voice-edits") {
    Task {
        do { try await VoiceEditEvaluation.run(); exit(0) }
        catch { print("Voice edit evaluation failed: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
}
if let flag = args.firstIndex(of: "--benchmark-openai"), args.indices.contains(flag + 1) {
    let audioPath = args[flag + 1]
    Task {
        do {
            try await OpenAIBenchmark.run(path: audioPath)
            exit(0)
        } catch {
            print("OpenAI benchmark failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}
if let flag = args.firstIndex(of: "--benchmark"), args.indices.contains(flag + 1) {
    let audioPath = args[flag + 1]
    let modelName = args.indices.contains(flag + 2)
        ? args[flag + 2] : WhispConfig.defaults.whisperModel
    do {
        let samples = try WavReader.readMono16k(path: audioPath)
        let vocabulary = Paths.loadVocabulary()
        let loadStart = ContinuousClock.now
        let transcriber = try WhisperTranscriber(
            modelPath: Paths.modelPath(modelName), vocabulary: vocabulary,
            threads: args.indices.contains(flag + 3) ? Int32(args[flag + 3]) ?? WhisperTranscriber.recommendedThreadCount : WhisperTranscriber.recommendedThreadCount)
        let loadTime = loadStart.duration(to: .now)
        let runStart = ContinuousClock.now
        let text = try transcriber.transcribeForBenchmark(samples)
        let runTime = runStart.duration(to: .now)
        let audioSeconds = Double(samples.count) / 16_000
        let audioLabel = String(format: "%.2f", audioSeconds)
        print("model=\(modelName) audio=\(audioLabel)s load=\(loadTime) transcribe=\(runTime)")
        print(VocabularyCorrector.correct(text, vocabulary: vocabulary))
        exit(0)
    } catch {
        fputs("benchmark failed: \(error)\n", stderr)
        exit(1)
    }
}
if args.contains("--login-on") {
    _ = LoginItem.setEnabled(true)
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}
if args.contains("--login-off") {
    _ = LoginItem.setEnabled(false)
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}
if args.contains("--login-status") {
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}

let app = NSApplication.shared
if args.contains("--hud-preview"), args.contains("--no-hotkeys") {
    let preview = HUDPreviewWindow(reducedMotion: args.contains("--reduce-motion") ? true : nil)
    app.delegate = preview
    app.setActivationPolicy(.regular)
    withExtendedLifetime(preview) { app.run() }
    exit(0)
}
if args.contains("--voice-edit-check"), args.contains("--no-hotkeys"), args.contains("--data-dir") {
    let check = VoiceEditCheckWindow()
    app.delegate = check
    app.setActivationPolicy(.regular)
    withExtendedLifetime(check) { app.run() }
    exit(0)
}
// Isolated visual QA can exercise both native appearances without changing
// the user's system preference.
if args.contains("--no-hotkeys"), args.contains("--data-dir"),
   let flag = args.firstIndex(of: "--appearance"), args.indices.contains(flag + 1) {
    app.appearance = NSAppearance(named: args[flag + 1] == "dark" ? .darkAqua : .aqua)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement at runtime too
app.run()
