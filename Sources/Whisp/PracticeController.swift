import AppKit
import WhispCore

/// Owns the practice capture lifecycle. Deliberately separate from
/// SpeechPipeline: no DeepSeek cleanup (it strips the fillers being measured)
/// and no PasteInserter (nothing is ever typed at the cursor).
@MainActor
final class PracticeController {
    private let recorder: AudioRecorder
    private let transcriber: WhisperTranscriber
    /// Used ONLY by the opt-in coach feedback in Task 18. The practice
    /// transcription path never calls it — cleanup strips fillers, which are
    /// exactly what is being measured.
    private let cleaner: Cleaning
    private let config: WhispConfig

    private(set) var isRecording = false
    private var startedAt = Date()
    private var currentPrompt: PracticePrompt?
    private var sessionID = UUID()

    private(set) var store: PracticeStore
    private(set) var prompts: PromptStore

    /// Fired on the main actor whenever a session is added or updated, so an
    /// open review window can refresh.
    var sessionsChanged: () -> Void = {}
    /// Fired with a HUD-facing status string and whether it's a terminal
    /// (resting) state — the HUD auto-hides on terminal statuses and stays up
    /// through in-flight/progress ones.
    var onStatus: (String, Bool) -> Void = { _, _ in }

    init(recorder: AudioRecorder, transcriber: WhisperTranscriber, cleaner: Cleaning,
         config: WhispConfig, store: PracticeStore, prompts: PromptStore) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.config = config
        self.store = store
        self.prompts = prompts
    }

    /// Tags the in-flight session. The picker never gates the mic, so this can
    /// arrive seconds after recording began.
    func setPrompt(_ prompt: PracticePrompt?) {
        currentPrompt = prompt
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard !isRecording else { return }
        sessionID = UUID()
        startedAt = Date()
        currentPrompt = nil
        // Deliberately does NOT touch `recorder.level`. AppDelegate assigns that
        // handler once at startup to feed the HUD, and reassigning it here would
        // permanently steal the level feed from dictation — the handler is a
        // single slot, not a list of observers.
        do {
            try recorder.start()
            isRecording = true
            Diag.log("practice: recording started \(sessionID)")
        } catch {
            Diag.log("practice: failed to start recording — \(error.localizedDescription)")
            onStatus("Mic unavailable", true)
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false

        let (samples, envelope) = recorder.stopWithEnvelope()
        let duration = Date().timeIntervalSince(startedAt)
        let filename = "\(sessionID.uuidString).wav"
        let prompt = currentPrompt

        // Write the audio FIRST. A whisper crash, a quit, or a power loss may
        // cost a transcript; it must never cost the recording.
        do {
            try Paths.writeRecording(samples: samples, filename: filename)
        } catch {
            Diag.log("practice: FAILED to write \(filename) — \(error.localizedDescription)")
            onStatus("Could not save recording", true)
            return
        }

        let session = PracticeSession(
            id: sessionID, promptID: prompt?.id,
            promptTitle: prompt?.title ?? "Free-form",
            startedAt: startedAt, durationSec: duration,
            audioFilename: filename, envelope: envelope, status: .pending)
        store.append(session)
        persist()
        sessionsChanged()
        onStatus("Saved, transcribing…", false)

        Task { await self.transcribe(session: session, samples: samples, envelope: envelope) }
    }

    private func transcribe(session: PracticeSession, samples: [Float], envelope: [Float]) async {
        var updated = session
        do {
            let chunks = AudioChunker.chunk(
                samples: samples, sampleRate: 16_000, envelope: envelope,
                binSeconds: EnvelopeBuilder.defaultBinSeconds)

            let segments = try await transcriber.transcribeSegments(chunks) { pct in
                // transcribeSegments is nonisolated and calls this from the
                // cooperative pool, NOT the main actor — assumeIsolated would trap.
                Task { @MainActor in self.onStatus("Transcribing \(Int(pct * 100))%", false) }
            }
            let transcript = segments.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            updated.segments = segments
            updated.transcript = transcript
            updated.metrics = SpeechAnalyzer.analyze(
                transcript: transcript, envelope: envelope,
                binSeconds: EnvelopeBuilder.defaultBinSeconds,
                fillers: Paths.loadFillers(),
                silenceThreshold: Float(config.silenceRMSThreshold),
                minPauseSec: config.pauseThresholdSec)
            updated.status = .ready
            onStatus("Practice session ready", true)
        } catch {
            updated.status = .failed(error.localizedDescription)
            Diag.log("practice: transcription failed — \(error.localizedDescription)")
            onStatus("Transcription failed", true)
        }

        // update() ignores unknown ids, so a session deleted while this ran is
        // not resurrected. The WAV stays on disk either way.
        store.update(updated)
        persist()
        sessionsChanged()
    }

    /// Opt-in. The ONLY egress in Practice Mode, and it carries transcript text
    /// alone. Never called automatically.
    func requestCoachFeedback(for id: UUID) async {
        guard var s = store.all.first(where: { $0.id == id }),
              let transcript = s.transcript, let metrics = s.metrics else { return }
        onStatus("Asking the coach…", false)
        do {
            let messages = TranscriptCleaner.coachPrompt(
                transcript: transcript, promptTitle: s.promptTitle, metrics: metrics)
            s.coachFeedback = try await cleaner.complete(messages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onStatus("Coach feedback ready", true)
        } catch {
            s.coachFeedback = "Coach unavailable: \(error.localizedDescription)"
            onStatus("Coach unavailable", true)
        }
        store.update(s)
        persist()
        sessionsChanged()
    }

    func deleteSession(id: UUID) {
        guard let removed = store.delete(id: id) else { return }
        try? FileManager.default.removeItem(
            at: Paths.recordingURL(filename: removed.audioFilename))
        persist()
        sessionsChanged()
    }

    func savePrompts() {
        do {
            try prompts.encoded().write(to: URL(fileURLWithPath: Paths.promptsFile))
        } catch {
            Diag.log("practice: failed to save prompts — \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try store.encoded().write(to: URL(fileURLWithPath: Paths.sessionsFile))
        } catch {
            Diag.log("practice: failed to save sessions — \(error.localizedDescription)")
        }
    }

    /// Total bytes used by every recording on disk.
    func recordingsDiskBytes() -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.recordingsDir) else { return 0 }
        return names.reduce(Int64(0)) { total, name in
            let attrs = try? fm.attributesOfItem(atPath: Paths.recordingsDir + "/" + name)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }
}
