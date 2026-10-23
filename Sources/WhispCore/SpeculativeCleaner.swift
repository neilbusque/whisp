import Foundation

/// Prepares writing while speech is arriving. Only an exact final prompt can
/// consume a result; this type has no access to the document or clipboard.
public actor SpeculativeCleaner: Cleaning {
    private struct Candidate {
        let id: UUID
        let messages: [ChatMessage]
        let task: Task<String, Error>
    }
    private let cleaner: Cleaning
    private let debounce: Duration
    private let limit: Int
    private let onReuse: @Sendable () -> Void
    private var session: UUID?
    private var sealed = true
    private var count = 0
    private var revision = 0
    private var pending: [ChatMessage]?
    private var latest: [ChatMessage]?
    private var released = false
    private var active: Candidate?
    private var cached: (messages: [ChatMessage], text: String)?
    private var timer: Task<Void, Never>?

    // Read-only observation for deterministic coordination with preview work.
    var hasActivePreview: Bool { active != nil }

    public init(cleaner: Cleaning, debounce: Duration = .milliseconds(250), limit: Int = 6,
                onReuse: @escaping @Sendable () -> Void = {}) {
        self.cleaner = cleaner
        self.debounce = debounce
        self.limit = max(0, limit)
        self.onReuse = onReuse
    }

    public func begin() -> UUID {
        cancel()
        let id = UUID()
        session = id
        sealed = false
        count = 0
        released = false
        return id
    }

    public func cancel() {
        session = nil
        sealed = true
        revision += 1
        timer?.cancel(); timer = nil
        active?.task.cancel(); active = nil
        pending = nil
        latest = nil
        cached = nil
    }

    public func offer(_ messages: [ChatMessage]?, session id: UUID) {
        guard session == id, !sealed else { return }
        revision += 1
        let version = revision
        timer?.cancel()
        pending = nil
        latest = messages
        guard let messages, !messages.isEmpty, count < budget,
              active?.messages != messages, cached?.messages != messages else { return }
        timer = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.enqueue(messages, session: id, revision: version)
        }
    }

    /// Reserve up to two more attempts for the end of a long recording, even
    /// if earlier pauses used the bounded while-speaking budget.
    public func release(session id: UUID) {
        guard session == id, !sealed, !released else { return }
        released = true
        count = 0
        revision += 1
        timer?.cancel(); timer = nil
        guard let latest, active?.messages != latest, cached?.messages != latest else { return }
        active?.task.cancel(); active = nil
        pending = latest
        startNext(session: id)
    }

    private var budget: Int { released ? min(2, limit) : limit }

    private func enqueue(_ messages: [ChatMessage], session id: UUID, revision version: Int) {
        guard session == id, !sealed, revision == version, count < budget else { return }
        pending = messages
        startNext(session: id)
    }

    private func startNext(session id: UUID) {
        guard session == id, !sealed, active == nil, count < budget,
              let messages = pending else { return }
        pending = nil
        count += 1
        let task = Task { [cleaner] in try await cleaner.complete(messages) }
        let candidate = Candidate(id: UUID(), messages: messages, task: task)
        active = candidate
        Task { [weak self] in
            let result = await task.result
            await self?.finished(candidate, result: result, session: id)
        }
    }

    private func finished(_ candidate: Candidate, result: Result<String, Error>, session id: UUID) {
        guard session == id, active?.id == candidate.id, !sealed else { return }
        active = nil
        if case .success(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cached = (candidate.messages, text)
        }
        startNext(session: id)
    }

    public func complete(_ messages: [ChatMessage]) async throws -> String {
        try Task.checkCancellation()
        sealed = true
        timer?.cancel(); timer = nil
        pending = nil
        latest = nil
        if let cached, cached.messages == messages {
            active?.task.cancel(); active = nil
            self.cached = nil
            onReuse()
            return cached.text
        }
        self.cached = nil
        let matching = active?.messages == messages ? active : nil
        if matching == nil { active?.task.cancel() }
        active = nil
        if let matching {
            // Keep the original request's deadline. Retrying a failed in-flight
            // attempt here could double the wait after release.
            let text = try await Self.value(of: matching.task)
            onReuse()
            return text
        }
        return try await cleaner.complete(messages)
    }

    private static func value(of task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}
