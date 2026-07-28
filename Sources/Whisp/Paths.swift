import Foundation
import WhispCore

enum Paths {
    static var dir: String { NSString(string: "~/.whisp").expandingTildeInPath }
    static var configFile: String { dir + "/config.json" }
    static var snippetsFile: String { dir + "/snippets.json" }
    static var vocabularyFile: String { dir + "/vocabulary.txt" }
    static var modelsDir: String { dir + "/models" }
    static var recordingsDir: String { dir + "/recordings" }
    static var sessionsFile: String { dir + "/sessions.json" }
    static var promptsFile: String { dir + "/prompts.json" }
    static var fillersFile: String { dir + "/fillers.txt" }

    static func recordingURL(filename: String) -> URL {
        URL(fileURLWithPath: recordingsDir + "/" + filename)
    }

    /// Writes 16 kHz mono samples as a 16-bit PCM WAV.
    static func writeRecording(samples: [Float], filename: String) throws {
        try FileManager.default.createDirectory(atPath: recordingsDir,
                                                withIntermediateDirectories: true)
        try WavCodec.encode(samples: samples).write(to: recordingURL(filename: filename))
    }

    static func loadFillers() -> [String] {
        guard let text = try? String(contentsOfFile: fillersFile, encoding: .utf8) else {
            return FillerList.parse(FillerList.seed)
        }
        return FillerList.parse(text)
    }

    static func loadPrompts() throws -> PromptStore {
        let data = try Data(contentsOf: URL(fileURLWithPath: promptsFile))
        return try PromptStore.load(from: data)
    }

    static func loadSessions() throws -> PracticeStore {
        let data = try Data(contentsOf: URL(fileURLWithPath: sessionsFile))
        return try PracticeStore.load(from: data)
    }

    /// Creates `~/.whisp` + `~/.whisp/models`, and seeds config.json /
    /// snippets.json with sensible defaults only if they don't already exist.
    /// Never overwrites a user's existing files.
    static func ensureSeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: configFile) {
            try WhispConfig.defaults.encoded().write(to: URL(fileURLWithPath: configFile))
        }
        if !fm.fileExists(atPath: snippetsFile) {
            let seed = [
                Snippet(keyword: "bug report template", mode: .verbatim,
                        content: "## Bug Report\n\n**Steps to reproduce:**\n1. \n\n**Expected:**\n\n**Actual:**\n"),
                Snippet(keyword: "cold email", mode: .ai,
                        content: "Write a short, friendly cold email. No em dashes. 70-110 words. Plain language."),
            ]
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(seed).write(to: URL(fileURLWithPath: snippetsFile))
        }
        if !fm.fileExists(atPath: vocabularyFile) {
            try seedVocabulary.write(toFile: vocabularyFile, atomically: true, encoding: .utf8)
        }

        try fm.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: fillersFile) {
            try FillerList.seed.write(toFile: fillersFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: promptsFile) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(PromptStore.seed).write(to: URL(fileURLWithPath: promptsFile))
        }
        if !fm.fileExists(atPath: sessionsFile) {
            try Data("[]".utf8).write(to: URL(fileURLWithPath: sessionsFile))
        }
    }

    /// Reads vocabulary.txt: one term per line, `#` comments and blanks ignored.
    static func loadVocabulary() -> [String] {
        guard let text = try? String(contentsOfFile: vocabularyFile, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Marketing + brand terms so Whisp hears Neil's jargon correctly out of the box.
    private static let seedVocabulary = """
    # Whisp vocabulary — one term per line. Lines starting with # are ignored.
    # These bias Whisper's transcription and tell the cleanup not to "correct" them.
    # Add your own names, brands, clients, and jargon below.

    # Brands & names
    Niruron
    Busque
    busqueneil
    Neil Busque
    Whisp
    Orbit
    Hatch
    DeepSeek
    GoHighLevel
    GHL
    Klaviyo
    HubSpot
    Shopify
    Meta Ads
    Google Ads

    # Marketing / SEO / paid search
    ROAS
    ROI
    CPC
    CPM
    CTR
    CPA
    CPL
    SERP
    SEO
    SEM
    PPC
    backlink
    backlinks
    retargeting
    remarketing
    lookalike audience
    UTM
    funnel
    landing page
    lead magnet
    nurture sequence
    cold email
    conversion rate
    cost per acquisition
    attribution
    impressions
    click-through rate
    organic traffic
    paid search
    programmatic
    schema markup
    canonical
    anchor text
    long-tail keyword
    A/B test

    """

    static func loadConfig() throws -> WhispConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: configFile))
        return try WhispConfig.load(from: data)
    }

    static func loadSnippets() throws -> SnippetStore {
        let data = try Data(contentsOf: URL(fileURLWithPath: snippetsFile))
        return try SnippetStore.load(from: data)
    }

    /// Prefer a model bundled in the app's Resources; else `~/.whisp/models`.
    static func modelPath(_ name: String) -> String {
        let bundled = Bundle.main.path(forResource: name, ofType: "bin")
        return bundled ?? (modelsDir + "/\(name).bin")
    }
}
