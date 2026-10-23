import Foundation
import Testing
@testable import Whisp

@Suite struct RealtimeLifecycleTests {
    @Test func missingKeyFailsWithoutWaitingForDeadline() async {
        let client = OpenAIRealtimeTranscriber(apiKey: " ")
        client.begin()
        client.append(Data(repeating: 0, count: 4_800))
        do {
            _ = try await client.finish(timeout: 1)
            Issue.record("Missing credentials must fail")
        } catch {
            #expect(error.localizedDescription.contains("OpenAI API key"))
        }
    }

    @Test func abortBeforeStartNeverConnectsOrHangs() async {
        let client = OpenAIRealtimeTranscriber(apiKey: "unused-test-key")
        client.abort()
        client.begin()
        do {
            _ = try await client.finish(timeout: 1)
            Issue.record("An aborted turn must never return text")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
