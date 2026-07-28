import Testing
@testable import WhispCore

@Suite struct EnvelopeBuilderTests {
    @Test func keepsTheMaxWithinEachBin() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // Three levels inside bin 0, two inside bin 1.
        b.add(level: 0.1, atSeconds: 0.00)
        b.add(level: 0.9, atSeconds: 0.02)
        b.add(level: 0.3, atSeconds: 0.04)
        b.add(level: 0.2, atSeconds: 0.05)
        b.add(level: 0.4, atSeconds: 0.09)
        #expect(b.finish() == [0.9, 0.4])
    }

    @Test func fillsSkippedBinsWithZero() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        b.add(level: 0.5, atSeconds: 0.0)
        b.add(level: 0.7, atSeconds: 0.2)   // bin 4; bins 1-3 never fed
        #expect(b.finish() == [0.5, 0, 0, 0, 0.7])
    }

    @Test func returnsEmptyWhenNothingWasAdded() {
        #expect(EnvelopeBuilder(binSeconds: 0.05).finish().isEmpty)
    }

    @Test func ignoresNegativeTimestamps() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        b.add(level: 0.9, atSeconds: -1.0)
        b.add(level: 0.4, atSeconds: 0.0)
        #expect(b.finish() == [0.4])
    }

    @Test func defaultBinIsTwentyHertz() {
        #expect(EnvelopeBuilder.defaultBinSeconds == 0.05)
    }
}
