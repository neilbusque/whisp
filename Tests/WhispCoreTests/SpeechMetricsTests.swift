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
