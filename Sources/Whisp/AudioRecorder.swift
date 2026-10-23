import Foundation
import AVFoundation
import WhispCore
import WhispAudio

/// Captures microphone audio at the hardware sample rate, then converts
/// captured PCM to 16 kHz mono Float32 on ``stop()``.
///
/// Swift 6 concurrency notes:
/// - The AVAudioEngine tap closure runs on an internal audio thread managed by
///   CoreAudio, outside of Swift's cooperative concurrency.  `_buffers`,
///   `_inputFormat`, and `_level` are all protected by a plain `NSLock`.
/// - `level` is exposed as a computed property backed by `_level` under the
///   lock, so a `level =` set racing the tap's read is serialized. The tap
///   snapshots the callback under the lock and invokes it OUTSIDE the lock so a
///   slow user callback can never block the lock or re-enter it.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Protected by `lock`; written from the audio tap, read on stop().
    private var _buffers: [AVAudioPCMBuffer] = []
    private var _inputFormat: AVAudioFormat?
    private var _stream: StreamingCapture?
    private var _capturing = false

    // Protected by `lock`; read on the audio thread, settable by callers.
    private var _level: (Float) -> Void = { _ in }

    // Protected by `lock`. Built from the same RMS the tap already computes, so
    // there is no extra DSP cost. Dictation ignores it.
    private var _envelope = EnvelopeBuilder()
    private var _framesSeen: Int = 0

    /// Called on the audio thread during recording with a 0–1 RMS level.
    /// Safe to set before or during recording.
    var level: (Float) -> Void {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }

    // MARK: - Public interface

    /// Starts microphone capture. Throws if the audio engine fails to start.
    func start(onPCM24k: (@Sendable (Data) -> Void)? = nil,
               onPCMError: @Sendable @escaping (Error) -> Void = { _ in }) throws {
        // One tap per bus. AVAudioEngine raises a fatal exception on a second
        // installTap, and the callers share this instance, so enforce it here
        // rather than trusting every call site to check.
        guard !engine.isRunning else {
            throw NSError(domain: "Whisp.AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Recorder is already running"])
        }

        lock.lock()
        _buffers.removeAll()
        _inputFormat = nil
        _envelope = EnvelopeBuilder()
        _framesSeen = 0
        _stream = nil
        _capturing = false
        lock.unlock()

        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)

        lock.lock()
        _inputFormat = fmt
        lock.unlock()

        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Whisp.AudioRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        var stream: StreamingCapture?
        if let onPCM24k {
            do { stream = try StreamingCapture(format: fmt, callback: onPCM24k, onError: onPCMError) }
            catch { onPCMError(error) }
        }
        lock.withLock { _stream = stream; _capturing = true }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let rms = Self.rms(buf)
            let copy = buf.copy() as? AVAudioPCMBuffer
            // Append the buffer and snapshot the callback under the lock, then
            // release the lock BEFORE invoking the callback so a slow user
            // closure can never block — or re-enter — the lock.
            let cb: (Float) -> Void = self.lock.withLock {
                guard self._capturing else { return { _ in } }
                if let copy { self._buffers.append(copy) }
                if let copy { self._stream?.append(copy) }
                // Sample-clock time, not wall-clock: exact and monotonic.
                let seconds = Double(self._framesSeen) / fmt.sampleRate
                self._framesSeen += Int(buf.frameLength)
                let duration = Double(buf.frameLength) / fmt.sampleRate
                self._envelope.add(level: rms, atSeconds: seconds, durationSeconds: duration)
                return self._level
            }
            cb(rms)
        }

        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            engine.stop()
            lock.withLock { _capturing = false; _stream = nil; _buffers.removeAll() }
            throw error
        }
    }

    /// Captured buffers are immutable after removing the tap. Resampling runs
    /// away from the main actor and the retained mic buffers are released.
    private struct Capture: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        let format: AVAudioFormat?
        let envelope: [Float]
        let stream: StreamingCapture?
    }

    private func finishCapture() -> Capture {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            _capturing = false
            let capture = Capture(buffers: _buffers, format: _inputFormat,
                                  envelope: _envelope.finish(), stream: _stream)
            _buffers.removeAll(keepingCapacity: false)
            _inputFormat = nil
            _stream = nil
            return capture
        }
    }

    /// The remote stream is fully drained when this handle is returned. Local
    /// recovery/audio-history samples convert in parallel, so the caller can
    /// commit the remote turn without waiting for whole-clip resampling.
    /// The caller owns `samples` and should cancel it when no longer needed.
    struct StreamingStop: Sendable {
        let hasAudio: Bool
        let samples: Task<[Float], Error>
    }

    func stopForStreaming() async -> StreamingStop {
        await Self.prepareStreamingStop(finishCapture())
    }

    func stop() async throws -> [Float] {
        let capture = finishCapture()
        return try await Self.convert(capture)
    }

    func stopWithEnvelope() async throws -> (samples: [Float], envelope: [Float]) {
        let capture = finishCapture()
        return (try await Self.convert(capture), capture.envelope)
    }

    private static func convert(_ capture: Capture) async throws -> [Float] {
        let stopped = await prepareStreamingStop(capture)
        return try await withTaskCancellationHandler {
            try await stopped.samples.value
        } onCancel: {
            stopped.samples.cancel()
        }
    }

    private static func prepareStreamingStop(_ capture: Capture) async -> StreamingStop {
        let hasAudio = capture.format != nil && capture.buffers.contains { $0.frameLength > 0 }
        let samples = Task.detached(priority: .userInitiated) { () throws -> [Float] in
            try Task.checkCancellation()
            guard let format = capture.format else { return [] }
            let result = try PCMResampler.mono16k(capture.buffers, from: format)
            try Task.checkCancellation()
            return result
        }
        return await withTaskCancellationHandler {
            // Every append callback, including final converter samples, must
            // complete before the caller can commit the remote audio turn.
            // Resampling uses immutable buffers and can run during this drain.
            await capture.stream?.finish()
            return StreamingStop(hasAudio: hasAudio, samples: samples)
        } onCancel: {
            samples.cancel()
        }
    }

    /// Owns the converter on one queue. Nothing converts or sends network
    /// traffic on CoreAudio's callback thread.
    private final class StreamingCapture: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.busqueneil.whisp.stream-audio", qos: .userInitiated)
        private let converter: PCM24kStream
        private let callback: @Sendable (Data) -> Void
        private let onError: @Sendable (Error) -> Void
        private var error: Error?

        init(format: AVAudioFormat, callback: @Sendable @escaping (Data) -> Void,
             onError: @Sendable @escaping (Error) -> Void) throws {
            converter = try PCM24kStream(format: format)
            self.callback = callback
            self.onError = onError
        }

        private struct Buffer: @unchecked Sendable { let value: AVAudioPCMBuffer }

        func append(_ buffer: AVAudioPCMBuffer) {
            let immutable = Buffer(value: buffer)
            queue.async {
                guard self.error == nil else { return }
                do {
                    let data = try self.converter.append(immutable.value)
                    if !data.isEmpty { self.callback(data) }
                } catch { self.report(error) }
            }
        }

        func finish() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    defer { continuation.resume() }
                    guard self.error == nil else { return }
                    do {
                        let tail = try self.converter.finish()
                        if !tail.isEmpty { self.callback(tail) }
                    } catch { self.report(error) }
                }
            }
        }

        private func report(_ error: Error) {
            guard self.error == nil else { return }
            self.error = error
            onError(error)
        }
    }

    // MARK: - Private helpers

    private static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, sqrt(sum / Float(n)) * 4)
    }
}
