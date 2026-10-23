import Foundation
import Testing
@testable import WhispCore

@Suite struct SpokenEditPipelineTests {
    actor Destination: TextInserting, TextEditing {
        var text: String?
        var inserted: [String] = []
        var replacements: [String] = []
        var preferredRecent: [Bool] = []
        var rejectReplacement = false
        let isExplicitSelection: Bool
        private var target: TextEditTarget?
        init(_ text: String? = nil, isExplicitSelection: Bool = false) {
            self.text = text
            self.isExplicitSelection = isExplicitSelection
        }
        func insert(_ value: String) { inserted.append(value) }
        func prepareEdit(preferRecent: Bool) -> TextEditTarget? {
            preferredRecent.append(preferRecent)
            target = text.map { TextEditTarget(text: $0, isExplicitSelection: isExplicitSelection) }
            return target
        }
        func rejectEdits() { rejectReplacement = true }
        func replace(_ target: TextEditTarget, with value: String) throws {
            guard !rejectReplacement, self.target == target else { throw CancellationError() }
            replacements.append(value)
            text = value
        }
    }

    private func pipeline(_ destination: Destination,
                          cleaner: SpeechPipelineTests.FakeCleaner = .init(reply: "unused"),
                          onResult: @escaping @Sendable (DictationResult) async -> Void = { _ in }) -> SpeechPipeline {
        SpeechPipeline(snippets: .init(snippets: []),
                       transcriber: PipelineReliabilityTests.NeverTranscribe(),
                       cleaner: cleaner, inserter: destination, editor: destination,
                       cleanupMode: .fast, onResult: onResult, onStatus: { _ in })
    }

    @Test func standaloneScratchDeletesBoundedTargetWithoutNetwork() async {
        let destination = Destination("Only the last Whisp insertion.")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "unused")
        await pipeline(destination, cleaner: cleaner).process(transcript: "Scratch that.")
        #expect(await destination.replacements == [""])
        #expect(await destination.inserted.isEmpty)
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func commandWithoutSafeTargetDoesNotPasteInstruction() async {
        let destination = Destination()
        await pipeline(destination).process(transcript: "Delete the last sentence.")
        #expect(await destination.replacements.isEmpty)
        #expect(await destination.inserted.isEmpty)
    }

    @Test func removeThisPartDeletesOnlyAnExplicitSelectionWithoutNetwork() async {
        let destination = Destination("Selected phrase", isExplicitSelection: true)
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "unused")
        await pipeline(destination, cleaner: cleaner).process(transcript: "Oh wait, remove this part please.")
        #expect(await destination.replacements == [""])
        #expect(await destination.inserted.isEmpty)
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func ambiguousPartRemovalPreservesUnselectedRecentDictation() async {
        let destination = Destination("A complete draft with several distinct parts.")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "unused")
        await pipeline(destination, cleaner: cleaner).process(transcript: "Oh wait, remove this part please.")
        #expect(await destination.replacements.isEmpty)
        #expect(await destination.inserted.isEmpty)
        #expect(await destination.text == "A complete draft with several distinct parts.")
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func deleteLastSentencePreservesEarlierText() async {
        let destination = Destination("The proposal is ready. The budget is tentative.")
        await pipeline(destination).process(transcript: "Delete the last sentence.")
        #expect(await destination.replacements == ["The proposal is ready."])
    }

    @Test func sameTurnRestartKeepsOnlyNewDraftWithoutNetwork() async {
        let destination = Destination()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "unused")
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "Send it today. Start over. Can you send it tomorrow?")
        #expect(await destination.inserted == ["Can you send it tomorrow?"])
        #expect(await destination.replacements.isEmpty)
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func selfCorrectionUsesOneRequiredInterpretation() async {
        let destination = Destination()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "Meet me Friday at three.")
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "Meet me Thursday, no, I mean Friday at three.")
        #expect(await destination.inserted == ["Meet me Friday at three."])
        #expect(cleaner.lastMessages.last?.content.contains("Thursday") == true)
    }

    @Test func failedInterpretationDoesNotPasteAnEditingInstruction() async {
        let destination = Destination()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "")
        cleaner.shouldThrow = true
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "Meet Thursday, no I mean Friday.")
        #expect(await destination.inserted.isEmpty)
    }

    @Test func rewriteRecentUsesReplacementInsteadOfAppend() async {
        let destination = Destination("hey can you send the file")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "Could you send the file?")
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "Rewrite what I just said more professionally.")
        #expect(await destination.preferredRecent == [true])
        #expect(await destination.replacements == ["Could you send the file?"])
        #expect(await destination.inserted.isEmpty)
    }

    @Test func spokenStyleAndSourceDoesNotReadOrReplacePriorDraft() async {
        let destination = Destination("Prior unrelated draft.")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "Could you send the proposal?")
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "Rewrite this more professionally: send me the proposal.")
        #expect(await destination.preferredRecent.isEmpty)
        #expect(await destination.replacements.isEmpty)
        #expect(await destination.inserted == ["Could you send the proposal?"])
    }

    @Test func cursorChangeRejectsLateRewriteWithoutAppending() async {
        let destination = Destination("Original text.")
        await destination.rejectEdits()
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "Edited text.")
        await pipeline(destination, cleaner: cleaner).process(transcript: "Make this shorter.")
        #expect(await destination.text == "Original text.")
        #expect(await destination.replacements.isEmpty)
        #expect(await destination.inserted.isEmpty)
    }

    @Test func cancellationBeforeDeletionLeavesTextIntact() async {
        let destination = Destination("Keep this.")
        let pipe = pipeline(destination, onResult: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { await pipe.process(transcript: "Scratch that.") }
        await task.value
        #expect(await destination.replacements.isEmpty)
    }

    @Test func quotedCommandsStayLiteral() async {
        let destination = Destination("Keep prior text.")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: "unused")
        await pipeline(destination, cleaner: cleaner).process(
            transcript: "The button says ‘delete that’.")
        #expect(await destination.inserted == ["The button says ‘delete that’."])
        #expect(await destination.replacements.isEmpty)
        #expect(cleaner.lastMessages.isEmpty)
    }

    @Test func removingOnlySentenceUsesExplicitDeletionMarker() async {
        let destination = Destination("Pricing is $500.")
        let cleaner = SpeechPipelineTests.FakeCleaner(reply: TranscriptCleaner.emptyEditMarker)
        await pipeline(destination, cleaner: cleaner).process(transcript: "Remove the sentence about pricing.")
        #expect(await destination.replacements == [""])
        #expect(await destination.inserted.isEmpty)
    }

    @Test func restartDoesNotExpandAbandonedSnippet() async {
        let destination = Destination()
        let pipe = SpeechPipeline(snippets: .init(snippets: [
            .init(keyword: "bug report", mode: .verbatim, content: "Wrong template")
        ]), transcriber: PipelineReliabilityTests.NeverTranscribe(),
            cleaner: SpeechPipelineTests.FakeCleaner(reply: "unused"), inserter: destination,
            cleanupMode: .fast, onStatus: { _ in })
        await pipe.process(transcript: "Bug report. Start over: Friday works.")
        #expect(await destination.inserted == ["Friday works."])
    }

    @Test func terminalRestartCancelsOnlyCurrentDraft() async {
        let destination = Destination("Keep prior text.")
        await pipeline(destination).process(transcript: "New draft. Start over.")
        #expect(await destination.replacements.isEmpty)
        #expect(await destination.inserted.isEmpty)
        #expect(await destination.text == "Keep prior text.")
    }
}
