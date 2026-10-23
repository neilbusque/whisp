import AppKit
import Testing
@testable import Whisp

@Suite @MainActor struct HUDNoticeViewTests {
    @Test func surfaceStaysDarkAndStaticInEitherAppearance() throws {
        let view = HUDNoticeView(frame: .zero)
        view.setMessage("Nothing heard")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let parent = NSView(frame: .zero)
            parent.appearance = NSAppearance(named: appearance)
            parent.addSubview(view)
            let color = try #require(view.layer?.backgroundColor)
            let rgb = try #require(NSColor(cgColor: color)?.usingColorSpace(.sRGB))
            #expect(abs(rgb.redComponent - 30.0 / 255) < 0.001)
            #expect(abs(rgb.greenComponent - 32.0 / 255) < 0.001)
            #expect(abs(rgb.blueComponent - 38.0 / 255) < 0.001)
            #expect(rgb.alphaComponent == 1)
            #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            #expect(view.layer?.animationKeys()?.isEmpty ?? true)
            view.removeFromSuperview()
        }
    }

    @Test func silentRecordingGetsNeutralActionableGuidance() throws {
        let view = HUDNoticeView(frame: .zero)
        for message in ["Nothing heard", "No audio captured"] {
            view.setMessage(message)
            #expect(try label("notice.heading", in: view).stringValue == "Nothing heard")
            #expect(try label("notice.detail", in: view).stringValue == "Hold Fn while you speak, then release.")
            #expect(view.accessibilityLabel()?.contains("Hold Fn") == true)
            let icon = try #require(view.subviews.compactMap { $0 as? NSImageView }.first)
            let tint = try #require(icon.contentTintColor?.usingColorSpace(.sRGB))
            #expect(abs(tint.redComponent - 178.0 / 255) < 0.001)
            #expect(!view.accessibilityLabel()!.contains("copied"))
        }
    }

    @Test func permissionNoticeRetainsEveryRecoveryStep() throws {
        let view = HUDNoticeView(frame: .zero)
        let message = "Enable Accessibility for automatic paste. Dictation copied. Press Command+V to paste."
        view.setMessage(message)
        #expect(try label("notice.heading", in: view).stringValue == "Enable Accessibility for automatic paste")
        #expect(try label("notice.detail", in: view).stringValue == "Dictation copied. Press Command+V to paste.")
        #expect(view.accessibilityLabel() == message)
        let icon = try #require(view.subviews.compactMap { $0 as? NSImageView }.first)
        let tint = try #require(icon.contentTintColor?.usingColorSpace(.sRGB))
        #expect(abs(tint.redComponent - 253.0 / 255) < 0.001)
    }

    @Test func textFieldGuidanceKeepsClipboardRecoveryWithoutInventingCopySuccess() throws {
        let view = HUDNoticeView(frame: .zero)
        let message = "Text field changed. Use Command+V or Copy Last Dictation."
        view.setMessage(message)
        #expect(try label("notice.heading", in: view).stringValue == "Choose a text field")
        let detail = try label("notice.detail", in: view).stringValue
        #expect(detail.contains("Click where you want the text."))
        #expect(detail.contains("Use Command+V or Copy Last Dictation."))
        #expect(!detail.lowercased().contains("copied"))
        #expect(view.accessibilityLabel() == message)
    }

    @Test func longRecoveryMessagesGrowWithoutClipping() throws {
        let view = HUDNoticeView(frame: .zero)
        view.setMessage("Nothing heard")
        let shortHeight = view.sizeThatFits(width: 340).height
        let recovery = String(repeating: "Check the selected text before trying again. ", count: 18)
            + "Use Command+V or Copy Last Dictation if needed."
        view.setMessage("Could not verify the edit. " + recovery)
        let size = view.sizeThatFits(width: 340)
        #expect(size.height > shortHeight * 3)
        #expect(size.width == 340)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let detail = try label("notice.detail", in: view)
        #expect(detail.stringValue == recovery)
        #expect(detail.maximumNumberOfLines == 0)
        #expect(detail.frame.maxY <= view.bounds.height - 11)
        #expect(detail.frame.height > 200)
        #expect(view.sizeThatFits(width: 280).height > size.height)
    }

    @Test func unsplitMessagesWrapCompletelyAndDoNotRetainPreviousDetail() throws {
        let view = HUDNoticeView(frame: .zero)
        view.setMessage("Nothing heard")
        let message = String(repeating: "A very long provider explanation without punctuation ", count: 8)
        view.setMessage(message)
        let size = view.sizeThatFits(width: 340)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let title = try label("notice.heading", in: view)
        #expect(title.stringValue == message.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(try label("notice.detail", in: view).isHidden)
        #expect(title.frame.maxY <= view.bounds.height - 11)
        #expect(title.frame.height > 100)
    }

    private func label(_ identifier: String, in view: HUDNoticeView) throws -> NSTextField {
        try #require(view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == identifier })
    }
}
