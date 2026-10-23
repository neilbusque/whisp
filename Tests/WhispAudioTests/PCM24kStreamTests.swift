import AVFoundation
import Foundation
import Testing
@testable import WhispAudio

@Suite struct PCM24kStreamTests {
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

    private func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
        }
    }

    @Test(arguments: [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0])
    func continuousStreamingPreservesDurationAndChunkBoundaries(_ rate: Double) throws {
        let frames = Int(rate)
        let whole = audio(rate: rate, frames: frames)
        let batch = try PCM24kStream(format: whole.format)
        var expected = try batch.append(whole)
        expected.append(try batch.finish())
        let stream = try PCM24kStream(format: whole.format)
        var actual = Data()
        var emittedBeforeFinish = false
        for start in stride(from: 0, to: frames, by: 1024) {
            let chunk = try stream.append(audio(rate: rate, frames: min(1024, frames - start), offset: start))
            if !chunk.isEmpty { emittedBeforeFinish = true }
            actual.append(chunk)
        }
        actual.append(try stream.finish())
        #expect(emittedBeforeFinish)
        #expect(actual.count.isMultiple(of: 2))
        #expect(abs(actual.count / 2 - 24_000) <= 2)
        #expect(actual == expected)
        #expect(samples(actual).contains { abs(Int($0)) > 6_000 })
        #expect(try stream.finish().isEmpty)
    }

    @Test func finalSpeechSurvivesDrainAndStereoDownmix() throws {
        let buffer = audio(rate: 48_000, channels: 2, frames: 48_000)
        for channel in 0..<2 {
            for frame in 0..<47_520 { buffer.floatChannelData![channel][frame] = 0 }
        }
        let stream = try PCM24kStream(format: buffer.format)
        var result = try stream.append(buffer)
        result.append(try stream.finish())
        #expect(abs(result.count / 2 - 24_000) <= 2)
        #expect(samples(result).suffix(240).contains { abs(Int($0)) > 3_000 })
    }

    @Test func rejectsChangedFormatsAndAppendAfterFinish() throws {
        let buffer = audio(rate: 48_000, frames: 1024)
        let stream = try PCM24kStream(format: buffer.format)
        #expect(throws: (any Error).self) { try stream.append(audio(rate: 44_100, frames: 1024)) }
        _ = try stream.append(buffer)
        _ = try stream.finish()
        #expect(throws: (any Error).self) { try stream.append(buffer) }
    }

    @Test func emptyBuffersDoNotEndTheStream() throws {
        let empty = audio(rate: 48_000, frames: 0)
        let stream = try PCM24kStream(format: empty.format)
        #expect(try stream.append(empty).isEmpty)
        var result = try stream.append(audio(rate: 48_000, frames: 48_000))
        result.append(try stream.finish())
        #expect(abs(result.count / 2 - 24_000) <= 2)
    }
}
