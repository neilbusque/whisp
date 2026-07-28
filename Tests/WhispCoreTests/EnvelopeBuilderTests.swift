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

    @Test func exactMultipleTimestampsLandInCorrectBin() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // These timestamps are exact multiples of 0.05 and prone to IEEE-754 truncation.
        // Without proper rounding, they would land in the PREVIOUS bin.
        b.add(level: 0.1, atSeconds: 0.15)  // Should be bin 3, not bin 2
        b.add(level: 0.2, atSeconds: 0.30)  // Should be bin 6, not bin 5
        b.add(level: 0.3, atSeconds: 0.60)  // Should be bin 12, not bin 11
        b.add(level: 0.4, atSeconds: 1.20)  // Should be bin 24, not bin 23
        let result = b.finish()
        #expect(result.count == 25)
        #expect(result[3] == 0.1)
        #expect(result[6] == 0.2)
        #expect(result[12] == 0.3)
        #expect(result[24] == 0.4)
    }

    @Test func nonBoundaryTimestampsStillFloor() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // A timestamp that is NOT an exact multiple should still floor, not round up.
        // 0.09 / 0.05 = 1.8, which should floor to bin 1, not round to bin 2.
        b.add(level: 0.5, atSeconds: 0.09)
        let result = b.finish()
        #expect(result.count == 2)
        #expect(result[0] == 0)
        #expect(result[1] == 0.5)
    }

    // MARK: - Buffer-span filling (fixes the "half the envelope is fake silence" bug)

    @Test func bufferSpanningExactlyTwoBinsFillsBothNotAThird() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // [0.0, 0.1) against 0.05-second bins covers bin 0 and bin 1 only.
        // The end lands exactly on the boundary of bin 2, which must NOT be marked.
        b.add(level: 0.5, atSeconds: 0.0, durationSeconds: 0.1)
        #expect(b.finish() == [0.5, 0.5])
    }

    @Test func bufferSpanningTwoAndAHalfBinsFillsThree() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // [0.0, 0.125) covers bins 0, 1, 2 (bin 2 spans 0.10..<0.15, and 0.125 is inside it).
        b.add(level: 0.5, atSeconds: 0.0, durationSeconds: 0.125)
        #expect(b.finish() == [0.5, 0.5, 0.5])
    }

    @Test func bufferStartingMidBinFillsEveryBinItTouches() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // [0.03, 0.13) touches bin 0 (0..<0.05), bin 1 (0.05..<0.10), bin 2 (0.10..<0.15).
        b.add(level: 0.5, atSeconds: 0.03, durationSeconds: 0.1)
        #expect(b.finish() == [0.5, 0.5, 0.5])
    }

    @Test func regressionTwentyConsecutiveHundredMsBuffersFillEveryBin() {
        // This is the actual bug: AVAudioEngine delivers ~100ms buffers against
        // a 50ms bin. The OLD single-bin `add` marked only the bin containing
        // each buffer's start timestamp, leaving every other bin at 0 — on a
        // real 20.7s recording, exactly 205 of 409 bins were non-zero in a
        // perfect alternating pattern. This test reproduces that feed pattern
        // and asserts every bin gets filled.
        let b = EnvelopeBuilder(binSeconds: 0.05)
        for i in 0..<20 {
            b.add(level: 0.5, atSeconds: Double(i) * 0.1, durationSeconds: 0.1)
        }
        let envelope = b.finish()
        #expect(envelope.count == 40)
        #expect(envelope.allSatisfy { $0 == 0.5 })
        #expect(envelope.filter { $0 == 0 }.count == 0)
    }

    @Test func omittingDurationPreservesOldSingleBinBehavior() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        b.add(level: 0.5, atSeconds: 0.0)
        b.add(level: 0.7, atSeconds: 0.2)
        #expect(b.finish() == [0.5, 0, 0, 0, 0.7])
    }

    @Test func maxSemanticsAcrossOverlappingBuffers() {
        let b = EnvelopeBuilder(binSeconds: 0.05)
        // A quiet buffer spanning bins 0-3, then a loud short buffer inside
        // that span (bin 2 only). Max-per-bin must leave the loud value.
        b.add(level: 0.1, atSeconds: 0.0, durationSeconds: 0.2)
        b.add(level: 0.9, atSeconds: 0.10, durationSeconds: 0.05)
        #expect(b.finish() == [0.1, 0.1, 0.9, 0.1])
    }
}
