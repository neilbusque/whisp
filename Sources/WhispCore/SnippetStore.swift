import Foundation

public final class SnippetStore {
    private(set) public var snippets: [Snippet]

    public init(snippets: [Snippet]) { self.snippets = snippets }

    public var all: [Snippet] { snippets }

    public static func load(from data: Data) throws -> SnippetStore {
        SnippetStore(snippets: try JSONDecoder().decode([Snippet].self, from: data))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(snippets)
    }

    public func upsert(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s }
        else { snippets.append(s) }
    }

    public func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    /// Lowercase, strip punctuation to spaces, collapse whitespace, trim.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        let collapsed = String(mapped).split(separator: " ", omittingEmptySubsequences: true)
        return collapsed.joined(separator: " ")
    }

    /// Start-anchored match: the normalized transcript must equal the keyword,
    /// or begin with `keyword + " "`. Returns the matched snippet + trailing remainder.
    public func match(transcript: String) -> SnippetMatch? {
        let t = SnippetStore.normalize(transcript)
        for s in snippets where s.enabled {
            let k = SnippetStore.normalize(s.keyword)
            guard !k.isEmpty else { continue }
            if t == k {
                return SnippetMatch(snippet: s, remainder: "")
            }
            if t.hasPrefix(k + " ") {
                // The remainder must be returned in the ORIGINAL casing, not the
                // normalized (lowercased) form — e.g. "SEO" must reach the LLM as
                // "SEO" for AI-template snippets, not flattened to "seo". So we
                // cannot just `dropFirst` on the normalized `t`.
                //
                // We re-walk the ORIGINAL transcript char-by-char (rather than
                // dropping N whitespace-delimited words from it) because punctuation
                // can split or merge words differently between the original and the
                // normalized form — e.g. "e-mail" → "e mail" — so a word-count drop
                // would misalign the boundary. Walking char-by-char and re-deriving
                // the normalized prefix until it equals the keyword is the only
                // reliable way to find where the keyword ends in the original text.

                // Find the position in original where the remainder starts
                // We need to match k characters worth of normalized content + 1 space
                var idx = transcript.startIndex
                var normalizedChars: [Character] = []

                // Build normalized stream from original until we have k + " "
                while idx < transcript.endIndex {
                    let char = transcript[idx]
                    if CharacterSet.alphanumerics.contains(char.unicodeScalars.first!) {
                        normalizedChars.append(char.lowercased().first!)
                    } else if !normalizedChars.isEmpty && normalizedChars.last != " " {
                        normalizedChars.append(" ")
                    }
                    idx = transcript.index(after: idx)

                    // Check if we have enough
                    let current = String(normalizedChars).trimmingCharacters(in: .whitespaces)
                    if current == k {
                        // Skip any remaining whitespace in original
                        while idx < transcript.endIndex && transcript[idx].isWhitespace {
                            idx = transcript.index(after: idx)
                        }
                        let remainder = String(transcript[idx...])
                        return SnippetMatch(snippet: s, remainder: remainder)
                    }
                }
            }
        }
        return nil
    }
}
