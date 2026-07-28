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
        let idx = Self.binIndex(forSeconds: t, binSeconds: binSeconds)
        if idx >= bins.count {
            bins.append(contentsOf: repeatElement(0, count: idx - bins.count + 1))
        }
        bins[idx] = max(bins[idx], level)
    }

    public func finish() -> [Float] { bins }

    /// `Int(t / binSeconds)` alone is wrong: for t an exact multiple of
    /// binSeconds, IEEE-754 error makes the quotient land just BELOW the
    /// integer (0.15 / 0.05 == 2.9999999999999996), truncating the level into
    /// the previous bin. Snap to the nearest integer when we are within an
    /// epsilon of it; floor otherwise.
    static func binIndex(forSeconds t: Double, binSeconds: Double) -> Int {
        let raw = t / binSeconds
        let nearest = raw.rounded()
        return Int(abs(raw - nearest) < 1e-9 ? nearest : raw.rounded(.down))
    }
}
