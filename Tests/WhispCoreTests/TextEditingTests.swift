import Foundation
import Testing
@testable import WhispCore

@Suite struct TextEditingTests {
    @Test func replacementsPreserveTextOutsideTheBoundedTarget() {
        let range = TextEditRange(location: 7, length: 5)
        #expect(range.text(in: "Before hello after") == "hello")
        #expect(range.replacing(in: "Before hello after", with: "goodbye") == "Before goodbye after")
        #expect(range.replacing(in: "Before hello after", with: "") == "Before  after")
    }

    @Test func usesUTF16OffsetsForEmoji() {
        let range = TextEditRange(location: 3, length: 5)
        #expect(range.text(in: "🙂 hello") == "hello")
        #expect(range.replacing(in: "🙂 hello", with: "hi") == "🙂 hi")
        #expect(TextEditRange(location: 1, length: 1).text(in: "🙂 hello") == nil)
        #expect(TextEditRange(location: 0, length: 1).text(in: "🙂 hello") == nil)
        #expect(TextEditRange(location: 1, length: 0).text(in: "🙂 hello") == nil)
        #expect(TextEditRange(location: 0, length: 2).text(in: "🙂 hello") == "🙂")
        #expect(TextEditRange(location: 2, length: 0).text(in: "🙂 hello") == "")
    }

    @Test func neverSplitsComposedUserVisibleCharacters() {
        #expect(TextEditRange(location: 0, length: 1).text(in: "e\u{301}clair") == nil)
        #expect(TextEditRange(location: 1, length: 1).text(in: "e\u{301}clair") == nil)
        #expect(TextEditRange(location: 0, length: 2).text(in: "e\u{301}clair") == "e\u{301}")
        #expect(TextEditRange(location: 0, length: 2).text(in: "👨‍👩‍👧‍👦!") == nil)
        #expect(TextEditRange(location: 2, length: 1).text(in: "👨‍👩‍👧‍👦!") == nil)
        #expect(TextEditRange(location: 0, length: 11).text(in: "👨‍👩‍👧‍👦!") == "👨‍👩‍👧‍👦")
        #expect(TextEditRange(location: 0, length: 2).text(in: "🇺🇸!") == nil)
        #expect(TextEditRange(location: 2, length: 2).text(in: "🇺🇸!") == nil)
        #expect(TextEditRange(location: 0, length: 4).text(in: "🇺🇸!") == "🇺🇸")
        #expect(TextEditRange(location: 0, length: 2).replacing(in: "👍🏽", with: "") == nil)
    }

    @Test func rejectsInvalidAndOverflowingRanges() {
        for range in [
            TextEditRange(location: -1, length: 1),
            TextEditRange(location: 0, length: -1),
            TextEditRange(location: 1, length: 4),
            TextEditRange(location: 4, length: 0),
            TextEditRange(location: Int.max, length: 1),
            TextEditRange(location: 1, length: Int.max)
        ] {
            #expect(range.text(in: "abc") == nil)
            #expect(range.replacing(in: "abc", with: "changed") == nil)
        }
    }

    @Test func acceptsEmptyCaretRangesAtValidBoundaries() {
        let range = TextEditRange(location: 3, length: 0)
        #expect(range.text(in: "abc") == "")
        #expect(range.replacing(in: "abc", with: "def") == "abcdef")
        #expect(TextEditRange(location: 0, length: 0).text(in: "") == "")
    }

    @Test func targetTokensDoNotConflateIdenticalText() {
        let first = TextEditTarget(text: "Same words")
        let next = TextEditTarget(text: "Same words")
        #expect(first != next)
        #expect(first == TextEditTarget(id: first.id, text: first.text))
        #expect(first != TextEditTarget(id: first.id, text: "Other words"))
    }
}
