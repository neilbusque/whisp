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
    func insert(_ text: String) async throws
}
public protocol SelectedTextReading: Sendable {
    func readSelectedText() async throws -> String?
}

public final class SpeechPipeline: @unchecked Sendable {
    private let snippets: SnippetStore
    private let transcriber: Transcribing
    private let cleaner: Cleaning
    private let inserter: TextInserting
    private let selectionReader: SelectedTextReading?
    private let editor: TextEditing?
    private let vocabulary: [String]
    private let cleanupMode: CleanupMode
    private let profileContext: String
    private let onStatus: (PipelineStatus) -> Void
    private let corrections: @Sendable () async -> [CorrectionRule]
    private let onResult: @Sendable (DictationResult) async -> Void
    private let processLock = NSLock()
    private var processing = false

    public init(snippets: SnippetStore, transcriber: Transcribing, cleaner: Cleaning,
                inserter: TextInserting, selectionReader: SelectedTextReading? = nil,
                editor: TextEditing? = nil,
                vocabulary: [String] = [], profileContext: String = "",
                cleanupMode: CleanupMode = .smart,
                corrections: @escaping @Sendable () async -> [CorrectionRule] = { [] },
                onResult: @escaping @Sendable (DictationResult) async -> Void = { _ in },
                onStatus: @escaping (PipelineStatus) -> Void) {
        self.snippets = snippets
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.selectionReader = selectionReader
        self.editor = editor
        self.vocabulary = vocabulary
        self.profileContext = profileContext
        self.cleanupMode = cleanupMode
        self.onStatus = onStatus
        self.corrections = corrections
        self.onResult = onResult
    }

    public func process(samples: [Float]) async {
        await process(samples: samples, transcript: nil)
    }

    /// Reuse corrections, commands, snippets and safe insertion after live recognition.
    public func process(transcript: String) async {
        await process(samples: [], transcript: transcript)
    }

    /// Side-effect-free preparation from live speech. Selection-dependent edits
    /// are resolved only from the final transcript and freshly verified target.
    public func previewMessages(for transcript: String) async -> [ChatMessage]? {
        let rules = await corrections()
        let effectiveVocabulary = rules.filter(\.enabled).map(\.intended) + vocabulary
        let corrected = CorrectionEngine(rules: rules).apply(transcript) {
            VocabularyCorrector.correct($0, vocabulary: vocabulary)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return nil }
        let edit = SpokenEdit.parse(corrected)
        let intended: String
        if case .dictation(let text) = edit { intended = text } else { intended = corrected }
        guard !intended.isEmpty, RewriteCommand.parse(intended) == nil,
              snippets.match(transcript: intended) == nil else { return nil }
        switch edit {
        case .command: return nil
        case .interpret(let text):
            return TranscriptCleaner.dictationPrompt(raw: text, vocabulary: effectiveVocabulary)
        case .dictation(let text):
            if case .interpret(let draft) = SpokenEdit.parse(text) {
                return TranscriptCleaner.dictationPrompt(raw: draft, vocabulary: effectiveVocabulary)
            }
            return cleanupMode == .smart
                ? TranscriptCleaner.polishPrompt(raw: text, vocabulary: effectiveVocabulary) : nil
        }
    }

    private func process(samples: [Float], transcript: String?) async {
        // Do not queue dictations that could land at a different cursor later.
        guard processLock.withLock({
            if processing { return false }
            processing = true
            return true
        }) else { return }
        defer { processLock.withLock { processing = false } }
        do {
            onStatus(.transcribing)
            let raw: String
            if let transcript { raw = transcript }
            else { raw = try await transcriber.transcribe(samples) }
            try Task.checkCancellation()
            let rules = await corrections()
            let effectiveVocabulary = rules.filter(\.enabled).map(\.intended) + vocabulary
            let corrected = CorrectionEngine(rules: rules).apply(raw) {
                VocabularyCorrector.correct($0, vocabulary: vocabulary)
            }
            let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onStatus(.error("Nothing heard"))
                return
            }

            let output: String
            var editTarget: TextEditTarget?
            var allowsDeletion = false
            let spokenEdit = SpokenEdit.parse(trimmed)
            let intended: String
            if case .dictation(let dictation) = spokenEdit { intended = dictation }
            else { intended = trimmed }
            if intended.isEmpty {
                onStatus(.done(""))
                return
            }
            if let rewrite = RewriteCommand.parse(intended) {
                let source: String
                if rewrite.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let editor {
                    editTarget = try await editor.prepareEdit(preferRecent: rewrite.prefersRecentText)
                    source = editTarget?.text ?? ""
                } else {
                    source = try await rewriteSource(for: rewrite)
                }
                guard !source.isEmpty else {
                    onStatus(.error("Select text or dictate what to rewrite"))
                    return
                }
                onStatus(.polishing)
                let rewritten = try await completeRequired(
                    TranscriptCleaner.rewritePrompt(
                        source: source, instruction: rewrite.instruction,
                        profileContext: profileContext, vocabulary: effectiveVocabulary,
                        allowDeletion: rewrite.isRemoval))
                if rewrite.isRemoval, rewritten == TranscriptCleaner.emptyEditMarker {
                    output = ""
                    allowsDeletion = true
                } else {
                    output = rewritten
                }
            } else if let m = snippets.match(transcript: intended) {
                switch m.snippet.mode {
                case .verbatim:
                    output = m.snippet.content
                case .ai:
                    onStatus(.polishing)
                    output = try await cleanOrFallback(
                        TranscriptCleaner.aiTemplatePrompt(template: m.snippet.content,
                                                           dictation: m.remainder,
                                                           vocabulary: effectiveVocabulary),
                        fallback: TranscriptCleaner.offlineClean(m.remainder))
                }
            } else {
                switch spokenEdit {
                case .command(let command):
                    guard let editor,
                          let target = try await editor.prepareEdit(preferRecent: false) else {
                        onStatus(.error("Select text or keep the cursor after your last dictation"))
                        return
                    }
                    guard !command.requiresSelection || target.isExplicitSelection else {
                        onStatus(.error("Select the part to remove, then say it again"))
                        return
                    }
                    editTarget = target
                    if case .replace(let replacement) = command {
                        output = try await prepareDictation(replacement, vocabulary: effectiveVocabulary)
                    } else {
                        output = SpokenEdit.applying(command, to: target.text)
                    }
                    allowsDeletion = true
                case .interpret(let dictation):
                    onStatus(.polishing)
                    // Never paste a spoken editing instruction if the model
                    // fails. The user can retry without corrupting the draft.
                    output = try await completeRequired(
                        TranscriptCleaner.dictationPrompt(raw: dictation, vocabulary: effectiveVocabulary))
                case .dictation(let dictation):
                    output = try await prepareDictation(dictation, vocabulary: effectiveVocabulary)
                }
            }

            guard allowsDeletion || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onStatus(.error("Nothing heard"))
                return
            }
            try Task.checkCancellation()
            await onResult(DictationResult(raw: raw, output: output))
            try Task.checkCancellation()
            if let editTarget, let editor {
                try await editor.replace(editTarget, with: output)
            } else {
                try await inserter.insert(output)
            }
            onStatus(.done(output))
        } catch {
            onStatus(.error(error.localizedDescription))
        }
    }

    private func prepareDictation(_ text: String, vocabulary: [String]) async throws -> String {
        // A locally resolved restart may itself contain another correction.
        if case .interpret(let dictation) = SpokenEdit.parse(text) {
            onStatus(.polishing)
            return try await completeRequired(
                TranscriptCleaner.dictationPrompt(raw: dictation, vocabulary: vocabulary))
        }
        switch cleanupMode {
        case .fast: return TranscriptCleaner.offlineClean(text)
        case .smart:
            onStatus(.polishing)
            return try await cleanOrFallback(
                TranscriptCleaner.polishPrompt(raw: text, vocabulary: vocabulary),
                fallback: TranscriptCleaner.offlineClean(text))
        }
    }

    private func cleanOrFallback(_ messages: [ChatMessage], fallback: String) async throws -> String {
        do {
            let result = try await cleaner.complete(messages)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            try Task.checkCancellation()
            return fallback
        }
    }

    private func completeRequired(_ messages: [ChatMessage]) async throws -> String {
        let result = try await cleaner.complete(messages)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw NSError(domain: "Whisp.Rewrite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Rewrite returned no text"])
        }
        return result
    }

    private func rewriteSource(for command: RewriteCommand) async throws -> String {
        let spoken = command.spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty { return spoken }
        return try await selectionReader?.readSelectedText()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
