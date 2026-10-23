import Foundation
import Testing
@testable import WhispCore

@Suite struct PipelineReliabilityTests {
    struct NeverTranscribe: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String {
            Issue.record("Live transcripts must not run local recognition")
            throw CancellationError()
        }
    }
    @Test func liveTranscriptUsesCorrectionsWithoutLocalRecognitionOrCleanupRequest() async {
        let inserter = SpeechPipelineTests.FakeInserter()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "not used")
        let pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: NeverTranscribe(),
            cleaner: cleaner, inserter: inserter, cleanupMode: .fast,
            corrections: { [.init(heard: "super base", intended: "MyBase")] }, onStatus: { _ in })
        await pipeline.process(transcript: "connect super base")
        #expect(inserter.inserted == ["Connect MyBase."])
        #expect(cleaner.lastMessages.isEmpty)
    }
    @Test func liveTranscriptStillExpandsVerbatimSnippet() async {
        let inserter = SpeechPipelineTests.FakeInserter()
        let pipeline = SpeechPipeline(snippets: .init(snippets: [
            Snippet(keyword: "report template", mode: .verbatim, content: "Exact\nTemplate")
        ]), transcriber: NeverTranscribe(), cleaner: SpeechPipelineTests.FakeCleaner(reply: "not used"),
            inserter: inserter, cleanupMode: .fast, onStatus: { _ in })
        await pipeline.process(transcript: "report template")
        #expect(inserter.inserted == ["Exact\nTemplate"])
    }
    @Test func cancellationDuringResultCallbackNeverPastes() async {
        let inserter = SpeechPipelineTests.FakeInserter()
        let pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: NeverTranscribe(),
            cleaner: SpeechPipelineTests.FakeCleaner(reply: ""), inserter: inserter,
            cleanupMode: .fast, onResult: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, onStatus: { _ in })
        let task = Task { await pipeline.process(transcript: "do not paste") }
        await task.value
        #expect(inserter.inserted.isEmpty)
    }
    actor GateTranscriber: Transcribing {
        var starts = 0
        private var continuation: CheckedContinuation<String, Never>?
        func transcribe(_ samples: [Float]) async throws -> String {
            starts += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: "hello"); continuation = nil }
    }
    actor Results {
        var values: [DictationResult] = []
        func append(_ result: DictationResult) { values.append(result) }
    }
    struct BrokenInserter: TextInserting {
        func insert(_ text: String) async throws { throw LearningError.invalid("destination changed") }
    }
    @Test func overlappingDictationsAreNotQueuedForLaterPasting() async {
        let gate = GateTranscriber()
        let inserter = SpeechPipelineTests.FakeInserter()
        let pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: gate,
            cleaner: SpeechPipelineTests.FakeCleaner(reply: ""), inserter: inserter,
            cleanupMode: .fast, onStatus: { _ in })
        let first = Task { await pipeline.process(samples: [0.1]) }
        while await gate.starts == 0 { await Task.yield() }
        await pipeline.process(samples: [0.2])
        #expect(await gate.starts == 1)
        await gate.release(); await first.value
        #expect(inserter.inserted == ["Hello."])
    }
    @Test func cancellationNeverPastesALateTranscript() async {
        let gate = GateTranscriber()
        let inserter = SpeechPipelineTests.FakeInserter()
        let pipeline = SpeechPipeline(snippets: .init(snippets: []), transcriber: gate,
            cleaner: SpeechPipelineTests.FakeCleaner(reply: ""), inserter: inserter,
            cleanupMode: .fast, onStatus: { _ in })
        let task = Task { await pipeline.process(samples: [0.1]) }
        while await gate.starts == 0 { await Task.yield() }
        task.cancel(); await gate.release(); await task.value
        #expect(inserter.inserted.isEmpty)
    }
    @Test func failedPasteStillProvidesRecoverableText() async {
        let results = Results()
        let pipeline = SpeechPipeline(snippets: .init(snippets: []),
            transcriber: SpeechPipelineTests.FakeTranscriber("my important sentence"),
            cleaner: SpeechPipelineTests.FakeCleaner(reply: ""), inserter: BrokenInserter(),
            cleanupMode: .fast, onResult: { await results.append($0) }, onStatus: { _ in })
        await pipeline.process(samples: [0.1])
        #expect(await results.values.first?.output == "My important sentence.")
    }
    @Test func userCorrectionsReachPastedOutputWithoutNetworkCleanup() async {
        let inserter = SpeechPipelineTests.FakeInserter()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "not used")
        let pipeline = SpeechPipeline(snippets: .init(snippets: []),
            transcriber: SpeechPipelineTests.FakeTranscriber("I like super base"),
            cleaner: cleaner, inserter: inserter, cleanupMode: .fast,
            corrections: { [.init(heard: "super base", intended: "MyBase")] }, onStatus: { _ in })
        await pipeline.process(samples: [0.1])
        #expect(inserter.inserted == ["I like MyBase."])
        #expect(cleaner.lastMessages.isEmpty)
    }
}
