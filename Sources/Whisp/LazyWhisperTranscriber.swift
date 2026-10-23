import Foundation
import WhispCore

/// Cloud dictation never has to load the local model. Practice and offline
/// fallback share one lazily loaded instance, avoiding duplicate model memory.
actor LazyWhisperTranscriber: Transcribing {
    private let modelPath: String
    private var vocabulary: [String]
    private var resident: WhisperTranscriber?
    private var loading: Task<WhisperTranscriber, Error>?

    init(modelPath: String, vocabulary: [String]) {
        self.modelPath = modelPath
        self.vocabulary = vocabulary
    }

    func load() async throws -> WhisperTranscriber {
        if let resident { return resident }
        if let loading { return try await loading.value }
        let path = modelPath, hints = vocabulary
        let task = Task.detached(priority: .userInitiated) {
            try WhisperTranscriber(modelPath: path, vocabulary: hints)
        }
        loading = task
        do {
            let model = try await task.value
            model.updateVocabulary(vocabulary)
            resident = model
            loading = nil
            return model
        } catch {
            loading = nil
            throw error
        }
    }

    func updateVocabulary(_ terms: [String]) {
        vocabulary = terms
        resident?.updateVocabulary(terms)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        let model = try await load()
        try Task.checkCancellation()
        return try await model.transcribe(samples)
    }
}
