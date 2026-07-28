import Foundation

/// Parses `~/.whisp/fillers.txt`, using the same convention as vocabulary.txt:
/// one term per line, `#` comments, blank lines ignored.
public enum FillerList {
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static let seed = """
    # Whisp filler words — one term per line. Lines starting with # are ignored.
    # These are counted against your practice transcripts. Multi-word phrases work.

    um
    uh
    er
    ah
    like
    you know
    i mean
    sort of
    kind of
    basically
    actually
    literally
    right
    so yeah

    """
}

public enum SpeechAnalyzer {
    /// Lowercase, punctuation to spaces, collapse whitespace, split to words.
    /// Tokenizing both sides is what makes whole-word matching fall out for
    /// free: "likely" tokenizes to ["likely"], which never equals ["like"].
    static func tokenize(_ s: String) -> [String] {
        let mapped = s.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Counts each filler term. Terms with zero occurrences are omitted.
    /// Multi-word phrases are matched as consecutive token runs.
    public static func countFillers(in transcript: String, fillers: [String]) -> [String: Int] {
        let words = tokenize(transcript)
        guard !words.isEmpty else { return [:] }

        var out: [String: Int] = [:]
        for filler in fillers {
            let needle = tokenize(filler)
            guard !needle.isEmpty, needle.count <= words.count else { continue }
            var count = 0
            for start in 0...(words.count - needle.count) {
                if Array(words[start..<(start + needle.count)]) == needle { count += 1 }
            }
            if count > 0 { out[filler.lowercased()] = count }
        }
        return out
    }
}

public struct Pause: Codable, Equatable, Sendable {
    public let startSec: Double
    public let durationSec: Double
    public init(startSec: Double, durationSec: Double) {
        self.startSec = startSec
        self.durationSec = durationSec
    }
}

public struct SpeechMetrics: Codable, Equatable, Sendable {
    public let wordCount: Int
    public let durationSec: Double
    /// Total duration minus LEADING and TRAILING silence only. Internal pauses
    /// stay counted — they are part of delivery pace, and excluding them would
    /// hide the exact problem being measured.
    public let speakingDurationSec: Double
    public let wpm: Double
    public let fillerCounts: [String: Int]
    public let totalFillers: Int
    /// Fillers per 100 words. The headline number.
    public let fillerRate: Double
    public let pauses: [Pause]
    public let pauseCount: Int
    public let longestPauseSec: Double
    public let silenceRatio: Double
}

extension SpeechAnalyzer {
    /// Index of the first and last bin at or above the speech threshold.
    static func speechBounds(envelope: [Float], silenceThreshold: Float) -> (first: Int, last: Int)? {
        guard let first = envelope.firstIndex(where: { $0 >= silenceThreshold }),
              let last = envelope.lastIndex(where: { $0 >= silenceThreshold }) else { return nil }
        return (first, last)
    }

    /// Silent runs of at least `minPauseSec`, BETWEEN the first and last speech.
    /// Leading and trailing silence is dead air, not a pause in delivery.
    public static func pauses(envelope: [Float], binSeconds: Double,
                              silenceThreshold: Float, minPauseSec: Double) -> [Pause] {
        guard let bounds = speechBounds(envelope: envelope, silenceThreshold: silenceThreshold),
              bounds.last > bounds.first else { return [] }

        var out: [Pause] = []
        var runStart: Int?
        for i in bounds.first...bounds.last {
            if envelope[i] < silenceThreshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                let duration = Double(i - s) * binSeconds
                if duration >= minPauseSec {
                    out.append(Pause(startSec: Double(s) * binSeconds, durationSec: duration))
                }
                runStart = nil
            }
        }
        // No trailing flush needed: bounds.last is speech by definition, so any
        // open run was closed by the loop.
        return out
    }

    public static func analyze(transcript: String, envelope: [Float], binSeconds: Double,
                               fillers: [String], silenceThreshold: Float,
                               minPauseSec: Double) -> SpeechMetrics {
        let words = tokenize(transcript)
        let durationSec = Double(envelope.count) * binSeconds

        let speakingDurationSec: Double
        if let b = speechBounds(envelope: envelope, silenceThreshold: silenceThreshold) {
            speakingDurationSec = Double(b.last - b.first + 1) * binSeconds
        } else {
            speakingDurationSec = 0
        }

        let wpm = speakingDurationSec > 0
            ? Double(words.count) / (speakingDurationSec / 60.0)
            : 0

        let counts = countFillers(in: transcript, fillers: fillers)
        let totalFillers = counts.values.reduce(0, +)
        let fillerRate = words.isEmpty ? 0 : Double(totalFillers) / Double(words.count) * 100.0

        let ps = pauses(envelope: envelope, binSeconds: binSeconds,
                        silenceThreshold: silenceThreshold, minPauseSec: minPauseSec)

        // Bounded to speech, exactly like pauses() and speakingDurationSec:
        // silence before the first word and after the last is dead air, not
        // part of how the delivery sounded. Counting it would make this metric
        // track hotkey-to-speech lag instead of speaking.
        let silenceRatio: Double
        if let b = speechBounds(envelope: envelope, silenceThreshold: silenceThreshold) {
            let span = envelope[b.first...b.last]
            let silentBins = span.filter { $0 < silenceThreshold }.count
            silenceRatio = Double(silentBins) / Double(span.count)
        } else {
            // No speech at all. "100% silent" is the honest answer for a
            // non-empty recording; an empty envelope has no ratio to report.
            silenceRatio = envelope.isEmpty ? 0 : 1
        }

        return SpeechMetrics(
            wordCount: words.count,
            durationSec: durationSec,
            speakingDurationSec: speakingDurationSec,
            wpm: wpm,
            fillerCounts: counts,
            totalFillers: totalFillers,
            fillerRate: fillerRate,
            pauses: ps,
            pauseCount: ps.count,
            longestPauseSec: ps.map(\.durationSec).max() ?? 0,
            silenceRatio: silenceRatio
        )
    }
}
