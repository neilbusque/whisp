import AppKit
import WhispCore

/// A small floating overlay that shows what Whisp is doing. It never takes
/// focus (so you keep typing into your own app) and is built on real macOS
/// vibrancy with the live waveform as its centerpiece.
@MainActor
final class HUDWindow {
    private let window: NSWindow
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let wave = WaveformView(frame: .zero)
    private var hideWork: Task<Void, Never>?

    private static let cardWidth: CGFloat = 280
    private static let cardHeight: CGFloat = 96

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

        // Real blur instead of a flat card, masked to a rounded "glass" tile.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        window.contentView = blur

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Theme.mist
        label.font = Theme.rounded(15, .semibold)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.lineBreakMode = .byTruncatingTail

        wave.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(glyph)
        blur.addSubview(label)
        blur.addSubview(wave)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            glyph.topAnchor.constraint(equalTo: blur.topAnchor, constant: 17),
            glyph.widthAnchor.constraint(equalToConstant: 20),
            glyph.heightAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -18),

            wave.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            wave.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -18),
            wave.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -18),
            wave.heightAnchor.constraint(equalToConstant: 30),
        ])

        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: f.midX - Self.cardWidth / 2, y: f.minY + 90))
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
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
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
