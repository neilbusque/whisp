import Foundation

/// Accumulates a stream of RMS levels into a fixed-rate envelope.
///
/// Takes the MAX within each bin rather than the mean: a brief loud syllable
/// inside an otherwise quiet bin must not average away into looking like
/// silence, or pause detection would invent pauses that never happened.
///
/// Not thread-safe by itself — AudioRecorder calls `add` from the audio tap
/// while already holding its own lock.
public final class EnvelopeBuilder {
    public static let defaultBinSeconds: Double = 0.05

    private let binSeconds: Double
    private var bins: [Float] = []

    public init(binSeconds: Double = EnvelopeBuilder.defaultBinSeconds) {
        self.binSeconds = binSeconds > 0 ? binSeconds : EnvelopeBuilder.defaultBinSeconds
    }

    public func add(level: Float, atSeconds t: Double) {
        guard t >= 0 else { return }
        let idx = Int(t / binSeconds)
        if idx >= bins.count {
            bins.append(contentsOf: repeatElement(0, count: idx - bins.count + 1))
        }
        bins[idx] = max(bins[idx], level)
    }

    public func finish() -> [Float] { bins }
}
