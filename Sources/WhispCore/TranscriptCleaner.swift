import Foundation

public struct ChatMessage: Equatable, Codable, Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public enum TranscriptCleaner {
    static let fillers: Set<String> = ["um", "uh", "erm", "ah", "like", "you know", "i mean"]

    public static func polishPrompt(raw: String, vocabulary: [String] = []) -> [ChatMessage] {
        let system = """
        You clean up dictated speech into polished written text. Remove filler words \
        (um, uh, like), fix grammar and punctuation, and format naturally. Do NOT add \
        content, greetings, or commentary. Do NOT use em dashes. Return ONLY the cleaned text.\
        \(vocabularyClause(vocabulary))
        """
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: raw),
        ]
    }

    /// Appended to a system prompt so the model keeps the user's known terms
    /// spelled correctly instead of "fixing" unfamiliar names.
    static func vocabularyClause(_ vocabulary: [String]) -> String {
        guard !vocabulary.isEmpty else { return "" }
        return "\n\nThese terms are spelled correctly; preserve them exactly when they "
            + "appear (fix near-misses to match): \(vocabulary.joined(separator: ", "))."
    }

    public static func aiTemplatePrompt(template: String, dictation: String,
                                        vocabulary: [String] = []) -> [ChatMessage] {
        let system = """
        You generate written text from a template instruction plus the user's spoken \
        details. Follow the instruction exactly. Do NOT use em dashes. Return ONLY the \
        generated text, no commentary.\(vocabularyClause(vocabulary))
        """
        let user = """
        INSTRUCTION:
        \(template)

        DETAILS:
        \(dictation)
        """
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    /// Builds a coaching critique request. Sends the TRANSCRIPT TEXT ONLY —
    /// never audio, never an envelope, never a file path.
    public static func coachPrompt(transcript: String, promptTitle: String,
                                   metrics: SpeechMetrics) -> [ChatMessage] {
        let stats = String(
            format: "Pace %.0f wpm. Fillers %.1f per 100 words. %d pauses, longest %.1fs.",
            metrics.wpm, metrics.fillerRate, metrics.pauseCount, metrics.longestPauseSec)
        return [
            ChatMessage(role: "system", content: """
                You are a speaking coach. The user practised answering: "\(promptTitle)".
                Give at most 5 short bullets of specific, actionable feedback on their \
                delivery and structure. Quote their own words when pointing at a problem. \
                No preamble, no praise padding, no em dashes. Be direct.
                """),
            ChatMessage(role: "user", content: "\(stats)\n\nTranscript:\n\(transcript)"),
        ]
    }

    /// Pure on-device fallback used when DeepSeek is unreachable.
    public static func offlineClean(_ raw: String) -> String {
        var words = raw.split(separator: " ").map(String.init)
        words.removeAll { fillers.contains($0.lowercased()) }
        guard !words.isEmpty else { return "" }
        var text = words.joined(separator: " ")
        // Capitalize first letter.
        text = text.prefix(1).uppercased() + text.dropFirst()
        // Add terminal punctuation if missing.
        if let last = text.last, !".?!".contains(last) { text += "." }
        return text
    }
}
