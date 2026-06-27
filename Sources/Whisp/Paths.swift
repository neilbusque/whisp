import Foundation
import WhispCore

enum Paths {
    static var dir: String { NSString(string: "~/.whisp").expandingTildeInPath }
    static var configFile: String { dir + "/config.json" }
    static var snippetsFile: String { dir + "/snippets.json" }
    static var modelsDir: String { dir + "/models" }

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
    }

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
