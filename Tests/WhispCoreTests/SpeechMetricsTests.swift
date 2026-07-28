import Foundation
import Testing
@testable import WhispCore

@Suite struct FillerCountingTests {
    let fillers = ["um", "uh", "like", "you know", "i mean"]

    @Test func countsSingleWordFillers() {
        let counts = SpeechAnalyzer.countFillers(in: "Um, so uh I think um yes", fillers: fillers)
        #expect(counts["um"] == 2)
        #expect(counts["uh"] == 1)
    }

    @Test func matchesWholeWordsOnly() {
        // "likely" and "umbrella" must NOT count.
        let counts = SpeechAnalyzer.countFillers(in: "That is likely an umbrella", fillers: fillers)
        #expect(counts["like"] == nil)
        #expect(counts["um"] == nil)
    }

    @Test func countsMultiWordPhrases() {
        let counts = SpeechAnalyzer.countFillers(in: "You know, I mean, you know it works",
                                                 fillers: fillers)
        #expect(counts["you know"] == 2)
        #expect(counts["i mean"] == 1)
    }

    @Test func isCaseInsensitiveAndIgnoresPunctuation() {
        let counts = SpeechAnalyzer.countFillers(in: "UM... uh! Um?", fillers: fillers)
        #expect(counts["um"] == 2)
        #expect(counts["uh"] == 1)
    }

    @Test func omitsZeroCounts() {
        let counts = SpeechAnalyzer.countFillers(in: "A clean sentence.", fillers: fillers)
        #expect(counts.isEmpty)
    }

    @Test func handlesEmptyInputs() {
        #expect(SpeechAnalyzer.countFillers(in: "", fillers: fillers).isEmpty)
        #expect(SpeechAnalyzer.countFillers(in: "um um", fillers: []).isEmpty)
    }
}

@Suite struct FillerListTests {
    @Test func parsesOnePerLineIgnoringCommentsAndBlanks() {
        let text = """
        # comment
        um

        you know
           uh
        """
        #expect(FillerList.parse(text) == ["um", "you know", "uh"])
    }

    @Test func seedContainsTheCommonFillers() {
        let parsed = FillerList.parse(FillerList.seed)
        #expect(parsed.contains("um"))
        #expect(parsed.contains("you know"))
    }
}

@Suite struct PauseDetectionTests {
    // 0.05s bins. loud = 0.5, quiet = 0.01, threshold 0.06.
    func env(_ pattern: [(Float, Int)]) -> [Float] {
        pattern.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test func findsAPauseLongerThanTheThreshold() {
        // 1s loud, 1.5s quiet, 1s loud → one 1.5s pause starting at 1.0s.
        let e = env([(0.5, 20), (0.01, 30), (0.5, 20)])
        let pauses = SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                           silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].startSec - 1.0) < 0.001)
        #expect(abs(pauses[0].durationSec - 1.5) < 0.001)
    }

    @Test func ignoresGapsShorterThanTheThreshold() {
        // 0.5s quiet gap, below a 1.0s threshold.
        let e = env([(0.5, 20), (0.01, 10), (0.5, 20)])
        #expect(SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }

    @Test func ignoresLeadingAndTrailingSilence() {
        // Silence before the first and after the last speech is dead air, not a
        // pause in delivery.
        let e = env([(0.01, 40), (0.5, 20), (0.01, 40)])
        #expect(SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }

    @Test func findsMultiplePauses() {
        let e = env([(0.5, 10), (0.01, 25), (0.5, 10), (0.01, 30), (0.5, 10)])
        let pauses = SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                           silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(pauses.count == 2)
    }

    @Test func handlesAllSilentAndEmptyEnvelopes() {
        #expect(SpeechAnalyzer.pauses(envelope: env([(0.01, 100)]), binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
        #expect(SpeechAnalyzer.pauses(envelope: [], binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }
}

@Suite struct SpeechMetricsTests {
    func env(_ pattern: [(Float, Int)]) -> [Float] {
        pattern.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test func computesWpmOverSpeakingDurationOnly() {
        // 2s lead-in silence, 60s speech, 2s trailing silence = 64s total.
        // 120 words over 60s of speaking = 120 WPM (NOT 112.5 over 64s).
        let e = env([(0.01, 40), (0.5, 1_200), (0.01, 40)])
        let transcript = Array(repeating: "word", count: 120).joined(separator: " ")
        let m = SpeechAnalyzer.analyze(transcript: transcript, envelope: e, binSeconds: 0.05,
                                       fillers: ["um"], silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.wordCount == 120)
        #expect(abs(m.durationSec - 64.0) < 0.001)
        #expect(abs(m.speakingDurationSec - 60.0) < 0.001)
        #expect(abs(m.wpm - 120.0) < 0.5)
    }

    @Test func fillerRateIsPerHundredWords() {
        // 50 words, 5 of them "um" → 10 per 100 words.
        let words = Array(repeating: "word", count: 45) + Array(repeating: "um", count: 5)
        let e = env([(0.5, 600)])  // 30s
        let m = SpeechAnalyzer.analyze(transcript: words.joined(separator: " "), envelope: e,
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.totalFillers == 5)
        #expect(abs(m.fillerRate - 10.0) < 0.001)
    }

    @Test func reportsSilenceRatioAndLongestPause() {
        let e = env([(0.5, 20), (0.01, 40), (0.5, 20)])  // 1s + 2s + 1s
        let m = SpeechAnalyzer.analyze(transcript: "a b c", envelope: e, binSeconds: 0.05,
                                       fillers: [], silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(abs(m.silenceRatio - 0.5) < 0.001)
        #expect(abs(m.longestPauseSec - 2.0) < 0.001)
        #expect(m.pauseCount == 1)
    }

    @Test func silentRecordingYieldsZeroesNotNaN() {
        let m = SpeechAnalyzer.analyze(transcript: "", envelope: env([(0.01, 200)]),
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.wordCount == 0)
        #expect(m.wpm == 0)
        #expect(m.fillerRate == 0)
        #expect(m.speakingDurationSec == 0)
        #expect(!m.wpm.isNaN)
    }

    @Test func emptyEnvelopeYieldsZeroesNotNaN() {
        let m = SpeechAnalyzer.analyze(transcript: "hello there", envelope: [],
                                       binSeconds: 0.05, fillers: [],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.durationSec == 0)
        #expect(m.wpm == 0)
        #expect(!m.silenceRatio.isNaN)
    }

    @Test func roundTripsThroughJSON() throws {
        let m = SpeechAnalyzer.analyze(transcript: "um hello", envelope: env([(0.5, 20)]),
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        let decoded = try JSONDecoder().decode(SpeechMetrics.self, from: JSONEncoder().encode(m))
        #expect(decoded == m)
    }
}
