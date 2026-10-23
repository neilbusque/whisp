import AppKit
import QuartzCore

/// A gradient audio waveform on a completely clear surface. Recording motion is
/// driven only by microphone samples; Core Animation interpolates each response.
@MainActor
final class VoiceActivityView: NSView {
    enum State: Equatable {
        case idle, listening, transcribing, polishing, done, error, practice
    }

    static let preferredSize = NSSize(width: 176, height: 56)
    // AudioRecorder supplies RMS × 4. Keep ordinary room noise still.
    static let audioNoiseFloor: Float = 0.025
    private static let barCount = 31

    private let waves = CAGradientLayer()
    private let waveformMask = CALayer()
    private var bars: [CALayer] = []
    private let glow = CAGradientLayer()
    private let glowMask = CALayer()
    private var glowBars: [CALayer] = []
    private let glyph = NSImageView()
    private let reduceMotionOverride: Bool?
    private var animationsEnabled = false
    private var reducedMotion = false
    private var lastLayoutSize: NSSize?
    private var audioPhase: CGFloat = 0
    private(set) var state: State = .idle
    private(set) var audioStrength: CGFloat = 0

    private static let cyan = NSColor(srgbRed: 0.04, green: 0.70, blue: 0.83, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.22, green: 0.48, blue: 0.98, alpha: 1)
    private static let violet = NSColor(srgbRed: 0.59, green: 0.35, blue: 0.94, alpha: 1)
    private static let rose = NSColor(srgbRed: 0.86, green: 0.34, blue: 0.76, alpha: 1)
    private static let amber = NSColor(srgbRed: 0.88, green: 0.53, blue: 0.12, alpha: 1)

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, reduceMotion: nil)
    }

    /// The override is used by the isolated HUD preview and motion tests.
    init(frame frameRect: NSRect, reduceMotion: Bool?) {
        reduceMotionOverride = reduceMotion
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        waves.name = "voice.waves"
        glow.name = "voice.glow"
        for gradient in [glow, waves] {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [0, 0.34, 0.68, 1]
            layer?.addSublayer(gradient)
        }
        waves.mask = waveformMask
        glow.mask = glowMask

        for index in 0..<Self.barCount {
            let bar = CALayer()
            bar.name = "voice.bar.\(index)"
            bar.backgroundColor = NSColor.white.cgColor
            waveformMask.addSublayer(bar)
            bars.append(bar)

            // Only the individual bars cast a soft halo. The surrounding
            // surface stays clear, and the shared gradient colors the glow.
            let glowBar = CALayer()
            glowBar.backgroundColor = NSColor.white.cgColor
            glowBar.shadowColor = NSColor.white.cgColor
            glowBar.shadowOpacity = 0.9
            glowBar.shadowRadius = 3
            glowBar.shadowOffset = .zero
            glowMask.addSublayer(glowBar)
            glowBars.append(glowBar)
        }

        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.wantsLayer = true
        // The containing HUD exposes the complete status as one accessible item.
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        reducedMotion = shouldReduceMotion
        updateGeometry()
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        guard lastLayoutSize != bounds.size else { return }
        updateGeometry()
        updateAmbientMotion()
    }

    func setState(_ newState: State) {
        let changed = state != newState
        guard changed || !animationsEnabled else { return }
        state = newState
        animationsEnabled = newState != .idle
        audioStrength = 0
        audioPhase = 0
        reducedMotion = shouldReduceMotion
        updateAppearance(animated: changed && newState != .idle && !reducedMotion)
        updateAmbientMotion()
    }

    func pushLevel(_ level: Float) {
        guard animationsEnabled, !reducedMotion, level.isFinite,
              state == .listening || state == .practice else { return }
        guard level > Self.audioNoiseFloor else {
            // Silence is completely still. Remove even an unfinished response
            // from the last syllable, instead of leaving an idle pulse running.
            guard audioStrength > 0 else { return }
            audioStrength = 0
            audioPhase = 0
            removeAnimations(from: layer)
            setBarHeights(animated: false)
            return
        }

        let previousStrength = audioStrength
        let gatedLevel = CGFloat(min(1, level) - Self.audioNoiseFloor)
        audioStrength = min(1, pow(gatedLevel / 0.475, 0.45))
        // The shape changes with incoming audio, including sustained sounds.
        // No clock, repeating task, or timer advances a recording waveform.
        audioPhase = (audioPhase + 0.23).truncatingRemainder(dividingBy: .pi * 2)
        setBarHeights(animated: true, duration: audioStrength >= previousStrength ? 0.10 : 0.16)
    }

    /// Called whenever the HUD is ordered out. The same state can resume the next
    /// recording, while late audio callbacks cannot start a hidden animation.
    func stopAnimating() {
        animationsEnabled = false
        audioStrength = 0
        audioPhase = 0
        removeAnimations(from: layer)
        setBarHeights(animated: false)
    }

    func refreshMotionPreference() {
        let next = shouldReduceMotion
        guard reducedMotion != next else { return }
        reducedMotion = next
        audioStrength = 0
        audioPhase = 0
        updateAppearance(animated: false)
        updateAmbientMotion()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopAnimating()
    }

    private var shouldReduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateGeometry() {
        lastLayoutSize = bounds.size
        let availableWidth = max(0, bounds.width - 24)
        let spacing = availableWidth / CGFloat(Self.barCount - 1)
        let barWidth = min(3, spacing * 0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waves.frame = bounds
        waveformMask.frame = waves.bounds
        glow.frame = bounds
        glowMask.frame = glow.bounds
        for (index, bar) in bars.enumerated() {
            for element in [bar, glowBars[index]] {
                element.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight(at: index))
                element.position = CGPoint(x: 12 + CGFloat(index) * spacing, y: bounds.height / 2)
                element.cornerRadius = barWidth / 2
            }
        }
        glyph.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        CATransaction.commit()
    }

    private func updateAppearance(animated: Bool) {
        glyph.layer?.removeAllAnimations()
        let isSymbol = state == .error
        let palette = state == .polishing
            ? [Self.rose, Self.violet, Self.blue, Self.cyan]
            : [Self.cyan, Self.blue, Self.violet, Self.rose]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waves.colors = palette.map(\.cgColor)
        waves.opacity = isSymbol || state == .idle ? 0 : 1
        glow.colors = waves.colors
        glow.opacity = isSymbol || state == .idle ? 0 : 0.18
        glyph.isHidden = !isSymbol
        glyph.contentTintColor = Self.amber
        glyph.image = isSymbol
            ? NSImage(systemSymbolName: "exclamationmark",
                      accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
            : nil
        CATransaction.commit()
        setBarHeights(animated: false)

        if animated && isSymbol {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            glyph.layer?.add(transition, forKey: "activity.state")
        }
    }

    private func updateAmbientMotion() {
        for bar in bars + glowBars { bar.removeAllAnimations() }
        guard animationsEnabled, !reducedMotion else {
            removeAnimations(from: layer)
            return
        }
        // Listening and practice never animate themselves. Only incoming audio
        // above the noise floor can move those bars.
        guard state == .transcribing || state == .polishing else { return }

        for (index, bar) in bars.enumerated() {
            let flow = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let height = barHeight(at: index)
            flow.values = [0.66, 0.92, 1.15, 0.82, 0.66].map { height * $0 }
            flow.duration = (state == .polishing ? 1.65 : 1.05) + Double(index % 4) * 0.11
            flow.timeOffset = Double(index) * 0.07
            flow.repeatCount = .infinity
            flow.calculationMode = .cubic
            bar.add(flow, forKey: "activity.processing")
            glowBars[index].add(flow, forKey: "activity.processing")
        }
    }

    private func setBarHeights(animated: Bool, duration: CFTimeInterval = 0.12) {
        for (index, bar) in bars.enumerated() {
            let height = barHeight(at: index)
            let previousHeight = bar.presentation()?.bounds.height ?? bar.bounds.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = height
            glowBars[index].bounds.size.height = height
            CATransaction.commit()
            guard animated else { continue }
            let response = CABasicAnimation(keyPath: "bounds.size.height")
            response.fromValue = previousHeight
            response.toValue = height
            response.duration = duration
            response.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(response, forKey: "activity.level")
            glowBars[index].add(response, forKey: "activity.level")
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        let envelope = pow(max(0, sin(.pi * position)), 0.75)
        let maximum = max(4, bounds.height - 12)
        let offset = CGFloat(index)
        if audioStrength > 0 {
            let variation = 0.48 + 0.35 * abs(sin(offset * 0.79 + audioPhase))
                + 0.17 * abs(sin(offset * 1.73 - audioPhase * 0.7))
            return min(maximum, 4 + envelope * (12 + audioStrength * 28) * variation)
        }
        let variation = 0.48 + 0.52 * abs(sin(offset * 0.79))
        let amplitude: CGFloat = state == .transcribing || state == .polishing ? 23 : 9
        return min(maximum, 4 + envelope * amplitude * variation)
    }

    private func removeAnimations(from layer: CALayer?) {
        guard let layer else { return }
        layer.removeAllAnimations()
        removeAnimations(from: layer.mask)
        for child in layer.sublayers ?? [] { removeAnimations(from: child) }
    }
}
