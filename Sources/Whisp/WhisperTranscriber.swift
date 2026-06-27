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

    init(modelPath: String) throws {
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

        let rc: Int32 = "en".withCString { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
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
}
