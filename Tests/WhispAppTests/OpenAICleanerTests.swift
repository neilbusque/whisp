import Foundation
import Testing
import WhispCore
@testable import Whisp

/// Serial because URLProtocol installs one handler shared by these ephemeral sessions.
@Suite(.serialized) struct OpenAICleanerTests {
    private func session(handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> URLSession {
        WritingURLProtocol.handler.set(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WritingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(text: String?, finishReason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [[
            "message": ["content": text as Any? ?? NSNull()],
            "finish_reason": finishReason,
        ]]])
    }

    @Test func usesOpenAIContractAndPreservesLongRewriteBudget() async throws {
        let input = String(repeating: "word ", count: 1_200)
        let transport = session { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.timeoutInterval == 5)
            let body = try #require(request.httpBody ?? Self.read(request.httpBodyStream))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "gpt-5.4-nano")
            #expect(json["reasoning_effort"] as? String == "none")
            #expect(json["stream"] as? Bool == false)
            #expect(json["store"] as? Bool == false)
            #expect(json["temperature"] as? Double == 0)
            #expect(json["max_completion_tokens"] as? Int == 3_000)
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.last?["content"] == input)
            return (200, try Self.response(text: "  Complete rewrite.\n"))
        }
        defer { transport.invalidateAndCancel() }
        let cleaner = OpenAICleaner(apiKey: " sk-test\n", session: transport)
        let output = try await cleaner.complete([ChatMessage(role: "user", content: input)])
        #expect(output == "Complete rewrite.")
    }

    @Test func noteOrganizationHasRoomForStructuredMemoriesWithoutSlowingDictation() async throws {
        let transport = session { request in
            #expect(request.timeoutInterval == 30)
            let body = try #require(request.httpBody ?? Self.read(request.httpBodyStream))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["max_completion_tokens"] as? Int == 2_048)
            #expect(json["store"] as? Bool == false)
            return (200, try Self.response(text: "Organized note."))
        }
        defer { transport.invalidateAndCancel() }
        _ = try await OpenAICleaner(apiKey: "sk-test", session: transport, noteOrganization: true)
            .complete([ChatMessage(role: "user", content: "A short note.")])
    }

    @Test func missingKeyFailsBeforeRequest() async {
        let transport = session { _ in
            Issue.record("A missing OpenAI key must not send a request")
            return (500, Data())
        }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "  ", session: transport).complete([])
            Issue.record("Expected a missing-key error")
        } catch {
            #expect(error as? WhispConfigError == .missingKey("openaiKey"))
        }
    }

    @Test func rejectsTruncatedWritingInsteadOfPastingPartialText() async throws {
        let transport = session { _ in (200, try Self.response(text: "Partial", finishReason: "length")) }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "sk-test", session: transport).complete([])
            Issue.record("Expected a truncation error")
        } catch {
            #expect(error as? OpenAIWritingError == .truncated)
        }
    }

    @Test(arguments: ["", " \n", Optional<String>.none])
    func rejectsEmptyWriting(text: String?) async throws {
        let transport = session { _ in (200, try Self.response(text: text)) }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "sk-test", session: transport).complete([])
            Issue.record("Expected an empty-response error")
        } catch {
            #expect(error as? OpenAIWritingError == .emptyResponse)
        }
    }

    @Test func rejectsFilteredWriting() async throws {
        let transport = session { _ in (200, try Self.response(text: "partial", finishReason: "content_filter")) }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "sk-test", session: transport).complete([])
            Issue.record("Expected an incomplete-response error")
        } catch {
            #expect(error as? OpenAIWritingError == .incompleteResponse)
        }
    }

    @Test(arguments: [401, 429, 500])
    func reportsAPIErrorWithoutLeakingResponseBody(status: Int) async throws {
        let transport = session { _ in (status, Data("private transcript and credential".utf8)) }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "sk-test", session: transport).complete([])
            Issue.record("Expected an HTTP error")
        } catch {
            #expect(error as? OpenAIWritingError == .http(status))
            #expect(!error.localizedDescription.contains("private transcript"))
        }
    }

    @Test func networkFailureIsPropagatedForPipelineFallback() async throws {
        let transport = session { _ in throw URLError(.timedOut) }
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await OpenAICleaner(apiKey: "sk-test", session: transport).complete([])
            Issue.record("Expected a timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class WritingURLProtocol: URLProtocol, @unchecked Sendable {
    final class Handler: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable (URLRequest) throws -> (Int, Data))?
        func set(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
            lock.withLock { value = handler }
        }
        func call(_ request: URLRequest) throws -> (Int, Data) {
            let handler = lock.withLock { value }
            return try handler!(request)
        }
    }
    static let handler = Handler()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler.call(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
