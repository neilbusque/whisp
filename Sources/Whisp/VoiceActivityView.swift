import AppKit
import QuartzCore

/// A compact status icon. Core Animation owns the ambient motion; audio updates
/// only adjust the rim, so the HUD has no display timer or rendering task.
@MainActor
final class VoiceActivityView: NSView {
    enum State: Equatable {
        case idle, listening, transcribing, polishing, done, error, practice
    }

    private let face = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let edge = CAShapeLayer()
    private let energy = CALayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let glyph = NSImageView()
    private let reduceMotionOverride: Bool?
    private var animationsEnabled = false
    private var reducedMotion = false
    private(set) var state: State = .idle

    private static let cyan = NSColor(srgbRed: 0.24, green: 0.82, blue: 0.89, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.36, green: 0.56, blue: 1, alpha: 1)
    private static let violet = NSColor(srgbRed: 0.65, green: 0.49, blue: 0.96, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.39, green: 0.87, blue: 0.72, alpha: 1)
    private static let amber = NSColor(srgbRed: 1, green: 0.74, blue: 0.35, alpha: 1)

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, reduceMotion: nil)
    }

    /// The override is used by the isolated HUD preview and motion tests.
    init(frame frameRect: NSRect, reduceMotion: Bool?) {
        reduceMotionOverride = reduceMotion
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        face.startPoint = CGPoint(x: 0, y: 1)
        face.endPoint = CGPoint(x: 1, y: 0)
        face.colors = [
            NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1).cgColor,
            NSColor(srgbRed: 0.075, green: 0.085, blue: 0.13, alpha: 1).cgColor,
        ]
        face.locations = [0, 1]
        layer?.addSublayer(face)

        sheen.startPoint = CGPoint(x: 0.25, y: 1)
        sheen.endPoint = CGPoint(x: 0.75, y: 0)
        sheen.colors = [NSColor.white.withAlphaComponent(0.075).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        layer?.addSublayer(sheen)

        edge.fillColor = NSColor.clear.cgColor
        edge.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        edge.lineWidth = 0.75
        layer?.addSublayer(edge)

        layer?.addSublayer(energy)
        rim.type = .conic
        rim.startPoint = CGPoint(x: 0.5, y: 0.5)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        rim.locations = [0, 0.32, 0.67, 1]
        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.8
        rim.mask = rimMask
        energy.addSublayer(rim)

        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        glyph.wantsLayer = true
        // The containing HUD exposes the complete status as one accessible item.
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        reducedMotion = shouldReduceMotion
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        let diameter = max(0, min(bounds.width, bounds.height) - 10)
        let circle = CGRect(x: bounds.midX - diameter / 2,
                            y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = circle
        face.cornerRadius = diameter / 2
        sheen.frame = circle
        sheen.cornerRadius = diameter / 2
        edge.frame = bounds
        edge.path = CGPath(ellipseIn: circle.insetBy(dx: 3, dy: 3), transform: nil)
        energy.bounds = bounds
        energy.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rim.frame = bounds
        rimMask.frame = bounds
        rimMask.path = CGPath(ellipseIn: circle, transform: nil)
        glyph.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12,
                             width: 24, height: 24)
        CATransaction.commit()
    }

    func setState(_ newState: State) {
        let changed = state != newState
        guard changed || !animationsEnabled else { return }
        state = newState
        animationsEnabled = newState != .idle
        reducedMotion = shouldReduceMotion
        updateAppearance(animated: changed && newState != .idle && !reducedMotion)
        updateAmbientMotion()
    }

    func pushLevel(_ level: Float) {
        guard animationsEnabled, state == .listening || state == .practice else { return }
        let finiteLevel = level.isFinite ? level : 0
        let strength = min(1, pow(CGFloat(max(0, min(1, finiteLevel))), 0.55) * 1.4)
        let nextScale = reducedMotion ? 1 : 1 + strength * 0.055
        let currentScale = energy.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        energy.transform = CATransform3DMakeScale(nextScale, nextScale, 1)
        rim.opacity = Float(0.72 + strength * 0.28)
        CATransaction.commit()

        guard !reducedMotion else { return }
        let response = CABasicAnimation(keyPath: "transform.scale")
        response.fromValue = currentScale
        response.toValue = nextScale
        response.duration = 0.16
        response.timingFunction = CAMediaTimingFunction(name: .easeOut)
        energy.add(response, forKey: "activity.level")
    }

    /// Called whenever the HUD is ordered out. A subsequent setState resumes it,
    /// including when the next recording uses the same state as the previous one.
    func stopAnimating() {
        animationsEnabled = false
        for animatedLayer in [face, sheen, edge, energy, rim, rimMask, glyph.layer].compactMap({ $0 }) {
            animatedLayer.removeAllAnimations()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        energy.transform = CATransform3DIdentity
        rim.transform = CATransform3DIdentity
        glyph.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func refreshMotionPreference() {
        let next = shouldReduceMotion
        guard reducedMotion != next else { return }
        reducedMotion = next
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

    private func updateAppearance(animated: Bool) {
        let symbol: String
        let colors: [NSColor]
        switch state {
        case .idle, .listening:
            symbol = "mic.fill"
            colors = [Self.cyan, Self.blue, Self.violet, Self.cyan]
        case .practice:
            symbol = "mic.badge.plus"
            colors = [Self.cyan, Self.blue, Self.violet, Self.cyan]
        case .transcribing:
            symbol = "waveform"
            colors = [Self.cyan, Self.blue, Self.violet, Self.cyan]
        case .polishing:
            symbol = "sparkles"
            colors = [Self.violet, Self.blue, Self.cyan, Self.violet]
        case .done:
            symbol = "checkmark"
            colors = [Self.mint, Self.cyan, Self.mint, Self.mint]
        case .error:
            symbol = "exclamationmark"
            colors = [Self.amber, Self.amber.withAlphaComponent(0.65), Self.amber, Self.amber]
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.colors = colors.map(\.cgColor)
        rim.opacity = state == .idle ? 0.45 : 0.88
        energy.transform = CATransform3DIdentity
        glyph.contentTintColor = state == .done ? Self.mint : state == .error ? Self.amber : .white
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        glyph.image = image?.withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        CATransaction.commit()

        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            glyph.layer?.add(transition, forKey: "activity.symbol")
        }
    }

    private func updateAmbientMotion() {
        rim.removeAnimation(forKey: "activity.rotation")
        sheen.removeAnimation(forKey: "activity.breathe")
        glyph.layer?.removeAnimation(forKey: "activity.polish")
        energy.removeAnimation(forKey: "activity.level")
        if !animationsEnabled || reducedMotion {
            glyph.layer?.removeAnimation(forKey: "activity.symbol")
        }
        guard animationsEnabled, !reducedMotion else { return }

        switch state {
        case .listening, .practice:
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.5
            breath.toValue = 1
            breath.duration = 1.7
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sheen.add(breath, forKey: "activity.breathe")
        case .transcribing, .polishing:
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = state == .polishing ? 4 : 3
            rotation.repeatCount = .infinity
            rim.add(rotation, forKey: "activity.rotation")
            if state == .polishing {
                let shimmer = CABasicAnimation(keyPath: "opacity")
                shimmer.fromValue = 0.6
                shimmer.toValue = 1
                shimmer.duration = 0.9
                shimmer.autoreverses = true
                shimmer.repeatCount = .infinity
                shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glyph.layer?.add(shimmer, forKey: "activity.polish")
            }
        case .idle, .done, .error:
            break
        }
    }
}
