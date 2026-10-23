import AppKit
import WhispCore

/// Local visual QA without opening the microphone, hotkeys, network, or profile.
@MainActor
final class HUDPreviewWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let hud: HUDWindow
    private let sample: VoiceActivityView
    private let darkSample: VoiceActivityView
    private let notice = HUDNoticeView(frame: .zero)
    private let noticeHost = NSView()
    private var levels: Task<Void, Never>?

    init(reducedMotion: Bool? = nil) {
        hud = HUDWindow(reducedMotion: reducedMotion)
        sample = VoiceActivityView(frame: NSRect(origin: .zero, size: VoiceActivityView.preferredSize), reduceMotion: reducedMotion)
        darkSample = VoiceActivityView(frame: NSRect(origin: .zero, size: VoiceActivityView.preferredSize), reduceMotion: reducedMotion)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Whisp animation preview"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Whisp indicators")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let info = NSTextField(wrappingLabelWithString: "Preview each state. No microphone or network is used.")
        let buttons = ["Listening", "Transcribing", "Polishing", "Done", "Error", "Practice", "Hide", "Silence", "Nothing heard", "Text field"].enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(selectState(_:)))
            button.tag = index
            return button
        }
        let rows = [NSStackView(views: Array(buttons.prefix(3))),
                    NSStackView(views: Array(buttons[3..<8])),
                    NSStackView(views: Array(buttons.suffix(2)))]
        let backdrops = NSStackView(views: [backdrop(sample, dark: false), backdrop(darkSample, dark: true)])
        backdrops.spacing = 16
        noticeHost.widthAnchor.constraint(equalToConstant: 444).isActive = true
        noticeHost.heightAnchor.constraint(equalToConstant: 112).isActive = true
        noticeHost.addSubview(notice)
        notice.isHidden = true
        let stack = NSStackView(views: [heading, info, backdrops, noticeHost] + rows)
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

    private func backdrop(_ wave: VoiceActivityView, dark: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.19, alpha: 1)
                                       : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)).cgColor
        card.layer?.cornerRadius = 12
        card.widthAnchor.constraint(equalToConstant: 208).isActive = true
        card.heightAnchor.constraint(equalToConstant: 112).isActive = true
        wave.frame = NSRect(x: 16, y: 38, width: 176, height: 56)
        card.addSubview(wave)
        let label = NSTextField(labelWithString: dark ? "Dark background" : "Light background")
        label.font = .systemFont(ofSize: 11)
        label.textColor = dark ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 12, width: 180, height: 14)
        card.addSubview(label)
        return card
    }

    private func show(_ index: Int) {
        levels?.cancel()
        let states: [VoiceActivityView.State] = [.listening, .transcribing, .polishing, .done, .idle, .practice, .idle, .listening]
        sample.setState(states.indices.contains(index) ? states[index] : .idle)
        darkSample.setState(states.indices.contains(index) ? states[index] : .idle)
        let message: String? = switch index {
        case 4: "Text copied. Press Command + V to paste."
        case 8: "Nothing heard"
        case 9: "Text field changed. Use Command+V or Copy Last Dictation."
        default: nil
        }
        notice.isHidden = message == nil
        if let message {
            notice.setMessage(message)
            let size = notice.sizeThatFits(width: HUDNoticeView.preferredWidth)
            notice.frame = NSRect(x: (444 - size.width) / 2, y: (112 - size.height) / 2,
                                 width: size.width, height: size.height)
        }
        switch index {
        case 0: hud.show(.listening)
        case 1: hud.show(.transcribing)
        case 2: hud.show(.polishing)
        case 3: hud.show(.done(""))
        case 4: hud.show(.error("Text copied. Press Command + V to paste."))
        case 5: hud.showPractice(elapsed: 83)
        case 7:
            hud.show(.listening)
            hud.setLevel(0)
            sample.pushLevel(0)
            darkSample.pushLevel(0)
        case 8, 9: hud.show(.error(message!))
        default: hud.hide()
        }
        if index == 0 || index == 5 {
            levels = Task { @MainActor [weak self] in
                var phase = 0.0
                while !Task.isCancelled {
                    let level = Float(max(0, sin(phase) * sin(phase * 0.31))) * 0.65
                    self?.hud.setLevel(level)
                    self?.sample.pushLevel(level)
                    self?.darkSample.pushLevel(level)
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
        darkSample.stopAnimating()
        hud.hide()
    }
}
