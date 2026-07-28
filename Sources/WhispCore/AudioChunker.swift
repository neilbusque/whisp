import Foundation

public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]
    /// Offset of this chunk's first sample within the whole session.
    public let startMS: Int

    public init(samples: [Float], startMS: Int) {
        self.samples = samples
        self.startMS = startMS
    }
}

/// Splits long recordings so the shared whisper_context lock is released
/// between chunks, letting dictation interleave instead of waiting out a
/// multi-minute practice transcription.
///
/// Cuts land at the quietest point in a search window BEFORE each hard
/// boundary, so a chunk edge falls in a breath rather than mid-word.
public enum AudioChunker {
    public static func chunk(samples: [Float], sampleRate: Int = 16_000,
                             envelope: [Float], binSeconds: Double,
                             maxChunkSec: Double = 30,
                             searchWindowSec: Double = 5) -> [AudioChunk] {
        guard !samples.isEmpty, sampleRate > 0, maxChunkSec > 0 else { return [] }

        let maxChunkSamples = Int(maxChunkSec * Double(sampleRate))
        let searchSamples = min(Int(searchWindowSec * Double(sampleRate)), maxChunkSamples - 1)

        var out: [AudioChunk] = []
        var cursor = 0

        while cursor < samples.count {
            let remaining = samples.count - cursor
            if remaining <= maxChunkSamples {
                out.append(AudioChunk(samples: Array(samples[cursor...]),
                                      startMS: cursor * 1_000 / sampleRate))
                break
            }

            let hardEnd = cursor + maxChunkSamples
            let searchStart = max(cursor + 1, hardEnd - searchSamples)
            let cut = quietestSample(in: searchStart..<hardEnd, envelope: envelope,
                                     binSeconds: binSeconds, sampleRate: sampleRate)
                      ?? hardEnd

            out.append(AudioChunk(samples: Array(samples[cursor..<cut]),
                                  startMS: cursor * 1_000 / sampleRate))
            cursor = cut
        }
        return out
    }

    /// Sample index of the lowest-energy envelope bin overlapping `range`.
    /// Returns nil when the envelope doesn't cover the range at all, so the
    /// caller falls back to the hard boundary.
    private static func quietestSample(in range: Range<Int>, envelope: [Float],
                                       binSeconds: Double, sampleRate: Int) -> Int? {
        guard !envelope.isEmpty, binSeconds > 0 else { return nil }
        let samplesPerBin = binSeconds * Double(sampleRate)
        let firstBin = Int(Double(range.lowerBound) / samplesPerBin)
        let lastBin = min(Int(Double(range.upperBound) / samplesPerBin), envelope.count - 1)
        guard firstBin <= lastBin, firstBin < envelope.count else { return nil }

        var bestBin = firstBin
        var bestLevel = envelope[firstBin]
        for b in firstBin...lastBin where envelope[b] < bestLevel {
            bestLevel = envelope[b]
            bestBin = b
        }
        let sample = Int(Double(bestBin) * samplesPerBin)
        // Clamp back into the range; bin granularity can push it just outside.
        return min(max(sample, range.lowerBound), range.upperBound)
    }
}
