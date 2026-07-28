import Foundation

/// One transcribed span with whole-session timing. Timestamps are offset back
/// into whole-session time when chunks are stitched (see AudioChunker).
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startMS: Int
    public let endMS: Int

    public init(text: String, startMS: Int, endMS: Int) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
    }
}

public enum SessionStatus: Codable, Equatable, Sendable {
    /// Audio is on disk; transcription has not finished.
    case pending
    case ready
    case failed(String)
}

/// One practice recording plus everything derived from it.
///
/// `promptTitle` is denormalized on purpose: deleting a prompt must not orphan
/// the label on months of past sessions.
public struct PracticeSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let promptID: UUID?
    public let promptTitle: String
    public let startedAt: Date
    public let durationSec: Double
    /// Filename only, relative to `~/.whisp/recordings/`. Never an absolute
    /// path — the home directory can move, and this file is portable.
    public let audioFilename: String
    /// 20 Hz RMS envelope. Drives pause detection and the review scrubber.
    public let envelope: [Float]

    public var status: SessionStatus
    public var transcript: String?
    public var segments: [TranscriptSegment]?
    public var metrics: SpeechMetrics?
    public var coachFeedback: String?

    public init(id: UUID = UUID(), promptID: UUID?, promptTitle: String,
                startedAt: Date, durationSec: Double, audioFilename: String,
                envelope: [Float], status: SessionStatus = .pending,
                transcript: String? = nil, segments: [TranscriptSegment]? = nil,
                metrics: SpeechMetrics? = nil, coachFeedback: String? = nil) {
        self.id = id
        self.promptID = promptID
        self.promptTitle = promptTitle
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.audioFilename = audioFilename
        self.envelope = envelope
        self.status = status
        self.transcript = transcript
        self.segments = segments
        self.metrics = metrics
        self.coachFeedback = coachFeedback
    }
}
