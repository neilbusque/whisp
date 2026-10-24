import AppKit
import AVFoundation
import SwiftUI
import WhispCore

@MainActor
final class NotebookModel: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published private(set) var memories: [MemoryFact] = []
    @Published var selectedNoteID: UUID?
    @Published var memoryTab = 0
    @Published var recording = false
    @Published var recordingStartedAt: Date?
    @Published var finishing = false
    @Published var analyzing: Set<UUID> = []
    @Published var error: String?
    @Published var notice: String?
    @Published var profile = Paths.loadContext()
    @Published var learnFromNotes = true
    @Published var playingNoteID: UUID?
    var toggleRecording: (() -> Void)?
    var onContextChanged: (() -> Void)?
    private var profileDirectory: String
    private var loadedProfile = Paths.loadContext()
    private var observedProfile = Paths.loadContext()
    private var profilePath: String { profileDirectory + "/context.md" }
    private func diskProfile() -> String { (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? "" }
    private var database: NotebookDatabase?
    private var player: AVAudioPlayer?
    private var drafts: [UUID: NotebookDraft] = [:]
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]

    init(path: String = Paths.dir + "/notebook.sqlite3") {
        profileDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let initialProfile = (try? String(contentsOfFile: profileDirectory + "/context.md", encoding: .utf8)) ?? ""
        profile = initialProfile; loadedProfile = initialProfile; observedProfile = initialProfile
        do {
            database = try NotebookDatabase(path: path)
            learnFromNotes = try database?.setting("learn_from_notes") != "false"
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        do {
            guard let database else { return }
            let nextNotes = try database.notes(), nextMemories = try database.memories()
            if notes != nextNotes { notes = nextNotes }
            for note in nextNotes { drafts[note.id]?.receive(note) }
            if memories != nextMemories { memories = nextMemories; onContextChanged?() }
            let nextLearning = try database.setting("learn_from_notes") != "false"
            if learnFromNotes != nextLearning { learnFromNotes = nextLearning }
            if let selectedNoteID, !notes.contains(where: { $0.id == selectedNoteID }) { self.selectedNoteID = nil }
            let currentProfile = diskProfile()
            if currentProfile != observedProfile {
                if profile == loadedProfile { profile = currentProfile; loadedProfile = currentProfile }
                observedProfile = currentProfile; onContextChanged?()
            }
            if let player, !player.isPlaying { playingNoteID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func draft(for note: VoiceNote) -> NotebookDraft {
        if let draft = drafts[note.id] { return draft }
        let draft = NotebookDraft(note: note)
        drafts[note.id] = draft
        return draft
    }
    func writingContext() -> String {
        (try? database?.writingContext(profile: diskProfile())) ?? diskProfile()
    }
    @discardableResult func newNote() -> UUID? {
        do {
            guard let database else { throw NotebookError.storage }
            let note = VoiceNote()
            try database.save(note); refresh(); selectedNoteID = note.id
            return note.id
        } catch { self.error = error.localizedDescription; return nil }
    }
    func saveDraft(id: UUID, title: String, body: String, expectedUpdatedAt: Date?) {
        do {
            guard let database, let note = try database.notes().first(where: { $0.id == id }) else { return }
            if let expectedUpdatedAt, note.updatedAt != expectedUpdatedAt,
               (note.title != title || note.body != body) {
                error = "This note changed in another app. Copy your draft before reloading it."
                return
            }
            guard note.title != title || note.body != body else { return }
            let savedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
            guard try database.updateDraft(id: id, title: savedTitle, body: body, expectedUpdatedAt: expectedUpdatedAt ?? note.updatedAt) else {
                error = "This note changed in another app. Copy your draft before reloading it."; return
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ id: UUID) {
        do {
            guard let database else { throw NotebookError.storage }
            analysisTasks[id]?.cancel(); analysisTasks[id] = nil
            let note = try database.notes().first { $0.id == id }
            try database.deleteNote(id)
            if playingNoteID == id { stopPlayback() }
            if let filename = note?.audioFilename, filename == id.uuidString + ".wav" {
                let url = URL(fileURLWithPath: profileDirectory + "/note-audio/" + filename)
                if FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    catch { self.error = "The note was deleted. Its recording could not be moved to Trash." }
                }
            }
            refresh(); onContextChanged?()
        } catch { self.error = error.localizedDescription }
    }
    /// Save the original before any AI request. Network failure never loses a note.
    @discardableResult func capture(transcript: String, samples: [Float], cleaner: Cleaning?) throws -> UUID {
        guard let database else { throw NotebookError.storage }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = VoiceNote(title: String(text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")),
                             body: text.isEmpty ? "Transcription unavailable. Your recording is saved." : text, transcript: text, duration: Double(samples.count) / 16_000)
        if note.title.isEmpty { note.title = "Voice recording" }
        let audioDir = URL(fileURLWithPath: profileDirectory + "/note-audio", isDirectory: true)
        if !samples.isEmpty {
            do {
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let filename = note.id.uuidString + ".wav"
                let url = audioDir.appendingPathComponent(filename)
                try WavCodec.encode(samples: samples).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                note.audioFilename = filename
            } catch { self.error = "The transcript was saved, but audio could not be kept." }
        }
        try database.save(note); refresh(); selectedNoteID = note.id
        notice = "Note saved"
        if let cleaner, !text.isEmpty { organize(note, cleaner: cleaner) }
        return note.id
    }
    func organize(_ note: VoiceNote, cleaner: Cleaning) {
        guard analysisTasks[note.id] == nil else { return }
        notice = nil
        analyzing.insert(note.id)
        let context = writingContext()
        let mayLearn = learnFromNotes
        analysisTasks[note.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { analyzing.remove(note.id); analysisTasks[note.id] = nil }
            do {
                let response = try await cleaner.complete(NoteAnalysis.prompt(transcript: note.transcript.isEmpty ? note.body : note.transcript, context: context))
                try Task.checkCancellation()
                let original = note.transcript.isEmpty ? note.body : note.transcript
                let analysis = try NoteAnalysis.parse(response, transcript: original)
                guard let database, var current = try database.notes().first(where: { $0.id == note.id }) else { return }
                // An edit made while analysis runs always wins.
                if current.updatedAt == note.updatedAt {
                    if current.transcript.isEmpty { current.transcript = original }
                    current.title = String(analysis.title.prefix(160)); current.body = analysis.body
                    current.updatedAt = Date(); try database.save(current)
                }
                if mayLearn && learnFromNotes && current.updatedAt >= note.updatedAt {
                    var existing = try database.memories().map { $0.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                    for fact in analysis.supportedMemories(transcript: original, noteID: note.id) {
                        let key = fact.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !existing.contains(key), try !database.isForgotten(fact.content) { try database.save(fact); existing.append(key) }
                    }
                }
                refresh(); onContextChanged?()
            } catch is CancellationError { }
            catch { notice = "Original note saved. AI organization was unavailable." }
        }
    }
    func setLearning(_ enabled: Bool) {
        do { try database?.setSetting("learn_from_notes", enabled ? "true" : "false"); learnFromNotes = enabled }
        catch { self.error = error.localizedDescription }
    }
    func saveMemory(_ memory: MemoryFact) {
        do {
            guard let database else { throw NotebookError.storage }
            var memory = memory; memory.updatedAt = Date()
            guard !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try database.save(memory); refresh(); onContextChanged?()
        } catch { self.error = error.localizedDescription }
    }
    func forget(_ id: UUID) {
        do { try database?.forget(id); refresh(); onContextChanged?() }
        catch { self.error = error.localizedDescription }
    }
    func saveProfile() {
        do {
            guard diskProfile() == loadedProfile else {
                error = "Your profile changed in another app. Copy your draft before reloading it."; return
            }
            let backup = URL(fileURLWithPath: profileDirectory + "/backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try loadedProfile.write(to: backup.appendingPathComponent("context-" + UUID().uuidString + ".md"), atomically: true, encoding: .utf8)
            try profile.write(toFile: profilePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilePath)
            loadedProfile = profile; observedProfile = profile
            notice = "Profile saved"; onContextChanged?()
        } catch { self.error = error.localizedDescription }
    }
    func togglePlayback(_ note: VoiceNote) {
        if playingNoteID == note.id { stopPlayback(); return }
        stopPlayback()
        guard let filename = note.audioFilename, filename == note.id.uuidString + ".wav" else { return }
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: profileDirectory + "/note-audio/" + filename))
            guard player?.play() == true else { throw NotebookError.storage }
            playingNoteID = note.id
        } catch { self.error = "The recording could not be played." }
    }
    func stopPlayback() { player?.stop(); player = nil; playingNoteID = nil }
    func export(_ note: VoiceNote) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Whisp note.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "America/New_York")
            formatter.dateStyle = .long; formatter.timeStyle = .short
            let markdown = "# \(note.title)\n\n\(formatter.string(from: note.createdAt)) Eastern\n\n\(note.body)\n"
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        for draft in Array(drafts.values) { draft.save(using: self) }
        stopPlayback(); for task in analysisTasks.values { task.cancel() }
    }
    func waitForAnalysis() async { for task in analysisTasks.values { await task.value } }
}

/// Draft lifetime belongs to the notebook, so a database refresh cannot reset an
/// editor. The timestamp advances only after its own save is acknowledged.
@MainActor
final class NotebookDraft: ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var bodyText: String
    private var savedTitle: String
    private var savedBody: String
    private var baseDate: Date
    var isDirty: Bool { title != savedTitle || bodyText != savedBody }
    init(note: VoiceNote) {
        id = note.id; title = note.title; bodyText = note.body
        savedTitle = note.title; savedBody = note.body; baseDate = note.updatedAt
    }
    func receive(_ note: VoiceNote) {
        guard !isDirty, note.updatedAt != baseDate else { return }
        savedTitle = note.title; savedBody = note.body; baseDate = note.updatedAt
        title = note.title; bodyText = note.body
    }
    func save(using model: NotebookModel) {
        guard isDirty else { return }
        let expectedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        model.saveDraft(id: id, title: expectedTitle, body: bodyText, expectedUpdatedAt: baseDate)
        if let current = model.notes.first(where: { $0.id == id }),
           current.title == expectedTitle, current.body == bodyText {
            objectWillChange.send()
            savedTitle = current.title; savedBody = current.body; baseDate = current.updatedAt
            title = current.title
        }
    }
}
