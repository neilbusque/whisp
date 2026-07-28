import Foundation

/// One point on a per-prompt improvement chart.
public struct TrendPoint: Equatable, Sendable {
    public let date: Date
    public let wpm: Double
    public let fillerRate: Double
    public let pauseCount: Int
}

public final class PracticeStore {
    private(set) public var sessions: [PracticeSession]

    public init(sessions: [PracticeSession]) { self.sessions = sessions }

    public var all: [PracticeSession] { sessions }

    public static func load(from data: Data) throws -> PracticeStore {
        PracticeStore(sessions: try JSONDecoder().decode([PracticeSession].self, from: data))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(sessions)
    }

    public func append(_ s: PracticeSession) { sessions.append(s) }

    /// Replaces by id. Unknown ids are ignored rather than appended — a late
    /// transcription result for a session the user already deleted must not
    /// resurrect it.
    public func update(_ s: PracticeSession) {
        guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions[i] = s
    }

    /// Returns the removed session so the caller can delete its WAV.
    @discardableResult
    public func delete(id: UUID) -> PracticeSession? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        return sessions.remove(at: i)
    }

    /// Oldest first. `nil` selects free-form sessions.
    public func sessions(forPrompt promptID: UUID?) -> [PracticeSession] {
        sessions.filter { $0.promptID == promptID }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Oldest first. Sessions without metrics (still transcribing, or failed)
    /// are skipped — a missing point is honest, a zeroed point is a lie that
    /// would look like a catastrophic regression on the chart.
    public func trend(forPrompt promptID: UUID?) -> [TrendPoint] {
        sessions(forPrompt: promptID).compactMap { s in
            guard let m = s.metrics else { return nil }
            return TrendPoint(date: s.startedAt, wpm: m.wpm,
                              fillerRate: m.fillerRate, pauseCount: m.pauseCount)
        }
    }
}
