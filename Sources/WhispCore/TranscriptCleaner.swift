import Foundation

public struct ChatMessage: Equatable, Codable, Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public enum TranscriptCleaner {
    static let fillers: Set<String> = ["um", "uh", "erm", "ah", "like", "you know", "i mean"]

    public static func polishPrompt(raw: String) -> [ChatMessage] {
        let system = """
        You clean up dictated speech into polished written text. Remove filler words \
        (um, uh, like), fix grammar and punctuation, and format naturally. Do NOT add \
        content, greetings, or commentary. Do NOT use em dashes. Return ONLY the cleaned text.
        """
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: raw),
        ]
    }

    public static func aiTemplatePrompt(template: String, dictation: String) -> [ChatMessage] {
        let system = """
        You generate written text from a template instruction plus the user's spoken \
        details. Follow the instruction exactly. Do NOT use em dashes. Return ONLY the \
        generated text, no commentary.
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
