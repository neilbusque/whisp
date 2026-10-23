import Testing
import Foundation
@testable import WhispCore

@Suite struct ConfigTests {
    @Test func defaultsHaveSensibleValues() {
        let c = WhispConfig.defaults
        #expect(c.whisperModel == "ggml-small.en")
        #expect(c.cleanupMode == .fast)
        #expect(c.hotkey == "fn")
        #expect(c.deepseekKey.isEmpty)
        #expect(c.openaiKey.isEmpty)
        #expect(c.transcriptionMode == .local)
        #expect(c.transcriptionModel == "gpt-live-transcribe")
        #expect(c.textModel == "gpt-4.1-nano")
    }

    @Test func roundTripsThroughJSON() throws {
        let original = WhispConfig(hotkey: "fn",
                                   whisperModel: "ggml-small.en", snippetsPath: "/tmp/s.json",
                                   openaiKey: "sk-openai", transcriptionMode: .openai,
                                   cleanupMode: .smart)
        let decoded = try WhispConfig.load(from: original.encoded())
        #expect(decoded == original)
    }

    @Test func smartCleanupRequiresOpenAIKey() {
        let c = WhispConfig(deepseekKey: "sk-legacy", hotkey: "fn",
                            whisperModel: "ggml-base.en", snippetsPath: "/tmp/s.json", cleanupMode: .smart)
        #expect(throws: WhispConfigError.missingKey("openaiKey")) {
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
        #expect(c.openaiKey.isEmpty)
        #expect(c.transcriptionMode == .local)
        #expect(c.practiceHotkey == "ctrl+opt+cmd+r")
        #expect(c.pauseThresholdSec == 1.0)
        #expect(c.silenceRMSThreshold == 0.06)
        #expect(c.cleanupMode == .fast)
    }

    @Test func fastDictationWorksWithoutAKey() throws {
        #expect(try WhispConfig.defaults.validated().cleanupMode == .fast)
    }

    @Test func legacySmartConfigMigratesToFastWithoutReusingKey() throws {
        let legacy = Data(#"{"deepseekKey":"sk-legacy","cleanupMode":"smart"}"#.utf8)
        let c = try WhispConfig.load(from: legacy).validated()
        #expect(c.deepseekKey == "sk-legacy")
        #expect(c.openaiKey.isEmpty)
        #expect(c.transcriptionMode == .local)
        #expect(c.cleanupMode == .fast)
    }

    @Test func addingOpenAIKeyDoesNotImplicitlyEnableAudioUploads() throws {
        let data = Data(#"{"openaiKey":"sk-openai","cleanupMode":"smart"}"#.utf8)
        let c = try WhispConfig.load(from: data).validated()
        #expect(c.transcriptionMode == .local)
        #expect(c.cleanupMode == .smart)
    }

    @Test func cloudDictationRequiresOpenAIKeyEvenWithFastCleanup() {
        var c = WhispConfig.defaults
        c.transcriptionMode = .openai
        c.openaiKey = "  \n"
        #expect(throws: WhispConfigError.missingKey("openaiKey")) { try c.validated() }
    }

    @Test func explicitCloudModePersistsWithFastCleanup() throws {
        var c = WhispConfig.defaults
        c.transcriptionMode = .openai
        c.openaiKey = "sk-openai"
        let decoded = try WhispConfig.load(from: c.encoded()).validated()
        #expect(decoded.transcriptionMode == .openai)
        #expect(decoded.cleanupMode == .fast)
        #expect(decoded.openaiKey == "sk-openai")
    }

    @Test func newSmartConfigWithMissingKeyReportsError() throws {
        let data = Data(#"{"openaiKey":"","cleanupMode":"smart"}"#.utf8)
        let c = try WhispConfig.load(from: data)
        #expect(throws: WhispConfigError.missingKey("openaiKey")) { try c.validated() }
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
