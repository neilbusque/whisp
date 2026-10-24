import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import Combine
import WhispCore

enum WorkspaceRoute: String, CaseIterable, Identifiable {
    case home, notes, memory, history, corrections, snippets, practice, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Dictation"
        case .notes: return "Notes"
        case .memory: return "Memory"
        case .history: return "Recent dictations"
        case .corrections: return "Corrections"
        case .snippets: return "Snippets"
        case .practice: return "Practice"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .notes: return "book.closed"
        case .memory: return "brain"
        case .history: return "clock"
        case .corrections: return "text.badge.checkmark"
        case .snippets: return "text.bubble"
        case .practice: return "mic"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class WorkspaceState: ObservableObject {
    @Published var route: WorkspaceRoute = .home
    @Published var visited: Set<WorkspaceRoute> = [.home]
    @Published var status = "Getting ready"
    @Published var recognition = "OpenAI streaming"
    @Published var practice: PracticeController?
    @Published var practiceLoading = false
    @Published var practiceError: String?
    @Published var selectedEntry: UUID?
    private var notebookChanges: AnyCancellable?
    @Published var notebook: NotebookModel? {
        didSet {
            notebookChanges = notebook?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
    }
    var loadPractice: (() -> Void)?
    var recordPractice: (() -> Void)?
    var openContext: (() -> Void)?

    func select(_ destination: WorkspaceRoute) {
        visited.insert(destination)
        route = destination
        if destination == .practice, practice == nil, !practiceLoading { loadPractice?() }
    }
}

@MainActor
final class WorkspaceWindow {
    static let shared = WorkspaceWindow()
    private var window: NSWindow?

    func show(model: LearningModel, state: WorkspaceState, route: WorkspaceRoute) {
        if window == nil {
            let snippetsPath = (try? Paths.loadConfig()).map { NSString(string: $0.snippetsPath).expandingTildeInPath } ?? Paths.snippetsFile
            let host = NSHostingController(rootView: WorkspaceView(model: model, state: state, snippetsPath: snippetsPath))
            let window = NSWindow(contentViewController: host)
            window.title = CommandLine.arguments.contains("--no-hotkeys") ? "Whisp Preview" : "Whisp"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "WhispWorkspace")
            window.toolbar?.showsBaselineSeparator = false
            let compactPreview = CommandLine.arguments.contains("--no-hotkeys") && CommandLine.arguments.contains("--compact-preview")
            window.setContentSize(compactPreview ? NSSize(width: 940, height: 610) : NSSize(width: 1120, height: 750))
            window.minSize = NSSize(width: 940, height: 640)
            window.isReleasedWhenClosed = false
            window.appearance = NSApp.appearance ?? NSAppearance(named: .darkAqua)
            window.center()
            self.window = window
        }
        state.select(route)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct WorkspaceView: View {
    @ObservedObject var model: LearningModel
    @ObservedObject var state: WorkspaceState
    let snippetsPath: String
    private var learningActive: Bool { state.route == .corrections || state.route == .history }

    var body: some View {
        GeometryReader { geometry in
            workspaceContent.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var workspaceContent: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                // Keep visited editors mounted so navigating never discards a draft.
                ZStack {
                    DictationHome(model: model, state: state).workspaceDestination(state.route == .home)
                    if state.visited.contains(.corrections) || state.visited.contains(.history) {
                        LearningView(model: model, initialTab: state.route == .history ? 1 : 0,
                                     requestedTab: state.route == .history ? 1 : 0,
                                     embedded: true, active: learningActive, requestedEntry: state.selectedEntry,
                                     onEntrySelected: { state.selectedEntry = $0 })
                            .workspaceDestination(learningActive)
                    }
                    if let notebook = state.notebook {
                        if state.visited.contains(.notes) {
                            NotebookView(model: notebook).workspaceDestination(state.route == .notes)
                        }
                        if state.visited.contains(.memory) {
                            NotebookMemoryView(model: notebook).workspaceDestination(state.route == .memory)
                        }
                    }
                    if state.visited.contains(.snippets) {
                        SnippetsView(path: snippetsPath)
                            .workspaceDestination(state.route == .snippets)
                    }
                    if state.visited.contains(.settings) {
                        SettingsView(path: Paths.configFile).workspaceDestination(state.route == .settings)
                    }
                    if let practice = state.practice, state.visited.contains(.practice) {
                        PracticeRootView(controller: practice, onRecord: state.recordPractice, active: state.route == .practice)
                            .id(ObjectIdentifier(practice))
                            .workspaceDestination(state.route == .practice)
                    } else if state.route == .practice {
                        practicePlaceholder
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }.background(Color.workspaceBackground)
        }
        .tint(Color.workspaceAccent)
        .environment(\.timeZone, TimeZone(identifier: "America/New_York")!)
        .onChange(of: state.route) { _ in model.stopPlayback(); state.notebook?.stopPlayback() }
        .alert("Notebook", isPresented: Binding(get: { state.notebook?.error != nil }, set: { if !$0 { state.notebook?.error = nil } })) {
            Button("OK") { state.notebook?.error = nil }
        } message: { Text(state.notebook?.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .whispWorkspaceRoute)) { note in
            if let route = note.object as? WorkspaceRoute { state.select(route) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 34, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisp").font(.system(size: 18, weight: .semibold))
                    Text("Your voice, clearly.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 26)
            VStack(spacing: 5) {
                ForEach(WorkspaceRoute.allCases.filter { $0 != .settings }) { route in navButton(route) }
            }.padding(.horizontal, 10)
            Spacer()
            Divider().padding(.horizontal, 18).padding(.bottom, 12)
            VStack(spacing: 5) {
                Button { state.openContext?() } label: {
                    Label("Writing context", systemImage: "text.alignleft")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Edit your background and writing preferences")
                navButton(.settings)
            }.padding(.horizontal, 10).padding(.bottom, 16)
        }.background(Color.workspaceSidebar)
    }

    private func navButton(_ route: WorkspaceRoute) -> some View {
        Button { state.select(route) } label: {
            Label(route.title, systemImage: route.symbol)
                .font(.system(size: 13, weight: state.route == route ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(state.route == route ? Color.workspaceSelection : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(state.route == route ? .primary : .secondary)
            .accessibilityAddTraits(state.route == route ? .isSelected : [])
    }

    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Color.workspaceAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPreview ? "Preview" : statusTitle).font(.system(size: 12, weight: .medium))
                    Text(isPreview ? "Sample workspace · voice shortcuts off" : state.recognition)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Hold").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("fn").font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.workspaceSelection, in: RoundedRectangle(cornerRadius: 5))
                Text("to dictate").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 13)
        }.background(Color.workspaceSidebar)
    }

    private var statusTitle: String {
        if state.status == "Ready" || state.status == "Idle" {
            if !AXIsProcessTrusted() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                return "Finish setup in Settings"
            }
            return "Ready to dictate"
        }
        return state.status
    }
    private var isPreview: Bool { CommandLine.arguments.contains("--no-hotkeys") }
    private var practicePlaceholder: some View {
        VStack(spacing: 16) {
            if state.practiceLoading { ProgressView().controlSize(.small) }
            else { Image(systemName: "mic").font(.system(size: 32)).foregroundStyle(.secondary) }
            Text(state.practiceLoading ? "Preparing practice" : "Practice when you’re ready")
                .font(.system(size: 24, weight: .semibold))
            Text(state.practiceError ?? "Record a thought, review your delivery, and improve at your own pace.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !state.practiceLoading {
                Button("Open practice") { state.loadPractice?() }.buttonStyle(.borderedProminent)
            }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DictationHome: View {
    @ObservedObject var model: LearningModel
    @ObservedObject var state: WorkspaceState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("A thought. Into words.").font(.system(size: 28, weight: .semibold))
                    Text("Speak naturally. Whisp takes care of the writing.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Image(systemName: "waveform").font(.system(size: 28, weight: .light))
                                .foregroundStyle(Color.workspaceAccent)
                            Spacer()
                            Text("fn").font(.system(size: 25, weight: .medium, design: .monospaced))
                                .frame(width: 62, height: 54)
                                .background(Color.workspaceSelection, in: RoundedRectangle(cornerRadius: 12))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hold. Speak. Release.").font(.system(size: 21, weight: .semibold))
                            Text("Click where you want to write, hold Fn, and say what’s on your mind. Release to insert your words.")
                                .foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        Label("Hesitations cleaned up as you go", systemImage: "checkmark")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).workspacePanel()
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Say it your way").font(.system(size: 16, weight: .semibold))
                        command("Make this better", detail: "Polish selected text or your last dictation.", icon: "text.alignleft")
                        Divider()
                        command("Make it more casual", detail: "Change the tone in place.", icon: "text.bubble")
                        Divider()
                        command("Remove this part", detail: "Delete only the text you highlighted.", icon: "delete.left")
                    }.padding(22).frame(width: 254, alignment: .leading).workspacePanel()
                }
                HStack {
                    Text("Recent dictations").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("View all") { state.select(.history) }.buttonStyle(.plain).foregroundStyle(Color.workspaceAccent)
                }
                if model.data.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Your next thought starts here.").fontWeight(.medium)
                        Text("Dictate into any text field. Your recent words will be here when history is enabled.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("History settings") { state.select(.settings) }.padding(.top, 5)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).workspacePanel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.data.entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            Button {
                                state.selectedEntry = entry.id
                                state.select(.history)
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "text.alignleft").foregroundStyle(.secondary).frame(width: 22)
                                    Text(entry.output).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(entry.createdAt, style: .time).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                }.padding(18).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.workspacePanel()
                }
                Text("To edit existing text, select it first or keep the cursor after your last Whisp insertion.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func command(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text("“\(title)”").font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    func workspaceDestination(_ active: Bool) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(active ? 1 : 0).allowsHitTesting(active).disabled(!active).accessibilityHidden(!active)
    }
    func workspacePanel() -> some View {
        self.background(Color.workspaceSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.workspaceBorder, lineWidth: 0.75))
    }
}

extension Notification.Name {
    static let whispWorkspaceRoute = Notification.Name("WhispWorkspaceRoute")
}
