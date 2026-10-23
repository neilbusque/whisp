import Foundation
import WhispCore

/// Opt-in synthetic checks use the same pipeline and writer as dictation.
/// No microphone, clipboard, history, or application text is touched.
enum VoiceEditEvaluation {
    private struct NoAudio: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String { throw CancellationError() }
    }
    private actor Draft: TextInserting, TextEditing {
        var text: String
        private var target: TextEditTarget?
        private let isExplicitSelection: Bool
        init(_ text: String, isExplicitSelection: Bool = false) {
            self.text = text
            self.isExplicitSelection = isExplicitSelection
        }
        func insert(_ text: String) { self.text = text }
        func prepareEdit(preferRecent: Bool) -> TextEditTarget? {
            guard !text.isEmpty else { return nil }
            let result = TextEditTarget(text: text, isExplicitSelection: isExplicitSelection)
            target = result
            return result
        }
        func replace(_ target: TextEditTarget, with text: String) throws {
            guard self.target == target else { throw CancellationError() }
            self.text = text
        }
    }
    struct Example {
        let name: String
        let speech: String
        var prior = ""
        var includes: [String] = []
        var excludes: [String] = []
        var exact: String? = nil
        var cleanupMode: CleanupMode = .fast
        var mustChange: Bool = false
        var isExplicitSelection: Bool = false
        var includesOneOf: [[String]] = []
        var ending: String? = nil
    }
    static func run() async throws {
        let config = try Paths.loadConfig()
        let writer = OpenAICleaner(apiKey: config.openaiKey, model: config.textModel)
        let examples: [Example] = [
            .init(name: "fillers", speech: "Um, uh, send the draft tomorrow", exact: "Send the draft tomorrow."),
            .init(name: "date correction", speech: "Meet me Thursday, no, I mean Friday at three.",
                  includes: ["Friday", "three"], excludes: ["Thursday", "I mean"]),
            .init(name: "negation correction", speech: "I can attend, actually I cannot attend.",
                  includes: ["cannot attend"], excludes: ["I can attend", "actually"]),
            .init(name: "same turn restart", speech: "Send it today. Start over. Can you send it tomorrow?",
                  exact: "Can you send it tomorrow?"),
            .init(name: "inline removal", speech: "The proposal is ready. The budget is tentative. Scratch that last sentence.",
                  includes: ["proposal", "ready"], excludes: ["budget", "Scratch"]),
            .init(name: "style and spoken source", speech: "Rewrite this more professionally: hey can you send the draft by Friday?",
                  includes: ["draft", "Friday"], excludes: ["hey", "Rewrite", "professionally"]),
            .init(name: "rewrite previous", speech: "Make this shorter.",
                  prior: "I wanted to ask whether you could possibly send me the draft by Friday.",
                  includes: ["draft", "Friday"], excludes: ["Make this"], mustChange: true),
            .init(name: "targeted removal", speech: "Remove the sentence about the budget.",
                  prior: "The proposal is ready. The budget is tentative.",
                  includes: ["proposal", "ready"], excludes: ["budget", "Remove"]),
            .init(name: "delete previous", speech: "Scratch that.", prior: "Only this insertion.", exact: ""),
            .init(name: "remove entire target", speech: "Remove the sentence about pricing.", prior: "Pricing is $500.", exact: ""),
            .init(name: "correct previous", speech: "Actually, make that Friday.", prior: "Meet me Thursday at three.",
                  includes: ["Friday", "three"], excludes: ["Thursday", "Actually"]),
            .init(name: "rewrite it", speech: "Um, make it shorter.",
                  prior: "I wanted to ask whether you could possibly send me the draft by Friday.",
                  includes: ["draft", "Friday"], excludes: ["Make it", "Um"], mustChange: true),
            .init(name: "quoted words", speech: "The button says ‘delete that’.", exact: "The button says ‘delete that’."),
            .init(name: "automatic polish", speech: "So basically I just wanted to ask if you could, like, send me the final draft by Friday please.",
                  includes: ["final draft", "Friday"], excludes: ["basically", "wanted to ask", "like,"],
                  cleanupMode: .smart),
            .init(name: "preserve uncertainty", speech: "Um, we might launch Friday if legal approves. It is not confirmed.",
                  includes: ["might", "Friday", "legal", "not confirmed"], excludes: ["Um", "will launch"],
                  cleanupMode: .smart),
            .init(name: "natural tone followup", speech: "Oh wait, make this better please.",
                  prior: "So basically I just wanted to ask if you could send me the draft by Friday.",
                  includes: ["draft", "Friday"], excludes: ["basically", "wanted to ask", "Oh wait", "make this"],
                  cleanupMode: .smart, mustChange: true),
            .init(name: "natural removal followup", speech: "Oh wait, remove the part about the budget please.",
                  prior: "The proposal is ready. The budget is tentative. Delivery is Friday.",
                  includes: ["proposal", "ready", "Friday"], excludes: ["budget", "Oh wait", "remove"],
                  cleanupMode: .smart),
            .init(name: "remove highlighted part", speech: "Oh wait, remove this part please.",
                  prior: "Remove only this selected sentence.", exact: "", cleanupMode: .smart,
                  isExplicitSelection: true),
            .init(name: "inline natural removal", speech: "The proposal is ready. The budget is tentative. Oh wait, remove the part about the budget please.",
                  includes: ["proposal", "ready"], excludes: ["budget", "Oh wait", "remove"],
                  cleanupMode: .smart),
            .init(name: "reported editing request", speech: "She told me to make it better please, but I only changed punctuation.",
                  includes: ["make it better", "only changed", "punctuation"], cleanupMode: .smart,
                  includesOneOf: [["told me", "asked me"]]),
            .init(name: "question remains a question", speech: "Could you send me the draft by Friday?",
                  includes: ["send", "draft", "Friday"], cleanupMode: .smart,
                  includesOneOf: [["could you", "can you", "would you", "will you"]], ending: "?"),
        ]
        var failed = 0
        for example in examples {
            let draft = Draft(example.prior, isExplicitSelection: example.isExplicitSelection)
            let pipe = SpeechPipeline(snippets: .init(snippets: []), transcriber: NoAudio(),
                cleaner: writer, inserter: draft, editor: draft, cleanupMode: example.cleanupMode,
                onStatus: { status in if case .error(let message) = status { print("error: \(message)") } })
            let started = ContinuousClock.now
            await pipe.process(transcript: example.speech)
            let output = await draft.text
            let contentMatches = example.exact.map { output == $0 } ??
                (example.includes.allSatisfy { output.localizedCaseInsensitiveContains($0) } &&
                 example.excludes.allSatisfy { !output.localizedCaseInsensitiveContains($0) })
            let alternativesMatch = example.includesOneOf.allSatisfy { alternatives in
                alternatives.contains { output.localizedCaseInsensitiveContains($0) }
            }
            let endingMatches = example.ending.map { output.hasSuffix($0) } ?? true
            let passed = contentMatches && alternativesMatch && endingMatches
                && (!example.mustChange || output != example.prior)
            if !passed { failed += 1 }
            print("\(passed ? "PASS" : "FAIL") \(example.name) \(started.duration(to: .now))")
            print("  \(output)")
        }
        guard failed == 0 else {
            throw NSError(domain: "Whisp.Evaluation", code: failed,
                          userInfo: [NSLocalizedDescriptionKey: "\(failed) voice-edit examples failed"])
        }
    }
}
