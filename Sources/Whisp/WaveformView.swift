import AppKit

/// The signature element: a row of rounded bars that visualizes the voice.
///
/// `.live` runs a continuous 60fps loop so the bars are always alive — your
/// voice spikes them instantly and silence eases them back down, so it reads
/// as real voice vibration rather than a static bar. `.shimmer` flows a calm
/// wave while transcribing/polishing. `.idle` settles flat. Reduce Motion is
/// respected: the loop is skipped and bars map directly to the input.
@MainActor
final class WaveformView: NSView {
    enum Mode { case live, shimmer, idle }

    private let barCount = 16
    private static let baseline: CGFloat = 0.09

    private var barValues: [CGFloat]      // current drawn height per bar, 0...1
    private let seeds: [CGFloat]          // per-bar phase offset for organic variation
    private let profile: [CGFloat]        // center-weighted hump so the middle reads taller
    private var targetLevel: CGFloat = 0  // latest voice energy (instant attack, eased decay)
    private var phase: CGFloat = 0
    private var anim: Task<Void, Never>?
    private var mode: Mode = .idle
    private var logCounter = 0

    override init(frame: NSRect) {
        let n = 16
        barValues = Array(repeating: WaveformView.baseline, count: n)
        seeds = (0..<n).map { CGFloat($0) * 0.7 }
        profile = (0..<n).map { i in
            0.45 + 0.55 * sin(.pi * (CGFloat(i) + 0.5) / CGFloat(n))
        }
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Feed a 0...1 voice level. Instant attack, the loop handles decay.
    func pushLevel(_ level: Float) {
        guard mode == .live else { return }
        let clamped = max(0, min(1, CGFloat(level)))
        let curved = min(1, pow(clamped, 0.55) * 1.6)   // gain so speech clearly drives the bars
        targetLevel = max(targetLevel, curved)
        logCounter += 1
        if logCounter % 20 == 0 {
            Diag.log("wave.level in=\(String(format: "%.3f", Double(level))) target=\(String(format: "%.3f", Double(targetLevel)))")
        }
        // With Reduce Motion there's no loop, so map straight to the bars.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for i in 0..<barCount {
                barValues[i] = WaveformView.baseline + (1 - WaveformView.baseline) * curved * profile[i]
            }
            needsDisplay = true
        }
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        anim?.cancel()
        anim = nil
        switch newMode {
        case .live:
            targetLevel = 0
            for i in 0..<barCount { barValues[i] = WaveformView.baseline }
            startLoop()
        case .shimmer:
            startLoop()
        case .idle:
            for i in 0..<barCount { barValues[i] = WaveformView.baseline }
        }
        needsDisplay = true
    }

    private func startLoop() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // Static fallback: a gentle wave for shimmer, baseline for live.
            if mode == .shimmer {
                for i in 0..<barCount { barValues[i] = 0.28 + 0.16 * profile[i] }
                needsDisplay = true
            }
            return
        }
        anim = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.tick()
                self.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(16))   // ~60fps
            }
        }
    }

    private func tick() {
        phase += 0.16
        switch mode {
        case .live:
            targetLevel *= 0.92   // smooth release toward silence
            for i in 0..<barCount {
                let dance = 0.80 + 0.20 * sin(phase * 1.8 + seeds[i])
                let desired = WaveformView.baseline
                    + (1 - WaveformView.baseline) * targetLevel * profile[i] * dance
                barValues[i] += (min(1, desired) - barValues[i]) * 0.5
            }
        case .shimmer:
            for i in 0..<barCount {
                let t = phase + CGFloat(i) * 0.45
                let desired = 0.22 + 0.22 * (sin(t) * 0.5 + 0.5)
                barValues[i] += (desired - barValues[i]) * 0.3
            }
        case .idle:
            for i in 0..<barCount {
                barValues[i] += (WaveformView.baseline - barValues[i]) * 0.3
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let gap: CGFloat = 2.5
        let barW = max(1, (w - gap * CGFloat(barCount - 1)) / CGFloat(barCount))

        let colors = [Theme.iris.cgColor, Theme.aqua.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors, locations: [0, 1]) else { return }

        for i in 0..<barCount {
            let amp = max(WaveformView.baseline, min(1, barValues[i]))
            let barH = max(barW, amp * h)
            let x = CGFloat(i) * (barW + gap)
            let y = (h - barH) / 2   // grow symmetrically from the center
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
