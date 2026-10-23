import Foundation

/// A thing to practise saying. Sessions are tagged to one so metrics compare
/// like with like across attempts at the same answer.
public struct PracticePrompt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

/// Mirrors SnippetStore deliberately — same shape, same method names — so
/// there is one storage pattern in this codebase, not two.
public final class PromptStore {
    private(set) public var prompts: [PracticePrompt]

    public init(prompts: [PracticePrompt]) { self.prompts = prompts }

    public var all: [PracticePrompt] { prompts }

    public static func load(from data: Data) throws -> PromptStore {
        PromptStore(prompts: try JSONDecoder().decode([PracticePrompt].self, from: data))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(prompts)
    }

    public func prompt(id: UUID) -> PracticePrompt? {
        prompts.first { $0.id == id }
    }

    public func upsert(_ p: PracticePrompt) {
        if let i = prompts.firstIndex(where: { $0.id == p.id }) { prompts[i] = p }
        else { prompts.append(p) }
    }

    public func delete(id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    public static let seed: [PracticePrompt] = [
        PracticePrompt(title: "Tell me about yourself",
                       text: "Two minutes. Where you are now, what you do, what you want next."),
        PracticePrompt(title: "Why should we hire you?",
                       text: "90 seconds. Lead with the result, not the resume."),
        PracticePrompt(title: "Walk me through a campaign you ran",
                       text: "Situation, what you changed, the number it moved, what you'd do differently."),
        PracticePrompt(title: "Pitch an idea",
                       text: "60 seconds. Who it's for, the problem, the offer, the proof."),
    ]
}
