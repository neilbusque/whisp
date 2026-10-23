import Foundation

public enum CleanupMode: String, Codable, CaseIterable, Sendable {
    /// Purely local filler removal and punctuation cleanup. No network wait.
    case fast
    /// OpenAI polish with the local cleaner as a bounded fallback.
    case smart
}

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    /// Audio stays on this Mac and is processed after recording.
    case local
    /// Dictation audio streams to OpenAI while Fn is held.
    case openai
}

public struct WhispConfig: Codable, Equatable, Sendable {
    public static let defaultTranscriptionModel = "gpt-live-transcribe"
    public static let defaultTextModel = "gpt-4.1-nano"

    /// Retained only to load older config files. Never used for OpenAI requests.
    public var deepseekKey: String
    public var openaiKey: String
    public var transcriptionMode: TranscriptionMode
    public var transcriptionModel: String
    public var textModel: String
    public var hotkey: String
    public var whisperModel: String
    public var snippetsPath: String
    public var cleanupMode: CleanupMode
    public var keepHistory: Bool
    public var saveVoiceExamples: Bool

    // Practice Mode. All three decode to their defaults when absent, so a
    // config.json written before Practice Mode existed still loads.
    public var practiceHotkey: String
    /// Minimum silence, in seconds, before a gap counts as a pause.
    public var pauseThresholdSec: Double
    /// Compared against AudioRecorder's ALREADY-SCALED level,
    /// `min(1, sqrt(meanSquare) * 4)` — not against raw RMS.
    public var silenceRMSThreshold: Double

    public init(deepseekKey: String = "", hotkey: String, whisperModel: String,
                snippetsPath: String,
                openaiKey: String = "", transcriptionMode: TranscriptionMode = .local,
                transcriptionModel: String = WhispConfig.defaultTranscriptionModel,
                textModel: String = WhispConfig.defaultTextModel,
                cleanupMode: CleanupMode = .fast,
                keepHistory: Bool = true, saveVoiceExamples: Bool = false,
                practiceHotkey: String = "ctrl+opt+cmd+r",
                pauseThresholdSec: Double = 1.0,
                silenceRMSThreshold: Double = 0.06) {
        self.deepseekKey = deepseekKey
        self.openaiKey = openaiKey
        self.transcriptionMode = transcriptionMode
        self.transcriptionModel = transcriptionModel
        self.textModel = textModel
        self.hotkey = hotkey
        self.whisperModel = whisperModel
        self.snippetsPath = snippetsPath
        self.cleanupMode = cleanupMode
        self.keepHistory = keepHistory
        self.saveVoiceExamples = saveVoiceExamples
        self.practiceHotkey = practiceHotkey
        self.pauseThresholdSec = pauseThresholdSec
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case deepseekKey, hotkey, whisperModel, snippetsPath
        case openaiKey, transcriptionMode, transcriptionModel, textModel
        case cleanupMode, keepHistory, saveVoiceExamples
        case practiceHotkey, pauseThresholdSec, silenceRMSThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WhispConfig.defaults
        deepseekKey = try c.decodeIfPresent(String.self, forKey: .deepseekKey) ?? ""
        openaiKey = try c.decodeIfPresent(String.self, forKey: .openaiKey) ?? ""
        // A missing field must never silently opt an existing user into audio uploads.
        transcriptionMode = try c.decodeIfPresent(TranscriptionMode.self, forKey: .transcriptionMode) ?? .local
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? d.transcriptionModel
        textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? d.textModel
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        snippetsPath = try c.decodeIfPresent(String.self, forKey: .snippetsPath) ?? d.snippetsPath
        cleanupMode = try c.decodeIfPresent(CleanupMode.self, forKey: .cleanupMode) ?? d.cleanupMode
        // DeepSeek credentials do not transfer. Keep legacy dictation usable until
        // the user adds their OpenAI key and chooses Smart cleanup again.
        if !c.contains(.openaiKey) && cleanupMode == .smart {
            cleanupMode = .fast
        }
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? true
        saveVoiceExamples = try c.decodeIfPresent(Bool.self, forKey: .saveVoiceExamples) ?? false
        practiceHotkey = try c.decodeIfPresent(String.self, forKey: .practiceHotkey) ?? d.practiceHotkey
        pauseThresholdSec = try c.decodeIfPresent(Double.self, forKey: .pauseThresholdSec) ?? d.pauseThresholdSec
        silenceRMSThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceRMSThreshold) ?? d.silenceRMSThreshold
    }

    public static var defaults: WhispConfig {
        WhispConfig(deepseekKey: "", hotkey: "fn",
                    whisperModel: "ggml-small.en",
                    snippetsPath: NSString(string: "~/.whisp/snippets.json").expandingTildeInPath,
                    cleanupMode: .fast,
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
        if (cleanupMode == .smart || transcriptionMode == .openai)
            && openaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WhispConfigError.missingKey("openaiKey")
        }
        guard whisperModel.range(of: #"^ggml-[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw WhispConfigError.invalid("Choose a valid Whisper model.")
        }
        guard [transcriptionModel, textModel].allSatisfy({
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        }) else {
            throw WhispConfigError.invalid("Choose a valid OpenAI model.")
        }
        guard pauseThresholdSec.isFinite, (0.1...10).contains(pauseThresholdSec),
              silenceRMSThreshold.isFinite, (0...1).contains(silenceRMSThreshold) else {
            throw WhispConfigError.invalid("Practice thresholds are outside the supported range.")
        }
        return self
    }
}

public enum WhispConfigError: LocalizedError, Equatable {
    case missingKey(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an OpenAI API key for cloud dictation and AI writing, or choose local recognition with Fast cleanup."
        case .invalid(let text): return text
        }
    }
}
