import AppKit

/// Local spelling and grammar check that decides whether a dictation needs
/// the OpenAI proofread at all. Takes a few milliseconds and stays on this Mac.
@MainActor
enum WritingCheck {
    static func hasIssues(_ text: String, knownTerms: [String]) -> Bool {
        let known = Set(knownTerms.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) }.map(String.init))
        let string = text as NSString
        let results = NSSpellChecker.shared.check(
            text, range: NSRange(location: 0, length: string.length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue
                | NSTextCheckingResult.CheckingType.grammar.rawValue,
            options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        return results.contains { result in
            guard result.resultType == .spelling else { return true }
            // Names the user taught Whisp are spelled right even if macOS disagrees.
            return !known.contains(string.substring(with: result.range).lowercased())
        }
    }
}
