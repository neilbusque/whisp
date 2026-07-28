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
