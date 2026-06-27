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
            win.setContentSize(NSSize(width: 560, height: 460))
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        // The app runs as .accessory (LSUIElement) so the menu-bar HUD stays
        // non-activating. To present a real, focusable settings window we flip to
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

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(snippets) { s in
                    VStack(alignment: .leading) {
                        Text(s.keyword).bold()
                        Text(s.mode.rawValue.uppercased())
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(s.id)
                }
            }.frame(minWidth: 180)

            if let idx = snippets.firstIndex(where: { $0.id == selection }) {
                editor(idx)
            } else {
                Text("Select or add a snippet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button("Add") { add() }
            Button("Delete") { delete() }.disabled(selection == nil)
            Button("Save") { save() }
        }
        .onAppear(perform: load)
        .frame(minWidth: 560, minHeight: 460)
    }

    @ViewBuilder private func editor(_ idx: Int) -> some View {
        Form {
            TextField("Keyword", text: Binding(
                get: { snippets[idx].keyword },
                set: { snippets[idx].keyword = $0 }))
            Picker("Mode", selection: Binding(
                get: { snippets[idx].mode },
                set: { snippets[idx].mode = $0 })) {
                    Text("Verbatim").tag(SnippetMode.verbatim)
                    Text("AI template").tag(SnippetMode.ai)
                }.pickerStyle(.segmented)
            Toggle("Enabled", isOn: Binding(
                get: { snippets[idx].enabled },
                set: { snippets[idx].enabled = $0 }))
            Text(snippets[idx].mode == .ai ? "Instruction for the LLM:" : "Text pasted verbatim:")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { snippets[idx].content },
                set: { snippets[idx].content = $0 }))
                .font(.body.monospaced()).frame(minHeight: 200)
        }.padding()
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let store = try? SnippetStore.load(from: data) {
            snippets = store.all
        }
    }

    private func add() {
        let s = Snippet(keyword: "new keyword", mode: .verbatim, content: "")
        snippets.append(s)
        selection = s.id
    }

    private func delete() {
        snippets.removeAll { $0.id == selection }
        selection = nil
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(snippets).write(to: URL(fileURLWithPath: path))
    }
}
