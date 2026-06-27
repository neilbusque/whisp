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
            win.setContentSize(NSSize(width: 640, height: 480))
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        // The app runs as .accessory (LSUIElement) so the menu-bar HUD stays
        // non-activating. To present a real, focusable window we flip to
        // .regular while it's open; the HUD remains a borderless floating panel
        // unaffected by activation policy.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SnippetsView: View {
    let path: String
    @State private var snippets: [Snippet] = []
    @State private var selection: UUID?
    @State private var saveState: SaveState = .clean

    enum SaveState { case clean, dirty, saved }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                detail
            }
        }
        .tint(.wIris)
        .onAppear(perform: load)
        .frame(minWidth: 600, minHeight: 440)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.voiceGradient)
            Text("Snippets")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Say a keyword to drop in saved text or an AI-written reply.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            saveControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var saveControls: some View {
        HStack(spacing: 12) {
            switch saveState {
            case .dirty:
                Label("Unsaved", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.secondary)
                    .imageScale(.small)
            case .saved:
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Color.wMint)
            case .clean:
                EmptyView()
            }
            Button { add() } label: { Image(systemName: "plus") }
                .help("Add snippet")
            Button { delete() } label: { Image(systemName: "trash") }
                .help("Delete snippet")
                .disabled(selection == nil)
            Button { save() } label: { Label("Save", systemImage: "tray.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled(saveState != .dirty)
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(snippets) { s in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.keyword.isEmpty ? "untitled" : s.keyword)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(s.enabled ? .primary : .secondary)
                            .lineLimit(1)
                        modeChip(s.mode)
                    }
                    Spacer()
                    if !s.enabled {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.tertiary)
                            .help("Disabled")
                    }
                }
                .padding(.vertical, 2)
                .tag(s.id)
            }
        }
        .frame(minWidth: 200, idealWidth: 220)
    }

    private func modeChip(_ mode: SnippetMode) -> some View {
        Text(mode == .ai ? "AI" : "VERBATIM")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(mode == .ai
                    ? AnyShapeStyle(Color.voiceGradient)
                    : AnyShapeStyle(Color.secondary.opacity(0.22))))
            .foregroundStyle(mode == .ai ? .white : .secondary)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let idx = snippets.firstIndex(where: { $0.id == selection }) {
            editor(idx)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No snippet selected")
                    .font(.system(.headline, design: .rounded))
                Text("Pick a snippet on the left, or add one to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder private func editor(_ idx: Int) -> some View {
        let isAI = snippets[idx].mode == .ai
        Form {
            Section {
                TextField("Keyword you'll say", text: binding(idx, \.keyword))
                Picker("Mode", selection: binding(idx, \.mode)) {
                    Text("Verbatim").tag(SnippetMode.verbatim)
                    Text("AI template").tag(SnippetMode.ai)
                }
                .pickerStyle(.segmented)
                Toggle("Enabled", isOn: binding(idx, \.enabled))
            }

            Section {
                TextEditor(text: binding(idx, \.content))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            } header: {
                Text(isAI ? "Instruction for the AI" : "Text pasted exactly")
            } footer: {
                Text(isAI
                    ? "Whisp sends this plus anything you say after the keyword to DeepSeek, and pastes the reply."
                    : "Pasted verbatim, no AI. Good for templates and boilerplate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings + IO

    private func binding<T>(_ idx: Int, _ key: WritableKeyPath<Snippet, T>) -> Binding<T> {
        Binding(
            get: { snippets[idx][keyPath: key] },
            set: { snippets[idx][keyPath: key] = $0; saveState = .dirty })
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let store = try? SnippetStore.load(from: data) {
            snippets = store.all
        }
        saveState = .clean
    }

    private func add() {
        let s = Snippet(keyword: "new keyword", mode: .verbatim, content: "")
        snippets.append(s)
        selection = s.id
        saveState = .dirty
    }

    private func delete() {
        snippets.removeAll { $0.id == selection }
        selection = nil
        saveState = .dirty
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(snippets).write(to: URL(fileURLWithPath: path))
        saveState = .saved
    }
}
