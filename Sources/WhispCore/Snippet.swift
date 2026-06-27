import Foundation

public enum SnippetMode: String, Codable, Equatable, Sendable {
    case verbatim
    case ai
}

public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var keyword: String
    public var mode: SnippetMode
    public var content: String
    public var enabled: Bool

    public init(id: UUID = UUID(), keyword: String, mode: SnippetMode,
                content: String, enabled: Bool = true) {
        self.id = id
        self.keyword = keyword
        self.mode = mode
        self.content = content
        self.enabled = enabled
    }
}

public struct SnippetMatch: Equatable {
    public let snippet: Snippet
    public let remainder: String
}
