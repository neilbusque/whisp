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
        #expect(!hud.window.isOpaque)
        #expect(!hud.window.hasShadow)
        #expect(hud.window.backgroundColor.alphaComponent == 0)
        hud.show(.listening)
        let backings = hud.window.contentView?.subviews.compactMap { $0 as? HUDNoticeView } ?? []
        #expect(backings.count == 1)
        #expect(backings.allSatisfy { $0.isHidden })
    }

    @Test func errorsRemainReadableAndNextDictationIsCompact() {
        _ = NSApplication.shared
        let hud = HUDWindow(reducedMotion: true)
        defer { hud.hide() }
        let explanation = "Enable Accessibility for automatic paste. Dictation copied. Press Command+V to paste."
        hud.show(.error(explanation))
        #expect(hud.window.frame.width == 340)
        #expect(hud.window.title.contains(explanation))
        let notice = hud.window.contentView?.subviews.compactMap { $0 as? HUDNoticeView }.first
        let waveform = hud.window.contentView?.subviews.compactMap { $0 as? VoiceActivityView }.first
        #expect(notice?.isHidden == false)
        #expect(waveform?.isHidden == true)
        #expect(waveform?.state == .idle)
        hud.show(.listening)
        hud.setLevel(0.3)
        #expect(hud.window.frame.size == NSSize(width: 196, height: 76))
        #expect(hud.window.title == "Whisp: Listening")
        #expect(notice?.isHidden == true)
        #expect(waveform?.isHidden == false)
        #expect(waveform?.state == .listening)
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
        #expect(hud.window.frame.width == 196)
        #expect(hud.window.title == "Whisp: Practice recording, 1:23")
    }
}
