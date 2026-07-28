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

@Suite struct PracticeStoreTests {
    func metrics(wpm: Double, fillerRate: Double, pauseCount: Int) -> SpeechMetrics {
        SpeechMetrics(wordCount: 100, durationSec: 60, speakingDurationSec: 60, wpm: wpm,
                      fillerCounts: [:], totalFillers: 0, fillerRate: fillerRate,
                      pauses: [], pauseCount: pauseCount, longestPauseSec: 0, silenceRatio: 0)
    }

    func session(prompt: UUID?, day: Int, wpm: Double = 140,
                 fillerRate: Double = 3, pauseCount: Int = 2) -> PracticeSession {
        var s = PracticeSession(promptID: prompt, promptTitle: "P",
                                startedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                                durationSec: 60, audioFilename: "\(day).wav", envelope: [])
        s.status = .ready
        s.metrics = metrics(wpm: wpm, fillerRate: fillerRate, pauseCount: pauseCount)
        return s
    }

    @Test func appendUpdateDeleteRoundTrip() throws {
        let store = PracticeStore(sessions: [])
        let a = session(prompt: nil, day: 1)
        store.append(a)
        #expect(store.all.count == 1)

        var updated = a
        updated.transcript = "hello"
        updated.status = .ready
        store.update(updated)
        #expect(store.all.count == 1)
        #expect(store.all[0].transcript == "hello")

        let decoded = try PracticeStore.load(from: store.encoded())
        #expect(decoded.all[0].transcript == "hello")

        let removed = store.delete(id: a.id)
        #expect(removed?.audioFilename == "1.wav")
        #expect(store.all.isEmpty)
        #expect(store.delete(id: a.id) == nil)
    }

    @Test func updateOfAnUnknownSessionIsANoOp() {
        let store = PracticeStore(sessions: [session(prompt: nil, day: 1)])
        store.update(session(prompt: nil, day: 99))
        #expect(store.all.count == 1)
    }

    @Test func sessionsForPromptFilterAndSortChronologically() {
        let p = UUID(), other = UUID()
        let store = PracticeStore(sessions: [
            session(prompt: p, day: 3),
            session(prompt: other, day: 2),
            session(prompt: p, day: 1),
        ])
        let mine = store.sessions(forPrompt: p)
        #expect(mine.count == 2)
        #expect(mine[0].audioFilename == "1.wav")   // oldest first
        #expect(mine[1].audioFilename == "3.wav")
    }

    @Test func freeFormSessionsAreQueriedWithNil() {
        let store = PracticeStore(sessions: [
            session(prompt: nil, day: 1),
            session(prompt: UUID(), day: 2),
        ])
        #expect(store.sessions(forPrompt: nil).count == 1)
    }

    @Test func trendIsChronologicalAndSkipsUnfinishedSessions() {
        let p = UUID()
        var pending = session(prompt: p, day: 2)
        pending.status = .pending
        pending.metrics = nil

        let store = PracticeStore(sessions: [
            session(prompt: p, day: 3, wpm: 150, fillerRate: 1, pauseCount: 1),
            pending,
            session(prompt: p, day: 1, wpm: 130, fillerRate: 5, pauseCount: 4),
        ])
        let t = store.trend(forPrompt: p)
        #expect(t.count == 2)               // the pending one has no metrics
        #expect(t[0].wpm == 130)            // oldest first
        #expect(t[1].wpm == 150)
        #expect(t[0].fillerRate == 5)
        #expect(t[1].pauseCount == 1)
    }

    @Test func trendIsEmptyWhenNothingHasMetrics() {
        let store = PracticeStore(sessions: [])
        #expect(store.trend(forPrompt: UUID()).isEmpty)
    }
}
