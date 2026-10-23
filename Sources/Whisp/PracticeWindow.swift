import AppKit
import SwiftUI
import AVFoundation
import WhispCore

@MainActor
final class PracticeWindow {
    static let shared = PracticeWindow()
    private var window: NSWindow?

    func invalidate() {
        guard let window else { return }
        window.contentView = NSHostingView(rootView:
            Text("Open Practice from Whisp's menu to load the current settings.")
                .foregroundStyle(.secondary).padding(24))
    }

    func refresh(controller: PracticeController) {
        guard let window else { return }
        window.contentView = NSHostingView(rootView: PracticeRootView(controller: controller))
    }

    func show(controller: PracticeController) {
        if let window {
            refresh(controller: controller)
            // Stay .accessory (LSUIElement) so Whisp never shows a Dock icon. An
            // accessory app can still present a focusable key window; we just
            // activate and bring it to front, no policy change.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = PracticeRootView(controller: controller)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Practice"
        w.minSize = NSSize(width: 780, height: 560)
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        // Stay .accessory (LSUIElement) so Whisp never shows a Dock icon. An
        // accessory app can still present a focusable key window; we just
        // activate and bring it to front, no policy change.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Plays back a recording. One shared player so starting a second clip stops
/// the first instead of layering two voices.
@MainActor
final class SessionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(session: PracticeSession) {
        if playingID == session.id {
            stop()
            return
        }
        stop()
        let url = Paths.recordingURL(filename: session.audioFilename)
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            Diag.log("practice: cannot play \(session.audioFilename)")
            return
        }
        p.delegate = self
        player = p
        playingID = session.id
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    // AVFoundation calls delegate methods from an arbitrary thread, not
    // guaranteed to be the main actor — hop explicitly rather than assume.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // AVAudioPlayer isn't Sendable, so identity is captured as a plain
        // ObjectIdentifier before crossing into the @MainActor closure, rather
        // than sending `player` itself across the actor boundary.
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor in
            // Only clear if the player that finished is still the current one.
            // A newer clip may have started while this hop was queued; nil-ing
            // it out here would drop the only strong reference to that clip's
            // player and silently stop it mid-playback.
            guard let current = self.player, ObjectIdentifier(current) == finishedID else { return }
            self.player = nil
            self.playingID = nil
        }
    }
}

/// Keep free-form as a real selection, distinct from an absent prompt ID.
private enum PromptFilter: Hashable {
    case freeForm
    case prompt(UUID)

    var promptID: UUID? {
        switch self {
        case .freeForm: return nil
        case .prompt(let id): return id
        }
    }
}

@MainActor
struct PracticeRootView: View {
    @ObservedObject var controller: PracticeController
    var onRecord: (() -> Void)? = nil
    var active = true
    @State private var selectedFilter: PromptFilter = .freeForm
    @State private var selectedSession: PracticeSession?
    @State private var sessions: [PracticeSession] = []
    @State private var trend: [TrendPoint] = []
    @StateObject private var player = SessionPlayer()

    private var prompts: [PracticePrompt] { controller.prompts.all }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Practice").font(.system(size: 24, weight: .semibold))
                    Text("Review your recordings and speaking feedback.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let onRecord, active {
                    Button(action: onRecord) {
                            Label(controller.isRecording ? "Stop practice" : "Start practice",
                                  systemImage: controller.isRecording ? "stop.fill" : "mic.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(controller.isStopping)
                }
            }
            .padding(24)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Prompt", selection: $selectedFilter) {
                        Text("Free-form").tag(PromptFilter.freeForm)
                        ForEach(prompts) { prompt in
                            Text(prompt.title).tag(PromptFilter.prompt(prompt.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(16)
                    Divider()

                    if sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No recordings yet").font(.system(size: 13, weight: .medium))
                            Text("Your attempts appear here.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        Spacer()
                    } else {
                        List(sessions, selection: Binding(
                            get: { selectedSession?.id },
                            set: { id in selectedSession = sessions.first { $0.id == id } }
                        )) { session in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.startedAt, formatter: Self.sessionDate)
                                    .font(.system(size: 13, weight: .medium))
                                Text(statusLine(session))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 7)
                            .tag(session.id)
                        }
                        .listStyle(.inset).scrollContentBackground(.hidden)
                    }
                }
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                .background(Color(nsColor: .controlBackgroundColor))

                Group {
                    if let session = selectedSession {
                        SessionDetailView(session: session, controller: controller,
                                          player: player, trend: trend)
                            .id(session.id)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Make room for a little practice")
                                .font(.system(size: 17, weight: .semibold))
                            Text(onRecord == nil
                                 ? "Use your practice shortcut to record an attempt."
                                 : "Record an attempt to review your pace, pauses, and fillers.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(.tertiary)
                Text(diskUsage()).foregroundStyle(.secondary)
                Spacer()
                Text("Recordings stay on your Mac").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
        }
        .background(Color.workspaceBackground)
        .onAppear {
            reload()
            controller.sessionsChanged = { reload() }
        }
        .onChange(of: selectedFilter) { _ in reload() }
        .onChange(of: selectedSession?.id) { _ in player.stop() }
        .onChange(of: active) { isActive in
            if !isActive { player.stop() }
        }
        .onDisappear { player.stop() }
    }

    private static let sessionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter
    }()

    /// Reconcile the selected value snapshot whenever a session changes, so a
    /// completed transcript replaces its pending record in the detail pane.
    private func reload() {
        let promptID = selectedFilter.promptID
        sessions = controller.store.sessions(forPrompt: promptID).reversed()
        trend = controller.store.trend(forPrompt: promptID)
        if let selected = selectedSession,
           let updated = sessions.first(where: { $0.id == selected.id }) {
            selectedSession = updated
        } else {
            selectedSession = sessions.first
        }
    }

    private func statusLine(_ session: PracticeSession) -> String {
        switch session.status {
        case .pending: return "Transcribing…"
        case .failed: return "Transcription failed"
        case .ready:
            guard let metrics = session.metrics else { return "Ready to review" }
            return String(format: "%.0f words/min, %.1f fillers/100 words",
                          metrics.wpm, metrics.fillerRate)
        }
    }

    private func diskUsage() -> String {
        ByteCountFormatter.string(fromByteCount: controller.recordingsDiskBytes(), countStyle: .file)
            + " of recordings"
    }
}

struct SessionDetailView: View {
    let session: PracticeSession
    let controller: PracticeController
    @ObservedObject var player: SessionPlayer
    let trend: [TrendPoint]
    @State private var isRequestingFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.promptTitle).font(.system(size: 18, weight: .semibold))
                        Text(String(format: "%.0f seconds", session.durationSec))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button {
                        player.toggle(session: session)
                    } label: {
                        Label(player.playingID == session.id ? "Stop" : "Play",
                              systemImage: player.playingID == session.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        if player.playingID == session.id { player.stop() }
                        controller.deleteSession(id: session.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete recording")
                    .accessibilityLabel("Delete recording")
                }

                if case .pending = session.status {
                    ProgressView("Transcribing your recording…")
                        .controlSize(.small)
                        .font(.system(size: 12))
                }

                if case .failed(let reason) = session.status {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                EnvelopeView(envelope: session.envelope,
                             pauses: session.metrics?.pauses ?? [],
                             binSeconds: EnvelopeBuilder.defaultBinSeconds)
                    .frame(height: 56)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Recording waveform")

                if let m = session.metrics {
                    MetricTiles(metrics: m)
                }

                if let t = session.transcript, !t.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcript").font(.headline)
                        Text(t).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if session.metrics != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        Text("Coach feedback").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            if let f = session.coachFeedback {
                                Text(f).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("Sends the transcript text to OpenAI. Practice audio stays on your Mac.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(isRequestingFeedback ? "Getting feedback…" : "Get feedback") {
                                guard !isRequestingFeedback else { return }
                                isRequestingFeedback = true
                                Task {
                                    await controller.requestCoachFeedback(for: session.id)
                                    isRequestingFeedback = false
                                }
                            }
                            .disabled(isRequestingFeedback)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if trend.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        Text("Fillers across your attempts").font(.headline)
                        TrendSparkline(points: trend)
                            .frame(height: 100)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct MetricTiles: View {
    let metrics: SpeechMetrics

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150))]
        LazyVGrid(columns: columns, spacing: 12) {
            tile("Pace", String(format: "%.0f", metrics.wpm), "words per minute")
            tile("Fillers", String(format: "%.1f", metrics.fillerRate), "per 100 words")
            tile("Pauses", "\(metrics.pauseCount)",
                 String(format: "longest %.1fs", metrics.longestPauseSec))
            tile("Silence", String(format: "%.0f%%", metrics.silenceRatio * 100), "of the session")
        }
    }

    private func tile(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// The recorded envelope with detected pauses shaded.
struct EnvelopeView: View {
    let envelope: [Float]
    let pauses: [Pause]
    let binSeconds: Double

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(envelope.count) * binSeconds, 0.001)
            ZStack(alignment: .leading) {
                ForEach(Array(pauses.enumerated()), id: \.offset) { _, p in
                    Rectangle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: geo.size.width * (p.durationSec / total))
                        .offset(x: geo.size.width * (p.startSec / total))
                }
                Path { path in
                    guard !envelope.isEmpty else { return }
                    let step = geo.size.width / CGFloat(envelope.count)
                    for (i, v) in envelope.enumerated() {
                        let x = CGFloat(i) * step
                        let h = CGFloat(v) * geo.size.height
                        path.move(to: CGPoint(x: x, y: geo.size.height / 2 - h / 2))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height / 2 + h / 2))
                    }
                }
                .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

/// Filler rate over time. Lower values mean fewer fillers.
struct TrendSparkline: View {
    let points: [TrendPoint]

    var body: some View {
        let values = points.map(\.fillerRate)
        let maximum = max(values.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing) {
                    Text(String(format: "%.1f", maximum))
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 28)
                GeometryReader { geometry in
                    ZStack {
                        VStack {
                            Divider()
                            Spacer()
                            Divider()
                        }
                        Path { path in
                            for (index, value) in values.enumerated() {
                                let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                                let y = geometry.size.height * (1 - CGFloat(value / maximum))
                                if index == 0 {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
            }
            HStack {
                Text("First attempt")
                Spacer()
                Text("Latest attempt")
            }
            .padding(.leading, 36)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Fillers per 100 words")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.leading, 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filler rate across \(points.count) attempts")
        .accessibilityValue(values.last.map { String(format: "Latest attempt: %.1f fillers per 100 words", $0) } ?? "No attempts")
    }
}
