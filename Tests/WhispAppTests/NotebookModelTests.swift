import Foundation
import Testing
import WhispCore
@testable import Whisp

@Suite @MainActor struct NotebookModelTests {
    struct FakeOrganizer: Cleaning {
        var fail = false
        func complete(_ messages: [ChatMessage]) async throws -> String {
            if fail { throw NotebookError.invalidAnalysis }
            return #"{"title":"Editor idea","body":"Keep the editor quiet.","memories":[{"content":"Prefers quiet editors.","kind":"preference","evidence":"I prefer quiet editors."}]}"#
        }
    }
    @Test func capturePersistsOriginalAudioThenOrganizesAndLearns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispCapture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        let id = try model.capture(transcript: "I prefer quiet editors.", samples: Array(repeating: 0.1, count: 1600), cleaner: FakeOrganizer())
        #expect(model.notes.first?.transcript == "I prefer quiet editors.")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("note-audio/\(id.uuidString).wav").path))
        await model.waitForAnalysis()
        #expect(model.notes.first?.title == "Editor idea")
        #expect(model.notes.first?.body == "Keep the editor quiet.")
        #expect(model.memories.first?.sourceNoteID == id)
        let restored = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        #expect(restored.notes.first?.transcript == "I prefer quiet editors.")
        model.forget(model.memories[0].id)
        model.organize(model.notes[0], cleaner: FakeOrganizer())
        await model.waitForAnalysis()
        #expect(model.memories.isEmpty)
    }
    @Test func organizingATypedPageKeepsItsOriginalWords() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispTyped-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        let id = try #require(model.newNote())
        let note = try #require(model.notes.first)
        model.saveDraft(id: id, title: "An idea", body: "I prefer quiet editors.", expectedUpdatedAt: note.updatedAt)
        model.organize(try #require(model.notes.first), cleaner: FakeOrganizer())
        await model.waitForAnalysis()
        #expect(model.notes.first?.transcript == "I prefer quiet editors.")
        #expect(model.notes.first?.body == "Keep the editor quiet.")
        #expect(model.memories.first?.evidence == "I prefer quiet editors.")
    }
    @Test func externalProfileUpdatesDoNotReplaceAnUnsavedDraftOrGetClobbered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispProfile-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("context.md")
        try "Original profile".write(to: file, atomically: true, encoding: .utf8)
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        model.profile = "Unsaved local draft"
        try "Assistant update".write(to: file, atomically: true, encoding: .utf8)
        model.refresh(); model.saveProfile()
        #expect(try String(contentsOf: file, encoding: .utf8) == "Assistant update")
        #expect(model.profile == "Unsaved local draft")
        #expect(model.error != nil)
    }
    @Test func repeatedEditorSavesKeepTheDraftAndAdvanceItsTimestamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispDraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        _ = model.newNote()
        let draft = model.draft(for: try #require(model.notes.first))
        draft.title = "A real title"; draft.bodyText = "The first idea."
        draft.save(using: model); model.refresh()
        #expect(draft.title == "A real title")
        #expect(draft.bodyText == "The first idea.")
        #expect(!draft.isDirty)
        draft.bodyText += " A second point."
        draft.save(using: model); model.refresh()
        #expect(model.notes.first?.body == "The first idea. A second point.")
        #expect(model.error == nil)
        #expect(model.draft(for: try #require(model.notes.first)) === draft)
    }
    @Test func quittingFlushesTheLastKeystrokesWithoutWaitingForDebounce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispQuit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        _ = model.newNote()
        let draft = model.draft(for: try #require(model.notes.first))
        draft.bodyText = "The very last words."
        model.stop()
        #expect(model.notes.first?.body == "The very last words.")
    }
    @Test func disabledLearningAndAIFailurePreserveOriginalNotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhispCapture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = NotebookModel(path: dir.appendingPathComponent("notebook.sqlite3").path)
        model.setLearning(false)
        try model.capture(transcript: "I prefer quiet editors.", samples: [], cleaner: FakeOrganizer())
        await model.waitForAnalysis()
        #expect(model.memories.isEmpty)
        try model.capture(transcript: "An original idea.", samples: [], cleaner: FakeOrganizer(fail: true))
        await model.waitForAnalysis()
        #expect(model.notes.first?.body == "An original idea.")
        #expect(model.notes.count == 2)
        model.organize(try #require(model.notes.first), cleaner: FakeOrganizer())
        await model.waitForAnalysis()
        #expect(model.notice == nil)
    }
}
