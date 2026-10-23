import Foundation

public enum RecognitionPrompt {
    /// Keep whole terms in file order. whisper.cpp otherwise truncates from
    /// the front, silently discarding the user's highest-priority names.
    public static func make(vocabulary: [String], tokenLimit: Int,
                            tokenCount: (String) -> Int) -> String {
        var terms: [String] = []
        var seen = Set<String>()
        for value in vocabulary {
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let candidate = (terms + [term]).joined(separator: ", ") + "."
            guard tokenCount(candidate) <= tokenLimit else { continue }
            terms.append(term)
        }
        return terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
    }
}
