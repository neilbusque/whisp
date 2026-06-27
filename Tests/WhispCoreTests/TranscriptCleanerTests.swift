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
}
