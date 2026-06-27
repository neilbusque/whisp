import Foundation
import AVFoundation

enum WavReader {
    /// Reads any audio file and returns 16 kHz mono Float32 samples.
    static func readMono16k(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1,
                                      interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat,
                                               to: outFormat) else {
            throw NSError(domain: "Whisp.WavReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Cannot create AVAudioConverter from \(file.processingFormat) → 16kHz mono"])
        }

        guard file.length > 0 else {
            throw NSError(domain: "Whisp.WavReader", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Audio file is empty: \(path)"])
        }
        // length is already > 0 here; max(1, …) keeps the allocation defensive
        // (AVAudioPCMBuffer rejects a zero frameCapacity).
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: max(1, AVAudioFrameCount(file.length))) else {
            throw NSError(domain: "Whisp.WavReader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate input buffer"])
        }
        try file.read(into: inBuf)

        let ratio = 16_000.0 / file.processingFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: outCap) else {
            throw NSError(domain: "Whisp.WavReader", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate output buffer"])
        }

        var fed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let convErr { throw convErr }

        guard let ptr = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
    }
}
