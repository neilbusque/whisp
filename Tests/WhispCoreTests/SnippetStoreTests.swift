import Testing
import Foundation
@testable import WhispCore

@Suite struct SnippetStoreTests {
    func store() -> SnippetStore {
        SnippetStore(snippets: [
            Snippet(id: UUID(), keyword: "Bug report template.", mode: .verbatim,
                    content: "## Bug Report", enabled: true),
            Snippet(id: UUID(), keyword: "cold email", mode: .ai,
                    content: "Write a short cold email.", enabled: true),
            Snippet(id: UUID(), keyword: "disabled one", mode: .verbatim,
                    content: "X", enabled: false),
        ])
    }

    @Test func normalizeLowercasesAndStripsPunctuation() {
        #expect(SnippetStore.normalize("Bug Report Template.") == "bug report template")
        #expect(SnippetStore.normalize("  cold,  EMAIL!  ") == "cold email")
    }

    @Test func matchesStartAnchoredVerbatim() {
        let m = store().match(transcript: "Bug report template")
        #expect(m?.snippet.mode == .verbatim)
        #expect(m?.remainder == "")
    }

    @Test func aiMatchExtractsRemainder() {
        let m = store().match(transcript: "cold email to a dentist about SEO")
        #expect(m?.snippet.mode == .ai)
        #expect(m?.remainder == "to a dentist about SEO")
    }

    @Test func noMatchWhenKeywordIsMidSentence() {
        #expect(store().match(transcript: "please send a cold email") == nil)
    }

    @Test func disabledSnippetsDoNotMatch() {
        #expect(store().match(transcript: "disabled one") == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let s = store()
        let decoded = try SnippetStore.load(from: s.encoded())
        #expect(decoded.all.count == s.all.count)
    }
}
