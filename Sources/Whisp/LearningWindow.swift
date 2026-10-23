import AppKit
import SwiftUI
import WhispCore

@MainActor
final class LearningWindow {
    static let shared = LearningWindow()
    private var window: NSWindow?
    func show(model: LearningModel, tab: Int = 0) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LearningView(model: model, initialTab: tab)))
            window.title = "Teach Whisp"
            window.setContentSize(NSSize(width: 900, height: 650))
            window.minSize = NSSize(width: 780, height: 570)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else {
            NotificationCenter.default.post(name: .whispLearningTab, object: tab)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let whispLearningTab = Notification.Name("WhispLearningTab")
    static let whispConfigChanged = Notification.Name("WhispConfigChanged")
}

struct LearningView: View {
    @ObservedObject var model: LearningModel
    let initialTab: Int
    var requestedTab: Int? = nil
    var embedded = false
    var active = true
    var requestedEntry: UUID? = nil
    var onEntrySelected: (UUID?) -> Void = { _ in }
    @State private var tab = 0
    @State private var ruleID: UUID?
    @State private var heard = ""
    @State private var intended = ""
    @State private var enabled = true
    @State private var testPhrase = ""
    @State private var selectedEntry: UUID?
    @State private var reference = ""
    @State private var search = ""
    @State private var confirmClear = false
    @State private var isDraftDirty = false
    @State private var pendingSelection: UUID?
    @State private var showDiscard = false

    private var visibleRules: [CorrectionRule] {
        model.data.rules.filter { search.isEmpty || ($0.heard + " " + $0.intended).localizedCaseInsensitiveContains(search) }
    }
    private var visibleEntries: [DictationEntry] {
        model.data.entries.filter { search.isEmpty || ($0.raw + " " + $0.output).localizedCaseInsensitiveContains(search) }
    }
    private var entry: DictationEntry? { model.data.entries.first { $0.id == selectedEntry } }
    private var validation: String? {
        do { _ = try CorrectionRule(heard: heard, intended: intended).validated(); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tab == 0 ? "Corrections" : "Recent dictations").font(.system(size: 24, weight: .semibold))
                    Text(tab == 0 ? "Names and phrases, exactly as you mean them." : "Find, recover, and refine your words.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import…", action: model.importCorrections)
                    .help("Import corrections from a Whisp dataset JSON file")
                Button("Export…", action: model.exportDataset)
                    .help("Export your corrections and reviewed examples to a local folder")
            }.padding(28)
            if !embedded { HStack {
                Picker("Learning view", selection: $tab) {
                    Text("Corrections").tag(0)
                    Text("Recent dictations").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Spacer()
                Text(tab == 0 ? "\(model.data.rules.filter(\.enabled).count) active corrections" : "Latest \(model.data.entries.count) · stored on this Mac")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 18) }
            Divider()
            if !model.isLoaded {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Your learning file needs attention").font(.title2)
                    Text(model.error ?? "Could not load learning data.").textSelection(.enabled)
                    Button("Try Again", action: model.reload)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
                    ScrollView {
                        if tab == 0 { correctionEditor }
                        else if let entry { entryEditor(entry) }
                        else { emptyHistory }
                    }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let error = model.error {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { model.error = nil }
                } else {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text(model.notice ?? "Corrections and saved voice examples stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.canUndo { Button("Undo") { model.undo(); if !isDraftDirty { loadRule(ruleID) } } }
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(Color.workspaceBackground)
        .tint(.accentColor)
        .onAppear {
            tab = requestedTab ?? initialTab
            selectEntry(requestedEntry ?? model.data.entries.first?.id)
        }
        .onChange(of: requestedTab) { value in if let value { tab = value } }
        .onChange(of: requestedEntry) { selectEntry($0) }
        .onChange(of: active) { if !$0 { model.stopPlayback() } }
        .onReceive(NotificationCenter.default.publisher(for: .whispLearningTab)) { notification in
            if let requested = notification.object as? Int { tab = requested }
        }
        .onChange(of: tab) { _ in search = ""; model.stopPlayback() }
        .onChange(of: model.data.rules) { _ in
            if !isDraftDirty { loadRule(ruleID) }
        }
        .alert("Clear recent dictations?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive, action: model.clearHistory)
        } message: { Text("This removes all saved transcript examples. Audio moves to Trash. Your corrections are kept.") }
        .alert("Discard unsaved correction?", isPresented: $showDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) { loadRule(pendingSelection) }
        } message: { Text("Save the current correction first if you want to keep it.") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search \(tab == 0 ? "corrections" : "dictations")", text: $search)
                .textFieldStyle(.roundedBorder).padding(16)
            if tab == 0 {
                if visibleRules.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.badge.checkmark").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text(search.isEmpty ? "Your words, remembered" : "No matching corrections").font(.headline)
                        Text(search.isEmpty ? "Add a name or phrase that Whisp often gets wrong." : "Try another word.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visibleRules) { rule in
                        Button { chooseRule(rule.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.intended).fontWeight(.medium)
                                HStack {
                                    Text(rule.heard).lineLimit(1)
                                    if !rule.enabled { Text("Paused").font(.caption) }
                                }.foregroundStyle(.secondary).font(.callout)
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .listRowBackground(ruleID == rule.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
                Divider()
                HStack {
                    Button { chooseRule(nil) } label: { Label("New Correction", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                    Spacer()
                }.padding(16)
            } else {
                List(visibleEntries) { item in
                    Button {
                        selectEntry(item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.output).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(item.createdAt, style: .time)
                                if item.reference != nil { Image(systemName: "checkmark.circle").accessibilityLabel("Reviewed") }
                                if item.hasAudio { Image(systemName: "waveform").accessibilityLabel("Audio saved") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .listRowBackground(selectedEntry == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                }.listStyle(.inset).scrollContentBackground(.hidden)
                Divider()
                HStack {
                    Button("Clear History…") { confirmClear = true }.disabled(model.data.entries.isEmpty)
                    Spacer()
                }.padding(16)
            }
        }.background(Color.workspaceSurface)
    }

    private var correctionEditor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ruleID == nil ? "Teach a correction" : "Edit correction").font(.title2.weight(.semibold))
                Text("Teach Whisp a name or phrase to use in future dictations.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Whisp heard").font(.headline)
                TextField("For example, Acme Cloud", text: $heard).textFieldStyle(.roundedBorder)
                    .onChange(of: heard) { _ in isDraftDirty = true }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("I meant").font(.headline)
                TextField("AcmeCloud", text: $intended).textFieldStyle(.roundedBorder)
                    .onChange(of: intended) { _ in isDraftDirty = true }
            }
            Toggle("Use this correction", isOn: $enabled)
                .onChange(of: enabled) { _ in isDraftDirty = true }
            if let validation, !heard.isEmpty || !intended.isEmpty {
                Text(validation).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Correction") { saveRule() }
                    .buttonStyle(.borderedProminent).disabled(validation != nil || !isDraftDirty)
                    .keyboardShortcut("s", modifiers: .command)
                if isDraftDirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                if let ruleID {
                    Button("Remove", role: .destructive) { model.deleteRule(ruleID); loadRule(nil) }
                }
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text("Try it before saving").font(.headline)
                TextField("Type a sentence containing the mistaken phrase", text: $testPhrase, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                if !testPhrase.isEmpty {
                    Text(CorrectionEngine(rules: [CorrectionRule(heard: heard, intended: intended, enabled: enabled)]).apply(testPhrase))
                        .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("Corrections apply to every matching phrase. You can pause or undo them anytime.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(maxWidth: 620, alignment: .leading)
    }

    private func entryEditor(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review a dictation").font(.title2.weight(.semibold))
                Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.duration, specifier: "%.1f")s audio · \(entry.processingSeconds, specifier: "%.1f")s processing")
                    .font(.callout).foregroundStyle(.secondary)
            }
            transcriptBlock("Whisp heard", text: entry.raw)
            transcriptBlock("Final text", text: entry.output)
            HStack {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.output, forType: .string)
                    model.notice = "Copied to clipboard."
                }
                if entry.hasAudio {
                    Button(model.playingID == entry.id ? "Stop Playback" : "Play Recording") {
                        model.play(entry)
                    }
                }
                Spacer()
                Button("Remove", role: .destructive) { model.deleteEntry(entry.id); selectedEntry = nil }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("What I actually said").font(.headline)
                Text("Review the entire transcript, then save it as a reference for your local dataset.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $reference).font(.body).frame(minHeight: 100)
                    .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("Correct reference transcript")
                Button("Save Reviewed Reference") { model.saveReference(id: entry.id, text: reference) }
                    .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Teach a Recurring Mistake…") {
                    if embedded { NotificationCenter.default.post(name: .whispWorkspaceRoute, object: WorkspaceRoute.corrections) }
                    tab = 0; chooseRule(nil)
                }
            }
            Text("Reviewed examples can be exported with their saved audio. Automatic fixes come from your Corrections; saving a reference does not retrain the speech model.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: 640, alignment: .leading)
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "text.bubble").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(model.data.entries.isEmpty ? "Your next dictation starts here" : "Choose a dictation to review").font(.title2.weight(.semibold))
            Text("Hold Fn, speak, and release. Recent text appears here so you can recover it, review mistakes, and build your own reference dataset.")
                .foregroundStyle(.secondary)
            Text("Keep up to 100 recent dictations. To save their audio too, enable “Save voice examples” in Settings. Both controls can be turned off.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Settings…") { NotificationCenter.default.post(name: .whispWorkspaceRoute, object: WorkspaceRoute.settings) }
        }.padding(32).frame(maxWidth: 560, alignment: .leading)
    }

    private func transcriptBlock(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func selectEntry(_ id: UUID?) {
        guard let item = model.data.entries.first(where: { $0.id == id }), selectedEntry != item.id else { return }
        selectedEntry = item.id
        onEntrySelected(item.id)
        reference = item.reference ?? item.raw
        model.stopPlayback()
    }
    private func chooseRule(_ id: UUID?) {
        if isDraftDirty && (!heard.isEmpty || !intended.isEmpty) {
            pendingSelection = id; showDiscard = true
        } else { loadRule(id) }
    }
    private func loadRule(_ id: UUID?) {
        let rule = model.data.rules.first { $0.id == id }
        ruleID = rule?.id; heard = rule?.heard ?? ""; intended = rule?.intended ?? ""
        enabled = rule?.enabled ?? true; testPhrase = ""
        // onChange runs after state updates, so clear the draft flag next turn.
        DispatchQueue.main.async { isDraftDirty = false }
    }
    private func saveRule() {
        let rule = CorrectionRule(id: ruleID ?? UUID(), heard: heard, intended: intended, enabled: enabled)
        if model.saveRule(rule) { ruleID = rule.id; isDraftDirty = false }
    }
}
