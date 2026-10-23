import AppKit
import Foundation
import Testing
import WhispCore
@testable import Whisp

@Suite @MainActor struct ClipboardRecoveryTests {
    @Test func completedDictationStaysCopiedAfterConsumptionWindow() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.setString("previous copy", forType: .string)

        #expect(ClipboardTransaction.publish("Finished dictation.", to: pb))
        let publishedChange = pb.changeCount
        await PasteConsumption.wait(verify: nil, pause: { _ in })

        #expect(pb.string(forType: .string) == "Finished dictation.")
        #expect(pb.changeCount == publishedChange)
    }

    @Test func newerUserCopySurvivesPasteCompletion() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        #expect(ClipboardTransaction.publish("Finished dictation.", to: pb))
        let rich = Data("{\\rtf1 user copy}".utf8)
        let image = Data([0x89, 0x50, 0x4e, 0x47])

        await PasteConsumption.wait(verify: nil, pause: { _ in
            let item = NSPasteboardItem()
            item.setString("user copied this", forType: .string)
            item.setData(rich, forType: .rtf)
            item.setData(image, forType: .png)
            pb.clearContents()
            pb.writeObjects([item])
        })

        #expect(pb.string(forType: .string) == "user copied this")
        #expect(pb.data(forType: .rtf) == rich)
        #expect(pb.data(forType: .png) == image)
    }

    @Test func deniedAutomaticPasteStillCopiesFinishedText() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.setString("previous copy", forType: .string)
        let inserter = PasteInserter(pasteboard: pb, isAccessibilityTrusted: { false })

        do {
            try await inserter.insert("Recovered dictation.")
            Issue.record("Automatic paste must fail without Accessibility permission")
        } catch {
            #expect(error.localizedDescription.contains("Command+V"))
        }

        #expect(pb.string(forType: .string) == "Recovered dictation.")
    }

    @Test func expiredEditStillCopiesItsFinishedReplacement() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let inserter = PasteInserter(pasteboard: pb, isAccessibilityTrusted: { true })

        do {
            try await inserter.replace(.init(text: "old text"), with: "Rewritten text.")
            Issue.record("An unprepared edit must never mutate a text field")
        } catch {
            #expect(error.localizedDescription.contains("expired"))
            #expect(error.localizedDescription.contains("Command+V"))
        }

        #expect(pb.string(forType: .string) == "Rewritten text.")
    }

    @Test func deletionDoesNotClearExistingClipboardContents() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let rich = Data("{\\rtf1 keep this}".utf8)
        let item = NSPasteboardItem()
        item.setString("keep this", forType: .string)
        item.setData(rich, forType: .rtf)
        pb.writeObjects([item])
        let existingChange = pb.changeCount
        let inserter = PasteInserter(pasteboard: pb, isAccessibilityTrusted: { false })

        do {
            try await inserter.replace(.init(text: "remove this"), with: "")
            Issue.record("An unapproved deletion must never mutate a text field")
        } catch {
            #expect(!error.localizedDescription.contains("Dictation copied"))
        }

        #expect(pb.changeCount == existingChange)
        #expect(pb.string(forType: .string) == "keep this")
        #expect(pb.data(forType: .rtf) == rich)
    }

    @Test func cancelledDictationDoesNotReplaceClipboard() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.setString("keep this", forType: .string)
        let existingChange = pb.changeCount
        let inserter = PasteInserter(pasteboard: pb, isAccessibilityTrusted: { false })
        let task = Task { @MainActor in
            do {
                try await inserter.insert("Cancelled text")
                Issue.record("Cancelled dictation must not be inserted")
            } catch {
                #expect(error is CancellationError)
            }
        }
        task.cancel()
        await task.value

        #expect(pb.changeCount == existingChange)
        #expect(pb.string(forType: .string) == "keep this")
    }
}
