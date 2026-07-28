import Foundation

/// Minimal 16-bit mono PCM WAV encoder/decoder.
///
/// Pure Foundation on purpose: it lives in WhispCore so the round-trip is unit
/// testable. The AVFoundation-backed `WavReader` in the Whisp target remains
/// the way to import arbitrary audio files in arbitrary formats.
public enum WavCodec {
    public enum WavError: Error, Equatable {
        case malformed(String)
    }

    private static let headerSize = 44

    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * 2

        var d = Data(capacity: headerSize + dataBytes)
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + dataBytes)     // chunk size = total file size - 8
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                 // PCM fmt chunk size
        u16(1)                  // format = PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(dataBytes)

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32_767)
            withUnsafeBytes(of: i.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        guard data.count >= headerSize else {
            throw WavError.malformed("File is shorter than a WAV header (\(data.count) bytes)")
        }
        let bytes = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func u32(_ offset: Int) -> Int {
            Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> Int { Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8) }

        guard ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" else {
            throw WavError.malformed("Missing RIFF/WAVE marker")
        }
        guard ascii(36..<40) == "data" else {
            throw WavError.malformed("Unsupported WAV layout: no data chunk at offset 36")
        }
        guard u16(20) == 1 else { throw WavError.malformed("Not uncompressed PCM") }
        guard u16(34) == 16 else { throw WavError.malformed("Only 16-bit samples are supported") }

        let sampleRate = u32(24)
        let declared = u32(40)
        let available = data.count - headerSize
        // Trust whichever is smaller, so a truncated file decodes what it has
        // instead of reading past the end.
        let dataBytes = min(declared, available)

        var samples = [Float]()
        samples.reserveCapacity(dataBytes / 2)
        var i = headerSize
        while i + 1 < headerSize + dataBytes {
            let raw = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            samples.append(Float(raw) / 32_767)
            i += 2
        }
        return (samples, sampleRate)
    }
}
