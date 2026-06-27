import AppKit

/// The signature element: a row of rounded bars that visualizes the voice.
/// In `.live` mode each incoming mic level scrolls in from the right, so the
/// bars read as the actual sound of your speech. In `.shimmer` mode (no mic
/// data, e.g. transcribing) they breathe with a gentle wave. `.idle` flattens.
@MainActor
final class WaveformView: NSView {
    enum Mode { case live, shimmer, idle }

    private let barCount = 23
    private var levels: [CGFloat]
    private var phase: CGFloat = 0
    private var anim: Task<Void, Never>?
    private var mode: Mode = .idle

    override init(frame: NSRect) {
        levels = Array(repeating: 0.05, count: barCount)
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Push a 0...1 mic level; the buffer scrolls left so the newest sound is
    /// on the right. Only meaningful in `.live` mode.
    func pushLevel(_ level: Float) {
        guard mode == .live else { return }
        levels.removeFirst()
        levels.append(max(0.05, min(1, CGFloat(level))))
        needsDisplay = true
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        anim?.cancel()
        anim = nil

        switch newMode {
        case .live:
            levels = Array(repeating: 0.05, count: barCount)
        case .idle:
            levels = Array(repeating: 0.05, count: barCount)
        case .shimmer:
            // Respect Reduce Motion: hold a calm static wave instead of animating.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                break
            }
            anim = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    self.phase += 0.20
                    self.needsDisplay = true
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let gap: CGFloat = 3
        let barW = max(1, (w - gap * CGFloat(barCount - 1)) / CGFloat(barCount))

        let colors = [Theme.iris.cgColor, Theme.aqua.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors, locations: [0, 1]) else { return }

        for i in 0..<barCount {
            let amp: CGFloat
            switch mode {
            case .live:
                amp = levels[i]
            case .shimmer:
                let t = phase + CGFloat(i) * 0.45
                amp = 0.22 + 0.24 * (sin(t) * 0.5 + 0.5)
            case .idle:
                amp = 0.05
            }
            let barH = max(barW, amp * h)
            let x = CGFloat(i) * (barW + gap)
            let y = (h - barH) / 2
            let rect = CGRect(x: x, y: y, width: barW, height: barH)
            let path = CGPath(roundedRect: rect, cornerWidth: barW / 2,
                              cornerHeight: barW / 2, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: w, y: 0), options: [])
            ctx.restoreGState()
        }
    }

    deinit { anim?.cancel() }
}
