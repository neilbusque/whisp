import AppKit

// ── TEMPORARY SPIKE: mic → 16 kHz → Whisper round-trip ──────────────────────
// Remove this block once live verification is confirmed.
// Usage: .build/release/Whisp --spike-record
//        Grant Microphone access when macOS prompts.
//        Speak for 4 s; the transcript is printed to stdout.
if CommandLine.arguments.contains("--spike-record") {
    let rec = AudioRecorder()
    rec.level = { lvl in
        // Print a simple live-level bar so the user can see audio is arriving.
        let bars = Int(lvl * 20)
        let bar = String(repeating: "█", count: bars) + String(repeating: "░", count: 20 - bars)
        print("\r[\(bar)] \(String(format: "%.2f", lvl))", terminator: "")
        fflush(stdout)
    }
    let modelPath = NSString(string: "~/.whisp/models/ggml-base.en.bin")
        .expandingTildeInPath
    do {
        // Print before start() so the in-place level bar doesn't overwrite it.
        print("Recording 4 s — speak now…")
        try rec.start()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let samples = rec.stop()
        print("\nCaptured \(samples.count) samples at 16 kHz (\(String(format: "%.1f", Double(samples.count) / 16_000.0)) s)")
        print("Transcribing…")
        let text = try await WhisperTranscriber(modelPath: modelPath).transcribe(samples)
        print("TRANSCRIPT: \(text)")
    } catch {
        print("SPIKE ERROR: \(error)")
    }
    exit(0)
}
// ── END TEMPORARY SPIKE ──────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement at runtime too
app.run()
