import Foundation
import WhispCore

enum Paths {
    static var dir: String {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--data-dir"), args.indices.contains(flag + 1) {
            return URL(fileURLWithPath: args[flag + 1]).standardizedFileURL.path
        }
        return NSString(string: "~/.whisp").expandingTildeInPath
    }
    static var configFile: String { dir + "/config.json" }
    static var snippetsFile: String { dir + "/snippets.json" }
    static var vocabularyFile: String { dir + "/vocabulary.txt" }
    static var contextFile: String { dir + "/context.md" }
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
    static func ensureSeeded(in directory: String = dir) throws {
        let fm = FileManager.default
        let configFile = directory + "/config.json"
        let snippetsFile = directory + "/snippets.json"
        let vocabularyFile = directory + "/vocabulary.txt"
        let contextFile = directory + "/context.md"
        let fillersFile = directory + "/fillers.txt"
        let promptsFile = directory + "/prompts.json"
        let sessionsFile = directory + "/sessions.json"
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(atPath: directory + "/models", withIntermediateDirectories: true)

        if !fm.fileExists(atPath: configFile) {
            var seed = WhispConfig.defaults
            seed.snippetsPath = snippetsFile
            try seed.encoded().write(to: URL(fileURLWithPath: configFile), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile)
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
        if !fm.fileExists(atPath: contextFile) {
            try seedContext.write(toFile: contextFile, atomically: true, encoding: .utf8)
        }

        try fm.createDirectory(atPath: directory + "/recordings", withIntermediateDirectories: true)

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

    static func loadContext() -> String {
        (try? String(contentsOfFile: contextFile, encoding: .utf8)) ?? seedContext
    }

    /// A small neutral starting point. Personal terms belong in the user's file.
    private static let seedVocabulary = """
    # Whisp vocabulary: one term per line. Lines starting with # are ignored.
    # Add names, brands, technical terms, and their preferred spelling below.
    # These help transcription and preserve your spelling during cleanup.

    Whisp
    OpenAI
    ChatGPT

    """

    private static let seedContext = """
    # My writing context

    ## About me
    <!-- Optional: add your name, role, and background. Leave blank if unnecessary. -->

    ## What I work on
    <!-- Optional: add relevant topics, projects, or terminology. -->

    ## How my writing should sound
    Use clear, natural language. Preserve my intended meaning and real facts, names,
    numbers, links, promises, and constraints. Do not invent claims or results.
    <!-- Optional: add your preferred tone, audience, and formatting. -->
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
