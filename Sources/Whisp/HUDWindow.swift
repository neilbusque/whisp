import AppKit
import WhispCore

/// A small, premium glass pill that shows what Whisp is doing. It never takes
/// focus (so you keep typing into your own app). Built on real macOS vibrancy
/// with a translucent frosted look and the live waveform inline on the right.
@MainActor
final class HUDWindow {
    private let window: NSWindow
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let wave = WaveformView(frame: .zero)
    private var hideWork: Task<Void, Never>?

    private static let cardWidth: CGFloat = 360
    private static let cardHeight: CGFloat = 56
    private static let radius: CGFloat = 28
    // Keep foreground content crisp; the material supplies translucency.
    private static let shownAlpha: CGFloat = 1

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Frosted glass base.
        let bounds = NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight)
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        // Core Animation cornerRadius alone does not mask the WindowServer's
        // behind-window material or its shadow. Give AppKit the actual alpha
        // silhouette so everything outside the pill stays transparent.
        let radius = Self.radius
        blur.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        window.contentView = blur

        // Neutral charcoal keeps the live status legible over any application.
        let glass = NSView(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight))
        glass.wantsLayer = true
        glass.layer?.backgroundColor = Theme.ink.withAlphaComponent(0.84).cgColor
        glass.autoresizingMask = [.width, .height]
        blur.addSubview(glass)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Theme.mist
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.setContentHuggingPriority(.required, for: .horizontal)

        blur.addSubview(glyph)
        blur.addSubview(label)
        blur.addSubview(wave)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            glyph.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wave.leadingAnchor, constant: -10),

            wave.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            wave.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 92),
            wave.heightAnchor.constraint(equalToConstant: 20),
        ])

        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: f.midX - Self.cardWidth / 2, y: f.minY + 84))
    }

    /// Feeds the live waveform while listening; ignored in other states.
    func setLevel(_ level: Float) {
        wave.pushLevel(level)
    }

    func show(_ status: PipelineStatus) {
        hideWork?.cancel()
        switch status {
        case .idle:
            wave.setMode(.idle)
            window.orderOut(nil)
            return
        case .listening:
            setGlyph("mic.fill", Theme.iris)
            label.stringValue = "Listening"
            wave.setMode(.live)
        case .transcribing:
            setGlyph("waveform", Theme.aqua)
            label.stringValue = "Transcribing"
            wave.setMode(.shimmer)
        case .polishing:
            setGlyph("sparkles", Theme.iris)
            label.stringValue = "Polishing"
            wave.setMode(.shimmer)
        case .done:
            setGlyph("checkmark.circle.fill", Theme.mint)
            label.stringValue = "Done"
            wave.setMode(.idle)
            scheduleHide()
        case .error(let m):
            setGlyph("exclamationmark.triangle.fill", Theme.amber)
            label.stringValue = m
            wave.setMode(.idle)
            scheduleHide(after: 2.2)
        }
        positionBottomCenter()
        present()
    }

    /// Practice recording: amber glyph and an elapsed timer, so there is never
    /// a doubt about which mode is capturing. The live waveform is fed by the
    /// existing `setLevel(_:)`, same as dictation.
    func showPractice(elapsed: TimeInterval) {
        hideWork?.cancel()
        setGlyph("record.circle", Theme.amber)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        label.stringValue = String(format: "Practice  %d:%02d", mins, secs)
        wave.setMode(.live)
        positionBottomCenter()
        present()
    }

    /// Post-recording practice status ("Saved, transcribing…", "Transcribing 40%").
    func showPracticeStatus(_ text: String, done: Bool = false) {
        hideWork?.cancel()
        setGlyph(done ? "checkmark.circle.fill" : "waveform", done ? Theme.mint : Theme.aqua)
        label.stringValue = text
        wave.setMode(done ? .idle : .shimmer)
        positionBottomCenter()
        present()
        if done { scheduleHide(after: 1.6) }
    }

    private func setGlyph(_ symbol: String, _ tint: NSColor) {
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.contentTintColor = tint
    }

    /// Order front without stealing focus, with a quick fade unless Reduce Motion is on.
    private func present() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window.isVisible {
            window.alphaValue = Self.shownAlpha
            window.orderFrontRegardless()
            return
        }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = Self.shownAlpha
        }
    }

    private func scheduleHide(after seconds: Double = 1.2) {
        hideWork?.cancel()
        hideWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
        }
    }
}
