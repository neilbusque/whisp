import Foundation
import WhispCore

final class DeepSeekCleaner: Cleaning {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    init(apiKey: String) { self.apiKey = apiKey }

    private struct Req: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    private struct Resp: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        let choices: [Choice]
    }

    func complete(_ messages: [ChatMessage]) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(
            Req(model: "deepseek-chat", messages: messages, stream: false))
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Whisp.DeepSeek", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }
}
