import AppKit
import WhispCore

/// Local visual QA without opening the microphone, hotkeys, network, or profile.
@MainActor
final class HUDPreviewWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let hud: HUDWindow
    private let sample: VoiceActivityView
    private var levels: Task<Void, Never>?

    init(reducedMotion: Bool? = nil) {
        hud = HUDWindow(reducedMotion: reducedMotion)
        sample = VoiceActivityView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), reduceMotion: reducedMotion)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Whisp animation preview"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Activity icon")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let info = NSTextField(wrappingLabelWithString: "Preview each state. No microphone or network is used.")
        let buttons = ["Listening", "Transcribing", "Polishing", "Done", "Error", "Practice", "Hide"].enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(selectState(_:)))
            button.tag = index
            return button
        }
        let rows = [NSStackView(views: Array(buttons.prefix(3))), NSStackView(views: Array(buttons.suffix(4)))]
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sample.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let stack = NSStackView(views: [heading, info, sample] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        show(0)
    }

    @objc private func selectState(_ sender: NSButton) { show(sender.tag) }

    private func show(_ index: Int) {
        levels?.cancel()
        let states: [VoiceActivityView.State] = [.listening, .transcribing, .polishing, .done, .error, .practice, .idle]
        sample.setState(states.indices.contains(index) ? states[index] : .idle)
        switch index {
        case 0: hud.show(.listening)
        case 1: hud.show(.transcribing)
        case 2: hud.show(.polishing)
        case 3: hud.show(.done(""))
        case 4: hud.show(.error("Text copied. Press Command + V to paste."))
        case 5: hud.showPractice(elapsed: 83)
        default: hud.hide()
        }
        if index == 0 || index == 5 {
            levels = Task { @MainActor [weak self] in
                var phase = 0.0
                while !Task.isCancelled {
                    let level = Float(max(0, sin(phase) * sin(phase * 0.31))) * 0.65
                    self?.hud.setLevel(level)
                    self?.sample.pushLevel(level)
                    phase += 0.24
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        levels?.cancel()
        sample.stopAnimating()
        hud.hide()
    }
}
