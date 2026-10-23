import Foundation
import Testing
@testable import WhispCore

@Suite struct RecognitionTests {
    @Test func shortUtteranceIsLongEnoughForWhisperWithoutLosingSamples() {
        let input = [Float](repeating: 0.5, count: 8_000)
        let result = DictationAudio.prepare(input)
        #expect(result.count >= 16_000)
        #expect(Array(result.prefix(input.count)) == input)
        #expect(result.dropFirst(input.count).allSatisfy { $0 == 0 })
    }

    @Test func quietSpeechIsAmplifiedWithoutClippingOrChangingRelativeLevels() {
        let result = DictationAudio.prepare([0.01, -0.02, 0.04, 0])
        #expect(abs(result[0] - 0.08) < 0.0001)
        #expect(abs(result[1] + 0.16) < 0.0001)
        #expect(abs(result[2] - 0.32) < 0.0001)
        #expect(result[3] == 0)
        #expect(result.allSatisfy { abs($0) <= 1 })
    }

    @Test func loudSpeechIsNotAmplified() {
        #expect(Array(DictationAudio.prepare([0.8, -0.9]).prefix(2)) == [0.8, -0.9])
        #expect(DictationAudio.prepare([2, -2]).prefix(2).allSatisfy { abs($0) <= 1 })
    }

    @Test func emptyAndSilentAudioDoNotBecomeSpeech() {
        #expect(DictationAudio.prepare([]).isEmpty)
        #expect(DictationAudio.prepare([0, 0]).isEmpty)
        #expect(DictationAudio.prepare([.nan, .infinity]).isEmpty)
    }

    @Test func longDictationRetainsItsFullDurationAndAddsOnlyATail() {
        let input = [Float](repeating: 0.5, count: 16_000 * 42)
        let result = DictationAudio.prepare(input)
        #expect(result.count == input.count + 4_000)
        #expect(Array(result.prefix(input.count)) == input)
    }

    @Test func vocabularyKeepsPriorityNamesAndWholeTermsWithinBudget() {
        let result = RecognitionPrompt.make(
            vocabulary: ["Neil Busque", "Whisp", "a very long term that does not fit", "CRM"],
            tokenLimit: 26, tokenCount: { $0.count })
        #expect(result == "Neil Busque, Whisp, CRM.")
        #expect(result.count <= 26)
    }

    @Test func vocabularyDeduplicatesAndHandlesAnEmptyBudget() {
        let vocabulary = [" Whisp ", "whisp", "", "CRM"]
        #expect(RecognitionPrompt.make(vocabulary: vocabulary, tokenLimit: 20,
                                     tokenCount: { $0.count }) == "Whisp, CRM.")
        #expect(RecognitionPrompt.make(vocabulary: vocabulary, tokenLimit: 0,
                                     tokenCount: { $0.count }).isEmpty)
    }

    @Test(arguments: [
        "I like this design.",
        "Make it look like my website.",
        "Do you know when it launches?",
        "I mean tomorrow, not today.",
        "I don't like that; keep the original.",
        "Ah, that is what I meant."
    ])
    func cleanupPreservesWordsThatExpressMeaning(_ spoken: String) {
        #expect(TranscriptCleaner.offlineClean(spoken) == spoken)
    }
}
