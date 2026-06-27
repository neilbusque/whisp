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
    private let sheen = CAGradientLayer()
    private var hideWork: Task<Void, Never>?

    private static let cardWidth: CGFloat = 248
    private static let cardHeight: CGFloat = 46
    private static let radius: CGFloat = 23
    private static let shownAlpha: CGFloat = 0.9   // reduced opacity / translucent glass

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Frosted glass base.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        window.contentView = blur

        // Glassmorphism layers: a faint dark tint to keep text legible while
        // translucent, plus a top sheen for depth. Below the content, above blur.
        let glass = NSView(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight))
        glass.wantsLayer = true
        glass.layer?.backgroundColor = Theme.ink.withAlphaComponent(0.14).cgColor
        glass.autoresizingMask = [.width, .height]
        sheen.frame = glass.bounds
        sheen.colors = [NSColor(white: 1, alpha: 0.14).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.45)
        glass.layer?.addSublayer(sheen)
        blur.addSubview(glass)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Theme.mist
        label.font = Theme.rounded(13, .semibold)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.lineBreakMode = .byTruncatingTail
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
