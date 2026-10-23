import Foundation
import Testing
@testable import WhispCore

@Suite struct SpeculativeCleanerTests {
    actor Writer: Cleaning {
        var calls: [[ChatMessage]] = []
        var failFirst = false
        init(failFirst: Bool = false) { self.failFirst = failFirst }
        func complete(_ messages: [ChatMessage]) async throws -> String {
            calls.append(messages)
            let shouldFail = failFirst && calls.count == 1
            try await Task.sleep(for: .milliseconds(30))
            if shouldFail { throw RealtimeTranscriptionProtocol.Failure("test failure") }
            return "Polished: " + (messages.last?.content ?? "")
        }
    }
    func prompt(_ text: String) -> [ChatMessage] { TranscriptCleaner.polishPrompt(raw: text) }
    func waitForCall(_ writer: Writer, count: Int = 1) async throws {
        for _ in 0..<500 {
            if await writer.calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected writing request did not start")
    }

    @Test func matchingInflightRequestIsReused() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("send it Friday"), session: id)
        try await waitForCall(writer)
        #expect(try await cleaner.complete(prompt("send it Friday")) == "Polished: send it Friday")
        #expect(await writer.calls.count == 1)
    }

    @Test func completedResultIsReusedButConsumedOnlyOnce() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("send it Friday"), session: id)
        try await waitForCall(writer)
        try await Task.sleep(for: .milliseconds(60))
        _ = try await cleaner.complete(prompt("send it Friday"))
        #expect(await writer.calls.count == 1)
        _ = try await cleaner.complete(prompt("send it Friday"))
        #expect(await writer.calls.count == 2)
    }

    @Test func changedFinalAndContextNeverReuseEarlierOutput() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("I can attend"), session: id)
        try await waitForCall(writer)
        #expect(try await cleaner.complete(prompt("I cannot attend")) == "Polished: I cannot attend")
        #expect(await writer.calls.count == 2)
        let second = await cleaner.begin()
        await cleaner.offer(prompt("Whisp"), session: second)
        try await waitForCall(writer, count: 3)
        _ = try await cleaner.complete(TranscriptCleaner.polishPrompt(raw: "Whisp", vocabulary: ["Whisp"]))
        #expect(await writer.calls.count == 4)
    }

    @Test func priorSessionAndLatePartialsAreIgnored() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let old = await cleaner.begin()
        let current = await cleaner.begin()
        await cleaner.offer(prompt("stale"), session: old)
        _ = try await cleaner.complete(prompt("final"))
        await cleaner.offer(prompt("late"), session: current)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await writer.calls == [prompt("final")])
    }

    @Test func debounceKeepsLatestAndRequestBudgetIsBounded() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .milliseconds(10), limit: 1)
        let id = await cleaner.begin()
        for text in ["one", "one two", "one two three"] {
            await cleaner.offer(prompt(text), session: id)
        }
        try await waitForCall(writer)
        await cleaner.offer(prompt("more speech"), session: id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await writer.calls == [prompt("one two three")])
        #expect(try await cleaner.complete(prompt("final")) == "Polished: final")
        #expect(await writer.calls.count == 2)
    }

    @Test func failedSpeculationStillTriesAuthoritativeRequest() async throws {
        let writer = Writer(failFirst: true)
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("hello"), session: id)
        try await waitForCall(writer)
        try await Task.sleep(for: .milliseconds(60))
        #expect(try await cleaner.complete(prompt("hello")) == "Polished: hello")
        #expect(await writer.calls.count == 2)
    }

    @Test func cancellingFinalNeverReturnsSpeculativeText() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("hello"), session: id)
        try await waitForCall(writer)
        let final = Task { try await cleaner.complete(prompt("hello")) }
        final.cancel()
        do { _ = try await final.value; Issue.record("Cancelled final returned text") }
        catch { #expect(error is CancellationError) }
        await cleaner.cancel()
    }

    @Test func releasePreparesLatestEvenAfterEarlyBudgetIsUsed() async throws {
        let writer = Writer()
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero, limit: 1)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("first words"), session: id)
        try await waitForCall(writer)
        await cleaner.offer(prompt("the final words"), session: id)
        await cleaner.release(session: id)
        try await waitForCall(writer, count: 2)
        #expect(try await cleaner.complete(prompt("the final words")) == "Polished: the final words")
        #expect(await writer.calls.count == 2)
    }

    @Test func matchingFailureDoesNotStartAnotherTimeout() async throws {
        let writer = Writer(failFirst: true)
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("hello"), session: id)
        try await waitForCall(writer)
        do { _ = try await cleaner.complete(prompt("hello")); Issue.record("Expected provider failure") }
        catch { #expect(error is RealtimeTranscriptionProtocol.Failure) }
        #expect(await writer.calls.count == 1)
    }

    @Test func previewsNeverInsertOrReadAnEditTarget() async throws {
        let inserter = SpeechPipelineTests.FakeInserter()
        let writer = SpeechPipelineTests.FakeCleaner(reply: "Polished")
        let pipeline = SpeechPipeline(snippets: .init(snippets: []),
            transcriber: PipelineReliabilityTests.NeverTranscribe(), cleaner: writer,
            inserter: inserter, corrections: { [.init(heard: "super base", intended: "MyBase")] },
            onStatus: { _ in Issue.record("Preview changed pipeline status") })
        let messages = await pipeline.previewMessages(for: "connect super base")
        #expect(messages == TranscriptCleaner.polishPrompt(raw: "connect MyBase", vocabulary: ["MyBase"]))
        #expect(await pipeline.previewMessages(for: "Oh wait, remove this part") == nil)
        #expect(await pipeline.previewMessages(for: "Make this more casual please") == nil)
        #expect(inserter.inserted.isEmpty)
        #expect(writer.lastMessages.isEmpty)
    }
}
