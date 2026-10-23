import AppKit
import Testing
import WhispCore
@testable import Whisp

@Suite(.serialized) @MainActor struct HUDWindowTests {
    @Test func floatingIndicatorNeverTakesKeyboardOrMouseInput() {
        _ = NSApplication.shared
        let hud = HUDWindow(reducedMotion: true)
        defer { hud.hide() }
        #expect(!hud.window.canBecomeKey)
        #expect(!hud.window.canBecomeMain)
        #expect(hud.window.ignoresMouseEvents)
        #expect(hud.window.styleMask.contains(.nonactivatingPanel))
    }

    @Test func errorsRemainReadableAndNextDictationIsCompact() {
        _ = NSApplication.shared
        let hud = HUDWindow(reducedMotion: true)
        defer { hud.hide() }
        let explanation = "Enable Accessibility for automatic paste. Dictation copied. Press Command+V to paste."
        hud.show(.error(explanation))
        #expect(hud.window.frame.width == 340)
        #expect(hud.window.title.contains(explanation))
        hud.show(.listening)
        #expect(hud.window.frame.size == NSSize(width: 80, height: 80))
        #expect(hud.window.title == "Whisp: Listening")
        hud.show(.idle)
        #expect(!hud.window.isVisible)
    }

    @Test func practiceFailureShowsMessageInsteadOfSuccessOnlyIcon() {
        _ = NSApplication.shared
        let hud = HUDWindow(reducedMotion: true)
        defer { hud.hide() }
        hud.showPracticeStatus("Microphone unavailable", done: true, error: true)
        #expect(hud.window.frame.width == 340)
        #expect(hud.window.title.contains("Microphone unavailable"))
        hud.showPractice(elapsed: 83)
        #expect(hud.window.frame.width == 80)
        #expect(hud.window.title == "Whisp: Practice recording, 1:23")
    }
}
