import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import WhispCore

@MainActor
final class LearningModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var data = LearningData()
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var playingID: UUID?
    var onRulesChanged: ([CorrectionRule]) -> Void = { _ in }
    private var player: AVAudioPlayer?
    private let file: URL
    private let audioDirectory: URL
    private var undoRules: [CorrectionRule]?
    var canUndo: Bool { undoRules != nil }

    init(directory: URL = URL(fileURLWithPath: Paths.dir)) {
        file = directory.appendingPathComponent("learning.json")
        audioDirectory = directory.appendingPathComponent("learning-audio", isDirectory: true)
        super.init()
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                data = try LearningData.load(Data(contentsOf: file))
            }
            isLoaded = true
        } catch {
            isLoaded = false
            self.error = "Could not read learning data. The original file has been kept. \(error.localizedDescription)"
        }
    }

    private func commit(_ updated: LearningData) throws {
        guard isLoaded else { throw LearningError.invalid("Learning data could not be loaded. Repair the file before saving.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.encoded().write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        data = updated
        error = nil
    }

    @discardableResult func saveRule(_ rule: CorrectionRule) -> Bool {
        do {
            var updated = data
            try updated.saveRule(rule)
            let previous = data.rules
            try commit(updated)
            undoRules = previous
            notice = "Correction saved. It applies to your next dictation."
            onRulesChanged(data.rules)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deleteRule(_ id: UUID) {
        do {
            var updated = data
            updated.rules.removeAll { $0.id == id }
            let previous = data.rules
            try commit(updated)
            undoRules = previous
            notice = "Correction removed. You can undo this."
            onRulesChanged(data.rules)
        } catch { self.error = error.localizedDescription }
    }

    func undo() {
        guard let undoRules else { return }
        do {
            var updated = data; updated.rules = undoRules
            try commit(updated)
            self.undoRules = nil
            notice = "Correction change undone."
            onRulesChanged(data.rules)
        } catch { self.error = error.localizedDescription }
    }

    func remember(_ result: DictationResult, samples: [Float], model: String,
                  seconds: Double, saveAudio: Bool) async {
        var entry = DictationEntry(raw: result.raw, output: result.output, model: model,
            duration: Double(samples.count) / 16_000, processingSeconds: seconds)
        do {
            if saveAudio {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDirectory.path)
                let encoded = await Task.detached(priority: .utility) { WavCodec.encode(samples: samples) }.value
                try encoded.write(to: audioURL(entry), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL(entry).path)
                entry.hasAudio = true
            }
            var updated = data
            let evicted = updated.append(entry)
            do { try commit(updated) }
            catch {
                if entry.hasAudio { try? FileManager.default.removeItem(at: audioURL(entry)) }
                throw error
            }
            for old in evicted where old.hasAudio { try? FileManager.default.removeItem(at: audioURL(old)) }
        } catch { self.error = "Dictation completed, but its example could not be saved: \(error.localizedDescription)" }
    }

    func saveReference(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "Enter the words you actually said before saving a reference."; return }
        do {
            var updated = data
            guard let index = updated.entries.firstIndex(where: { $0.id == id }) else { return }
            updated.entries[index].reference = trimmed
            try commit(updated)
            notice = "Reference saved for review and export. Add a correction for words to fix automatically."
        } catch { self.error = error.localizedDescription }
    }

    func deleteEntry(_ id: UUID) {
        do {
            guard let entry = data.entries.first(where: { $0.id == id }) else { return }
            var updated = data; updated.entries.removeAll { $0.id == id }
            try commit(updated)
            if entry.hasAudio { try FileManager.default.trashItem(at: audioURL(entry), resultingItemURL: nil) }
            notice = "Dictation removed. Any saved audio was moved to Trash."
        } catch { self.error = error.localizedDescription }
    }

    func clearHistory() {
        do {
            var updated = data; updated.entries = []
            try commit(updated)
            if FileManager.default.fileExists(atPath: audioDirectory.path) {
                try FileManager.default.trashItem(at: audioDirectory, resultingItemURL: nil)
            }
            notice = "Dictation history cleared. Saved audio was moved to Trash."
        } catch { self.error = error.localizedDescription }
    }

    func play(_ entry: DictationEntry) {
        if playingID == entry.id { stopPlayback(); return }
        do {
            stopPlayback()
            player = try AVAudioPlayer(contentsOf: audioURL(entry))
            player?.delegate = self
            guard player?.play() == true else { throw LearningError.invalid("Playback could not start.") }
            playingID = entry.id
        } catch { self.error = "Could not play this recording: \(error.localizedDescription)" }
    }
    func stopPlayback() { player?.stop(); player = nil; playingID = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished { self.stopPlayback() }
        }
    }
    func audioURL(_ entry: DictationEntry) -> URL { audioDirectory.appendingPathComponent(entry.audioFilename) }

    func importCorrections() {
        let panel = NSOpenPanel()
        panel.title = "Import Whisp corrections"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try LearningData.load(Data(contentsOf: url))
            guard !imported.rules.isEmpty else { notice = "This dataset contains no corrections."; return }
            let alert = NSAlert()
            alert.messageText = "Import \(imported.rules.count) saved \(imported.rules.count == 1 ? "correction" : "corrections")?"
            alert.informativeText = "Matching phrases will be updated. Your other corrections and recent dictations are kept. You can undo the import."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var updated = data
            try updated.importRules(imported.rules)
            let previous = data.rules
            try commit(updated)
            undoRules = previous
            onRulesChanged(data.rules)
            notice = "Corrections imported and ready for your next dictation."
        } catch { self.error = "Import failed: \(error.localizedDescription)" }
    }

    func exportDataset() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to export your Whisp dataset"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let folder = parent.appendingPathComponent("Whisp Dataset \(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Explicit references only: unreviewed recognizer output must never
            // masquerade as training ground truth.
            var exported = data
            exported.entries = data.entries.filter { $0.reference != nil }
            for entry in exported.entries where entry.hasAudio {
                try FileManager.default.copyItem(at: audioURL(entry), to: folder.appendingPathComponent(entry.audioFilename))
            }
            try exported.encoded().write(to: folder.appendingPathComponent("dataset.json"), options: .atomic)
            try "Whisp local dataset v1. Only reviewed references are exported. Audio files are mono 16 kHz PCM WAV named by entry UUID. Corrections apply locally; this export does not fine-tune a speech model.\n".write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            notice = "Export complete: \(exported.entries.count) reviewed, \(exported.rules.count) corrections."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            self.error = "Export failed: \(error.localizedDescription)"
        }
    }
}
