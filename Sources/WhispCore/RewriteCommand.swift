import Foundation

public struct RewriteCommand: Equatable, Sendable {
    public let trigger: String
    public let instruction: String
    public let spokenText: String

    public init(trigger: String, instruction: String, spokenText: String) {
        self.trigger = trigger
        self.instruction = instruction
        self.spokenText = spokenText
    }

    public var prefersRecentText: Bool { trigger.contains("what i just said") }
    public var isRemoval: Bool {
        let normalized = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["remove ", "delete ", "cut ", "drop "].contains { normalized.hasPrefix($0) }
    }

    private static let commands: [(trigger: String, instruction: String)] = [
        ("make this clearer and more professional",
         "Rewrite this so it is clearer, concise, and professional."),
        ("make this sound more professional",
         "Rewrite this in a polished, professional, human tone."),
        ("make this sound professional",
         "Rewrite this in a polished, professional, human tone."),
        ("make this more professional",
         "Rewrite this in a polished, professional, human tone."),
        ("make this more concise",
         "Rewrite this to be shorter and more concise without losing meaning."),
        ("make this shorter",
         "Rewrite this to be shorter without losing meaning or important details."),
        ("make this warmer",
         "Rewrite this in a warmer, friendly, natural tone."),
        ("make this friendlier",
         "Rewrite this in a friendly, approachable tone."),
        ("make this more casual",
         "Rewrite this in a relaxed, conversational tone."),
        ("make this more formal",
         "Rewrite this in a formal, respectful tone."),
        ("make this less formal",
         "Rewrite this in a relaxed, conversational tone."),
        ("make this more polite",
         "Rewrite this in a polite, considerate tone."),
        ("make this clearer",
         "Rewrite this in clearer, easier-to-understand language."),
        ("make this better",
         "Rewrite this so it is clear, polished, and natural."),
        ("rewrite this",
         "Rewrite this so it is clear, polished, and natural."),
        ("rephrase this",
         "Rephrase this clearly while preserving the exact meaning."),
        ("clean this up",
         "Clean this up for clarity, grammar, and flow."),
        ("improve this",
         "Improve this for clarity, structure, and tone."),
        ("make this",
         "Rewrite this while preserving its meaning and facts."),
    ]

    /// Recognizes a leading command or a final instruction about the dictated
    /// source. Quoted commands and ordinary sentences discussing a command are
    /// content, not requests to replace selected text.
    public static func parse(_ transcript: String) -> RewriteCommand? {
        // A hesitation before an otherwise standalone command is not its
        // source. Keep the original transcript for suffix parsing so a real
        // dictated draft still retains all its words for the editor.
        if let leading = parseLeading(transcript) { return leading }

        // A suffix must be a complete instruction, with no source after it.
        // Preserve the original source, including its case and punctuation.
        let pattern = #"(?i)\b"# + SpokenCommandLanguage.wrappersPattern
            + #"(?:(?:rewrite|rephrase|clean|improve|make)\s+(?:this|that|it|what\s+i\s+just\s+said)|(?:change|adjust)\s+(?:the\s+)?tone|(?:remove|delete|cut|drop)\s+the\s+(?:sentence|part|paragraph|section|bit|line)\s+(?:about|mentioning|that\s+mentions))\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in expression.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) {
            guard let range = Range(match.range, in: transcript),
                  range.lowerBound > transcript.startIndex,
                  !isInsideQuotation(at: range.lowerBound, in: transcript) else { continue }
            let prefix = String(transcript[..<range.lowerBound])
            guard isSuffixBoundary(prefix, command: String(transcript[range.lowerBound...])),
                  let command = parseLeading(String(transcript[range.lowerBound...])),
                  command.spokenText.isEmpty else { continue }
            let source = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            return RewriteCommand(trigger: command.trigger, instruction: command.instruction,
                                  spokenText: source)
        }
        return nil
    }

    private static func parseLeading(_ raw: String) -> RewriteCommand? {
        let request = SpokenCommandLanguage.unwrap(raw)
        let transcript = request.text
        if let removal = parseTargetedRemoval(transcript) { return removal }
        if let tone = parseToneChange(transcript) { return tone }
        let correctionText = request.hasCorrectionCue ? "actually, " + transcript : transcript
        if let correction = parseStandaloneCorrection(correctionText) { return correction }
        for command in commands {
            for target in ["what i just said", "this", "that", "it"] {
                let trigger = command.trigger.replacingOccurrences(of: "this", with: target)
                let words = trigger.split(separator: " ").map {
                    NSRegularExpression.escapedPattern(for: String($0))
                }.joined(separator: #"\s+"#)
                let pattern = #"(?i)^\s*(?:please\s+)?"# + words + #"(?=\s|[.!?:;,]|$)"#
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: transcript,
                          range: NSRange(transcript.startIndex..., in: transcript)),
                      let range = Range(match.range, in: transcript) else { continue }
                let remainder = String(transcript[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // A colon immediately after the command always introduces
                // source, even if that source starts with style-like words.
                if remainder.hasPrefix(":") {
                    return RewriteCommand(trigger: trigger, instruction: command.instruction,
                        spokenText: String(remainder.dropFirst())
                            .trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if isTerminalRemainder(remainder) {
                    return RewriteCommand(trigger: trigger, instruction: command.instruction,
                                          spokenText: "")
                }

                // Keep the colon until after splitting style from source.
                // Otherwise "more professionally: Our proposal..." would
                // consume the source as part of the editing instruction.
                if let colon = remainder.firstIndex(of: ":") {
                    let style = String(remainder[..<colon])
                    if isStyleDirective(style) {
                        return RewriteCommand(trigger: trigger,
                            instruction: styleInstruction(base: command.instruction, style: style),
                            spokenText: String(remainder[remainder.index(after: colon)...])
                                .trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } else if isStyleDirective(remainder) {
                    return RewriteCommand(trigger: trigger,
                        instruction: styleInstruction(base: command.instruction, style: remainder),
                        spokenText: "")
                }

                // A bare "make this" needs a recognized style. Everyday
                // instructions such as "make this work tomorrow" are content.
                if command.trigger == "make this" { return nil }

                // "Rewrite this is the phrase on the button" is a sentence
                // about words, not source to rewrite or a selection command.
                if remainder.range(of: #"(?i)^(?:is|was|means|meant|would|should|could|appears|sounds)\b"#,
                                   options: .regularExpression) != nil { return nil }
                // Quotes around the command must not become a source fragment.
                if let first = remainder.first, #"\"'”’`"#.contains(first) { return nil }
                let source = remainder.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return RewriteCommand(trigger: trigger, instruction: command.instruction,
                                      spokenText: source)
            }
        }
        return nil
    }

    private static func parseToneChange(_ transcript: String) -> RewriteCommand? {
        let pattern = #"(?i)^\s*((?:change|adjust)\s+(?:the\s+)?tone(?:\s+of\s+(?:this|that|it|what\s+i\s+just\s+said))?)\s+to\s+(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: transcript,
                  range: NSRange(transcript.startIndex..., in: transcript)),
              let triggerRange = Range(match.range(at: 1), in: transcript),
              let remainderRange = Range(match.range(at: 2), in: transcript) else { return nil }
        let remainder = String(transcript[remainderRange])
        let colon = remainder.firstIndex(of: ":")
        let style = SpokenCommandLanguage.withoutTrailingPlease(
            colon.map { String(remainder[..<$0]) } ?? remainder)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Recognize a writing tone, never an arbitrary instruction or another
        // sentence. A colon can explicitly introduce the draft to edit.
        let tonePattern = #"(?i)^(?:(?:a|an|something)\s+)?(?:(?:more|less)\s+)?(?:professional|friendly|friendlier|warm|warmer|casual|formal|polite|confident|direct|natural|conversational|respectful|empathetic|concise|clear|neutral|upbeat|gentle|assertive)\b"#
        guard style.range(of: tonePattern, options: .regularExpression) != nil,
              style.range(of: #"[.!?]\s+\S"#, options: .regularExpression) == nil,
              !isReportedStyle(style),
              !style.contains("\""), !style.contains("“"), !style.contains("`") else { return nil }
        let source = colon.map {
            String(remainder[remainder.index(after: $0)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        return RewriteCommand(trigger: String(transcript[triggerRange]).lowercased(),
            instruction: "Rewrite this with the requested tone: \(style). Preserve the meaning, facts, and intent. "
                + "Keep the result natural and ready to send.", spokenText: source)
    }

    private static func parseTargetedRemoval(_ transcript: String) -> RewriteCommand? {
        let pattern = #"(?i)^\s*(?:please\s+)?((?:remove|delete|cut|drop)\s+the\s+(?:sentence|part|paragraph|section|bit|line)\s+(?:about|mentioning|that\s+mentions))\s+(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: transcript,
                  range: NSRange(transcript.startIndex..., in: transcript)),
              let triggerRange = Range(match.range(at: 1), in: transcript),
              let remainderRange = Range(match.range(at: 2), in: transcript) else { return nil }
        let trigger = String(transcript[triggerRange]).lowercased()
        let remainder = String(transcript[remainderRange])
        // A time such as 10:30 belongs to the topic. Only a colon followed
        // by whitespace separates an explicitly dictated source.
        let separator = remainder.range(of: #":\s"#, options: .regularExpression)
        let topicText = separator.map { String(remainder[..<$0.lowerBound]) } ?? remainder
        let topic = SpokenCommandLanguage.withoutTrailingPlease(topicText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !topic.isEmpty,
              topic.range(of: #"[.!?]\s+\S"#, options: .regularExpression) == nil else { return nil }
        let source = separator.map {
            String(remainder[remainder.index(after: $0.lowerBound)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        return RewriteCommand(trigger: trigger,
            instruction: "\(trigger.capitalized) \(topic). Remove only the clearly matching portion. "
                + "Preserve every unrelated sentence, fact, and negation. If no portion matches, "
                + "return the original text unchanged. Do not invent replacement content.",
            spokenText: source)
    }

    private static func parseStandaloneCorrection(_ transcript: String) -> RewriteCommand? {
        let pattern = #"(?i)^\s*(?:(actually)[\s,]+)?(?:please\s+)?make\s+(this|that|it)\s+(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: transcript,
                  range: NSRange(transcript.startIndex..., in: transcript)),
              let targetRange = Range(match.range(at: 2), in: transcript),
              let replacementRange = Range(match.range(at: 3), in: transcript) else { return nil }
        let replacement = SpokenCommandLanguage.withoutTrailingPlease(String(transcript[replacementRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !replacement.isEmpty,
              replacement.range(of: #"[.!?]\s+\S"#, options: .regularExpression) == nil,
              !isReportedStyle(replacement),
              replacement.range(of: #"(?i)^(?:work|happen|call|appointment|reservation|booking|purchase|payment|order|decision|change|hurry|up)\b"#,
                                options: .regularExpression) == nil else { return nil }
        let target = String(transcript[targetRange]).lowercased()
        let hasCorrectionCue = match.range(at: 1).location != NSNotFound
        // Without "actually", recognize only a date or number correction.
        // Everyday dictation like "make that call tomorrow" stays literal.
        let dateOrNumber = #"(?i)^(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|january|february|march|april|may|june|july|august|september|october|november|december|\d+(?:\.\d+)?)\b"#
        guard hasCorrectionCue || (target == "that"
            && replacement.range(of: dateOrNumber, options: .regularExpression) != nil) else { return nil }
        // A correction cue may also introduce an ordinary style request. Only
        // delegate style requests; a date would recursively parse itself.
        if hasCorrectionCue, isStyleDirective(replacement),
           let style = parseLeading("make \(target) \(replacement)"), style.spokenText.isEmpty {
            return style
        }
        let trigger = hasCorrectionCue ? "actually make \(target)" : "make \(target)"
        return RewriteCommand(trigger: trigger,
            instruction: "The speaker explicitly corrects a detail in the supplied text to: \(replacement). "
                + "Replace only the clearly corresponding old detail with this correction, "
                + "even when it changes the original fact. Preserve all unrelated text and facts. "
                + "If no corresponding detail can be identified, return the original text unchanged.",
            spokenText: "")
    }

    private static func isTerminalRemainder(_ value: String) -> Bool {
        value.range(of: #"(?i)^(?:[,\s]*please)?[.!?\s]*$"#,
                    options: .regularExpression) != nil
    }

    private static func isStyleDirective(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isReportedStyle(trimmed) else { return false }
        if trimmed.lowercased().hasPrefix("and ") || trimmed.lowercased().hasPrefix("but ") {
            return isStyleDirective(String(trimmed.dropFirst(4)))
                || trimmed.lowercased().hasPrefix("and make it ")
                || trimmed.lowercased().hasPrefix("but make it ")
        }
        // Style qualifiers must start directly after the trigger. A source
        // beginning with "Our proposal" remains source, even when it has a colon.
        let pattern = #"(?i)^(?:to\s+(?:sound|be)\b|so\s+it\s+(?:sounds|is)\b|in\s+(?:a|an|bullet|numbered)\b|with\s+(?:a|an)\b|(?:and|but)\s+make\s+it\b|as\s+(?:a|an|bullet|numbered)\b|into\s+(?:a|an|bullet|numbered)\b|(?:sound\s+)?(?:more|less)\s+(?:professional(?:ly)?|formal(?:ly)?|casual(?:ly)?|concise(?:ly)?|polite(?:ly)?|friendly|confident(?:ly)?|clear(?:ly)?|warm(?:ly)?|direct(?:ly)?)\b|(?:sound\s+)?(?:shorter|warmer|clearer|friendlier|better|polished|natural|friendly|confident|direct|conversational|professional(?:ly)?|formal(?:ly)?|casual(?:ly)?|concise(?:ly)?|polite(?:ly)?)\b)"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return false }
        // A second sentence is dictated content, not a free-form instruction.
        return trimmed.range(of: #"[.!?]\s+\S"#, options: .regularExpression) == nil
    }

    private static func isReportedStyle(_ value: String) -> Bool {
        // A style word at the start does not make the whole sentence a style
        // request: "friendly is the instruction on screen" describes words.
        let description = #"(?i)\b(?:is|was|means|meant|reads?|appears|sounds)\s+(?:(?:a|an|the|like)\s+)?(?:phrase|label|command|instruction|words?|text|sentence|request|example|button|title|what|how)\b|,\s*(?:he|she|they|the\s+\w+)\s+(?:said|wrote|asked|told)\b"#
        return value.range(of: description, options: .regularExpression) != nil
    }

    private static func styleInstruction(base: String, style: String) -> String {
        let qualifier = style.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return "\(base) Apply this writing style or format request: \(qualifier). Preserve meaning and facts."
    }

    private static func isSuffixBoundary(_ prefix: String, command: String) -> Bool {
        let source = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return false }
        // Inspect only the current sentence so earlier reported speech does
        // not suppress a genuine instruction in a following sentence.
        let clause = source.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n".contains($0) }).last.map(String.init) ?? ""
        let reporting = #"(?i)\b(?:phrase|command|instruction|words?|says?|said|saying|asked|asking|told|wrote|write|type|dictate|literally|quotes?|reads?|means?|called)\b"#
        if clause.range(of: reporting, options: .regularExpression) != nil { return false }
        let trailingDependency = #"(?i)\b(?:to|should|would|could|will|must|can|may|might|is|was|and|or|you|it|we|they|i)\s*[,;:]*$"#
        if source.range(of: trailingDependency, options: .regularExpression) != nil { return false }
        if let last = source.last, ".,;:!?".contains(last) { return true }
        if command.lowercased().hasPrefix("please ") { return true }
        // ASR sometimes omits punctuation before a spoken suffix. Require a
        // substantial source rather than reinterpreting "Can you make this...".
        return source.split(whereSeparator: \.isWhitespace).count >= 3
    }

    private static func isInsideQuotation(at index: String.Index, in text: String) -> Bool {
        var doubleQuoted = false
        var singleQuoted = false
        var codeQuoted = false
        for position in text.indices where position < index {
            let character = text[position]
            if character == "\"" { doubleQuoted.toggle() }
            if character == "“" { doubleQuoted = true }
            if character == "”" { doubleQuoted = false }
            if character == "`" { codeQuoted.toggle() }
            if character == "‘" { singleQuoted = true }
            if character == "’", singleQuoted { singleQuoted = false }
            if character == "'" {
                let before = position > text.startIndex ? text[text.index(before: position)] : " "
                let next = text.index(after: position)
                let after = next < text.endIndex ? text[next] : " "
                if singleQuoted {
                    if !after.isLetter { singleQuoted = false }
                } else if !before.isLetter && after.isLetter {
                    singleQuoted = true
                }
            }
        }
        return doubleQuoted || singleQuoted || codeQuoted
    }
}

/// Small, shared grammar for conversational prefixes. It only unwraps words at
/// the beginning of a candidate command; the caller must still recognize the
/// complete command and protect quotation or reported speech boundaries.
enum SpokenCommandLanguage {
    static let wrappersPattern = #"(?:(?:um+|uh+|erm+|oh\s*,?\s*wait|wait|actually)\b[\s,;.!?]+|(?:can|could|would)\s+you\s+|please[\s,]+)*"#

    static func unwrap(_ raw: String) -> (text: String, hasCorrectionCue: Bool) {
        let pattern = #"(?i)^\s*"# + wrappersPattern
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range, in: raw) else { return (raw, false) }
        let prefix = String(raw[range])
        let correction = prefix.range(of: #"(?i)\bactually\b"#,
                                      options: .regularExpression) != nil
        return (String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), correction)
    }

    static func withoutTrailingPlease(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)[,\s]+please[.!?\s]*$"#,
                                  with: "", options: .regularExpression)
    }
}
