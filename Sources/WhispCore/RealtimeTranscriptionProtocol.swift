import Foundation

/// Wire-format helpers and one-turn correlation, kept separate from networking
/// so final-only insertion and out-of-order events can be tested deterministically.
public enum RealtimeTranscriptionProtocol {
    public static let model = "gpt-live-transcribe"

    public static func sessionUpdate(vocabulary: [String], model: String = RealtimeTranscriptionProtocol.model) throws -> Data {
        var seen = Set<String>()
        let keywords = vocabulary.compactMap { value -> String? in
            let safe = value.components(separatedBy: CharacterSet(charactersIn: "<>\r\n"))
                .joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !safe.isEmpty else { return nil }
            let clipped = String(safe.prefix(100))
            guard seen.insert(clipped.lowercased()).inserted else { return nil }
            return clipped
        }.prefix(100)
        return try JSONSerialization.data(withJSONObject: [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": ["model": model, "delay": "minimal",
                                      "languages": ["en"], "keywords": Array(keywords)],
                    "turn_detection": NSNull()
                ]]
            ]
        ])
    }

    public static func append(_ pcm: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()
        ])
    }

    public static func commit() -> Data {
        Data(#"{"type":"input_audio_buffer.commit"}"#.utf8)
    }

    public enum Event: Sendable, Equatable {
        case configured
        case committed(String)
        case delta(itemID: String, text: String)
        case completed(itemID: String, transcript: String)
        case failed(String)
        case ignored
    }

    public static func event(from data: Data) throws -> Event {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw Failure("OpenAI returned an invalid transcription event.")
        }
        switch type {
        case "session.updated", "transcription_session.updated":
            return .configured
        case "input_audio_buffer.committed":
            guard let item = json["item_id"] as? String, !item.isEmpty else {
                throw Failure("OpenAI did not identify the committed audio turn.")
            }
            return .committed(item)
        case "conversation.item.input_audio_transcription.delta":
            // A malformed preview must not prevent a valid final transcript.
            // This session sends one audio content part per turn.
            guard let item = json["item_id"] as? String, !item.isEmpty,
                  let text = json["delta"] as? String,
                  json["content_index"] == nil || json["content_index"] as? Int == 0 else {
                return .ignored
            }
            return .delta(itemID: item, text: text)
        case "conversation.item.input_audio_transcription.completed":
            guard let item = json["item_id"] as? String, !item.isEmpty,
                  let transcript = json["transcript"] as? String else {
                throw Failure("OpenAI returned an incomplete transcription event.")
            }
            return .completed(itemID: item, transcript: transcript)
        case "error", "conversation.item.input_audio_transcription.failed":
            let code = (json["error"] as? [String: Any])?["code"] as? String
            let safeCode = code?.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(80)
            return .failed(safeCode.map { "OpenAI transcription failed (\($0))." }
                ?? "OpenAI could not transcribe this recording.")
        default:
            return .ignored
        }
    }

    public struct Turn: Sendable {
        private struct Partial: Sendable {
            var text = ""
            var byteCount = 0
        }
        private var committedID: String?
        private var finals: [String: String] = [:]
        private var firstPartialID: String?
        private var partials: [String: Partial] = [:]
        private var discardedPartialIDs: Set<String> = []
        public init() {}

        /// Speculative input only. `accept` still returns text only after both
        /// the matching commit acknowledgement and final event have arrived.
        /// Until commit identifies the turn, use one provisional item without
        /// combining deltas from different items.
        public var partialTranscript: String? {
            guard let item = committedID ?? firstPartialID else { return nil }
            return partials[item]?.text
        }

        public mutating func accept(_ event: Event) throws -> String? {
            switch event {
            case .failed(let message): throw Failure(message)
            case .committed(let item):
                guard committedID == nil || committedID == item else {
                    throw Failure("OpenAI returned more than one audio turn.")
                }
                committedID = item
            case .delta(let item, let text):
                appendPartial(text, itemID: item)
            case .completed(let item, let transcript):
                guard finals.count < 8 || finals[item] != nil else {
                    throw Failure("OpenAI returned unexpected transcription turns.")
                }
                finals[item] = transcript
            case .configured, .ignored: break
            }
            guard let committedID else { return nil }
            return finals[committedID]
        }

        private mutating func appendPartial(_ text: String, itemID item: String) {
            guard !text.isEmpty, !item.isEmpty, item.utf8.count <= 256,
                  finals[item] == nil, !discardedPartialIDs.contains(item) else { return }
            guard partials[item] != nil || partials.count + discardedPartialIDs.count < 8 else { return }
            var partial = partials[item] ?? Partial()
            let addedBytes = text.utf8.count
            guard addedBytes <= 65_536 - partial.byteCount else {
                // Discard the whole preview rather than truncate it or later
                // expose a suffix as if it were a complete cumulative result.
                partials.removeValue(forKey: item)
                discardedPartialIDs.insert(item)
                return
            }
            partial.text += text
            partial.byteCount += addedBytes
            partials[item] = partial
            if firstPartialID == nil { firstPartialID = item }
        }
    }

    public struct Failure: LocalizedError, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
