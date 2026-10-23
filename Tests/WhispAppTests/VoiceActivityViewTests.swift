import AppKit
import QuartzCore
import Testing
@testable import Whisp

@Suite @MainActor struct VoiceActivityViewTests {
    @Test func hidingStopsMotionAndSameStateCanResume() {
        let view = VoiceActivityView(frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                                     reduceMotion: false)
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
        let view = VoiceActivityView(frame: .zero, reduceMotion: false)
        view.setState(.listening)
        view.pushLevel(0.8)
        #expect(animationCount(in: view.layer) > 0)

        view.stopAnimating()
        view.pushLevel(1)
        #expect(animationCount(in: view.layer) == 0)
    }

    @Test func reducedMotionKeepsEveryStatusStatic() {
        let view = VoiceActivityView(frame: .zero, reduceMotion: true)
        let states: [VoiceActivityView.State] = [
            .listening, .transcribing, .polishing, .practice, .done, .error, .idle,
        ]
        for state in states {
            view.setState(state)
            view.pushLevel(1)
            #expect(animationCount(in: view.layer) == 0)
        }
    }

    private func animationCount(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0)
            + (layer.sublayers ?? []).reduce(0) { $0 + animationCount(in: $1) }
    }
}
