import Foundation
import Testing
@testable import WhispCore

@Suite struct SpeculativeCleanerTests {
    actor Writer: Cleaning {
        var calls: [[ChatMessage]] = []
        let failFirst: Bool
        var heldCalls: Set<Int>
        var continuations: [Int: CheckedContinuation<String, Error>] = [:]
        init(failFirst: Bool = false, heldCalls: Set<Int> = []) {
            self.failFirst = failFirst
            self.heldCalls = heldCalls
        }
        func complete(_ messages: [ChatMessage]) async throws -> String {
            calls.append(messages)
            let call = calls.count
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard heldCalls.contains(call) else { return try result(for: call).get() }
                return try await withCheckedThrowingContinuation { continuations[call] = $0 }
            } onCancel: {
                Task { await self.cancel(call) }
            }
        }
        func finish(_ call: Int = 1) {
            heldCalls.remove(call)
            continuations.removeValue(forKey: call)?.resume(with: result(for: call))
        }
        func cancel(_ call: Int) {
            heldCalls.remove(call)
            continuations.removeValue(forKey: call)?.resume(throwing: CancellationError())
        }
        private func result(for call: Int) -> Result<String, Error> {
            if failFirst && call == 1 { return .failure(RealtimeTranscriptionProtocol.Failure("test failure")) }
            return .success("Polished: " + (calls[call - 1].last?.content ?? ""))
        }
    }
    func prompt(_ text: String) -> [ChatMessage] { TranscriptCleaner.polishPrompt(raw: text) }
    func waitForCall(_ writer: Writer, count: Int = 1) async throws {
        try await waitUntil { await writer.calls.count >= count }
    }
    func waitForNoActivePreview(_ cleaner: SpeculativeCleaner) async throws {
        try await waitUntil { await !cleaner.hasActivePreview }
    }
    func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            // Time only bounds a broken test; the observed state, never a
            // guessed delay, establishes when work is ready to continue.
            try #require(ContinuousClock.now < deadline, "Expected preview state was not reached")
            await Task.yield()
        }
    }

    @Test func matchingInflightRequestIsReused() async throws {
        let writer = Writer(heldCalls: [1])
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("send it Friday"), session: id)
        try await waitForCall(writer)
        let final = Task { try await cleaner.complete(prompt("send it Friday")) }
        try await waitForNoActivePreview(cleaner)
        await writer.finish()
        #expect(try await final.value == "Polished: send it Friday")
        #expect(await writer.calls.count == 1)
    }

    @Test func completedResultIsReusedButConsumedOnlyOnce() async throws {
        let writer = Writer(heldCalls: [1])
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("send it Friday"), session: id)
        try await waitForCall(writer)
        await writer.finish()
        try await waitForNoActivePreview(cleaner)
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
        #expect(await writer.calls == [prompt("final")])
    }

    @Test func debounceKeepsLatestAndRequestBudgetIsBounded() async throws {
        let writer = Writer(heldCalls: [1])
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero, limit: 1)
        let id = await cleaner.begin()
        await cleaner.offerBatch(["one", "one two", "one two three"].map(prompt), session: id)
        try await waitForCall(writer)
        await cleaner.offer(prompt("more speech"), session: id)
        #expect(await writer.calls == [prompt("one two three")])
        #expect(try await cleaner.complete(prompt("final")) == "Polished: final")
        #expect(await writer.calls.count == 2)
    }

    @Test func failedSpeculationStillTriesAuthoritativeRequest() async throws {
        let writer = Writer(failFirst: true, heldCalls: [1])
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("hello"), session: id)
        try await waitForCall(writer)
        await writer.finish()
        try await waitForNoActivePreview(cleaner)
        #expect(try await cleaner.complete(prompt("hello")) == "Polished: hello")
        #expect(await writer.calls.count == 2)
    }

    @Test func cancellingFinalNeverReturnsSpeculativeText() async throws {
        let writer = Writer(heldCalls: [1])
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
        let writer = Writer(failFirst: true, heldCalls: [1])
        let cleaner = SpeculativeCleaner(cleaner: writer, debounce: .zero)
        let id = await cleaner.begin()
        await cleaner.offer(prompt("hello"), session: id)
        try await waitForCall(writer)
        let final = Task { try await cleaner.complete(prompt("hello")) }
        try await waitForNoActivePreview(cleaner)
        await writer.finish()
        do { _ = try await final.value; Issue.record("Expected provider failure") }
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

private extension SpeculativeCleaner {
    /// Keep the entire speech burst in one actor turn so zero-delay timers
    /// cannot observe an intermediate offer between scheduler resumptions.
    func offerBatch(_ prompts: [[ChatMessage]], session: UUID) {
        for prompt in prompts { offer(prompt, session: session) }
    }
}
