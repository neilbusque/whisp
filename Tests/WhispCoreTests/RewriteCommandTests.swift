import Testing
@testable import WhispCore

@Suite struct RewriteCommandTests {
    @Test func exactCommandTargetsSelectedText() {
        let command = RewriteCommand.parse("Rewrite this.")
        #expect(command?.trigger == "rewrite this")
        #expect(command?.spokenText == "")
    }

    @Test func commandKeepsSpokenSourceInOriginalCase() {
        let command = RewriteCommand.parse(
            "Make this better: Our GoHighLevel CRM helps Neil Busque.")
        #expect(command?.spokenText == "Our GoHighLevel CRM helps Neil Busque.")
    }

    @Test func recognizesProfessionalAndClarityVariants() {
        #expect(RewriteCommand.parse("Make this sound professional") != nil)
        #expect(RewriteCommand.parse("Rephrase this") != nil)
        #expect(RewriteCommand.parse("Clean this up") != nil)
        #expect(RewriteCommand.parse("Improve this") != nil)
    }

    @Test func styleRemainderBecomesSelectedTextInstruction() {
        let command = RewriteCommand.parse("Rewrite this to sound warmer and more confident")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("warmer and more confident") == true)
    }

    @Test func normalSentencesDoNotTriggerRewrite() {
        #expect(RewriteCommand.parse("I need to rewrite the landing page tomorrow") == nil)
        #expect(RewriteCommand.parse("This rewrite looks much better") == nil)
    }

    @Test func styleBeforeColonDoesNotConsumeSpokenSource() {
        let command = RewriteCommand.parse(
            "Rewrite this more professionally: Our proposal costs $500, not $5,000.")
        #expect(command?.spokenText == "Our proposal costs $500, not $5,000.")
        #expect(command?.instruction.contains("more professionally") == true)
        #expect(command?.instruction.contains("Our proposal") == false)
    }

    @Test func soundStyleBeforeColonKeepsSourceSeparate() {
        let command = RewriteCommand.parse(
            "Rewrite this to sound warmer: Thanks, but I cannot commit to Friday.")
        #expect(command?.spokenText == "Thanks, but I cannot commit to Friday.")
        #expect(command?.instruction.contains("to sound warmer") == true)
    }

    @Test func explicitColonPreservesSourceStartingWithStyleWords() {
        let command = RewriteCommand.parse("Rewrite this: In a few days, we will call.")
        #expect(command?.spokenText == "In a few days, we will call.")
    }

    @Test func sourceColonsAndQuotedWordsArePreserved() {
        let command = RewriteCommand.parse("Rewrite this: \"Yes\", the call is at 10:30.")
        #expect(command?.spokenText == "\"Yes\", the call is at 10:30.")
        let legacy = RewriteCommand.parse("Rewrite this Our call is at 10:30.")
        #expect(legacy?.spokenText == "Our call is at 10:30.")
    }

    @Test func standaloneNaturalStyleCommandsTargetExistingText() {
        for phrase in ["Make this shorter.", "Make this warmer", "Make this more casual",
                       "Make that more professional.", "Make this sound warmer",
                       "Please make that sound more casual.", "Make this shorter and warmer"] {
            let command = RewriteCommand.parse(phrase)
            #expect(command != nil, "Unrecognized command: \(phrase)")
            #expect(command?.spokenText == "", "Style became source: \(phrase)")
        }
    }

    @Test func formatInstructionsTargetExistingText() {
        for phrase in ["Rewrite this as an email.", "Rewrite this as bullet points.",
                       "Rewrite this into bullet points", "Rewrite this in bullet points"] {
            let command = RewriteCommand.parse(phrase)
            #expect(command != nil)
            #expect(command?.spokenText == "")
        }
    }

    @Test func formatBeforeColonPreservesSuppliedDraft() {
        let command = RewriteCommand.parse(
            "Rewrite this as an email: Could you send the invoice today?")
        #expect(command?.instruction.contains("as an email") == true)
        #expect(command?.spokenText == "Could you send the invoice today?")
    }

    @Test func recentDictationCommandsExposeTheirTarget() {
        let command = RewriteCommand.parse("Rewrite what I just said more professionally.")
        #expect(command?.prefersRecentText == true)
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("more professionally") == true)
        #expect(RewriteCommand.parse("Rewrite this.")?.prefersRecentText == false)
    }

    @Test func suffixCommandRewritesTheSourceInThisDictation() {
        let command = RewriteCommand.parse(
            "I cannot finish the proposal by Friday. Make this warmer.")
        #expect(command?.spokenText == "I cannot finish the proposal by Friday.")
        #expect(command?.instruction.contains("warmer") == true)
    }

    @Test func suffixWorksWhenTranscriptionOmitsPunctuation() {
        let command = RewriteCommand.parse(
            "I cannot finish the proposal by Friday make this more professional")
        #expect(command?.spokenText == "I cannot finish the proposal by Friday")
    }

    @Test func suffixFormatRequestKeepsCaseAndFacts() {
        let command = RewriteCommand.parse(
            "Neil needs the GoHighLevel draft, please rewrite this as bullet points.")
        #expect(command?.spokenText == "Neil needs the GoHighLevel draft")
        #expect(command?.instruction.contains("bullet points") == true)
    }

    @Test func literalAndDiscussedCommandsDoNotTriggerRewrites() {
        for phrase in ["\"Make this shorter\" is the label.",
                       "The button says 'rewrite this'.",
                       "The words “make this shorter” should stay.",
                       "The instruction says make this more casual.",
                       "We discussed how to make this shorter.",
                       "Rewrite this is the phrase on the button.",
                       "You should make this shorter.",
                       "Make this work tomorrow."] {
            #expect(RewriteCommand.parse(phrase) == nil, "Literal parsed as command: \(phrase)")
        }
    }

    @Test func earlierReportedSpeechDoesNotHideAnActualSuffixCommand() {
        let command = RewriteCommand.parse(
            "The client said they need the proposal Friday. Make this shorter.")
        #expect(command?.spokenText == "The client said they need the proposal Friday.")
    }

    @Test func targetedTopicRemovalUsesExistingText() {
        let command = RewriteCommand.parse("Remove the sentence about pricing.")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("pricing") == true)
        #expect(command?.instruction.contains("Preserve every unrelated") == true)
        #expect(RewriteCommand.parse("Delete the part about the delay")?.spokenText == "")
        #expect(RewriteCommand.parse("Delete the file tomorrow") == nil)
    }

    @Test func targetedRemovalAcceptsExplicitSource() {
        let command = RewriteCommand.parse(
            "Delete the sentence about pricing: We launch Monday. Pricing is undecided.")
        #expect(command?.spokenText == "We launch Monday. Pricing is undecided.")
        #expect(command?.instruction.contains("We launch") == false)
    }

    @Test func quotedOrDiscussedRemovalIsNotACommand() {
        #expect(RewriteCommand.parse("The editor said delete the part about timing.") == nil)
        #expect(RewriteCommand.parse("\"Remove the sentence about pricing\" is an instruction.") == nil)
    }


    @Test func possessiveApostrophesDoNotHideSuffixCommands() {
        let command = RewriteCommand.parse("The clients' budget is fixed. Make this shorter.")
        #expect(command?.spokenText == "The clients' budget is fixed.")
    }


    @Test func hesitationBeforeStandaloneCommandDoesNotBecomeSource() {
        for phrase in ["Um, make this shorter.", "Uhhh, umm, rewrite that more professionally.",
                       "Erm. Please make this warmer.", "Um, remove the sentence about pricing."] {
            let command = RewriteCommand.parse(phrase)
            #expect(command != nil)
            #expect(command?.spokenText == "", "Hesitation became source: \(phrase)")
        }
    }

    @Test func hesitationBeforeRealDraftPreservesTheSourceForEditing() {
        let command = RewriteCommand.parse(
            "Um, I cannot finish the proposal by Friday. Make this warmer.")
        #expect(command?.spokenText == "Um, I cannot finish the proposal by Friday.")
    }

    @Test func leadingLiteralOrMeaningfulHesitationWordsAreNotStripped() {
        #expect(RewriteCommand.parse("\"Um\", make this shorter.")?.spokenText == "\"Um\"")
        #expect(RewriteCommand.parse("Uh-oh, make this shorter.")?.spokenText == "Uh-oh")
        #expect(RewriteCommand.parse("Um is a word. Make this shorter.")?.spokenText == "Um is a word.")
    }


    @Test func itPronounTargetsExistingTextAndWorksAsSuffix() {
        for phrase in ["Make it shorter.", "Rewrite it more professionally.", "Clean it up."] {
            let command = RewriteCommand.parse(phrase)
            #expect(command != nil)
            #expect(command?.spokenText == "")
        }
        #expect(RewriteCommand.parse("I cannot deliver Friday. Make it warmer.")?.spokenText
                == "I cannot deliver Friday.")
        #expect(RewriteCommand.parse("The button says 'rewrite it'.") == nil)
    }

    @Test func timeInRemovalTopicDoesNotBecomeSpokenSource() {
        let command = RewriteCommand.parse("Remove the sentence about the 10:30 meeting.")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("10:30 meeting") == true)
        #expect(command?.isRemoval == true)
    }

    @Test func removalSourceSeparatesAfterTheWholeTimeTopic() {
        let command = RewriteCommand.parse(
            "Remove the sentence about the 10:30 meeting: The meeting is at 10:30. Lunch is later.")
        #expect(command?.spokenText == "The meeting is at 10:30. Lunch is later.")
        #expect(command?.instruction.contains("10:30 meeting") == true)
        #expect(command?.instruction.contains("Lunch is later") == false)
    }

    @Test func standaloneFactualCorrectionUsesExistingSource() {
        let command = RewriteCommand.parse("Actually, make that Friday.")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("Friday") == true)
        #expect(command?.instruction.contains("changes the original fact") == true)
        #expect(command?.isRemoval == false)
        #expect(RewriteCommand.parse("Actually make it 10:30.")?.spokenText == "")
        #expect(RewriteCommand.parse("\"Actually, make that Friday\" was her correction.") == nil)
    }

    @Test func correctionCueBeforeStyleStillUsesStyleInstruction() {
        let command = RewriteCommand.parse("Actually, make that warmer.")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("warmer") == true)
        #expect(command?.instruction.contains("corrects a detail") == false)
    }

    @Test func onlyRemovalCommandsPermitAnEmptyEdit() {
        for phrase in ["Remove the sentence about pricing.", "Delete the part about timing.",
                       "Cut the paragraph mentioning the deadline.", "Drop the line about lunch."] {
            #expect(RewriteCommand.parse(phrase)?.isRemoval == true)
        }
        #expect(RewriteCommand.parse("Make it shorter.")?.isRemoval == false)
        #expect(RewriteCommand.parse("Rewrite this: Delete the file tomorrow.")?.isRemoval == false)
    }


    @Test func standaloneDateOrNumberCorrectionTargetsSelectedOrRecentText() {
        for phrase in ["Make that Friday.", "Make that 25.", "Make that tomorrow.",
                       "Make that October 25.", "Make that 10:30.", "Make that 25.5 dollars."] {
            let command = RewriteCommand.parse(phrase)
            #expect(command != nil, "Missing correction: \(phrase)")
            #expect(command?.spokenText == "")
            #expect(command?.instruction.contains("corrects a detail") == true)
            #expect(command?.isRemoval == false)
        }
    }

    @Test func ordinaryMakeThatPhrasesRemainDictation() {
        for phrase in ["Make that call tomorrow.", "Make that happen on Friday.",
                       "Make that appointment for 25 people.",
                       "The instruction says make that Friday.", "\"Make that 25\" is the phrase."] {
            #expect(RewriteCommand.parse(phrase) == nil, "Ordinary text became a correction: \(phrase)")
        }
    }

    @Test(arguments: [
        "Oh wait, make this better please.",
        "Wait, can you please make it shorter?",
        "Could you make this sound friendly, please?",
        "Actually, please make that sound better.",
        "Um, oh, wait, would you please clean this up?",
        "Can you make this shorter?",
    ])
    func conversationalRequestsTargetExistingText(_ phrase: String) {
        let command = RewriteCommand.parse(phrase)
        #expect(command != nil, "Missing request: \(phrase)")
        #expect(command?.spokenText == "", "Request words became source: \(phrase)")
    }

    @Test func suffixRequestDoesNotIncludeItsConversationalWrapperInTheDraft() {
        let command = RewriteCommand.parse(
            "I cannot finish by Friday. Oh wait, could you make this better please?")
        #expect(command?.spokenText == "I cannot finish by Friday.")
        #expect(command?.instruction.contains("polished") == true)
    }

    @Test(arguments: [
        "Change the tone to friendly.",
        "Can you change the tone to more professional please?",
        "Oh wait, adjust the tone to warm and empathetic.",
        "Please change the tone of this to something more casual.",
    ])
    func naturalToneRequestsAreInstructionsRatherThanSource(_ phrase: String) {
        let command = RewriteCommand.parse(phrase)
        #expect(command != nil, "Missing tone request: \(phrase)")
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("Preserve the meaning") == true)
    }

    @Test func toneRequestKeepsExplicitAndSuffixDraftsSeparate() {
        let leading = RewriteCommand.parse(
            "Change the tone to professional: hey Neil can you send the file?")
        #expect(leading?.spokenText == "hey Neil can you send the file?")
        let suffix = RewriteCommand.parse(
            "We cannot deliver Friday. Please change the tone to friendly.")
        #expect(suffix?.spokenText == "We cannot deliver Friday.")
        #expect(RewriteCommand.parse("Change the tone of what I just said to friendly.")?.prefersRecentText == true)
    }

    @Test func conversationalRemovalKeepsOnlyTheTopicAsTheInstruction() {
        let command = RewriteCommand.parse("Oh wait, could you remove the part about pricing please?")
        #expect(command?.isRemoval == true)
        #expect(command?.spokenText == "")
        #expect(command?.instruction.contains("pricing.") == true)
        #expect(command?.instruction.contains("please") == false)
        // An unspecified part is a local, explicitly selected deletion. It
        // must never become a rewrite of the entire recent insertion.
        #expect(RewriteCommand.parse("Oh wait, remove this part.") == nil)
    }

    @Test(arguments: [
        "The button says ‘Oh wait, make this better please.’",
        "He asked, could you please make this shorter?",
        "Write: can you make this better please.",
        "Literally say, change the tone to friendly.",
        "The note reads `change the tone to professional`.",
        "\"Can you make this shorter?\" is a question.",
        "Wait, make that call tomorrow.",
        "Actually, make this work tomorrow.",
        "Wait, make that reservation for Friday.",
        "Oh wait, make this booking for tomorrow.",
        "Wait, can you make that purchase today?",
        "Actually, make that reservation for Friday.",
        "Change the tone to friendly is the instruction on screen.",
        "Make it sound friendly is the instruction on screen.",
        "Make this more professional is the phrase on the button.",
        "Change the tone to friendly, she said.",
    ])
    func quotedReportedAndLiteralConversationalRequestsRemainContent(_ phrase: String) {
        #expect(RewriteCommand.parse(phrase) == nil, "Content became an edit: \(phrase)")
    }

}
