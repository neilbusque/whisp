import Foundation

/// Separates literal dictation from unambiguous editing commands without a model
/// round trip. Ambiguous corrections are preserved for the writing model.
public enum SpokenEdit: Equatable, Sendable {
    /// An empty dictation cancels this utterance without touching existing text.
    case dictation(String)
    case command(Command)
    case interpret(String)

    public enum Command: Equatable, Sendable {
        case deleteAll
        /// "This part" is ambiguous without a highlighted range. Unlike a
        /// whole-insertion command, it must never use a recent-text fallback.
        case deleteSelection
        case deleteLastWord
        case deleteLastSentence
        case replace(String)
        case startFrom(String)

        public var requiresSelection: Bool { self == .deleteSelection }
    }

    /// A command applies only to an explicitly selected or verified recent Whisp
    /// insertion. The caller chooses that target; this parser never chooses a
    /// document, cursor range, or application on the user's behalf.
    public static func parse(_ raw: String) -> SpokenEdit {
        let text = SpokenCommandLanguage.withoutTrailingPlease(SpokenCommandLanguage.unwrap(raw).text)
        let exact = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let wholeCommands: Set<String> = [
            "scratch that", "delete that", "undo that", "remove that",
            "start over", "start again",
        ]
        if wholeCommands.contains(exact) { return .command(.deleteAll) }
        if exact.range(of: #"^(?:delete|remove|cut|scratch) (?:(?:this|that) (?:part|bit|section)|(?:the )?(?:selected|highlighted) (?:text|part|section))$"#,
                       options: .regularExpression) != nil {
            return .command(.deleteSelection)
        }
        if exact.range(of: #"^(?:delete|remove|scratch) (?:(?:the|that) )?last word$"#,
                       options: .regularExpression) != nil {
            return .command(.deleteLastWord)
        }
        if exact.range(of: #"^(?:delete|remove|scratch) (?:(?:the|that) )?last sentence$"#,
                       options: .regularExpression) != nil {
            return .command(.deleteLastSentence)
        }
        if let match = matches(#"(?i)^start (?:from|at)\s*:?\s+(.+)$"#, in: text).first,
           let range = Range(match.range(at: 1), in: text) {
            let phrase = String(text[range])
                .replacingOccurrences(of: #"(?i)^the (?:word|words|phrase)\s+"#,
                                      with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'“”‘’"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty, !["scratch", "the beginning", "the top"].contains(phrase.lowercased()) {
                return .command(.startFrom(phrase))
            }
        }

        // A restart must be separated from its source. "Start over tomorrow"
        // is ordinary language and must never erase an existing insertion.
        let resets = matches(#"(?i)\b(?:start over|start again)\b"#, in: text)
        var lastReset: (NSRange, String)?
        for reset in resets {
            guard !isQuoted(reset.range, in: text),
                  !isDiscussed(reset.range, in: text),
                  let range = Range(reset.range, in: text) else { continue }
            let before = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasBoundary = before.isEmpty || before.last.map { ",.;:!?".contains($0) } == true
            if hasBoundary, !before.isEmpty,
               after.allSatisfy({ $0.isWhitespace || ",.;:!?".contains($0) }) {
                lastReset = (reset.range, "")
                continue
            }
            guard hasBoundary, let first = after.first, ",.;:!?".contains(first) else { continue }
            let remainder = String(after.drop(while: { $0.isWhitespace || ",.;:!?".contains($0) }))
            guard !remainder.isEmpty else { continue }
            // Temporal instructions are often literal speech about restarting.
            // A colon is the explicit escape hatch for such source material.
            if first != ":", remainder.range(
                of: #"(?i)^(?:tomorrow|today|tonight|next |after |before |when |once |in the morning)\b"#,
                options: .regularExpression) != nil { continue }
            lastReset = (reset.range, remainder)
        }
        if let (range, replacement) = lastReset,
           let swiftRange = Range(range, in: text) {
            let prefix = text[..<swiftRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? .command(.replace(replacement)) : .dictation(replacement)
        }

        // A terminal, explicitly bounded deletion has enough context to apply
        // locally. Keep the separator punctuation with the dictated source so
        // deleting its final sentence preserves earlier sentences exactly.
        if let suffix = matches(
            #"(?i)[,.;:!?]\s+("# + SpokenCommandLanguage.wrappersPattern
                + #"(?:delete|remove|scratch) (?:(?:the|that) )?last (word|sentence))\s*[.!?]*\s*$"#,
            in: text).first,
           !isQuoted(suffix.range(at: 1), in: text),
           !isDiscussed(suffix.range(at: 1), in: text),
           let commandRange = Range(suffix.range(at: 1), in: text),
           let unitRange = Range(suffix.range(at: 2), in: text) {
            let source = text[..<commandRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty {
                let command: Command = text[unitRange].lowercased() == "word"
                    ? .deleteLastWord : .deleteLastSentence
                return .dictation(applying(command, to: source))
            }
        }

        // Corrections need meaning and sentence context. Do not guess which
        // clause "scratch that" or which fact "make that Friday" replaces.
        let semanticPatterns = [
            #"(?i)\bno\s*,?\s+I mean\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)actually\s*,?\s+make that\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)make (?:that|it|this) (?:sound )?(?:(?:more|less) )?(?:professional|polished|clear(?:er)?|concise|natural|friendly|friendlier|warm(?:er)?|formal|casual|short(?:er)?|long(?:er)?|brief|direct|confident|persuasive|simple(?:r)?|better|clean(?:er)?|detailed)\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)make that (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|\d+(?:\.\d+)?)\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)(?:scratch that|delete that|undo that|remove that)(?=\s*[,.;:!?]|\s*$)"#,
            #"(?i)(?:^|[,.;:!?]\s+)(?:delete|remove|scratch) (?:(?:the|that) )?last (?:word|sentence)\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)(?:rewrite|rephrase|clean up) (?:that|it|this)\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)(?:start over|start again)\s*[,.;:!?]?\s*$"#,
            #"(?i)\b(?:no\s*,?\s+actually|sorry\s*,?\s+I (?:mean|meant))\b"#,
            #"(?i)[,.;:!?]\s+(?:sorry|actually)\b"#,
            #"(?i)(?:^|[,.;:!?]\s+)"# + SpokenCommandLanguage.wrappersPattern
                + #"(?:make\s+(?:that|it|this)\s+|(?:change|adjust)\s+(?:the\s+)?tone\s+to\s+|(?:remove|delete|cut)\s+(?:(?:this|that)\s+(?:part|bit|section)|the\s+(?:part|sentence|section|bit|line)\s+(?:about|mentioning|that\s+mentions))|(?:rewrite|rephrase|improve)\s+(?:that|it|this)\b|clean\s+(?:that|it|this)\s+up\b|(?:start\s+over|scratch\s+that)(?=\s*[,.;:!?]|\s*$))"#,
        ]
        for pattern in semanticPatterns {
            for match in matches(pattern, in: text) {
                guard !isQuoted(match.range, in: text),
                      !isDiscussed(match.range, in: text) else { continue }
                // The broader conversational pattern requires a real command
                // after "make". Ordinary requests to make a call or make
                // something work must remain literal dictation.
                if let range = Range(match.range, in: text) {
                    let candidate = String(text[range.lowerBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!? "))
                    let unwrapped = SpokenCommandLanguage.unwrap(candidate).text
                    if unwrapped.range(
                        of: #"(?i)^start\s+(?:over|again)\s*[,.;!?]\s*(?:tomorrow|today|tonight|next\b|after\b|before\b|when\b|once\b|in the morning)"#,
                        options: .regularExpression) != nil { continue }
                    if unwrapped.range(of: #"(?i)^(?:make\s+(?:that|it|this)\s+|(?:change|adjust)\s+(?:the\s+)?tone\b)"#,
                                       options: .regularExpression) != nil,
                       RewriteCommand.parse(candidate) == nil { continue }
                }
                return .interpret(raw)
            }
        }
        return .dictation(raw)
    }

    /// Calculates a replacement without touching the clipboard or active app.
    /// An empty result is a valid deletion, never an instruction to press Undo.
    public static func applying(_ command: Command, to raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case .deleteAll, .deleteSelection:
            return ""
        case .replace(let replacement):
            return replacement
        case .startFrom(let phrase):
            guard !phrase.isEmpty else { return raw }
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = #"(?i)(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
            let occurrences = matches(pattern, in: raw)
            guard occurrences.count == 1, let occurrence = occurrences.first,
                  let range = Range(occurrence.range, in: raw) else { return raw }
            return String(raw[range.lowerBound...])
        case .deleteLastWord:
            guard let range = text.range(of: #"\S+\s*$"#, options: .regularExpression) else {
                return ""
            }
            return text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        case .deleteLastSentence:
            var boundary: String.Index?
            for match in matches(#"[.!?]+[\"”’')\]]*(?=\s|$)"#, in: text) {
                guard let range = Range(match.range, in: text),
                      !text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !isAbbreviation(at: range, in: text) else { continue }
                boundary = range.upperBound
            }
            guard let boundary else { return "" }
            return text[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func isQuoted(_ range: NSRange, in text: String) -> Bool {
        matches(#"\"[^\"]*\"|“[^”]*”|‘[^’]*’|`[^`]*`|(?<!\p{L})'[^'\n]*'(?!\p{L})"#, in: text)
            .contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    private static func isDiscussed(_ range: NSRange, in text: String) -> Bool {
        guard let swiftRange = Range(range, in: text) else { return false }
        if let first = text[swiftRange].first, ".!?".contains(first) { return false }
        let prefix = String(text[..<swiftRange.lowerBound])
        // Inspect the current sentence only, so "I said the wrong thing.
        // Start over: ..." still works as an explicit restart.
        return prefix.range(
            of: #"(?i)\b(?:phrase|words?|command|expression|saying|said|says|asked|asking|told|tell|quote|quoted|write|type|dictate|literally|called|named)\b[^.!?]*$"#,
            options: .regularExpression) != nil
    }

    private static func isAbbreviation(at range: Range<String.Index>, in text: String) -> Bool {
        guard text[range].first == "." else { return false }
        let prefix = String(text[..<range.lowerBound])
        let token = prefix.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "e.g", "i.e",
        ]
        if abbreviations.contains(token.lowercased()) { return true }
        return token.range(of: #"^(?:[A-Z]\.)*[A-Z]$"#, options: .regularExpression) != nil
    }
}
