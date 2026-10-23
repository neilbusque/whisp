import Foundation

/// Preparation for recognition only; saved practice audio and timing stay intact.
public enum DictationAudio {
    public static func prepare(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let finite = samples.map { $0.isFinite ? $0 : 0 }
        let peak = finite.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return [] }
        // Lift quiet microphone recordings without compressing speech or
        // boosting the background independently during pauses. Never clip.
        let gain = peak < 0.5 ? min(8, 0.5 / peak) : min(1, 1 / peak)
        var prepared = finite.map { $0 * gain }
        // whisper.cpp refuses <1 s. A short silent tail also lets it decode
        // the last word when Fn is released immediately after speaking.
        let targetCount = max(17_600, prepared.count + 4_000)
        prepared.append(contentsOf: repeatElement(0, count: targetCount - prepared.count))
        return prepared
    }
}
