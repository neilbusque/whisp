import AppKit
import WhispCore

/// A floating aurora waveform. It cannot activate, take keyboard focus, or catch
/// mouse input. Text appears only when there is something the user must read.
@MainActor
final class HUDWindow: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let window: NSPanel
    private let activity: VoiceActivityView
    private let message = HUDNoticeView(frame: .zero)
    private var hideWork: Task<Void, Never>?
    private var presentation = 0
    private let reducedMotion: () -> Bool

    init(reducedMotion: Bool? = nil) {
        self.reducedMotion = { reducedMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        activity = VoiceActivityView(frame: NSRect(origin: .zero, size: VoiceActivityView.preferredSize),
                                     reduceMotion: reducedMotion)
        window = Panel(contentRect: NSRect(x: 0, y: 0, width: 196, height: 76),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .aqua)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: window.frame)
        window.contentView = content
        content.addSubview(activity)
        content.addSubview(message)
        message.isHidden = true
        activity.setAccessibilityElement(true)
        activity.setAccessibilityRole(.image)
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    deinit {
        hideWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setLevel(_ level: Float) { activity.pushLevel(level) }

    func show(_ status: PipelineStatus) {
        switch status {
        case .idle: hide()
        case .listening: present(.listening, description: "Listening")
        case .transcribing: present(.transcribing, description: "Transcribing")
        case .polishing: present(.polishing, description: "Polishing")
        case .done:
            finish(description: "Done")
        case .error(let text):
            present(.error, description: text, message: text)
            scheduleHide(after: noticeDuration(text), fadeDuration: 0.12)
        }
    }

    func showPractice(elapsed: TimeInterval) {
        let seconds = max(0, Int(elapsed))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        present(.practice, description: "Practice recording, \(time)")
    }

    func showPracticeStatus(_ text: String, done: Bool = false, error: Bool = false) {
        if done && !error { finish(description: text); return }
        present(error ? .error : .transcribing, description: text,
                message: error ? text : nil)
        if error { scheduleHide(after: noticeDuration(text), fadeDuration: 0.12) }
    }

    private func finish(description: String) {
        guard window.isVisible, !reducedMotion() else { hide(); return }
        hideWork?.cancel()
        presentation += 1
        activity.setState(.done)
        activity.setAccessibilityLabel(description)
        window.title = "Whisp: \(description)"
        layout(message: nil)
        scheduleHide(after: 0, fadeDuration: 0.16)
    }

    private func present(_ state: VoiceActivityView.State, description: String, message text: String? = nil) {
        hideWork?.cancel()
        presentation += 1
        activity.setState(text == nil ? state : .idle)
        activity.setAccessibilityLabel(description)
        window.title = "Whisp: \(description)"
        layout(message: text)
        guard !window.isVisible else {
            // Supersede a completion fade if another recording starts during it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reducedMotion() ? 0 : 0.12
                window.animator().alphaValue = 1
            }
            return
        }
        window.alphaValue = reducedMotion() ? 1 : 0
        window.orderFrontRegardless()
        guard !reducedMotion() else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    private func layout(message text: String?) {
        let waveSize = VoiceActivityView.preferredSize
        let width: CGFloat = text == nil ? waveSize.width + 20 : HUDNoticeView.preferredWidth + 20
        var height: CGFloat = waveSize.height + 20
        if let text {
            message.setMessage(text)
            let size = message.sizeThatFits(width: width - 20)
            height = size.height + 20
            message.frame = NSRect(origin: NSPoint(x: 10, y: 10), size: size)
        }
        message.isHidden = text == nil
        activity.isHidden = text != nil
        activity.frame = NSRect(x: 10, y: (height - waveSize.height) / 2,
                                width: waveSize.width, height: waveSize.height)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 72,
                               width: width, height: height), display: true)
    }

    /// Cancels all work immediately, including compositor animations when hidden.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        presentation += 1
        activity.setState(.idle)
        activity.stopAnimating()
        window.orderOut(nil)
        window.alphaValue = 1
    }

    private func noticeDuration(_ text: String) -> Double {
        text.count > 100 ? 2.8 : 2.0
    }

    private func scheduleHide(after seconds: Double, fadeDuration: Double = 0.18) {
        hideWork?.cancel()
        let token = presentation
        hideWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, token == self.presentation else { return }
            if self.reducedMotion() { self.hide(); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeDuration
                self.window.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(for: .seconds(fadeDuration + 0.01))
            guard !Task.isCancelled, token == self.presentation else { return }
            self.hide()
        }
    }

    @objc private func motionPreferenceChanged() {
        activity.refreshMotionPreference()
    }
}
