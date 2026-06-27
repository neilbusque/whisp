import AppKit
import SwiftUI
import WhispCore

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(configPath: String) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(path: configPath))
            let win = NSWindow(contentViewController: host)
            win.title = "Whisp Settings"
            win.setContentSize(NSSize(width: 420, height: 240))
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        }
        // Flip to .regular so the settings window is focusable; the borderless
        // HUD floating panel is unaffected and stays non-activating.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let path: String
    @State private var config = WhispConfig.defaults
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("DeepSeek API key", text: $config.deepseekKey)
            TextField("Hotkey", text: $config.hotkey)
            TextField("Whisper model", text: $config.whisperModel)
            HStack {
                Button("Save") { save() }
                if saved {
                    Text("Saved — restart Whisp to apply.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onAppear(perform: load)
        .frame(width: 420)
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let c = try? WhispConfig.load(from: data) {
            config = c
        }
    }

    private func save() {
        if let data = try? config.encoded() {
            try? data.write(to: URL(fileURLWithPath: path))
            saved = true
        }
    }
}
