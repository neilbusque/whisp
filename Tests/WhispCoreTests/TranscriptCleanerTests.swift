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
}
