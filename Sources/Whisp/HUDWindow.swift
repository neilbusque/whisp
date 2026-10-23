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
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let message = NSVisualEffectView()
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
        message.material = .popover
        message.blendingMode = .behindWindow
        message.state = .active
        message.wantsLayer = true
        message.layer?.cornerRadius = 14
        message.layer?.masksToBounds = true
        message.layer?.borderWidth = 0.5
        message.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        content.addSubview(message)
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = .labelColor
        detail.maximumNumberOfLines = 0
        message.addSubview(detail)
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
            present(.done, description: "Done")
            scheduleHide(after: 1.0)
        case .error(let text):
            present(.error, description: text, message: text)
            scheduleHide(after: 4.0)
        }
    }

    func showPractice(elapsed: TimeInterval) {
        let seconds = max(0, Int(elapsed))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        present(.practice, description: "Practice recording, \(time)")
    }

    func showPracticeStatus(_ text: String, done: Bool = false, error: Bool = false) {
        present(error ? .error : done ? .done : .transcribing, description: text,
                message: error ? text : nil)
        if done || error { scheduleHide(after: error ? 4.0 : 1.6) }
    }

    private func present(_ state: VoiceActivityView.State, description: String, message text: String? = nil) {
        hideWork?.cancel()
        presentation += 1
        activity.setState(state)
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
        let width: CGFloat = text == nil ? waveSize.width + 20 : 340
        var height: CGFloat = waveSize.height + 20
        if let text {
            detail.stringValue = text
            let textWidth: CGFloat = width - 104
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: textWidth, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: detail.font!])
            height = max(80, ceil(bounds.height) + 32)
            message.frame = NSRect(x: 72, y: 8, width: width - 80, height: height - 16)
            detail.frame = NSRect(x: 12, y: 8, width: textWidth, height: height - 32)
            let size = message.bounds.size
            message.maskImage = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
                return true
            }
        }
        message.isHidden = text == nil
        let activityWidth = text == nil ? waveSize.width : 56
        activity.frame = NSRect(x: 10, y: (height - waveSize.height) / 2,
                                width: activityWidth, height: waveSize.height)
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

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let token = presentation
        hideWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, token == self.presentation else { return }
            if self.reducedMotion() { self.hide(); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                self.window.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled, token == self.presentation else { return }
            self.hide()
        }
    }

    @objc private func motionPreferenceChanged() {
        activity.refreshMotionPreference()
    }
}
