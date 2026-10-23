import AppKit
import SwiftUI
import WhispCore

@MainActor
final class SnippetsWindowController {
    static let shared = SnippetsWindowController()
    private var window: NSWindow?

    func show(path: String) {
        if window == nil {
            let view = SnippetsView(path: path)
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "Whisp Snippets"
            win.setContentSize(NSSize(width: 780, height: 620))
            win.minSize = NSSize(width: 650, height: 540)
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        // Stay .accessory (LSUIElement) the whole time so Whisp never shows a
        // Dock icon. An accessory app can still present a focusable key window;
        // we just activate and bring it to front, no policy change.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SnippetsView: View {
    let path: String
    @State private var snippets: [Snippet] = []
    @State private var selection: UUID?
    @State private var saveState: SaveState = .clean
    @State private var savedSnippets: [Snippet] = []
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var keywordFocused: Bool

    enum SaveState { case clean, dirty, saved }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                detail
            }
            Divider()
            footer
        }
        .tint(Color.accentColor)
        .onAppear(perform: load)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Snippets")
                    .font(.system(size: 24, weight: .semibold))
                Text("Insert text with a spoken phrase.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: add) { Label("New snippet", systemImage: "plus") }
                .disabled(!loaded)
        }
        .padding(28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            } else {
                switch saveState {
                case .dirty:
                    Text("Unsaved changes").font(.system(size: 12)).foregroundStyle(.secondary)
                case .saved:
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                case .clean:
                    Text(snippets.count == 1 ? "1 snippet" : "\(snippets.count) snippets")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !loaded { Button("Try again", action: load) }
            Button("Save changes", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded || saveState != .dirty)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(snippets) { s in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(s.keyword.isEmpty ? "Untitled snippet" : s.keyword)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(s.enabled ? .primary : .secondary)
                            .lineLimit(1)
                        Text(s.mode == .ai ? "AI template" : "Saved text")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !s.enabled {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.tertiary)
                            .help("Disabled")
                    }
                }
                .padding(.vertical, 7)
                .tag(s.id)
            }
        }
        .listStyle(.inset)
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let idx = snippets.firstIndex(where: { $0.id == selection }) {
            editor(idx)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(snippets.isEmpty ? "Save text you use often." : "Choose a snippet to edit.")
                    .font(.system(size: 16, weight: .medium))
                Button("Add snippet", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(!loaded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder private func editor(_ idx: Int) -> some View {
        let isAI = snippets[idx].mode == .ai
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Edit snippet").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button(action: delete) { Image(systemName: "trash") }
                        .accessibilityLabel("Delete snippet")
                        .help("Delete snippet")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Phrase you'll say").font(.system(size: 12, weight: .medium))
                    TextField("For example, my signature", text: binding(idx, \.keyword))
                        .textFieldStyle(.roundedBorder)
                        .focused($keywordFocused)
                        .accessibilityLabel("Phrase you'll say")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Insert as").font(.system(size: 12, weight: .medium))
                    Picker("Insert as", selection: binding(idx, \.mode)) {
                        Text("Saved text").tag(SnippetMode.verbatim)
                        Text("AI template").tag(SnippetMode.ai)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(isAI ? "Instructions for OpenAI" : "Text to insert")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: binding(idx, \.content))
                        .font(.system(size: 13))
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .accessibilityLabel(isAI ? "Instructions for OpenAI" : "Text to insert")
                    Text(isAI
                        ? "OpenAI uses these instructions and anything you say after the phrase to write a reply."
                        : "Whisp inserts this text exactly as written.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Enable this snippet", isOn: binding(idx, \.enabled))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
    }

    // MARK: Bindings + IO

    private func binding<T>(_ idx: Int, _ key: WritableKeyPath<Snippet, T>) -> Binding<T> {
        let id = snippets[idx].id
        let fallback = snippets[idx][keyPath: key]
        return Binding(
            get: { snippets.first(where: { $0.id == id })?[keyPath: key] ?? fallback },
            set: { value in
                guard let current = snippets.firstIndex(where: { $0.id == id }) else { return }
                snippets[current][keyPath: key] = value
                markEdited()
            })
    }

    private func load() {
        guard !loaded else { return }
        do {
            if FileManager.default.fileExists(atPath: path) {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                snippets = try SnippetStore.load(from: data).all
            }
            savedSnippets = snippets
            selection = snippets.first?.id
            saveState = .clean
            loaded = true
            error = nil
        } catch {
            self.error = "Could not load snippets: \(error.localizedDescription)"
        }
    }

    private func markEdited() {
        saveState = snippets == savedSnippets ? .clean : .dirty
        error = nil
    }

    private func add() {
        let s = Snippet(keyword: "new keyword", mode: .verbatim, content: "")
        snippets.append(s)
        selection = s.id
        markEdited()
        keywordFocused = true
    }

    private func delete() {
        guard let idx = snippets.firstIndex(where: { $0.id == selection }) else { return }
        snippets.remove(at: idx)
        selection = snippets.isEmpty ? nil : snippets[min(idx, snippets.count - 1)].id
        markEdited()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(snippets).write(to: URL(fileURLWithPath: path), options: .atomic)
            savedSnippets = snippets
            saveState = .saved
            error = nil
            NotificationCenter.default.post(name: .whispConfigChanged, object: nil)
        } catch {
            self.error = "Could not save snippets: \(error.localizedDescription)"
        }
    }
}
