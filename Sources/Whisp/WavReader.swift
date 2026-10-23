import Foundation
import AVFoundation
import WhispAudio

enum WavReader {
    static func readMono16k(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Whisp.WavReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio file is empty or too large."])
        }
        try file.read(into: input)
        return try PCMResampler.mono16k([input], from: file.processingFormat)
    }
}
