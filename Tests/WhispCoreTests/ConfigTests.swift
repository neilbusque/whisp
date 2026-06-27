import Testing
import Foundation
@testable import WhispCore

@Suite struct ConfigTests {
    @Test func defaultsHaveSensibleValues() {
        let c = WhispConfig.defaults
        #expect(c.whisperModel == "ggml-base.en")
        #expect(c.hotkey == "fn")
        #expect(c.deepseekKey.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = WhispConfig(deepseekKey: "sk-x", hotkey: "fn",
                                   whisperModel: "ggml-small.en", snippetsPath: "/tmp/s.json")
        let decoded = try WhispConfig.load(from: original.encoded())
        #expect(decoded == original)
    }

    @Test func validatedThrowsOnEmptyDeepseekKey() {
        let c = WhispConfig(deepseekKey: "", hotkey: "fn",
                            whisperModel: "ggml-base.en", snippetsPath: "/tmp/s.json")
        #expect(throws: WhispConfigError.missingKey("deepseekKey")) {
            try c.validated()
        }
    }
}
