import Testing
@testable import WhispCore

@Suite struct VocabularyCorrectorTests {
    @Test func correctsExplicitVocabularyNearMisses() {
        let raw = "Wisp works with Go High Level, Deepseag, and Data for SEO."
        let corrected = VocabularyCorrector.correct(raw,
            vocabulary: ["Whisp", "GoHighLevel", "DeepSeek", "DataForSEO"])
        #expect(corrected == "Whisp works with GoHighLevel, DeepSeek, and DataForSEO.")
    }

    @Test func restoresCanonicalDictionaryCasing() {
        let corrected = VocabularyCorrector.correct(
            "we use crm, shopify, ga4 and meta ads",
            vocabulary: ["CRM", "Shopify", "GA4", "Meta Ads"])
        #expect(corrected == "we use CRM, Shopify, GA4 and Meta Ads")
    }

    @Test func correctsCommonSpokenToolForms() {
        let corrected = VocabularyCorrector.correct(
            "Connect N eight N to Super Base, Word Press, and Chat G P T.",
            vocabulary: ["n8n", "Supabase", "WordPress", "ChatGPT"])
        #expect(corrected == "Connect n8n to Supabase, WordPress, and ChatGPT.")
    }

    @Test func aliasesDoNotOverrideOrdinaryWordsWithoutVocabulary() {
        let raw = "A wisp of smoke, a smart lead, and an active campaign."
        #expect(VocabularyCorrector.correct(raw, vocabulary: []) == raw)
    }

    @Test func onlyEnabledAliasesAreApplied() {
        let raw = "Use Super Base and Word Press."
        #expect(VocabularyCorrector.correct(raw, vocabulary: ["Supabase"]) ==
                "Use Supabase and Word Press.")
    }

    @Test func vocabularyEnablesAliasesWithoutCaseOrWhitespaceSensitivity() {
        #expect(VocabularyCorrector.correct("Use Super Base.", vocabulary: ["  SUPABASE  "]) ==
                "Use Supabase.")
    }

    @Test func doesNotChangeUnrelatedWords() {
        let raw = "The clay model is linked in the notes, and the deep sea is blue."
        let corrected = VocabularyCorrector.correct(raw, vocabulary: [])
        #expect(corrected == raw)
    }
}
