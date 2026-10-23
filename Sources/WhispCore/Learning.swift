import Foundation

public struct CorrectionRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var heard: String
    public var intended: String
    public var enabled: Bool
    public init(id: UUID = UUID(), heard: String, intended: String, enabled: Bool = true) {
        self.id = id; self.heard = heard; self.intended = intended; self.enabled = enabled
    }

    public var matchKey: String { heard.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }

    public func validated() throws -> Self {
        var rule = self
        rule.heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.intended = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.heard.isEmpty, !rule.intended.isEmpty else {
            throw LearningError.invalid("Enter both what Whisp heard and what you meant.")
        }
        guard rule.heard.count <= 200, rule.intended.count <= 200 else {
            throw LearningError.invalid("Use a word or short phrase, up to 200 characters.")
        }
        guard rule.heard != rule.intended else {
            throw LearningError.invalid("The correction must be different from what Whisp heard.")
        }
        return rule
    }
}

public enum LearningError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Compiled once per edit. Matches whole phrases against the original text,
/// longest first, without cascading one replacement into another.
public struct CorrectionEngine: @unchecked Sendable {
    private let rules: [(CorrectionRule, NSRegularExpression)]
    public init(rules: [CorrectionRule]) {
        self.rules = rules.filter(\.enabled).sorted {
            if $0.heard.count != $1.heard.count { return $0.heard.count > $1.heard.count }
            return $0.id.uuidString < $1.id.uuidString
        }.compactMap { rule in
            guard (try? rule.validated()) != nil else { return nil }
            let words = rule.heard.split(whereSeparator: \.isWhitespace)
            let body = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            let pattern = "(?<![\\p{L}\\p{N}_])" + body + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (rule, regex)
        }
    }
    public func apply(_ text: String, transformUnmatched: (String) -> String = { $0 }) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        var replacements: [(NSRange, String)] = []
        for (rule, regex) in rules {
            for match in regex.matches(in: text, range: fullRange) {
                guard !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                replacements.append((match.range, rule.intended))
            }
        }
        let original = text as NSString
        var result = ""
        var position = 0
        for (range, value) in replacements.sorted(by: { $0.0.location < $1.0.location }) {
            result += transformUnmatched(original.substring(with: NSRange(location: position, length: range.location - position)))
            result += value
            position = NSMaxRange(range)
        }
        result += transformUnmatched(original.substring(from: position))
        return result
    }
}

public struct DictationResult: Sendable {
    public let raw: String
    public let output: String
    public init(raw: String, output: String) { self.raw = raw; self.output = output }
}

public struct DictationEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var raw: String
    public var output: String
    public var reference: String?
    public var model: String
    public var duration: Double
    public var processingSeconds: Double
    public var hasAudio: Bool
    public init(id: UUID = UUID(), createdAt: Date = Date(), raw: String, output: String,
                model: String, duration: Double, processingSeconds: Double, hasAudio: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.raw = raw; self.output = output
        self.model = model; self.duration = duration; self.processingSeconds = processingSeconds
        self.hasAudio = hasAudio
    }
    public var audioFilename: String { id.uuidString + ".wav" }
}

public struct LearningData: Codable, Equatable, Sendable {
    public var version = 1
    public var rules: [CorrectionRule] = []
    public var entries: [DictationEntry] = []
    public init() {}
    public mutating func saveRule(_ rule: CorrectionRule) throws {
        let valid = try rule.validated()
        guard !rules.contains(where: { $0.id != valid.id && $0.matchKey == valid.matchKey }) else {
            throw LearningError.invalid("That phrase already has a correction. Edit the existing one.")
        }
        if let index = rules.firstIndex(where: { $0.id == valid.id }) { rules[index] = valid }
        else { rules.insert(valid, at: 0) }
    }
    public mutating func importRules(_ rules: [CorrectionRule]) throws {
        var updated = self
        for imported in rules {
            var valid = try imported.validated()
            valid.id = updated.rules.first(where: { $0.matchKey == valid.matchKey })?.id ?? UUID()
            try updated.saveRule(valid)
        }
        self = updated
    }
    @discardableResult public mutating func append(_ entry: DictationEntry, limit: Int = 100) -> [DictationEntry] {
        entries.insert(entry, at: 0)
        let removed = Array(entries.dropFirst(max(0, limit)))
        entries = Array(entries.prefix(max(0, limit)))
        return removed
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func load(_ data: Data) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.version == 1 else { throw LearningError.invalid("This learning file was created by a newer Whisp version.") }
        guard Set(decoded.rules.map(\.id)).count == decoded.rules.count,
              Set(decoded.entries.map(\.id)).count == decoded.entries.count else {
            throw LearningError.invalid("The learning file contains duplicate identifiers.")
        }
        for rule in decoded.rules { _ = try rule.validated() }
        return decoded
    }
}
