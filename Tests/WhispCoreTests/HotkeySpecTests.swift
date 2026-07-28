import Testing
@testable import WhispCore

@Suite struct HotkeySpecTests {
    @Test func parsesTheDefault() throws {
        let h = try #require(HotkeySpec.parse("ctrl+opt+cmd+r"))
        #expect(h.control && h.option && h.command)
        #expect(!h.shift)
        #expect(h.key == "r")
    }

    @Test func acceptsAliasesAndWhitespaceAndCase() throws {
        let a = try #require(HotkeySpec.parse("Control + Option + Command + R"))
        let b = try #require(HotkeySpec.parse("ctrl+alt+cmd+r"))
        #expect(a == b)
    }

    @Test func parsesDigitsAndSingleModifier() throws {
        let h = try #require(HotkeySpec.parse("cmd+7"))
        #expect(h.command && !h.control && !h.option && !h.shift)
        #expect(h.key == "7")
    }

    @Test func rejectsMalformedInput() {
        #expect(HotkeySpec.parse("") == nil)
        #expect(HotkeySpec.parse("ctrl+opt+cmd") == nil)        // no key
        #expect(HotkeySpec.parse("r") == nil)                    // no modifier
        #expect(HotkeySpec.parse("ctrl+opt+cmd+rr") == nil)      // multi-char key
        #expect(HotkeySpec.parse("ctrl+banana+r") == nil)        // unknown token
        #expect(HotkeySpec.parse("ctrl+r+p") == nil)             // two keys
        #expect(HotkeySpec.parse("fn+r") == nil)                 // fn is not supported here
    }

    @Test func rendersDisplayString() throws {
        let h = try #require(HotkeySpec.parse("ctrl+opt+cmd+r"))
        #expect(h.display == "⌃⌥⌘R")
        let s = try #require(HotkeySpec.parse("shift+cmd+p"))
        #expect(s.display == "⇧⌘P")
    }
}
