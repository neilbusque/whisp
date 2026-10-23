import AppKit
import QuartzCore
import Testing
@testable import Whisp

@Suite @MainActor struct VoiceActivityViewTests {
    @Test func hidingStopsMotionAndSameStateCanResume() {
        let view = makeView()
        view.setState(.transcribing)
        #expect(animationCount(in: view.layer) > 0)

        view.stopAnimating()
        #expect(animationCount(in: view.layer) == 0)

        view.setState(.transcribing)
        #expect(animationCount(in: view.layer) > 0)
        view.setState(.idle)
        #expect(animationCount(in: view.layer) == 0)
    }

    @Test func lateAudioCannotRestartHiddenIndicator() {
        let view = makeView()
        view.setState(.listening)
        view.pushLevel(0.8)
        #expect(view.audioStrength > 0)
        #expect(animationCount(in: view.layer) > 0)

        view.stopAnimating()
        view.pushLevel(1)
        #expect(view.audioStrength == 0)
        #expect(animationCount(in: view.layer) == 0)
    }

    @Test func voiceChangesUnevenBarHeightsAndSilenceSettlesThem() {
        let view = makeView()
        view.setState(.listening)
        let restingHeights = heights(in: view)
        view.pushLevel(0.25)
        let speakingHeights = heights(in: view)
        #expect(view.audioStrength > 0)
        #expect(speakingHeights.reduce(0, +) > restingHeights.reduce(0, +))
        #expect((speakingHeights.max() ?? 0) > 24)
        #expect(Set(speakingHeights.map { Int($0) }).count > 10)
        #expect(bars(in: view).allSatisfy { $0.bounds.width == 3 })

        view.pushLevel(1)
        #expect(view.audioStrength == 1)
        #expect(heights(in: view).allSatisfy { $0 <= VoiceActivityView.preferredSize.height - 12 })
        view.pushLevel(0)
        #expect(view.audioStrength == 0)
        #expect(heights(in: view) == restingHeights)
        #expect(animationCount(in: view.layer) == 0)
    }

    @Test func silentRecordingAndRoomNoiseHaveNoMotion() {
        let view = makeView()
        for state in [VoiceActivityView.State.listening, .practice] {
            view.setState(state)
            let restingHeights = heights(in: view)
            #expect(animationCount(in: view.layer) == 0)
            for noise in [Float(0), 0.001, VoiceActivityView.audioNoiseFloor * 0.99,
                          VoiceActivityView.audioNoiseFloor, -1] {
                view.pushLevel(noise)
                #expect(view.audioStrength == 0)
                #expect(heights(in: view) == restingHeights)
                #expect(animationCount(in: view.layer) == 0)
            }
            view.pushLevel(0.4)
            #expect(animationCount(in: view.layer) > 0)
            view.pushLevel(VoiceActivityView.audioNoiseFloor * 0.5)
            #expect(heights(in: view) == restingHeights)
            #expect(animationCount(in: view.layer) == 0)
        }
    }

    @Test func sustainedSoundMovesBarsWithoutARepeatingAnimation() {
        let view = makeView()
        view.setState(.listening)
        view.pushLevel(0.3)
        let firstHeights = heights(in: view)
        view.pushLevel(0.3)
        #expect(heights(in: view) != firstHeights)
        for bar in bars(in: view) {
            let animation = bar.animation(forKey: "activity.level")
            #expect(animation != nil)
            #expect(animation?.repeatCount == 0)
            #expect((animation?.duration ?? 1) <= 0.16)
            #expect(bar.animation(forKey: "activity.processing") == nil)
        }
    }

    @Test func recordingResumesStillAfterProcessingOrCompletion() {
        let view = makeView()
        for previous in [VoiceActivityView.State.transcribing, .polishing, .done, .error] {
            view.setState(previous)
            view.setState(.listening)
            #expect(animationCount(in: view.layer) == 0)
            view.pushLevel(0)
            #expect(animationCount(in: view.layer) == 0)
        }
    }

    @Test func invalidAudioAndRepeatedStatusDoNotResetSpeakingBars() {
        let view = makeView()
        view.setState(.practice)
        view.pushLevel(0.3)
        let strength = view.audioStrength
        let speakingHeights = heights(in: view)
        let animations = animationCount(in: view.layer)

        view.pushLevel(.nan)
        view.pushLevel(.infinity)
        view.pushLevel(-.infinity)
        view.setState(.practice)
        #expect(view.audioStrength == strength)
        #expect(heights(in: view) == speakingHeights)
        #expect(animationCount(in: view.layer) == animations)
    }

    @Test func audioDoesNotChangeProcessingOrCompletionStates() {
        let view = makeView()
        for state in [VoiceActivityView.State.transcribing, .polishing, .done, .error, .idle] {
            view.setState(state)
            let previousHeights = heights(in: view)
            view.pushLevel(1)
            #expect(view.audioStrength == 0)
            #expect(heights(in: view) == previousHeights)
        }
    }

    @Test func reducedMotionKeepsEveryStatusStatic() {
        let view = makeView(reduceMotion: true)
        let states: [VoiceActivityView.State] = [
            .listening, .transcribing, .polishing, .practice, .done, .error, .idle,
        ]
        for state in states {
            view.setState(state)
            let previousHeights = heights(in: view)
            view.pushLevel(1)
            #expect(view.audioStrength == 0)
            #expect(heights(in: view) == previousHeights)
            #expect(animationCount(in: view.layer) == 0)
        }
    }

    @Test func liveStatesUseGradientBarsWithoutAnIconOrOpaqueBase() {
        let view = makeView()
        #expect(view.layer?.backgroundColor?.alpha == 0)
        #expect(bars(in: view).count == 31)
        #expect(waveLayer(in: view)?.backgroundColor == nil)
        #expect(waveLayer(in: view)?.mask?.backgroundColor == nil)
        #expect((waveLayer(in: view) as? CAGradientLayer)?.colors?.count == 4)
        for state in [VoiceActivityView.State.listening, .practice, .transcribing, .polishing] {
            view.setState(state)
            #expect(view.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.isHidden && $0.image == nil })
            #expect(waveLayer(in: view)?.opacity == 1)
        }
    }

    @Test func subtleGlowFollowsBarsAndStopsWithSilence() {
        let view = makeView()
        view.setState(.listening)
        let glow = view.layer?.sublayers?.first { $0.name == "voice.glow" }
        let glowBars = glow?.mask?.sublayers ?? []
        #expect(glowBars.count == bars(in: view).count)
        #expect(glow?.backgroundColor == nil)
        #expect(glow?.mask?.backgroundColor == nil)
        #expect((glow?.opacity ?? 0) > 0)
        #expect((glow?.opacity ?? 1) <= 0.2)
        #expect(animationCount(in: glow) == 0)

        view.pushLevel(0.4)
        for (bar, halo) in zip(bars(in: view), glowBars) {
            #expect(halo.bounds == bar.bounds)
            #expect(halo.position == bar.position)
            #expect(halo.animation(forKey: "activity.level")?.duration
                    == bar.animation(forKey: "activity.level")?.duration)
        }
        view.pushLevel(0)
        #expect(animationCount(in: glow) == 0)
        #expect(glowBars.map { $0.bounds.height } == heights(in: view))

        view.setState(.polishing)
        #expect(animationCount(in: glow) > 0)
        view.stopAnimating()
        #expect(animationCount(in: glow) == 0)
    }

    private func makeView(reduceMotion: Bool = false) -> VoiceActivityView {
        VoiceActivityView(frame: CGRect(origin: .zero, size: VoiceActivityView.preferredSize),
                          reduceMotion: reduceMotion)
    }

    private func waveLayer(in view: VoiceActivityView) -> CALayer? {
        view.layer?.sublayers?.first { $0.name == "voice.waves" }
    }

    private func bars(in view: VoiceActivityView) -> [CALayer] {
        waveLayer(in: view)?.mask?.sublayers ?? []
    }

    private func heights(in view: VoiceActivityView) -> [CGFloat] {
        bars(in: view).map { $0.bounds.height }
    }

    private func animationCount(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0)
            + animationCount(in: layer.mask)
            + (layer.sublayers ?? []).reduce(0) { $0 + animationCount(in: $1) }
    }
}
