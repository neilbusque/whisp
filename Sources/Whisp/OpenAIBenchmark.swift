import Foundation
import AVFoundation
import WhispAudio
import WhispCore

/// Explicit file-only diagnostic. Never records the mic, pastes, or saves history.
enum OpenAIBenchmark {
    private final class ResultSink: TextInserting, @unchecked Sendable {
        private let lock = NSLock()
        private var output: String?
        private var reuse = false
        func insert(_ text: String) async throws { lock.withLock { output = text } }
        func reused() { lock.withLock { reuse = true } }
        var result: (String?, Bool) { lock.withLock { (output, reuse) } }
    }
    private struct NoLocalRecognition: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String { throw CancellationError() }
    }
    static func run(path: String) async throws {
        let config = try Paths.loadConfig()
        let samples = try WavReader.readMono16k(path: path)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false) else {
            throw WhispConfigError.invalid("Cannot create benchmark audio format.")
        }
        let encoder = try PCM24kStream(format: format)
        let sink = ResultSink()
        let writer = SpeculativeCleaner(
            cleaner: OpenAICleaner(apiKey: config.openaiKey, model: config.textModel),
            onReuse: { sink.reused() })
        let id = await writer.begin()
        let pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: NoLocalRecognition(),
            cleaner: writer, inserter: sink, cleanupMode: .smart, onStatus: { _ in })
        let speculate = !CommandLine.arguments.contains("--no-speculation")
        let live = OpenAIRealtimeTranscriber(apiKey: config.openaiKey, model: config.transcriptionModel,
            onPartial: { text in
                guard speculate else { return }
                Task {
                    await writer.offer(pipeline.previewMessages(for: text), session: id)
                }
            })
        defer { live.abort() }
        let start = ContinuousClock.now
        live.begin()
        for offset in stride(from: 0, to: samples.count, by: 1_600) {
            let count = min(1_600, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else {
                throw WhispConfigError.invalid("Cannot create benchmark audio buffer.")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress! + offset, count: count)
            }
            live.append(try encoder.append(buffer))
            try await Task.sleep(for: .seconds(Double(count) / 16_000))
        }
        live.append(try encoder.finish())
        let released = ContinuousClock.now
        if speculate { await writer.release(session: id) }
        let raw = try await live.finish(timeout: 8)
        let recognitionTime = released.duration(to: .now)
        await pipeline.process(transcript: raw)
        let (final, reused) = sink.result
        print("model=\(config.transcriptionModel) audio=\(Double(samples.count) / 16_000)s release_to_transcript=\(recognitionTime) release_to_polished=\(released.duration(to: .now)) total=\(start.duration(to: .now)) speculative=\(speculate) reused=\(reused)")
        await writer.cancel()
        guard let final else { throw WhispConfigError.invalid("Benchmark produced no text.") }
        print(final)
    }
}
