import Testing
import Foundation
@testable import WhispCore

@Suite struct PracticeSessionTests {
    @Test func roundTripsThroughJSONIncludingFailedStatus() throws {
        let s = PracticeSession(promptID: UUID(), promptTitle: "Niruron pitch",
                                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                durationSec: 42.5, audioFilename: "abc.wav",
                                envelope: [0.1, 0.9, 0.0],
                                status: .failed("whisper_full failed (rc=-1)"))
        let decoded = try JSONDecoder().decode(PracticeSession.self,
                                               from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(decoded.status == .failed("whisper_full failed (rc=-1)"))
    }

    @Test func defaultsToPendingWithNoTranscript() {
        let s = PracticeSession(promptID: nil, promptTitle: "Free-form",
                                startedAt: Date(), durationSec: 10,
                                audioFilename: "x.wav", envelope: [])
        #expect(s.status == .pending)
        #expect(s.transcript == nil)
        #expect(s.metrics == nil)
        #expect(s.coachFeedback == nil)
    }

    @Test func segmentsRoundTrip() throws {
        var s = PracticeSession(promptID: nil, promptTitle: "Free-form",
                                startedAt: Date(), durationSec: 3,
                                audioFilename: "x.wav", envelope: [])
        s.segments = [TranscriptSegment(text: "hello", startMS: 0, endMS: 900),
                      TranscriptSegment(text: " there", startMS: 900, endMS: 1_800)]
        s.status = .ready
        let decoded = try JSONDecoder().decode(PracticeSession.self,
                                               from: JSONEncoder().encode(s))
        #expect(decoded.segments?.count == 2)
        #expect(decoded.segments?[1].startMS == 900)
    }
}
