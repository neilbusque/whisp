import Foundation

public struct ClipboardSnapshot: Equatable, Sendable {
    public let string: String?
    public init(string: String?) { self.string = string }
}

public enum ClipboardPlan {
    public static func snapshot(currentString: String?) -> ClipboardSnapshot {
        ClipboardSnapshot(string: currentString)
    }
    public static func restoreString(from snap: ClipboardSnapshot) -> String? {
        snap.string
    }
}
