import Foundation
import Testing
@testable import WhispCore

@Suite struct NotebookTests {
    private func withDatabase(_ body: (NotebookDatabase, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhispNotebook-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("notebook.sqlite3").path
        try body(NotebookDatabase(path: path), path)
    }
    @Test func notesAndMemoriesSurviveReopenAndDeletionRemovesDerivedFacts() throws {
        try withDatabase { db, path in
            let note = VoiceNote(title: "A project idea", body: "Keep the editor simple.", transcript: "I prefer simple editors.")
            try db.save(note)
            try db.save(MemoryFact(content: "Prefers simple editors.", kind: .preference,
                                   evidence: note.transcript, sourceNoteID: note.id))
            let second = try NotebookDatabase(path: path)
            #expect(try second.notes() == [note])
            #expect(try second.memories().count == 1)
            try db.deleteNote(note.id)
            #expect(try second.notes().isEmpty)
            #expect(try second.memories().isEmpty)
        }
    }
    @Test func quotingAndSQLLikeTextRoundTripsWithoutExecuting() throws {
        try withDatabase { db, _ in
            var note = VoiceNote(title: "Robert's idea", body: "'); DROP TABLE notes; --")
            try db.save(note); note.body = "An updated idea."; try db.save(note)
            #expect(try db.notes().count == 1)
            #expect(try db.notes().first?.body == "An updated idea.")
            #expect(try db.notes().first?.createdAt == note.createdAt)
        }
    }
    @Test func pausedAndOldActivityDoNotEnterWritingContext() throws {
        try withDatabase { db, _ in
            try db.save(MemoryFact(content: "Prefers plain English.", kind: .preference))
            try db.save(MemoryFact(content: "This is paused.", enabled: false))
            try db.save(MemoryFact(content: "An old plan.", kind: .activity, updatedAt: Date(timeIntervalSinceNow: -15 * 86400)))
            let context = try db.writingContext(profile: "User profile")
            #expect(context.contains("User profile"))
            #expect(context.contains("Prefers plain English."))
            #expect(!context.contains("This is paused."))
            #expect(!context.contains("An old plan."))
        }
    }
    @Test func learningPreferencePersistsWithoutTouchingOtherSettings() throws {
        try withDatabase { db, path in
            try db.setSetting("learn_from_notes", "false")
            #expect(try NotebookDatabase(path: path).setting("learn_from_notes") == "false")
            #expect(try db.setting("missing") == nil)
        }
    }
    @Test func staleAppEditsCannotOverwriteConnectorChangesAndForgottenFactsStayForgotten() throws {
        try withDatabase { db, path in
            let note = VoiceNote(title: "Original", body: "Original body")
            try db.save(note)
            let second = try NotebookDatabase(path: path)
            #expect(try second.updateDraft(id: note.id, title: "External", body: "Updated elsewhere", expectedUpdatedAt: note.updatedAt))
            #expect(try !db.updateDraft(id: note.id, title: "Clobber", body: "Old draft", expectedUpdatedAt: note.updatedAt))
            #expect(try db.notes().first?.title == "External")
            let fact = MemoryFact(content: "Prefers a quiet editor.")
            try db.save(fact); try db.forget(fact.id)
            #expect(try second.isForgotten("Prefers a quiet editor."))
            #expect(try db.memories().isEmpty)
        }
    }
    @Test func unsupportedMemoryEvidenceIsDiscarded() throws {
        let raw = "I prefer short notes. I am working on Example Studio this week."
        let json = #"{"title":"Editor ideas","body":"Keep notes short.","memories":[{"content":"Prefers short notes.","kind":"preference","evidence":"I prefer short notes."},{"content":"A made up personal fact.","kind":"personal","evidence":"This was never spoken."}]}"#
        let analysis = try NoteAnalysis.parse(json, transcript: raw)
        let facts = analysis.supportedMemories(transcript: raw, noteID: UUID())
        #expect(facts.count == 1)
        #expect(facts.first?.content == "Prefers short notes.")
        #expect(throws: NotebookError.self) { try NoteAnalysis.parse("not JSON", transcript: raw) }
    }
}
