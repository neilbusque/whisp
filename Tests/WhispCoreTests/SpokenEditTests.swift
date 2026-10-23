import Testing
@testable import WhispCore

@Suite struct SpokenEditTests {
    @Test(arguments: [
        "Scratch that.", "DELETE THAT!", "Undo that", "Start over.",
        "Start again", "Remove that", "Um, scratch that.", "Uh, um, start over.",
    ])
    func standaloneDiscardCommands(_ text: String) {
        #expect(SpokenEdit.parse(text) == .command(.deleteAll))
    }

    @Test(arguments: [
        "Delete last word.", "Remove the last word", "delete  the  last word",
        "Scratch that last word.", "Scratch the last word.", "Scratch last word.",
    ])
    func standaloneWordCommands(_ text: String) {
        #expect(SpokenEdit.parse(text) == .command(.deleteLastWord))
    }

    @Test(arguments: [
        "Delete the last sentence.", "Remove last sentence!",
        "Scratch that last sentence.", "Scratch the last sentence.", "Scratch last sentence.",
    ])
    func standaloneSentenceCommands(_ text: String) {
        #expect(SpokenEdit.parse(text) == .command(.deleteLastSentence))
    }

    @Test func explicitPrefixRestartTargetsExistingText() {
        #expect(SpokenEdit.parse("Start over: Let's meet Friday.") ==
                .command(.replace("Let's meet Friday.")))
        #expect(SpokenEdit.parse("Um, start over. Neil will call.") ==
                .command(.replace("Neil will call.")))
    }

    @Test func inlineRestartKeepsOnlyFreshContent() {
        #expect(SpokenEdit.parse("Please meet Monday. Start over: Let's meet Friday.") ==
                .dictation("Let's meet Friday."))
        #expect(SpokenEdit.parse("Hello, start over, We can meet tomorrow!") ==
                .dictation("We can meet tomorrow!"))
    }

    @Test func lastInlineRestartWins() {
        #expect(SpokenEdit.parse("First. Start over: Second. Start over: Third.") ==
                .dictation("Third."))
    }

    @Test func explicitColonAllowsTemporalSource() {
        #expect(SpokenEdit.parse("Start over: Tomorrow works for me.") ==
                .command(.replace("Tomorrow works for me.")))
    }

    @Test(arguments: [
        "Let's meet Monday, no, I mean Friday.",
        "Let's meet Monday. Actually make that Friday.",
        "Actually, make that Friday.",
        "Make that more professional.",
        "Make it sound friendlier.",
        "We could meet Monday. Make that Friday.",
        "hey can you send it. Make that more professional.",
        "I can do Monday. Scratch that. Friday works.",
        "I can do Monday, delete that, Friday works.",
        "First sentence. Delete the last sentence. A replacement sentence.",
        "I can do Monday, sorry, I meant Friday.",
        "No, actually let's meet Friday.",
        "I said Monday. Actually make that Friday.",
        "Meet Friday, sorry, Monday at three.",
        "I can attend, actually I cannot attend.",
        "The proposal is ready. The budget is tentative. Scratch that last sentence. Say the budget is approved.",
    ])
    func semanticCorrectionsKeepFullSourceForInterpretation(_ text: String) {
        #expect(SpokenEdit.parse(text) == .interpret(text))
    }

    @Test func terminalSentenceDeletionUsesCurrentUtterance() {
        #expect(SpokenEdit.parse(
            "The proposal is ready. The budget is tentative. Scratch that last sentence.") ==
                .dictation("The proposal is ready."))
        #expect(SpokenEdit.parse("First sentence. Delete the last sentence.") == .dictation(""))
        #expect(SpokenEdit.parse("Keep this. Remove this. Remove last sentence.") ==
                .dictation("Keep this."))
    }

    @Test func terminalWordDeletionUsesCurrentUtterance() {
        #expect(SpokenEdit.parse("Send the proposal today tomorrow. Scratch that last word.") ==
                .dictation("Send the proposal today"))
        #expect(SpokenEdit.parse("We do not agree today, delete the last word.") ==
                .dictation("We do not agree"))
        #expect(SpokenEdit.parse("Only. Delete last word.") == .dictation(""))
    }

    @Test(arguments: [
        "The phrase start over means try again.",
        "The phrase, start over, is on the button.",
        "I told him to delete that.",
        "I told him, start over, and he did.",
        "I said, scratch that, and he laughed.",
        "Start over tomorrow.",
        "Start over, tomorrow.",
        "Start from scratch.",
        "We should start over tomorrow.",
        "Please don't delete that.",
        "Delete that file tomorrow.",
        "Scratch that itch before the meeting.",
        "Make this work tomorrow.",
        "Make that call tomorrow.",
        "Make it happen on Friday.",
        "The plan is clear. Make that call tomorrow.",
        "The phrase, scratch that last sentence, is confusing.",
        "He said, scratch that last sentence.",
        "The command is, delete the last word.",
        "He said, make that more professional, when reviewing it.",
        "We can actually make that Friday.",
        "We need to make that more professional before launch.",
        "I like this, and you know why.",
        "Actually I like this.",
        "I mean it when I say no.",
        "Do you know what I mean?",
        "Um, I like this, and I mean tomorrow.",
        "Write the word \"uh\" on the card.",
        "The total is $10.50, not $15.50.",
    ])
    func ordinarySpeechPreservesExactMeaning(_ text: String) {
        #expect(SpokenEdit.parse(text) == .dictation(text))
    }

    @Test(arguments: [
        "\"Scratch that.\"", "‘Start over.’", "“Start over: Hello.”",
        "She wrote \"Hello, start over, goodbye\" in the script.",
        "I said 'scratch that' as a joke.",
        "The note reads \"No, I mean Friday.\"",
        "The button says “Make that more professional.”",
        "The note reads “Scratch that last sentence.”",
    ])
    func quotedCommandsStayLiteral(_ text: String) {
        #expect(SpokenEdit.parse(text) == .dictation(text))
    }

    @Test(arguments: [
        "I can do Monday. Start over.",
        "Hello, start over", "First. Start over: Second. Start over.",
    ])
    func trailingRestartCancelsOnlyCurrentUtterance(_ text: String) {
        #expect(SpokenEdit.parse(text) == .dictation(""))
    }

    @Test func reportedSpeechInEarlierSentenceDoesNotBlockRestart() {
        #expect(SpokenEdit.parse("I said the wrong thing. Start over: Friday works.") ==
                .dictation("Friday works."))
    }

    @Test func startFromExtractsLiteralPhrase() {
        #expect(SpokenEdit.parse("Start from Friday.") == .command(.startFrom("Friday")))
        #expect(SpokenEdit.parse("Start at the phrase \"we can meet\".") == .command(.startFrom("we can meet")))
        #expect(SpokenEdit.parse("Start from: Tomorrow works.") == .command(.startFrom("Tomorrow works")))
    }

    @Test func startFromTrimsOnlyToUniqueWholePhrase() {
        #expect(SpokenEdit.applying(.startFrom("Friday"), to: "Monday is out. Friday works.") == "Friday works.")
        #expect(SpokenEdit.applying(.startFrom("we can meet"), to: "Let's try again. We can meet tomorrow.") == "We can meet tomorrow.")
        #expect(SpokenEdit.applying(.startFrom("Friday"), to: "Friday or next Friday?") == "Friday or next Friday?")
        #expect(SpokenEdit.applying(.startFrom("day"), to: "Friday works.") == "Friday works.")
        #expect(SpokenEdit.applying(.startFrom("Thursday"), to: "  Friday works.  ") == "  Friday works.  ")
        #expect(SpokenEdit.applying(.startFrom(""), to: "Friday works.") == "Friday works.")
    }

    @Test func deletingAllAndReplacementAreExplicit() {
        #expect(SpokenEdit.applying(.deleteAll, to: "Private source.") == "")
        #expect(SpokenEdit.applying(.replace("Friday works."), to: "Monday works.") == "Friday works.")
    }

    @Test func deleteLastWordPreservesOtherWordsNumbersAndNegation() {
        #expect(SpokenEdit.applying(.deleteLastWord, to: "We do not agree today.") == "We do not agree")
        #expect(SpokenEdit.applying(.deleteLastWord, to: "The cost is $10.50 today.") == "The cost is $10.50")
        #expect(SpokenEdit.applying(.deleteLastWord, to: "Use GoHighLevel's API.") == "Use GoHighLevel's")
        #expect(SpokenEdit.applying(.deleteLastWord, to: "Only.") == "")
        #expect(SpokenEdit.applying(.deleteLastWord, to: "   ") == "")
    }

    @Test func deleteLastSentenceHandlesOrdinaryPunctuation() {
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "First sentence. Last sentence.") == "First sentence.")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "Is that ready? Yes!") == "Is that ready?")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "First sentence. Unfinished thought") == "First sentence.")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "Only one sentence.") == "")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "") == "")
    }

    @Test func deleteLastSentencePreservesDecimalsAbbreviationsAndNames() {
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "It costs $10.50. Buy it tomorrow.") == "It costs $10.50.")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "Dr. Smith called.") == "")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "N. Busque called.") == "")
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "The U.S. office called. We answered.") == "The U.S. office called.")
    }

    @Test func deleteLastSentenceKeepsQuoteClosingPunctuation() {
        #expect(SpokenEdit.applying(.deleteLastSentence, to: "He said, “Go.” I left.") == "He said, “Go.”")
    }

    @Test(arguments: [
        "Oh wait, remove this part.", "Wait, delete that part please.",
        "Could you please remove the selected text?", "Please cut the highlighted section.",
        "Actually, remove this bit.",
    ])
    func ambiguousPartRemovalRequiresAnExplicitSelection(_ phrase: String) {
        #expect(SpokenEdit.parse(phrase) == .command(.deleteSelection))
        #expect(SpokenEdit.Command.deleteSelection.requiresSelection)
        #expect(!SpokenEdit.Command.deleteAll.requiresSelection)
        #expect(SpokenEdit.applying(.deleteSelection, to: "Selected words only.") == "")
    }

    @Test func conversationalBoundedEditsRemainLocal() {
        #expect(SpokenEdit.parse("Oh wait, delete the last word please.") == .command(.deleteLastWord))
        #expect(SpokenEdit.parse("Can you please remove the last sentence?") == .command(.deleteLastSentence))
        #expect(SpokenEdit.parse("Actually, scratch that please.") == .command(.deleteAll))
        #expect(SpokenEdit.parse("Wait, start from Friday please.") == .command(.startFrom("Friday")))
        #expect(SpokenEdit.parse("Could you start over: Friday works.") == .command(.replace("Friday works.")))
    }

    @Test func conversationalTerminalDeletionUsesOnlyThisUtterance() {
        #expect(SpokenEdit.parse("Keep the proposal. Drop the budget. Oh wait, delete the last sentence please.")
                == .dictation("Keep the proposal."))
        #expect(SpokenEdit.parse("Send this today tomorrow. Could you remove the last word please?")
                == .dictation("Send this today"))
    }

    @Test(arguments: [
        "The proposal is ready. Oh wait, remove this part.",
        "The deadline is Monday. Wait, make that Friday.",
        "The first price is wrong. Oh wait, remove the part about pricing.",
        "We cannot send it Friday. Can you change the tone to friendly?",
        "This sounds rough. Could you make this better please?",
        "Meet Monday. Oh wait, scratch that. Friday works.",
    ])
    func inlineConversationalCorrectionsKeepSourceForInterpretation(_ phrase: String) {
        #expect(SpokenEdit.parse(phrase) == .interpret(phrase))
    }

    @Test(arguments: [
        "He asked, could you remove this part?",
        "The button says ‘oh wait, remove this part’.",
        "Write: oh wait, delete the last word please.",
        "Literally say, make this better please.",
        "She wrote `oh wait, remove this part` in the document.",
        "Wait, make this work tomorrow.",
        "Actually, make that call tomorrow.",
        "Could you start over tomorrow?",
        "Oh wait, could you start over, tomorrow?",
        "Wait, make that reservation for Friday.",
        "Oh wait, make this booking for tomorrow.",
        "Wait, can you make that purchase today?",
        "Change the tone to friendly is the instruction on screen.",
        "Make it sound friendly is the instruction on screen.",
    ])
    func reportedQuotedAndOrdinaryRequestsStayLiteral(_ phrase: String) {
        #expect(SpokenEdit.parse(phrase) == .dictation(phrase))
    }
}
