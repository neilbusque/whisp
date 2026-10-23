import Foundation
import Testing
import WhispCore
@testable import Whisp

@Suite struct PathsSeedingTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WhispSeedTests-\(UUID())")
    }

    @Test func freshProfileUsesNeutralDefaultsAndPrivateConfig() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Paths.ensureSeeded(in: directory.path)

        let configURL = directory.appendingPathComponent("config.json")
        let config = try WhispConfig.load(from: Data(contentsOf: configURL))
        #expect(config.openaiKey.isEmpty)
        #expect(config.deepseekKey.isEmpty)
        #expect(config.transcriptionMode == .local)
        #expect(config.snippetsPath == directory.appendingPathComponent("snippets.json").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let vocabulary = try String(contentsOf: directory.appendingPathComponent("vocabulary.txt"),
                                    encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") }
            .map(String.init)
        #expect(vocabulary == ["Whisp", "OpenAI", "ChatGPT"])
        let context = try String(contentsOf: directory.appendingPathComponent("context.md"),
                                 encoding: .utf8)
        #expect(context.contains("<!-- Optional: add your name, role, and background."))
        #expect(!context.contains("I am "))
    }

    @Test func seedingPreservesEveryExistingProfileFile() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ["config.json", "snippets.json", "vocabulary.txt", "context.md",
                     "fillers.txt", "prompts.json", "sessions.json"]
        for file in files {
            try Data("User-owned contents for \(file)".utf8)
                .write(to: directory.appendingPathComponent(file))
        }

        try Paths.ensureSeeded(in: directory.path)
        for file in files {
            #expect(try Data(contentsOf: directory.appendingPathComponent(file)) ==
                    Data("User-owned contents for \(file)".utf8))
        }
    }

    @Test func repeatedSeedingDoesNotAppendVocabularyOrReplacePromptIDs() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Paths.ensureSeeded(in: directory.path)
        let files = ["vocabulary.txt", "prompts.json", "context.md", "config.json"]
        let original = try files.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        try Paths.ensureSeeded(in: directory.path)
        for (file, data) in zip(files, original) {
            #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == data)
        }
    }
}
