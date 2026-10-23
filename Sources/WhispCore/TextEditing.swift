import Foundation

/// An edit is bound to the exact text inspected by the inserter. The opaque
/// identifier prevents a delayed result from replacing a newer selection.
public struct TextEditTarget: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let isExplicitSelection: Bool

    public init(id: UUID = UUID(), text: String, isExplicitSelection: Bool = false) {
        self.id = id
        self.text = text
        self.isExplicitSelection = isExplicitSelection
    }
}

public protocol TextEditing: Sendable {
    /// Returns an explicit selection or a verified recent Whisp insertion.
    /// Unsupported fields return nil; callers must never invent a target.
    func prepareEdit(preferRecent: Bool) async throws -> TextEditTarget?
    func replace(_ target: TextEditTarget, with text: String) async throws
}

/// Accessibility text ranges use UTF-16 offsets, not Swift character counts.
/// Reject malformed ranges and split graphemes before editing anything.
public struct TextEditRange: Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int? {
        guard location >= 0, length >= 0 else { return nil }
        let result = location.addingReportingOverflow(length)
        return result.overflow ? nil : result.partialValue
    }

    public func text(in value: String) -> String? {
        guard let range = stringRange(in: value) else { return nil }
        return String(value[range])
    }

    public func replacing(in value: String, with replacement: String) -> String? {
        guard let range = stringRange(in: value) else { return nil }
        return value.replacingCharacters(in: range, with: replacement)
    }

    private func stringRange(in value: String) -> Range<String.Index>? {
        guard let end = upperBound else { return nil }
        // Foundation's NSRange conversion can normalize a split UTF-16 index
        // when it becomes a String slice. Find exact Character boundaries
        // instead, preserving surrogate pairs and composed user-visible text.
        var offset = 0
        var cursor = value.startIndex
        var lower = location == 0 ? cursor : nil
        while offset < end && cursor < value.endIndex {
            let next = value.index(after: cursor)
            offset += value[cursor..<next].utf16.count
            cursor = next
            if offset == location { lower = cursor }
        }
        guard offset == end, let lower else { return nil }
        return lower..<cursor
    }
}
