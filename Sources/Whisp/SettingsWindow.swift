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
            win.setContentSize(NSSize(width: 460, height: 420))
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

    // Known on-device models, plus whatever is currently configured.
    private var modelOptions: [(id: String, label: String)] {
        var opts = [
            ("ggml-base.en", "Base · fastest (English)"),
            ("ggml-small.en", "Small · balanced (English)"),
            ("ggml-medium.en", "Medium · most accurate (English)"),
        ]
        if !opts.contains(where: { $0.0 == config.whisperModel }) {
            opts.append((config.whisperModel, config.whisperModel))
        }
        return opts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.voiceGradient)
                Text("Settings")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    Picker("Model", selection: $config.whisperModel) {
                        ForEach(modelOptions, id: \.id) { opt in
                            Text(opt.label).tag(opt.id)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Runs on-device with whisper.cpp. Your audio never leaves this Mac. Larger models are more accurate but slower; switch the model file in ~/.whisp/models.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    SecureField("DeepSeek API key", text: $config.deepseekKey)
                } header: {
                    Text("Cleanup")
                } footer: {
                    Text("Stored locally in ~/.whisp/config.json. Only the transcript text (never audio) is sent to DeepSeek to remove filler and fix grammar.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Hold to talk", value: "Fn")
                } header: {
                    Text("Dictation")
                } footer: {
                    Text("Hold Fn, speak, release. The key is fixed in this version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if saved {
                    Label("Saved. Restart Whisp to apply.", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Color.wMint)
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tint(.wIris)
        .frame(width: 460)
        .onAppear(perform: load)
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
