import SwiftUI
import WhispCore

struct NotebookView: View {
    @ObservedObject var model: NotebookModel
    @State private var search = ""
    @State private var deleteID: UUID?
    private var filtered: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.notes : model.notes.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
                || $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Notes").font(.system(size: 22, weight: .semibold))
                Spacer()
                if let started = model.recordingStartedAt { Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
                if model.finishing { ProgressView().controlSize(.small); Text("Saving recording").foregroundStyle(.secondary) }
                Button { model.newNote() } label: { Label("New note", systemImage: "square.and.pencil") }
                    .disabled(model.finishing)
                Button { model.toggleRecording?() } label: {
                    Label(model.recording ? "Stop recording" : "Record idea", systemImage: model.recording ? "stop.circle.fill" : "mic")
                }.buttonStyle(.borderedProminent).disabled(model.finishing)
            }.padding(.horizontal, 24).padding(.vertical, 20)
            if let notice = model.notice, notice != "Note saved" {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TextField("Search notes", text: $search).textFieldStyle(.roundedBorder).padding(14)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { note in
                                Button { model.selectedNoteID = note.id } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                            Spacer(minLength: 4)
                                            if note.audioFilename != nil { Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(.secondary) }
                                        }
                                        Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        Text(note.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(model.selectedNoteID == note.id ? Color.workspaceSelection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 7))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if filtered.isEmpty { Text(search.isEmpty ? "Your ideas go here." : "No matching notes.").foregroundStyle(.secondary).padding(20) }
                        }.padding(7)
                    }
                }.frame(width: 240).background(Color.workspaceSidebar.opacity(0.5))
                Divider()
                if let note = model.notes.first(where: { $0.id == model.selectedNoteID }) {
                    NotePage(model: model, note: note, onDelete: { deleteID = note.id }).id(note.id)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "book.closed").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text("Make room for a thought.").font(.system(size: 26, weight: .semibold))
                        Text("Record an idea or start a page. Saved locally, with AI organization through OpenAI.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Start a note") { model.newNote() }
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .alert("Delete this note?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete note", role: .destructive) { if let id = deleteID { model.delete(id) }; deleteID = nil }
        } message: { Text("The note and memories learned from it will be removed. Its recording moves to Trash.") }
    }
}

private struct NotePage: View {
    @ObservedObject var model: NotebookModel
    let note: VoiceNote
    let onDelete: () -> Void
    @ObservedObject private var draft: NotebookDraft
    @State private var mode = 0
    @State private var showMemories = false
    init(model: NotebookModel, note: VoiceNote, onDelete: @escaping () -> Void) {
        self.model = model; self.note = note; self.onDelete = onDelete
        _draft = ObservedObject(wrappedValue: model.draft(for: note))
    }
    private var dirty: Bool { draft.isDirty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(dirty ? "Saving…" : "Saved on this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                if model.analyzing.contains(note.id) { ProgressView().controlSize(.mini); Text("Organizing").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button { save(); if !draft.isDirty, let latest = model.notes.first(where: { $0.id == note.id }) { model.export(latest) } } label: { Image(systemName: "square.and.arrow.up") }.help("Export Markdown")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete note")
            }.buttonStyle(.plain).padding(.bottom, 28)
            TextField("Untitled", text: $draft.title).textFieldStyle(.plain).font(.system(size: 28, weight: .semibold))
                .padding(.bottom, 18)
            HStack(spacing: 18) {
                Label { Text(note.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute()) } icon: { Image(systemName: "calendar") }
                if note.duration > 0 { Label(String(format: "%d:%02d", Int(note.duration) / 60, Int(note.duration) % 60), systemImage: "clock") }
                if note.audioFilename != nil {
                    Button { model.togglePlayback(note) } label: {
                        Label(model.playingNoteID == note.id ? "Stop audio" : "Play recording", systemImage: model.playingNoteID == note.id ? "stop.fill" : "play.fill")
                    }.buttonStyle(.plain)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 20)
            Divider()
            HStack {
                Picker("View", selection: $mode) {
                    Text("Write").tag(0); Text("Read").tag(1)
                    if !note.transcript.isEmpty { Text("Transcript").tag(2) }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                Spacer()
                if !dirty, !model.analyzing.contains(note.id), !draft.bodyText.isEmpty {
                    Button("Organize") {
                        guard let config = try? Paths.loadConfig(), !config.openaiKey.isEmpty else {
                            model.error = "Add your OpenAI key in Settings to organize notes."; return
                        }
                        model.organize(note, cleaner: OpenAICleaner(apiKey: config.openaiKey, model: config.textModel, noteOrganization: true))
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 16)
            if mode == 0 {
                TextEditor(text: $draft.bodyText).font(.system(size: 14)).lineSpacing(6)
                    .scrollContentBackground(.hidden).accessibilityLabel("Note body")
            } else {
                ScrollView {
                    Text(mode == 2 ? AttributedString(note.transcript) : (try? AttributedString(markdown: draft.bodyText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(draft.bodyText))
                        .font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
            let facts = model.memories.filter { $0.sourceNoteID == note.id }
            if !facts.isEmpty {
                Divider().padding(.vertical, 12)
                DisclosureGroup("Remembered from this note", isExpanded: $showMemories) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(facts) { fact in Text(fact.content).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.frame(maxHeight: 120)
                }.font(.system(size: 12))
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: draft.title + "\u{001f}" + draft.bodyText) {
                guard dirty else { return }
                do { try await Task.sleep(for: .milliseconds(600)); try Task.checkCancellation(); save() } catch { }
            }
            .onDisappear { save(); model.stopPlayback() }
    }
    private func save() { draft.save(using: model) }
}

struct NotebookMemoryView: View {
    @ObservedObject var model: NotebookModel
    @State private var search = ""
    @State private var editing: MemoryFact?
    @State private var forgetID: UUID?
    private var facts: [MemoryFact] {
        model.memories.filter { search.isEmpty || $0.content.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Memory").font(.system(size: 22, weight: .semibold)); Spacer()
                if model.memoryTab == 0 { Button("Add memory") { editing = MemoryFact(content: "") } }
                else { Button("Save profile") { model.saveProfile() }.buttonStyle(.borderedProminent) }
            }
            Picker("Memory view", selection: $model.memoryTab) { Text("Remembered").tag(0); Text("About me & projects").tag(1) }
                .pickerStyle(.segmented).frame(maxWidth: 340)
            if model.memoryTab == 0 {
                Toggle("Remember preferences and work context from voice notes", isOn: Binding(get: { model.learnFromNotes }, set: { model.setLearning($0) }))
                    .font(.system(size: 13))
                Text("Memories are used in AI writing. Temporary activities stop being used after 14 days. Ordinary dictation is not added to memory.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Search memory", text: $search).textFieldStyle(.roundedBorder)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(facts) { fact in
                            MemoryRow(model: model, fact: fact, onEdit: { editing = fact }, onForget: { forgetID = fact.id })
                            Divider()
                        }
                        if facts.isEmpty { Text(search.isEmpty ? "Record a note or add something to remember." : "No matching memories.").foregroundStyle(.secondary).padding(.vertical, 50) }
                    }
                }
            } else {
                Text("Your background, projects, and writing preferences. Included with AI writing and note organization.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $model.profile).font(.system(size: 13)).lineSpacing(5).scrollContentBackground(.hidden)
            }
        }.padding(28)
            .sheet(item: $editing) { fact in MemoryEditor(fact: fact) { model.saveMemory($0) } }
            .alert("Forget this memory?", isPresented: Binding(get: { forgetID != nil }, set: { if !$0 { forgetID = nil } })) {
                Button("Cancel", role: .cancel) { forgetID = nil }
                Button("Forget", role: .destructive) { if let id = forgetID { model.forget(id) }; forgetID = nil }
            } message: { Text("The source note will be kept.") }
    }
}

private struct MemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var fact: MemoryFact
    let onSave: (MemoryFact) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Memory").font(.system(size: 20, weight: .semibold))
            TextEditor(text: $fact.content).font(.system(size: 14)).frame(height: 120)
            Picker("Type", selection: $fact.kind) { ForEach(MemoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            if !fact.evidence.isEmpty { Text("Source: “\(fact.evidence)”").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { onSave(fact); dismiss() }.buttonStyle(.borderedProminent).disabled(fact.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 480)
    }
}

private struct MemoryRow: View {
    @ObservedObject var model: NotebookModel
    let fact: MemoryFact
    let onEdit: () -> Void
    let onForget: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("Use memory", isOn: Binding(get: { fact.enabled }, set: { enabled in
                var updated = fact; updated.enabled = enabled; model.saveMemory(updated)
            })).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Button(action: onEdit) {
                    Text(fact.content).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    Text(fact.kind.rawValue.capitalized)
                    Text(fact.updatedAt, format: .dateTime.month(.abbreviated).day())
                    if !fact.isRelevant(), fact.enabled { Text("Past context") }
                    if let source = fact.sourceNoteID {
                        Button("Source note") {
                            model.selectedNoteID = source
                            NotificationCenter.default.post(name: .whispWorkspaceRoute, object: WorkspaceRoute.notes)
                        }.buttonStyle(.plain)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(action: onForget) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Forget memory")
        }.padding(.vertical, 15)
    }
}
