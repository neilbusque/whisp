import AVFoundation
import Foundation

public enum PCMResampler {
    /// Feed every captured buffer through one converter and drain to EOS.
    /// Conversion failures fail the clip instead of silently dropping speech.
    public static func mono16k(_ buffers: [AVAudioPCMBuffer], from format: AVAudioFormat) throws -> [Float] {
        guard !buffers.isEmpty else { return [] }
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw failure("The microphone audio format is unavailable.")
        }
        guard buffers.allSatisfy({ $0.format == format }) else {
            throw failure("The microphone format changed during recording. Please try again.")
        }
        var index = 0
        var result: [Float] = []
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        result.reserveCapacity(Int(Double(frames) * 16_000 / format.sampleRate) + 1024)
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                while index < buffers.count && buffers[index].frameLength == 0 { index += 1 }
                guard index < buffers.count else { inputStatus.pointee = .endOfStream; return nil }
                let buffer = buffers[index]
                index += 1
                inputStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            guard status != .error else { throw failure("Audio conversion failed. Please try again.") }
            if let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream { return result }
            guard output.frameLength > 0 else { throw failure("The microphone did not provide audio.") }
        }
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Whisp.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
