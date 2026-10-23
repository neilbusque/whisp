import Foundation
import Testing
@testable import WhispCore

@Suite struct LearningTests {
    @Test func matchesWholeWordsAndFlexibleSpacing() {
        let engine = CorrectionEngine(rules: [.init(heard: "pyre o s", intended: "PyreOS")])
        #expect(engine.apply("Use PYRE  O S, then pyre o s.") == "Use PyreOS, then PyreOS.")
        #expect(engine.apply("xpyre o s and pyre o systems") == "xpyre o s and pyre o systems")
    }
    @Test func handlesUnicodeAndLiteralReplacementCharacters() {
        let engine = CorrectionEngine(rules: [.init(heard: "cafe", intended: "Café $1 \\ notes")])
        #expect(engine.apply("cafe / cafeteria / écafe") == "Café $1 \\ notes / cafeteria / écafe")
    }
    @Test func longestPhraseWinsWithoutCascading() {
        let engine = CorrectionEngine(rules: [.init(heard: "alpha", intended: "beta"),
            .init(heard: "beta", intended: "gamma"), .init(heard: "alpha beta", intended: "product")])
        #expect(engine.apply("alpha beta; alpha; beta") == "product; beta; gamma")
    }
    @Test func personalCorrectionsTakePriorityOverBuiltInAliases() {
        let engine = CorrectionEngine(rules: [.init(heard: "super base", intended: "MyBase")])
        let result = engine.apply("Connect Super Base and Go High Level.") {
            VocabularyCorrector.correct($0, vocabulary: ["Supabase", "GoHighLevel"])
        }
        #expect(result == "Connect MyBase and GoHighLevel.")
    }
    @Test func disablingRuleRestoresOriginalText() {
        let engine = CorrectionEngine(rules: [.init(heard: "clod", intended: "Claude", enabled: false)])
        #expect(engine.apply("clod") == "clod")
    }
    @Test func rejectsEmptyIdenticalAndOversizedRules() {
        for rule in [CorrectionRule(heard: " ", intended: "x"), .init(heard: "x", intended: ""),
                     .init(heard: "x", intended: "x"), .init(heard: String(repeating: "x", count: 201), intended: "y")] {
            #expect(throws: LearningError.self) { try rule.validated() }
        }
    }
    @Test func validatesDuplicateAliasesButAllowsEditing() throws {
        var data = LearningData()
        let rule = CorrectionRule(heard: "clod", intended: "Claude")
        try data.saveRule(rule)
        #expect(throws: LearningError.self) { try data.saveRule(.init(heard: "CLOD", intended: "Cloud")) }
        var edited = rule; edited.intended = "Cloud"; try data.saveRule(edited)
        #expect(data.rules.count == 1)
        #expect(data.rules[0].intended == "Cloud")
    }
    @Test func capsHistoryAndReturnsEvictedAudioReferences() {
        var data = LearningData()
        let first = DictationEntry(raw: "one", output: "One.", model: "small", duration: 1, processingSeconds: 1, hasAudio: true)
        data.append(first, limit: 1)
        let removed = data.append(.init(raw: "two", output: "Two.", model: "small", duration: 1, processingSeconds: 1), limit: 1)
        #expect(removed == [first]); #expect(data.entries.count == 1)
        #expect(data.entries[0].raw == "two")
    }
    @Test func learningDataRoundTripsReferencesAndRules() throws {
        var data = LearningData()
        try data.saveRule(.init(heard: "clod", intended: "Claude"))
        var entry = DictationEntry(raw: "clod", output: "Claude.", model: "small", duration: 1, processingSeconds: 2, hasAudio: true)
        entry.reference = "Claude"
        data.append(entry)
        #expect(try LearningData.load(data.encoded()) == data)
        #expect(!entry.audioFilename.contains("/"))
    }
    @Test func importMergesByPhraseAndIsAtomicOnInvalidData() throws {
        var data = LearningData()
        try data.saveRule(.init(heard: "pyre o s", intended: "Old"))
        let id = data.rules[0].id
        try data.importRules([.init(heard: "PYRE  O S", intended: "PyreOS")])
        #expect(data.rules.count == 1)
        #expect(data.rules[0].id == id)
        #expect(data.rules[0].intended == "PyreOS")
        let saved = data
        #expect(throws: LearningError.self) {
            try data.importRules([.init(heard: "clod", intended: "Claude"), .init(heard: "", intended: "invalid")])
        }
        #expect(data == saved)
    }

    @Test func refusesNewerOrCorruptDataInsteadOfResetting() throws {
        #expect(throws: (any Error).self) { try LearningData.load(Data("broken".utf8)) }
        var data = LearningData(); data.version = 20
        #expect(throws: LearningError.self) { try LearningData.load(data.encoded()) }
    }
}
