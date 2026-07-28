import Testing
import Foundation
@testable import WhispCore

@Suite struct WavCodecTests {
    @Test func roundTripsSamplesWithinQuantizationError() throws {
        // A 100 Hz sine at 16 kHz, 0.25 s.
        let n = 4_000
        let input = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 100 / 16_000)) * 0.8 }
        let data = WavCodec.encode(samples: input)
        let (output, rate) = try WavCodec.decode(data)

        #expect(rate == 16_000)
        #expect(output.count == input.count)
        // 16-bit quantization: max error is 1/32767 ≈ 3.05e-5. Allow 1e-4.
        for (a, b) in zip(input, output) {
            #expect(abs(a - b) < 1e-4)
        }
    }

    @Test func writesAWellFormedHeader() {
        let data = WavCodec.encode(samples: [0, 0.5, -0.5], sampleRate: 16_000)
        #expect(data.count == 44 + 6)  // 44-byte header + 3 samples × 2 bytes
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[8..<12]) == Array("WAVE".utf8))
        #expect(Array(data[36..<40]) == Array("data".utf8))
    }

    @Test func clampsOutOfRangeSamples() throws {
        let (output, _) = try WavCodec.decode(WavCodec.encode(samples: [2.0, -2.0]))
        #expect(output[0] > 0.99)
        #expect(output[1] < -0.99)
    }

    @Test func encodesEmptyInput() throws {
        let (output, _) = try WavCodec.decode(WavCodec.encode(samples: []))
        #expect(output.isEmpty)
    }

    @Test func rejectsGarbage() {
        #expect(throws: WavCodec.WavError.self) {
            _ = try WavCodec.decode(Data([0x00, 0x01, 0x02]))
        }
        #expect(throws: WavCodec.WavError.self) {
            _ = try WavCodec.decode(Data(repeating: 0x41, count: 100))
        }
    }
}
