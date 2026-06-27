import Foundation

public enum PipelineStatus: Equatable, Sendable {
    case idle, listening, transcribing, polishing
    case done(String)
    case error(String)
}

public protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}
public protocol Cleaning: Sendable {
    func complete(_ messages: [ChatMessage]) async throws -> String
}
public protocol TextInserting: Sendable {
    func insert(_ text: String) throws
}

public final class SpeechPipeline: @unchecked Sendable {
    private let snippets: SnippetStore
    private let transcriber: Transcribing
    private let cleaner: Cleaning
    private let inserter: TextInserting
    private let onStatus: (PipelineStatus) -> Void

    public init(snippets: SnippetStore, transcriber: Transcribing, cleaner: Cleaning,
                inserter: TextInserting, onStatus: @escaping (PipelineStatus) -> Void) {
        self.snippets = snippets
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.onStatus = onStatus
    }

    public func process(samples: [Float]) async {
        do {
            onStatus(.transcribing)
            let raw = try await transcriber.transcribe(samples)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onStatus(.error("Nothing heard"))
                return
            }

            let output: String
            if let m = snippets.match(transcript: trimmed) {
                switch m.snippet.mode {
                case .verbatim:
                    output = m.snippet.content
                case .ai:
                    onStatus(.polishing)
                    output = try await cleanOrFallback(
                        TranscriptCleaner.aiTemplatePrompt(template: m.snippet.content,
                                                           dictation: m.remainder),
                        fallback: m.remainder.isEmpty ? m.snippet.content : m.remainder)
                }
            } else {
                onStatus(.polishing)
                output = try await cleanOrFallback(
                    TranscriptCleaner.polishPrompt(raw: trimmed),
                    fallback: TranscriptCleaner.offlineClean(trimmed))
            }

            try inserter.insert(output)
            onStatus(.done(output))
        } catch {
            onStatus(.error(error.localizedDescription))
        }
    }

    private func cleanOrFallback(_ messages: [ChatMessage], fallback: String) async throws -> String {
        do {
            let result = try await cleaner.complete(messages)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            return fallback
        }
    }
}
