import Foundation
import CWhisper
import WhispCore

/// Local speech-to-text backed by vendored whisper.cpp (CPU backend).
///
/// The `whisper_context` is loaded once in `init` and kept resident in RAM for
/// the object's lifetime — there is no per-call model reload. Calls are
/// serialized with a lock because a single `whisper_context` is not safe to run
/// concurrently.
///
/// NOTE: on this Command-Line-Tools-only Mac the Metal shader compiler is
/// unavailable, so whisper.cpp is built CPU-only (Accelerate-accelerated).
/// `use_gpu` is therefore left off. The `init`/`transcribe` signatures match the
/// `Transcribing` protocol exactly, so swapping in a Metal build later changes
/// nothing for callers.
final class WhisperTranscriber: Transcribing, @unchecked Sendable {
    private let ctx: OpaquePointer
    private let lock = NSLock()
    /// Vocabulary hint that biases decoding toward the user's terms (names,
    /// brands, jargon). Empty disables it.
    private let initialPrompt: String

    init(modelPath: String, initialPrompt: String = "") throws {
        self.initialPrompt = initialPrompt
        var cparams = whisper_context_default_params()
        cparams.use_gpu = false // CPU backend only (no Metal compiler under CLT)
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw NSError(domain: "Whisp.Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load model at \(modelPath)"])
        }
        ctx = c
    }

    deinit { whisper_free(ctx) }

    func transcribe(_ samples: [Float]) async throws -> String {
        // whisper_full is blocking CPU work; run it off the cooperative pool so
        // we never park a Swift concurrency thread, and serialize access to the
        // single (non-reentrant) whisper_context with the lock.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try self.transcribeSync(samples))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeSync(_ samples: [Float]) throws -> String {
        lock.lock(); defer { lock.unlock() }

        guard !samples.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.translate = false
        params.single_segment = false

        func run() -> Int32 {
            samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        let rc: Int32 = "en".withCString { lang in
            params.language = lang
            // Keep the vocabulary C-string alive across the whisper_full call.
            guard !initialPrompt.isEmpty else { return run() }
            return initialPrompt.withCString { ip in
                params.initial_prompt = ip
                return run()
            }
        }
        guard rc == 0 else {
            throw NSError(domain: "Whisp.Transcriber", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "whisper_full failed (rc=\(rc))"])
        }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes chunks in order, returning whole-session-timed segments.
    ///
    /// Takes and releases the context lock ONCE PER CHUNK rather than holding it
    /// for the whole recording. A 3-minute practice clip would otherwise block
    /// every dictation attempt for its full ~60s of CPU work; this way dictation
    /// waits at most one chunk.
    ///
    /// Parameters differ from `transcribe(_:)` on purpose (see practiceParams):
    /// dictation wants Whisper's clean output, practice wants the disfluencies.
    func transcribeSegments(_ chunks: [AudioChunk],
                            progress: @Sendable @escaping (Double) -> Void) async throws
        -> [TranscriptSegment] {
        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            let segs: [TranscriptSegment] = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        cont.resume(returning: try self.segmentsSync(chunk))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            all.append(contentsOf: segs)
            progress(Double(i + 1) / Double(chunks.count))
            // Yield between chunks so a queued dictation can take the lock.
            await Task.yield()
        }
        return all
    }

    /// Biases decoding toward verbatim output. Whisper is trained to emit clean
    /// readable text and drops disfluencies; a disfluent initial_prompt plus
    /// unsuppressed non-speech tokens recovers much (NOT all) of it. Filler
    /// counts will still undercount reality — the trend stays honest because
    /// the bias is identical across sessions.
    private static let practicePrompt =
        "Um, so, uh, I mean, like, you know, it's basically, uh, kind of what I wanted to say."

    private func segmentsSync(_ chunk: AudioChunk) throws -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        guard !chunk.samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = false          // segments need timing
        // suppress_nst already defaults to false in this whisper.cpp; setting it
        // explicitly pins the value so a future default flip cannot silently start
        // stripping disfluencies. The real verbatim bias comes from the disfluent
        // initial_prompt below.
        params.suppress_nst = false
        params.translate = false
        params.single_segment = false

        func run() -> Int32 {
            chunk.samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        let rc: Int32 = "en".withCString { lang in
            params.language = lang
            return Self.practicePrompt.withCString { ip in
                params.initial_prompt = ip
                return run()
            }
        }
        guard rc == 0 else {
            throw NSError(domain: "Whisp.Transcriber", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "whisper_full failed in practice mode (rc=\(rc))"])
        }

        var out: [TranscriptSegment] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            // whisper timestamps are in centiseconds; ×10 → ms, then offset into
            // whole-session time.
            let t0 = Int(whisper_full_get_segment_t0(ctx, i)) * 10 + chunk.startMS
            let t1 = Int(whisper_full_get_segment_t1(ctx, i)) * 10 + chunk.startMS
            out.append(TranscriptSegment(text: String(cString: raw), startMS: t0, endMS: t1))
        }
        return out
    }
}
