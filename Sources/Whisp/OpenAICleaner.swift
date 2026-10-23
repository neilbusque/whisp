import Foundation
import WhispCore

/// OpenAI writing for automatic polish and explicit edits. Fast dictation only
/// skips the service when no semantic edit is needed.
final class OpenAICleaner: Cleaning {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let boundedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 5
        // A request timeout alone restarts when bytes arrive. Bound the entire
        // writing operation as well so slow responses cannot hold up dictation.
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = WhispConfig.defaultTextModel,
         session: URLSession? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.session = session ?? Self.boundedSession
    }

    private struct Request: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Double
        let max_completion_tokens: Int
        let store: Bool
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    func complete(_ messages: [ChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw WhispConfigError.missingKey("openaiKey") }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, messages: messages, stream: false, temperature: 0,
                    max_completion_tokens: outputTokenBudget(for: messages), store: false))
        // Ordinary dictation has a local fallback; required rewrites report the
        // failure without pasting partial text. Avoid retries on the typing path.
        request.timeoutInterval = 5

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIWritingError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Never echo provider bodies: they can contain request text or keys.
            throw OpenAIWritingError.http(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = decoded.choices.first else { throw OpenAIWritingError.emptyResponse }
        guard choice.finish_reason != "length" else { throw OpenAIWritingError.truncated }
        guard choice.finish_reason == "stop" else { throw OpenAIWritingError.incompleteResponse }
        let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw OpenAIWritingError.emptyResponse }
        Diag.log("OpenAI cleanup finished in \(started.duration(to: .now))")
        return text
    }

    private func outputTokenBudget(for messages: [ChatMessage]) -> Int {
        let userCharacters = messages.last(where: { $0.role == "user" })?.content.count ?? 0
        // Keep enough room for long rewrite selections rather than imposing a
        // short dictation-only limit that silently truncates edited paragraphs.
        return min(4_096, max(512, userCharacters / 2))
    }
}

enum OpenAIWritingError: LocalizedError, Equatable {
    case http(Int), invalidResponse, emptyResponse, truncated, incompleteResponse

    var errorDescription: String? {
        switch self {
        case .http(401): return "Check your OpenAI API key in Settings."
        case .http(429): return "OpenAI is at its usage limit. Try again shortly or check your API billing."
        case .http(let code): return "OpenAI writing is unavailable (HTTP \(code))."
        case .invalidResponse: return "OpenAI returned an invalid response."
        case .emptyResponse: return "OpenAI returned no text."
        case .truncated: return "The rewrite was cut short. Try a shorter selection."
        case .incompleteResponse: return "OpenAI did not finish the rewrite. Try again."
        }
    }
}
