import Foundation
import AVFoundation

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

    // Protected by `lock`; read on the audio thread, settable by callers.
    private var _level: (Float) -> Void = { _ in }

    /// Called on the audio thread during recording with a 0–1 RMS level.
    /// Safe to set before or during recording.
    var level: (Float) -> Void {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }

    // MARK: - Public interface

    /// Starts microphone capture. Throws if the audio engine fails to start.
    func start() throws {
        lock.lock()
        _buffers.removeAll()
        _inputFormat = nil
        lock.unlock()

        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)

        lock.lock()
        _inputFormat = fmt
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let rms = Self.rms(buf)
            let copy = buf.copy() as? AVAudioPCMBuffer
            // Append the buffer and snapshot the callback under the lock, then
            // release the lock BEFORE invoking the callback so a slow user
            // closure can never block — or re-enter — the lock.
            let cb: (Float) -> Void = self.lock.withLock {
                if let copy { self._buffers.append(copy) }
                return self._level
            }
            cb(rms)
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns 16 kHz mono Float32 samples.
    func stop() -> [Float] {
        // removeTap drains any in-flight tap callbacks, so no tap fires after
        // this returns — that's why the subsequent unlocked read of the
        // snapshotted buffers is sufficient.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let capturedBuffers = _buffers
        let inFmt = _inputFormat
        lock.unlock()

        guard let inFmt, !capturedBuffers.isEmpty else { return [] }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1,
                                            interleaved: false) else { return [] }
        guard let converter = AVAudioConverter(from: inFmt, to: outFormat) else {
            return []
        }

        var out: [Float] = []
        out.reserveCapacity(capturedBuffers.reduce(0) { $0 + Int($1.frameLength) })

        for inBuf in capturedBuffers {
            let ratio = 16_000.0 / inFmt.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 256
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                frameCapacity: cap) else { continue }
            var fed = false
            var convErr: NSError?
            converter.convert(to: outBuf, error: &convErr) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            guard convErr == nil, let ptr = outBuf.floatChannelData?[0] else { continue }
            out.append(contentsOf: UnsafeBufferPointer(start: ptr,
                                                        count: Int(outBuf.frameLength)))
        }
        return out
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
