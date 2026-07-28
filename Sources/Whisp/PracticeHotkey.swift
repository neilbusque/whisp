import AppKit
import Carbon.HIToolbox
import WhispCore

/// A keycode-based global hotkey via Carbon's RegisterEventHotKey.
///
/// Deliberately a DIFFERENT mechanism from HotkeyMonitor's Fn CGEventTap: the
/// two cannot interfere, cannot double-fire, and Practice Mode cannot regress
/// dictation's latency. Carbon is the only supported API for a system-wide
/// hotkey that works without Accessibility permission.
@MainActor
final class PracticeHotkey {
    private let spec: HotkeySpec
    private let onFire: @Sendable () -> Void
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Carbon fires into a C callback with no context pointer we control per
    /// instance, so the active instance is looked up here. Whisp registers
    /// exactly one practice hotkey.
    @MainActor private static var active: PracticeHotkey?

    init(spec: HotkeySpec, onFire: @Sendable @escaping () -> Void) {
        self.spec = spec
        self.onFire = onFire
    }

    /// Returns false if the key is already claimed by another app, which Carbon
    /// reports rather than silently losing.
    @discardableResult
    func register() -> Bool {
        unregister()

        guard let keyCode = Self.virtualKeyCode(for: spec.key) else {
            Diag.log("practice hotkey: no virtual keycode for '\(spec.key)'")
            return false
        }

        var mods: UInt32 = 0
        if spec.control { mods |= UInt32(controlKey) }
        if spec.option { mods |= UInt32(optionKey) }
        if spec.command { mods |= UInt32(cmdKey) }
        if spec.shift { mods |= UInt32(shiftKey) }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { PracticeHotkey.active?.onFire() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard installStatus == noErr else {
            Diag.log("practice hotkey: InstallEventHandler failed (\(installStatus))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x57485350), id: 1)  // 'WHSP'
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            // Release the handler we just installed. Otherwise an abandoned
            // instance leaks it for the life of the process — and this branch
            // fires exactly when another app owns the chord, which is the case
            // a configurable hotkey exists to survive.
            if let handler {
                RemoveEventHandler(handler)
                self.handler = nil
            }
            Diag.log("practice hotkey: \(spec.display) is unavailable (status \(status)) — another app owns it")
            return false
        }

        Self.active = self
        Diag.log("practice hotkey: \(spec.display) registered")
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if Self.active === self { Self.active = nil }
    }

    /// ANSI virtual keycodes. Layout-independent for the physical key positions
    /// Whisp cares about; a Dvorak user editing practiceHotkey gets the ANSI
    /// position, which is the same trade every Mac app with a fixed default makes.
    private static func virtualKeyCode(for key: Character) -> Int? {
        let map: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        return map[key]
    }
}
