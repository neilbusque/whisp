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

    @Test func decodesLegacyConfigMissingPracticeKeys() throws {
        // A config.json written by v1, before Practice Mode existed.
        let legacy = """
        {"deepseekKey":"sk-x","hotkey":"fn","snippetsPath":"/tmp/s.json","whisperModel":"ggml-base.en"}
        """.data(using: .utf8)!
        let c = try WhispConfig.load(from: legacy)
        #expect(c.deepseekKey == "sk-x")
        #expect(c.practiceHotkey == "ctrl+opt+cmd+r")
        #expect(c.pauseThresholdSec == 1.0)
        #expect(c.silenceRMSThreshold == 0.06)
    }

    @Test func practiceDefaultsAreSet() {
        let c = WhispConfig.defaults
        #expect(c.practiceHotkey == "ctrl+opt+cmd+r")
        #expect(c.pauseThresholdSec == 1.0)
        #expect(c.silenceRMSThreshold == 0.06)
    }

    @Test func roundTripsPracticeKeys() throws {
        let original = WhispConfig(deepseekKey: "sk-x", hotkey: "fn",
                                   whisperModel: "ggml-base.en", snippetsPath: "/tmp/s.json",
                                   practiceHotkey: "ctrl+cmd+p", pauseThresholdSec: 2.5,
                                   silenceRMSThreshold: 0.1)
        let decoded = try WhispConfig.load(from: original.encoded())
        #expect(decoded == original)
    }
}
