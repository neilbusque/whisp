import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import WhispCore

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    func show(configPath: String) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(path: configPath))
            let window = NSWindow(contentViewController: host)
            window.title = "Whisp Settings"
            window.setContentSize(NSSize(width: 680, height: 720))
            window.minSize = NSSize(width: 580, height: 540)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let path: String
    @State private var config = WhispConfig.defaults
    @State private var message: String?
    @State private var error: String?
    @State private var loaded = false
    @State private var savedConfig: WhispConfig?
    @State private var launchAtLogin = LoginItem.isEnabled

    private var isPreview: Bool { CommandLine.arguments.contains("--no-hotkeys") }
    private var hasChanges: Bool { loaded && config != savedConfig }

    private var modelOptions: [(id: String, label: String)] {
        var options = [
            ("ggml-small.en", "Small English (accurate)"),
            ("ggml-small.en-q5_1", "Small English (smaller file)"),
            ("ggml-base.en", "Base English (balanced)"),
            ("ggml-tiny.en", "Tiny English (fastest)"),
            ("ggml-medium.en", "Medium English"),
        ].filter { FileManager.default.fileExists(atPath: Paths.modelPath($0.0)) }
        if !options.contains(where: { $0.0 == config.whisperModel }) {
            options.append((config.whisperModel, config.whisperModel + " (not installed)"))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Settings").font(.system(size: 24, weight: .semibold))
                    Text("Recognition, writing, and privacy.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(28)
            Divider()
            Form {
                Section {
                    Picker("Dictation", selection: $config.transcriptionMode) {
                        Text("OpenAI streaming").tag(TranscriptionMode.openai)
                        Text("On this Mac").tag(TranscriptionMode.local)
                    }
                    SecureField("OpenAI API key", text: $config.openaiKey)
                        .textFieldStyle(.roundedBorder)
                    Picker(config.transcriptionMode == .openai ? "Practice model" : "Speech model", selection: $config.whisperModel) {
                        ForEach(modelOptions, id: \.id) { option in Text(option.label).tag(option.id) }
                    }
                } header: { Text("Recognition") } footer: {
                    Text(config.transcriptionMode == .openai
                        ? "Dictation audio streams to OpenAI while you hold Fn. Practice audio is processed on this Mac."
                        : "Dictation and practice audio are processed on this Mac. Smaller models finish faster; larger models favor accuracy.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
                Section {
                    Picker("Text cleanup", selection: $config.cleanupMode) {
                        Text("Fast with spoken edits").tag(CleanupMode.fast)
                        Text("Grammar fix with OpenAI").tag(CleanupMode.smart)
                    }
                } header: { Text("Writing") } footer: {
                    Text(config.cleanupMode == .fast
                        ? "Removes filler words on your Mac. OpenAI handles spoken corrections and rewrites, including the relevant writing context."
                        : "Types what you say. OpenAI only fixes grammar, punctuation and fillers, and never answers or rewrites. Say ‘make this better’ to edit selected text or your last dictation.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
                Section {
                    Toggle("Keep recent dictations", isOn: $config.keepHistory)
                        .onChange(of: config.keepHistory) { if !$0 { config.saveVoiceExamples = false } }
                    Toggle("Save voice examples", isOn: $config.saveVoiceExamples).disabled(!config.keepHistory)
                    Button("Open corrections") {
                        NotificationCenter.default.post(name: .whispOpenLearning, object: nil)
                    }
                } header: { Text("Personal learning") } footer: {
                    Text("Keep up to 100 dictations on this Mac. Voice examples also save audio. Turning these off stops future saves; remove existing entries in History.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
                Section {
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        permissionRow("Accessibility", ready: AXIsProcessTrusted(), detail: "Allow Fn and text insertion", pane: "Privacy_Accessibility")
                        permissionRow("Microphone", ready: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, detail: "Allow voice recording", pane: "Privacy_Microphone")
                    }
                } header: { Text("Permissions") }
                Section {
                    LabeledContent("Hold to talk", value: "Fn / Globe")
                    LabeledContent("Recording limit", value: "5 minutes per dictation")
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .disabled(isPreview)
                        .onChange(of: launchAtLogin) { value in
                            guard !isPreview else { return }
                            _ = LoginItem.setEnabled(value)
                            launchAtLogin = LoginItem.isEnabled
                        }
                } header: { Text("General") } footer: {
                    Text(isPreview
                        ? "Launch at login is unavailable in this preview."
                        : "Keep your text field selected until the dictation or edit finishes.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
                .disabled(!loaded)
            Divider()
            HStack {
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
                else if hasChanges { Text("Unsaved changes").font(.system(size: 12)).foregroundStyle(.secondary) }
                else if let message { Label(message, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if !loaded { Button("Try again", action: load) }
                Button("Save changes", action: save).buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .tint(Color.accentColor)
        .onAppear(perform: load)
        .onChange(of: config) { _ in if hasChanges { message = nil } }
    }

    private func permissionRow(_ title: String, ready: Bool, detail: String, pane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? Color.green : Color.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(ready ? "Ready" : detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ready {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }.accessibilityLabel("Open \(title) settings")
            }
        }
    }
    private func load() {
        guard !loaded else { return }
        do {
            config = try WhispConfig.load(from: Data(contentsOf: URL(fileURLWithPath: path)))
            savedConfig = config
            loaded = true; error = nil
        } catch { self.error = "Could not load settings: \(error.localizedDescription)" }
    }
    private func save() {
        do {
            let valid = try config.validated()
            guard valid.transcriptionMode == .openai || FileManager.default.fileExists(atPath: Paths.modelPath(valid.whisperModel)) else {
                throw WhispConfigError.invalid("The selected model is not installed. Choose an available model.")
            }
            try valid.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            config = valid
            savedConfig = valid
            message = "Saved. Applies when Whisp is idle."
            error = nil
            NotificationCenter.default.post(name: .whispConfigChanged, object: nil)
        } catch { self.error = error.localizedDescription; message = nil }
    }
}

extension Notification.Name { static let whispOpenLearning = Notification.Name("WhispOpenLearning") }
