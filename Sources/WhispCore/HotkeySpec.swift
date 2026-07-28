import Foundation

/// A parsed global-hotkey description, e.g. "ctrl+opt+cmd+r".
///
/// Deliberately does NOT support `fn`: the Fn key is delivered inconsistently
/// across Macs and is handled by HotkeyMonitor's dual-detector approach, which
/// is a different mechanism entirely. Practice Mode uses keycode-based Carbon
/// registration, so Fn is out of scope here and parsing it is an error.
public struct HotkeySpec: Equatable, Sendable {
    public let control: Bool
    public let option: Bool
    public let command: Bool
    public let shift: Bool
    /// A single lowercased letter or digit.
    public let key: Character

    public init(control: Bool, option: Bool, command: Bool, shift: Bool, key: Character) {
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
        self.key = key
    }

    /// Returns nil for anything malformed: no key, no modifier, more than one
    /// key, an unknown token, or `fn`. Callers fall back to the default.
    public static func parse(_ s: String) -> HotkeySpec? {
        let tokens = s.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var control = false, option = false, command = false, shift = false
        var key: Character?

        for t in tokens {
            switch t {
            case "ctrl", "control": control = true
            case "opt", "alt", "option": option = true
            case "cmd", "command": command = true
            case "shift": shift = true
            case "fn":
                // Explicitly reject fn; see docstring.
                return nil
            default:
                // Must be the single key: exactly one alphanumeric character.
                guard t.count == 1, let c = t.first, c.isLetter || c.isNumber else { return nil }
                guard key == nil else { return nil }  // two keys
                key = c
            }
        }

        guard let key else { return nil }
        guard control || option || command || shift else { return nil }
        return HotkeySpec(control: control, option: option, command: command,
                          shift: shift, key: key)
    }

    /// Mac-standard modifier order: ⌃⌥⇧⌘.
    public var display: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        out += String(key).uppercased()
        return out
    }
}
