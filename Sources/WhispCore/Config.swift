import Foundation

public struct WhispConfig: Codable, Equatable {
    public var deepseekKey: String
    public var hotkey: String
    public var whisperModel: String
    public var snippetsPath: String

    // Practice Mode. All three decode to their defaults when absent, so a
    // config.json written before Practice Mode existed still loads.
    public var practiceHotkey: String
    /// Minimum silence, in seconds, before a gap counts as a pause.
    public var pauseThresholdSec: Double
    /// Compared against AudioRecorder's ALREADY-SCALED level,
    /// `min(1, sqrt(meanSquare) * 4)` — not against raw RMS.
    public var silenceRMSThreshold: Double

    public init(deepseekKey: String, hotkey: String, whisperModel: String,
                snippetsPath: String,
                practiceHotkey: String = "ctrl+opt+cmd+r",
                pauseThresholdSec: Double = 1.0,
                silenceRMSThreshold: Double = 0.06) {
        self.deepseekKey = deepseekKey
        self.hotkey = hotkey
        self.whisperModel = whisperModel
        self.snippetsPath = snippetsPath
        self.practiceHotkey = practiceHotkey
        self.pauseThresholdSec = pauseThresholdSec
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case deepseekKey, hotkey, whisperModel, snippetsPath
        case practiceHotkey, pauseThresholdSec, silenceRMSThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WhispConfig.defaults
        deepseekKey = try c.decodeIfPresent(String.self, forKey: .deepseekKey) ?? ""
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        snippetsPath = try c.decodeIfPresent(String.self, forKey: .snippetsPath) ?? d.snippetsPath
        practiceHotkey = try c.decodeIfPresent(String.self, forKey: .practiceHotkey) ?? d.practiceHotkey
        pauseThresholdSec = try c.decodeIfPresent(Double.self, forKey: .pauseThresholdSec) ?? d.pauseThresholdSec
        silenceRMSThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceRMSThreshold) ?? d.silenceRMSThreshold
    }

    public static var defaults: WhispConfig {
        WhispConfig(deepseekKey: "", hotkey: "fn",
                    whisperModel: "ggml-base.en",
                    snippetsPath: NSString(string: "~/.whisp/snippets.json").expandingTildeInPath,
                    practiceHotkey: "ctrl+opt+cmd+r",
                    pauseThresholdSec: 1.0,
                    silenceRMSThreshold: 0.06)
    }

    public static func load(from data: Data) throws -> WhispConfig {
        try JSONDecoder().decode(WhispConfig.self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func validated() throws -> WhispConfig {
        if deepseekKey.isEmpty { throw WhispConfigError.missingKey("deepseekKey") }
        return self
    }
}

public enum WhispConfigError: Error, Equatable {
    case missingKey(String)
}
