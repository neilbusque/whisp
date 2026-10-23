import AVFoundation
import Foundation

/// One converter per recording, used serially. Input starvation is temporary;
/// only finish() signals EOS, preserving the resampler's state across taps.
public final class PCM24kStream {
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var finished = false

    public init(format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw Self.failure("The microphone format cannot be streamed.")
        }
        inputFormat = format
        self.converter = converter
        self.output = output
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard !finished else { throw Self.failure("The audio stream has already finished.") }
        guard buffer.format == inputFormat else {
            throw Self.failure("The microphone format changed during recording.")
        }
        guard buffer.frameLength > 0 else { return Data() }
        return try convert(buffer, endOfStream: false)
    }

    public func finish() throws -> Data {
        guard !finished else { return Data() }
        finished = true
        return try convert(nil, endOfStream: true)
    }

    private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> Data {
        var supplied = false
        var result = Data()
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw Self.failure("Microphone streaming conversion failed.") }
            if let samples = output.floatChannelData?[0] {
                for index in 0..<Int(output.frameLength) {
                    let sample = samples[index].isFinite ? samples[index] : 0
                    let scaled = Int16(max(-32_768, min(32_767, (sample * 32_768).rounded())))
                    var littleEndian = scaled.littleEndian
                    withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
                }
            }
            switch status {
            case .inputRanDry, .endOfStream:
                return result
            case .haveData:
                guard output.frameLength > 0 else {
                    throw Self.failure("Microphone streaming conversion made no progress.")
                }
            case .error:
                throw Self.failure("Microphone streaming conversion failed.")
            @unknown default:
                throw Self.failure("Unknown microphone streaming conversion status.")
            }
        }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Whisp.StreamingAudio", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
