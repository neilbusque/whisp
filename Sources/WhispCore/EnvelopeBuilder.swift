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

    /// Marks every bin overlapped by the half-open span `[t, t + d)`.
    ///
    /// A caller that omits `durationSeconds` keeps the old single-bin
    /// behavior. A caller that passes the buffer's real duration (as
    /// AudioRecorder does) spreads the level across every bin the buffer
    /// actually covers — a buffer whose span ends exactly on a bin boundary
    /// does NOT mark the bin starting at that boundary.
    public func add(level: Float, atSeconds t: Double, durationSeconds d: Double = 0) {
        guard t >= 0 else { return }
        let firstIdx = Self.binIndex(forSeconds: t, binSeconds: binSeconds)
        let lastIdx = max(firstIdx, Self.lastBinIndex(forSpanEnd: t + d, binSeconds: binSeconds))
        if lastIdx >= bins.count {
            bins.append(contentsOf: repeatElement(0, count: lastIdx - bins.count + 1))
        }
        for idx in firstIdx...lastIdx {
            bins[idx] = max(bins[idx], level)
        }
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

    /// Index of the last bin touched by a half-open span ending at `end`.
    ///
    /// A span end that lands exactly on a bin boundary (within the same
    /// epsilon as `binIndex`) must NOT mark the bin that starts there, since
    /// the span is half-open — so that case steps back one bin.
    static func lastBinIndex(forSpanEnd end: Double, binSeconds: Double) -> Int {
        let raw = end / binSeconds
        let nearest = raw.rounded()
        if abs(raw - nearest) < 1e-9 {
            return Int(nearest) - 1
        }
        return Int(raw.rounded(.down))
    }
}
