import Testing
@testable import WhispCore

@Suite struct AudioChunkerTests {
    let rate = 16_000

    /// `seconds` of samples, all 0.5.
    func samples(_ seconds: Double) -> [Float] {
        Array(repeating: 0.5, count: Int(Double(rate) * seconds))
    }

    /// A loud envelope with a quiet dip at `dipAtSec` lasting `dipLenSec`.
    func envelope(_ seconds: Double, dipAtSec: Double? = nil, dipLenSec: Double = 0.5) -> [Float] {
        var e = Array(repeating: Float(0.5), count: Int(seconds / 0.05))
        if let d = dipAtSec {
            let start = Int(d / 0.05), len = Int(dipLenSec / 0.05)
            for i in start..<min(start + len, e.count) { e[i] = 0.001 }
        }
        return e
    }

    @Test func returnsOneChunkWhenShorterThanTheMax() {
        let chunks = AudioChunker.chunk(samples: samples(10), sampleRate: rate,
                                        envelope: envelope(10), binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.count == 1)
        #expect(chunks[0].startMS == 0)
        #expect(chunks[0].samples.count == rate * 10)
    }

    @Test func returnsEmptyForEmptyInput() {
        #expect(AudioChunker.chunk(samples: [], sampleRate: rate, envelope: [],
                                   binSeconds: 0.05, maxChunkSec: 30,
                                   searchWindowSec: 5).isEmpty)
    }

    @Test func cutsAtTheQuietestPointInsideTheSearchWindow() {
        // 45s of audio, quiet dip at 27s. With a 30s max and a 5s search window
        // (25s-30s), the cut should land in the dip, not at exactly 30s.
        let chunks = AudioChunker.chunk(samples: samples(45), sampleRate: rate,
                                        envelope: envelope(45, dipAtSec: 27),
                                        binSeconds: 0.05, maxChunkSec: 30,
                                        searchWindowSec: 5)
        #expect(chunks.count == 2)
        let firstLenSec = Double(chunks[0].samples.count) / Double(rate)
        #expect(firstLenSec > 26.9 && firstLenSec < 27.6)
        #expect(chunks[1].startMS == Int(firstLenSec * 1_000))
    }

    @Test func uniformEnvelopeCutsAtTheSearchWindowStart() {
        // With a uniformly loud envelope, the tie-break picks the search window's
        // first bin (at 25s), not the hard boundary at 30s.
        let chunks = AudioChunker.chunk(samples: samples(45), sampleRate: rate,
                                        envelope: envelope(45), binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.count == 2)
        let firstLenSec = Double(chunks[0].samples.count) / Double(rate)
        // Envelope's minimum is at the search window's first bin (25s ±0.1s for granularity).
        #expect(firstLenSec >= 24.9 && firstLenSec <= 25.1)
    }

    @Test func chunksCoverEveryInputSampleExactlyOnce() {
        let input = samples(70)
        let chunks = AudioChunker.chunk(samples: input, sampleRate: rate,
                                        envelope: envelope(70, dipAtSec: 28),
                                        binSeconds: 0.05, maxChunkSec: 30,
                                        searchWindowSec: 5)
        #expect(chunks.count >= 3)
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == input.count)
        // startMS values are strictly increasing and contiguous.
        var cursor = 0
        for c in chunks {
            #expect(c.startMS == cursor * 1_000 / rate)
            cursor += c.samples.count
        }
    }

    @Test func toleratesAnEnvelopeShorterThanTheAudio() {
        // A truncated envelope triggers the nil-fallback path: `quietestSample`
        // returns nil because the search range is beyond envelope coverage, so
        // the cut lands on the hard boundary (30s). This test proves the fallback
        // was actually taken.
        let input = samples(45)
        let chunks = AudioChunker.chunk(samples: input, sampleRate: rate,
                                        envelope: envelope(5), binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.count == 2)
        #expect(chunks[0].samples.count == 30 * rate)
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == input.count)
    }

    @Test func emptyEnvelopeFallsBackToHardBoundary() {
        // An empty envelope makes `quietestSample` return nil via its
        // `!envelope.isEmpty` guard, isolating the fallback logic.
        let input = samples(45)
        let chunks = AudioChunker.chunk(samples: input, sampleRate: rate,
                                        envelope: [], binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.count == 2)
        #expect(chunks[0].samples.count == 30 * rate)
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == input.count)
    }
}
