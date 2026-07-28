import Testing
@testable import WhispCore

@Suite struct TranscriptCleanerTests {
    @Test func polishPromptCarriesRawTextInUserMessage() {
        let msgs = TranscriptCleaner.polishPrompt(raw: "um so like i went there")
        #expect(msgs.first?.role == "system")
        #expect(msgs.last?.role == "user")
        #expect(msgs.last?.content.contains("um so like i went there") == true)
    }

    @Test func aiTemplatePromptCombinesTemplateAndDictation() {
        let msgs = TranscriptCleaner.aiTemplatePrompt(
            template: "Write a cold email.", dictation: "to a dentist")
        #expect(msgs.last?.content.contains("Write a cold email.") == true)
        #expect(msgs.last?.content.contains("to a dentist") == true)
    }

    @Test func offlineCleanStripsFillerAndCapitalizes() {
        let out = TranscriptCleaner.offlineClean("um so i uh went to the store")
        #expect(!out.lowercased().contains(" um "))
        #expect(!out.lowercased().contains(" uh "))
        #expect(out.first == "I" || out.hasPrefix("So"))
    }

    @Test func offlineCleanAddsTerminalPunctuation() {
        let out = TranscriptCleaner.offlineClean("hello there")
        #expect(out.hasSuffix(".") || out.hasSuffix("?") || out.hasSuffix("!"))
    }

    @Test func polishPromptInjectsVocabularyTerms() {
        let msgs = TranscriptCleaner.polishPrompt(raw: "hi", vocabulary: ["Niruron", "ROAS"])
        #expect(msgs.first?.content.contains("Niruron") == true)
        #expect(msgs.first?.content.contains("ROAS") == true)
    }

    @Test func polishPromptOmitsVocabularyClauseWhenEmpty() {
        let msgs = TranscriptCleaner.polishPrompt(raw: "hi")
        #expect(msgs.first?.content.contains("preserve them exactly") == false)
    }

    @Test func aiTemplatePromptInjectsVocabularyTerms() {
        let msgs = TranscriptCleaner.aiTemplatePrompt(
            template: "Write an email.", dictation: "to a client", vocabulary: ["GoHighLevel"])
        #expect(msgs.first?.content.contains("GoHighLevel") == true)
    }

    private func sampleMetrics() -> SpeechMetrics {
        SpeechMetrics(wordCount: 42, durationSec: 30, speakingDurationSec: 28,
                      wpm: 132, fillerCounts: ["um": 3], totalFillers: 3,
                      fillerRate: 7.1, pauses: [], pauseCount: 2,
                      longestPauseSec: 1.4, silenceRatio: 0.1)
    }

    @Test func coachPromptCarriesTranscriptInUserMessage() {
        let msgs = TranscriptCleaner.coachPrompt(
            transcript: "so basically um the product helps you save time",
            promptTitle: "Tell me about your product", metrics: sampleMetrics())
        #expect(msgs.last?.role == "user")
        #expect(msgs.last?.content.contains(
            "so basically um the product helps you save time") == true)
    }

    @Test func coachPromptCarriesPromptTitle() {
        let msgs = TranscriptCleaner.coachPrompt(
            transcript: "some answer", promptTitle: "Why should we hire you?",
            metrics: sampleMetrics())
        #expect(msgs.first?.content.contains("Why should we hire you?") == true)
    }

    @Test func coachPromptCarriesMetricNumbers() {
        let msgs = TranscriptCleaner.coachPrompt(
            transcript: "some answer", promptTitle: "A prompt", metrics: sampleMetrics())
        let userContent = msgs.last?.content ?? ""
        #expect(userContent.contains("132"))
        #expect(userContent.contains("7.1"))
        #expect(userContent.contains("2 pauses"))
        #expect(userContent.contains("1.4"))
    }

    @Test func coachPromptNeverLeaksAudioRelatedTokens() {
        let msgs = TranscriptCleaner.coachPrompt(
            transcript: "some answer", promptTitle: "A prompt", metrics: sampleMetrics())
        let joined = msgs.map(\.content).joined(separator: "\n").lowercased()
        for token in [".wav", "/recordings/", "filename", "file path", "envelope", "samples"] {
            #expect(!joined.contains(token), "leaked audio-related token: \(token)")
        }
    }
}
