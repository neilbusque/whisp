import Testing
import Foundation
@testable import WhispCore

@Suite struct SpeechPipelineTests {
    final class FakeTranscriber: Transcribing, @unchecked Sendable {
        let text: String
        init(_ t: String) { text = t }
        func transcribe(_ samples: [Float]) async throws -> String { text }
    }
    final class FakeCleaner: Cleaning, @unchecked Sendable {
        var lastMessages: [ChatMessage] = []
        var shouldThrow = false
        let reply: String
        init(reply: String) { self.reply = reply }
        func complete(_ messages: [ChatMessage]) async throws -> String {
            lastMessages = messages
            if shouldThrow { throw NSError(domain: "x", code: 1) }
            return reply
        }
    }
    final class FakeInserter: TextInserting, @unchecked Sendable {
        var inserted: [String] = []
        func insert(_ text: String) throws { inserted.append(text) }
    }

    @Test func plainDictationGetsPolishedThenInserted() async {
        let cleaner = FakeCleaner(reply: "Cleaned text.")
        let inserter = FakeInserter()
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: []),
            transcriber: FakeTranscriber("um hello"),
            cleaner: cleaner, inserter: inserter, onStatus: { _ in })
        await pipe.process(samples: [0.0])
        #expect(inserter.inserted == ["Cleaned text."])
        #expect(cleaner.lastMessages.last?.content.contains("um hello") == true)
    }

    @Test func verbatimSnippetSkipsTheCleaner() async {
        let snip = Snippet(keyword: "bug template", mode: .verbatim, content: "## Bug")
        let cleaner = FakeCleaner(reply: "SHOULD-NOT-BE-USED")
        let inserter = FakeInserter()
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: [snip]),
            transcriber: FakeTranscriber("bug template"),
            cleaner: cleaner, inserter: inserter, onStatus: { _ in })
        await pipe.process(samples: [0.0])
        #expect(inserter.inserted == ["## Bug"])
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func aiSnippetSendsTemplateAndRemainder() async {
        let snip = Snippet(keyword: "cold email", mode: .ai, content: "Write an email.")
        let cleaner = FakeCleaner(reply: "Dear Dr. Smith...")
        let inserter = FakeInserter()
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: [snip]),
            transcriber: FakeTranscriber("cold email to a dentist"),
            cleaner: cleaner, inserter: inserter, onStatus: { _ in })
        await pipe.process(samples: [0.0])
        #expect(inserter.inserted == ["Dear Dr. Smith..."])
        #expect(cleaner.lastMessages.last?.content.contains("Write an email.") == true)
        #expect(cleaner.lastMessages.last?.content.contains("to a dentist") == true)
    }

    @Test func cleanerFailureFallsBackToOfflineClean() async {
        let cleaner = FakeCleaner(reply: "X")
        cleaner.shouldThrow = true
        let inserter = FakeInserter()
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: []),
            transcriber: FakeTranscriber("um hello there"),
            cleaner: cleaner, inserter: inserter, onStatus: { _ in })
        await pipe.process(samples: [0.0])
        #expect(inserter.inserted.count == 1)
        #expect(inserter.inserted[0].lowercased().contains("um") == false)
    }

    @Test func aiSnippetOfflineFallbackUsesCleanedRemainderNotInstruction() async {
        // When DeepSeek is unreachable the fallback must be offlineClean(remainder),
        // never the raw instruction string stored in snippet.content.
        let instruction = "Write a short friendly cold email to a prospect."
        let snip = Snippet(keyword: "cold email", mode: .ai, content: instruction)
        let cleaner = FakeCleaner(reply: "X")
        cleaner.shouldThrow = true
        let inserter = FakeInserter()
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: [snip]),
            transcriber: FakeTranscriber("cold email to a dentist"),
            cleaner: cleaner, inserter: inserter, onStatus: { _ in })
        await pipe.process(samples: [0.0])
        // Must have inserted something (offline-cleaned remainder)
        #expect(inserter.inserted.count == 1)
        // Must NOT have pasted the raw instruction
        #expect(inserter.inserted[0] != instruction)
        // The remainder "to a dentist" after offlineClean should be present (or empty), not the instruction
        #expect(!inserter.inserted[0].contains("Write a short friendly cold email"))
    }

    @Test func emptyTranscriptInsertsNothingAndReportsError() async {
        let inserter = FakeInserter()
        var statuses: [PipelineStatus] = []
        let pipe = SpeechPipeline(
            snippets: SnippetStore(snippets: []),
            transcriber: FakeTranscriber("   "),
            cleaner: FakeCleaner(reply: "X"), inserter: inserter,
            onStatus: { statuses.append($0) })
        await pipe.process(samples: [0.0])
        #expect(inserter.inserted.isEmpty)
        #expect(statuses.contains { if case .error = $0 { return true } else { return false } })
    }
}
