import AVFoundation
import Foundation
import Testing
@testable import WhispAudio

@Suite struct PCMResamplerTests {
    private func audio(rate: Double, channels: AVAudioChannelCount = 1, frames: Int,
                       offset: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(frame + offset) / rate)) * 0.25
            }
        }
        return buffer
    }
    @Test(arguments: [8_000.0, 16_000.0, 44_100.0, 48_000.0])
    func retainsDurationAndSpeechAcrossSampleRates(_ rate: Double) throws {
        let buffer = audio(rate: rate, frames: Int(rate))
        let result = try PCMResampler.mono16k([buffer], from: buffer.format)
        #expect(abs(result.count - 16_000) <= 2)
        #expect(result.allSatisfy { $0.isFinite })
        #expect(result.map { abs($0) }.max()! > 0.20)
    }
    @Test func splitBuffersMatchOneContinuousRecording() throws {
        let whole = audio(rate: 48_000, frames: 48_000)
        var chunks: [AVAudioPCMBuffer] = []
        for start in stride(from: 0, to: 48_000, by: 1024) {
            chunks.append(audio(rate: 48_000, frames: min(1024, 48_000 - start), offset: start))
        }
        let one = try PCMResampler.mono16k([whole], from: whole.format)
        let split = try PCMResampler.mono16k(chunks, from: whole.format)
        #expect(one.count == split.count)
        #expect(zip(one, split).allSatisfy { abs($0 - $1) < 0.0001 })
    }
    @Test func stereoIsMixedToMono() throws {
        let buffer = audio(rate: 48_000, channels: 2, frames: 48_000)
        let result = try PCMResampler.mono16k([buffer], from: buffer.format)
        #expect(abs(result.count - 16_000) <= 2)
        #expect(result.map { abs($0) }.max()! > 0.20)
    }
    @Test func finalSpeechSamplesAreNotDropped() throws {
        let buffer = audio(rate: 48_000, frames: 48_000)
        for i in 0..<47_520 { buffer.floatChannelData![0][i] = 0 }
        let result = try PCMResampler.mono16k([buffer], from: buffer.format)
        #expect(result.suffix(160).contains { abs($0) > 0.1 })
        #expect(abs(result.count - 16_000) <= 2)
    }
    @Test func rejectsMixedFormatsInsteadOfLosingAudio() {
        let a = audio(rate: 48_000, frames: 1000), b = audio(rate: 44_100, frames: 1000)
        #expect(throws: (any Error).self) { try PCMResampler.mono16k([a, b], from: a.format) }
    }
    @Test func emptyInputIsSafe() throws {
        let buffer = audio(rate: 48_000, frames: 0)
        #expect(try PCMResampler.mono16k([], from: buffer.format).isEmpty)
        #expect(try PCMResampler.mono16k([buffer], from: buffer.format).isEmpty)
    }
}
