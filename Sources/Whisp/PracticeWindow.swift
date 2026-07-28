import AppKit
import SwiftUI
import AVFoundation
import WhispCore

@MainActor
final class PracticeWindow {
    static let shared = PracticeWindow()
    private var window: NSWindow?

    func show(controller: PracticeController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = PracticeRootView(controller: controller)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Practice"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// Plays back a recording. One shared player so starting a second clip stops
/// the first instead of layering two voices.
@MainActor
final class SessionPlayer: ObservableObject {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(session: PracticeSession) {
        if playingID == session.id {
            player?.stop(); player = nil; playingID = nil
            return
        }
        player?.stop()
        let url = Paths.recordingURL(filename: session.audioFilename)
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            Diag.log("practice: cannot play \(session.audioFilename)")
            return
        }
        player = p
        playingID = session.id
        p.play()
    }
}

struct PracticeRootView: View {
    let controller: PracticeController
    @State private var selectedPrompt: UUID?
    @State private var selectedSession: PracticeSession?
    @State private var refreshToken = UUID()
    @StateObject private var player = SessionPlayer()

    private var prompts: [PracticePrompt] { controller.prompts.all }
    private var sessions: [PracticeSession] {
        controller.store.sessions(forPrompt: selectedPrompt).reversed()
    }
    private var trend: [TrendPoint] { controller.store.trend(forPrompt: selectedPrompt) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPrompt) {
                Section("Prompts") {
                    ForEach(prompts) { p in
                        Text(p.title).tag(Optional(p.id))
                    }
                    Text("Free-form").tag(Optional<UUID>.none)
                }
            }
            .frame(minWidth: 200)
        } content: {
            List(sessions, selection: Binding(
                get: { selectedSession?.id },
                set: { id in selectedSession = sessions.first { $0.id == id } }
            )) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(statusLine(s)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(s.id)
            }
            .frame(minWidth: 240)
        } detail: {
            if let s = selectedSession {
                SessionDetailView(session: s, controller: controller,
                                  player: player, trend: trend)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No session selected")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Press the practice hotkey to record one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(refreshToken)
        .onAppear {
            controller.sessionsChanged = { refreshToken = UUID() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(diskUsage()).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
    }

    private func statusLine(_ s: PracticeSession) -> String {
        switch s.status {
        case .pending: return "Transcribing…"
        case .failed(let why): return "Failed: \(why)"
        case .ready:
            guard let m = s.metrics else { return "Ready" }
            return String(format: "%.0f WPM · %.1f fillers/100w · %d pauses",
                          m.wpm, m.fillerRate, m.pauseCount)
        }
    }

    private func diskUsage() -> String {
        let bytes = controller.recordingsDiskBytes()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + " of recordings on disk"
    }
}

struct SessionDetailView: View {
    let session: PracticeSession
    let controller: PracticeController
    @ObservedObject var player: SessionPlayer
    let trend: [TrendPoint]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(player.playingID == session.id ? "Stop" : "Play") {
                        player.toggle(session: session)
                    }
                    Text(String(format: "%.0fs", session.durationSec))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        controller.deleteSession(id: session.id)
                    }
                }

                EnvelopeView(envelope: session.envelope,
                             pauses: session.metrics?.pauses ?? [],
                             binSeconds: EnvelopeBuilder.defaultBinSeconds)
                    .frame(height: 56)

                if let m = session.metrics {
                    MetricTiles(metrics: m)
                }

                if let t = session.transcript, !t.isEmpty {
                    GroupBox("Transcript") {
                        Text(t).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if trend.count > 1 {
                    GroupBox("Across your attempts at this prompt") {
                        TrendSparkline(points: trend)
                            .frame(height: 80)
                    }
                }
            }
            .padding(16)
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
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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

/// Filler rate over time — lower is better, so a falling line means progress.
struct TrendSparkline: View {
    let points: [TrendPoint]

    var body: some View {
        GeometryReader { geo in
            let values = points.map(\.fillerRate)
            let maxV = max(values.max() ?? 1, 0.001)
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    i == 0 ? path.move(to: CGPoint(x: x, y: y))
                           : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
    }
}
