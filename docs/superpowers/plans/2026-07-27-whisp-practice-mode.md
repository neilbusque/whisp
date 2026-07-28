# Whisp Practice Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second capture path to Whisp — press `⌃⌥⌘R`, pick a practice prompt, speak, press again — that stores the audio locally forever, transcribes it on-device, and scores speaking metrics (WPM, filler rate, pauses) trended per prompt.

**Architecture:** Practice Mode is a pipeline parallel to v1 dictation, sharing only the mic and the whisper context. All analysis logic lives in `WhispCore` as pure functions over `[Float]` envelopes and `String` transcripts, so it is entirely unit-testable; only mic capture, the Carbon hotkey, playback and SwiftUI windows live in the `Whisp` executable target. The DeepSeek cleanup pass and `PasteInserter` are never invoked — cleanup strips fillers, which are exactly what is being measured.

**Tech Stack:** Swift 6, SwiftPM, Command Line Tools only (no Xcode.app, no fetched dependencies), Swift Testing, AppKit/SwiftUI/AVFoundation, Carbon `RegisterEventHotKey`, vendored whisper.cpp (CPU/Accelerate backend).

**Spec:** `docs/superpowers/specs/2026-07-27-whisp-practice-mode-design.md`

## Global Constraints

- **Swift 6 language mode, macOS 13+ deployment target.** Concurrency warnings are errors; anything crossing an isolation boundary must be `Sendable` or explicitly `@unchecked Sendable` with a comment explaining the locking, matching `AudioRecorder`'s existing style.
- **No fetched dependencies, ever.** No SwiftPM remote packages, no CocoaPods, no Homebrew libs. Foundation, AppKit, SwiftUI, AVFoundation, Carbon and the vendored `CWhisper` target only.
- **`WhispCore` must not import AppKit, SwiftUI, AVFoundation, or Carbon.** It is pure logic plus Foundation. This is what keeps it testable — the test target depends on `WhispCore` alone.
- **`WhisperTranscriber.transcribe(_:)` must not change.** Dictation is the daily driver at ~100×/day. Practice Mode adds a new method beside it; it does not refactor, re-parameterize, or "improve" the existing one.
- **Audio never leaves the device.** No network call may ever take samples, a file path to a recording, or an envelope. The only permitted egress is transcript text through the existing DeepSeek cleaner, and only from the opt-in Coach Feedback button in Task 18.
- **Practice Mode never writes to the pasteboard and never calls `PasteInserter`.**
- **Backwards compatibility:** an existing `~/.whisp/config.json` lacking the new keys must keep working. Every new config key decodes to its default when absent.
- **Filler and vocabulary list files** use the established `vocabulary.txt` convention: one term per line, `#` starts a comment, blank lines ignored.
- **Test framework is Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest. Follow `Tests/WhispCoreTests/ConfigTests.swift` for style.
- **Commit after every task** with a `feat:`/`test:`/`fix:` prefix.

**Commands used throughout:**
- Run all Core tests: `cd ~/whisp && swift test`
- Run one suite: `cd ~/whisp && swift test --filter <SuiteName>`
- Build the app: `cd ~/whisp && swift build -c release --product Whisp`
- Bundle the app: `cd ~/whisp && ./build.sh`

---

## File Structure

**Created in `Sources/WhispCore/` (pure, unit-tested):**

| File | Responsibility |
|---|---|
| `HotkeySpec.swift` | Parse `"ctrl+opt+cmd+r"` into modifier booleans + a key character; render a display string. |
| `WavCodec.swift` | Encode/decode 16-bit PCM WAV as `Data`. Pure Foundation, no AVFoundation, so it round-trips in tests. |
| `EnvelopeBuilder.swift` | Bin a stream of RMS levels into a fixed-rate envelope, taking the max per bin. |
| `SpeechMetrics.swift` | `SpeechMetrics`, `Pause`, `FillerList`, and `SpeechAnalyzer` — all the coaching math. |
| `PracticeSession.swift` | `PracticeSession`, `TranscriptSegment`, `SessionStatus`. |
| `PracticePrompt.swift` | `PracticePrompt` + `PromptStore`. |
| `PracticeStore.swift` | Session index: append/update/delete/query/trend. |
| `AudioChunker.swift` | Split samples into ≤30s chunks cut at quiet points, carrying time offsets. |

**Created in `Sources/Whisp/` (native, live-verified):**

| File | Responsibility |
|---|---|
| `PracticeHotkey.swift` | Carbon `RegisterEventHotKey` global hotkey. |
| `PracticeController.swift` | Orchestrates capture → WAV → chunked transcription → metrics → persistence. |
| `PromptPickerView.swift` | The HUD-attached prompt picker. |
| `PracticeWindow.swift` | Review UI: prompts, sessions, playback, metrics, trend. |

**Created in `Tests/WhispCoreTests/`:** `HotkeySpecTests.swift`, `WavCodecTests.swift`, `EnvelopeBuilderTests.swift`, `SpeechMetricsTests.swift`, `PracticeStoreTests.swift`, `PromptStoreTests.swift`, `AudioChunkerTests.swift`.

**Modified:** `Config.swift`, `Paths.swift`, `AudioRecorder.swift`, `WhisperTranscriber.swift`, `HUDWindow.swift`, `AppDelegate.swift`.

---

### Task 1: Config gains practice settings, without breaking existing configs

`WhispConfig` currently has four non-optional stored properties and relies on synthesized `Codable`. Adding properties would make synthesized decoding **throw** on any existing `~/.whisp/config.json`, silently bricking Whisp on Neil's Mac at launch. This task adds the fields *and* a hand-written decoder that defaults every key.

**Files:**
- Modify: `Sources/WhispCore/Config.swift`
- Test: `Tests/WhispCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `WhispConfig.practiceHotkey: String` (default `"ctrl+opt+cmd+r"`), `WhispConfig.pauseThresholdSec: Double` (default `1.0`), `WhispConfig.silenceRMSThreshold: Double` (default `0.06`). The memberwise `init` gains these three as **defaulted** parameters so existing 4-argument call sites still compile.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/WhispCoreTests/ConfigTests.swift`, inside the existing `@Suite struct ConfigTests`:

```swift
    @Test func decodesLegacyConfigMissingPracticeKeys() throws {
        // A config.json written by v1, before Practice Mode existed.
        let legacy = """
        {"deepseekKey":"sk-x","hotkey":"fn","snippetsPath":"/tmp/s.json","whisperModel":"ggml-base.en"}
        """.data(using: .utf8)!
        let c = try WhispConfig.load(from: legacy)
        #expect(c.deepseekKey == "sk-x")
        #expect(c.practiceHotkey == "ctrl+opt+cmd+r")
        #expect(c.pauseThresholdSec == 1.0)
        #expect(c.silenceRMSThreshold == 0.06)
    }

    @Test func practiceDefaultsAreSet() {
        let c = WhispConfig.defaults
        #expect(c.practiceHotkey == "ctrl+opt+cmd+r")
        #expect(c.pauseThresholdSec == 1.0)
        #expect(c.silenceRMSThreshold == 0.06)
    }

    @Test func roundTripsPracticeKeys() throws {
        let original = WhispConfig(deepseekKey: "sk-x", hotkey: "fn",
                                   whisperModel: "ggml-base.en", snippetsPath: "/tmp/s.json",
                                   practiceHotkey: "ctrl+cmd+p", pauseThresholdSec: 2.5,
                                   silenceRMSThreshold: 0.1)
        let decoded = try WhispConfig.load(from: original.encoded())
        #expect(decoded == original)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/whisp && swift test --filter ConfigTests`
Expected: FAIL — compile error, `WhispConfig` has no member `practiceHotkey`.

- [ ] **Step 3: Implement**

Replace the body of `Sources/WhispCore/Config.swift` above `WhispConfigError` with:

```swift
public struct WhispConfig: Codable, Equatable {
    public var deepseekKey: String
    public var hotkey: String
    public var whisperModel: String
    public var snippetsPath: String

    // Practice Mode. All three decode to their defaults when absent, so a
    // config.json written before Practice Mode existed still loads.
    public var practiceHotkey: String
    /// Minimum silence, in seconds, before a gap counts as a pause.
    public var pauseThresholdSec: Double
    /// Compared against AudioRecorder's ALREADY-SCALED level,
    /// `min(1, sqrt(meanSquare) * 4)` — not against raw RMS.
    public var silenceRMSThreshold: Double

    public init(deepseekKey: String, hotkey: String, whisperModel: String,
                snippetsPath: String,
                practiceHotkey: String = "ctrl+opt+cmd+r",
                pauseThresholdSec: Double = 1.0,
                silenceRMSThreshold: Double = 0.06) {
        self.deepseekKey = deepseekKey
        self.hotkey = hotkey
        self.whisperModel = whisperModel
        self.snippetsPath = snippetsPath
        self.practiceHotkey = practiceHotkey
        self.pauseThresholdSec = pauseThresholdSec
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case deepseekKey, hotkey, whisperModel, snippetsPath
        case practiceHotkey, pauseThresholdSec, silenceRMSThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WhispConfig.defaults
        deepseekKey = try c.decodeIfPresent(String.self, forKey: .deepseekKey) ?? ""
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        snippetsPath = try c.decodeIfPresent(String.self, forKey: .snippetsPath) ?? d.snippetsPath
        practiceHotkey = try c.decodeIfPresent(String.self, forKey: .practiceHotkey) ?? d.practiceHotkey
        pauseThresholdSec = try c.decodeIfPresent(Double.self, forKey: .pauseThresholdSec) ?? d.pauseThresholdSec
        silenceRMSThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceRMSThreshold) ?? d.silenceRMSThreshold
    }

    public static var defaults: WhispConfig {
        WhispConfig(deepseekKey: "", hotkey: "fn",
                    whisperModel: "ggml-base.en",
                    snippetsPath: NSString(string: "~/.whisp/snippets.json").expandingTildeInPath,
                    practiceHotkey: "ctrl+opt+cmd+r",
                    pauseThresholdSec: 1.0,
                    silenceRMSThreshold: 0.06)
    }

    public static func load(from data: Data) throws -> WhispConfig {
        try JSONDecoder().decode(WhispConfig.self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func validated() throws -> WhispConfig {
        if deepseekKey.isEmpty { throw WhispConfigError.missingKey("deepseekKey") }
        return self
    }
}
```

Note `defaults` is referenced inside `init(from:)`. That is safe — `defaults` calls the memberwise `init`, not the decoder — but it must stay that way; never make `defaults` decode anything.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/whisp && swift test --filter ConfigTests`
Expected: PASS, all six tests (three pre-existing, three new).

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/Config.swift Tests/WhispCoreTests/ConfigTests.swift
git commit -m "feat(config): practice settings with backwards-compatible decoding"
```

---

### Task 2: HotkeySpec — parse a hotkey string

**Files:**
- Create: `Sources/WhispCore/HotkeySpec.swift`
- Test: `Tests/WhispCoreTests/HotkeySpecTests.swift`

**Interfaces:**
- Produces: `HotkeySpec { control, option, command, shift: Bool, key: Character }`, `HotkeySpec.parse(_ s: String) -> HotkeySpec?`, `HotkeySpec.display: String`. Task 13 maps this to Carbon modifier masks and a virtual keycode.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/HotkeySpecTests.swift`:

```swift
import Testing
@testable import WhispCore

@Suite struct HotkeySpecTests {
    @Test func parsesTheDefault() throws {
        let h = try #require(HotkeySpec.parse("ctrl+opt+cmd+r"))
        #expect(h.control && h.option && h.command)
        #expect(!h.shift)
        #expect(h.key == "r")
    }

    @Test func acceptsAliasesAndWhitespaceAndCase() throws {
        let a = try #require(HotkeySpec.parse("Control + Option + Command + R"))
        let b = try #require(HotkeySpec.parse("ctrl+alt+cmd+r"))
        #expect(a == b)
    }

    @Test func parsesDigitsAndSingleModifier() throws {
        let h = try #require(HotkeySpec.parse("cmd+7"))
        #expect(h.command && !h.control && !h.option && !h.shift)
        #expect(h.key == "7")
    }

    @Test func rejectsMalformedInput() {
        #expect(HotkeySpec.parse("") == nil)
        #expect(HotkeySpec.parse("ctrl+opt+cmd") == nil)        // no key
        #expect(HotkeySpec.parse("r") == nil)                    // no modifier
        #expect(HotkeySpec.parse("ctrl+opt+cmd+rr") == nil)      // multi-char key
        #expect(HotkeySpec.parse("ctrl+banana+r") == nil)        // unknown token
        #expect(HotkeySpec.parse("ctrl+r+p") == nil)             // two keys
        #expect(HotkeySpec.parse("fn+r") == nil)                 // fn is not supported here
    }

    @Test func rendersDisplayString() throws {
        let h = try #require(HotkeySpec.parse("ctrl+opt+cmd+r"))
        #expect(h.display == "⌃⌥⌘R")
        let s = try #require(HotkeySpec.parse("shift+cmd+p"))
        #expect(s.display == "⇧⌘P")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter HotkeySpecTests`
Expected: FAIL — cannot find `HotkeySpec` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/HotkeySpec.swift`:

```swift
import Foundation

/// A parsed global-hotkey description, e.g. "ctrl+opt+cmd+r".
///
/// Deliberately does NOT support `fn`: the Fn key is delivered inconsistently
/// across Macs and is handled by HotkeyMonitor's dual-detector approach, which
/// is a different mechanism entirely. Practice Mode uses keycode-based Carbon
/// registration, so Fn is out of scope here and parsing it is an error.
public struct HotkeySpec: Equatable, Sendable {
    public let control: Bool
    public let option: Bool
    public let command: Bool
    public let shift: Bool
    /// A single lowercased letter or digit.
    public let key: Character

    public init(control: Bool, option: Bool, command: Bool, shift: Bool, key: Character) {
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
        self.key = key
    }

    /// Returns nil for anything malformed: no key, no modifier, more than one
    /// key, an unknown token, or `fn`. Callers fall back to the default.
    public static func parse(_ s: String) -> HotkeySpec? {
        let tokens = s.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var control = false, option = false, command = false, shift = false
        var key: Character?

        for t in tokens {
            switch t {
            case "ctrl", "control": control = true
            case "opt", "alt", "option": option = true
            case "cmd", "command": command = true
            case "shift": shift = true
            default:
                // Must be the single key: exactly one alphanumeric character.
                guard t.count == 1, let c = t.first, c.isLetter || c.isNumber else { return nil }
                guard key == nil else { return nil }  // two keys
                key = c
            }
        }

        guard let key else { return nil }
        guard control || option || command || shift else { return nil }
        return HotkeySpec(control: control, option: option, command: command,
                          shift: shift, key: key)
    }

    /// Mac-standard modifier order: ⌃⌥⇧⌘.
    public var display: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        out += String(key).uppercased()
        return out
    }
}
```

Note the display order is ⌃⌥⇧⌘ (Mac convention), which is why the `shift+cmd+p` test expects `⇧⌘P`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter HotkeySpecTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/HotkeySpec.swift Tests/WhispCoreTests/HotkeySpecTests.swift
git commit -m "feat(core): HotkeySpec parser for configurable global hotkeys"
```

---

### Task 3: WavCodec — write and read 16-bit PCM WAV

The existing `WavReader` uses AVFoundation and lives in the `Whisp` target, so it cannot be unit-tested. This is a pure-Foundation codec in `WhispCore` that round-trips in tests. `WavReader` stays as-is for importing arbitrary audio files.

**Files:**
- Create: `Sources/WhispCore/WavCodec.swift`
- Test: `Tests/WhispCoreTests/WavCodecTests.swift`

**Interfaces:**
- Produces: `WavCodec.encode(samples: [Float], sampleRate: Int = 16_000) -> Data`, `WavCodec.decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int)`, `WavCodec.WavError.malformed(String)`. Task 12 writes recordings with `encode`; Task 16 plays them from disk via AVFoundation.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/WavCodecTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter WavCodecTests`
Expected: FAIL — cannot find `WavCodec` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/WavCodec.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter WavCodecTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/WavCodec.swift Tests/WhispCoreTests/WavCodecTests.swift
git commit -m "feat(core): pure-Foundation 16-bit PCM WAV codec"
```

---

### Task 4: EnvelopeBuilder — bin RMS levels to 20 Hz

**Files:**
- Create: `Sources/WhispCore/EnvelopeBuilder.swift`
- Test: `Tests/WhispCoreTests/EnvelopeBuilderTests.swift`

**Interfaces:**
- Produces: `EnvelopeBuilder(binSeconds: Double = 0.05)`, `.add(level: Float, atSeconds: Double)`, `.finish() -> [Float]`, and `EnvelopeBuilder.defaultBinSeconds = 0.05`. Task 12 feeds it from the audio tap; Tasks 6 and 10 consume the resulting array.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/EnvelopeBuilderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter EnvelopeBuilderTests`
Expected: FAIL — cannot find `EnvelopeBuilder` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/EnvelopeBuilder.swift`:

```swift
import Foundation

/// Accumulates a stream of RMS levels into a fixed-rate envelope.
///
/// Takes the MAX within each bin rather than the mean: a brief loud syllable
/// inside an otherwise quiet bin must not average away into looking like
/// silence, or pause detection would invent pauses that never happened.
///
/// Not thread-safe by itself — AudioRecorder calls `add` from the audio tap
/// while already holding its own lock.
public final class EnvelopeBuilder {
    public static let defaultBinSeconds: Double = 0.05

    private let binSeconds: Double
    private var bins: [Float] = []

    public init(binSeconds: Double = EnvelopeBuilder.defaultBinSeconds) {
        self.binSeconds = binSeconds > 0 ? binSeconds : EnvelopeBuilder.defaultBinSeconds
    }

    public func add(level: Float, atSeconds t: Double) {
        guard t >= 0 else { return }
        let idx = Int(t / binSeconds)
        if idx >= bins.count {
            bins.append(contentsOf: repeatElement(0, count: idx - bins.count + 1))
        }
        bins[idx] = max(bins[idx], level)
    }

    public func finish() -> [Float] { bins }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter EnvelopeBuilderTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/EnvelopeBuilder.swift Tests/WhispCoreTests/EnvelopeBuilderTests.swift
git commit -m "feat(core): EnvelopeBuilder bins RMS levels at 20Hz"
```

---

### Task 5: Filler counting

**Files:**
- Create: `Sources/WhispCore/SpeechMetrics.swift`
- Test: `Tests/WhispCoreTests/SpeechMetricsTests.swift`

**Interfaces:**
- Produces: `FillerList.parse(_ text: String) -> [String]`, `FillerList.seed: String`, `SpeechAnalyzer.countFillers(in:fillers:) -> [String: Int]`. Task 6 adds `Pause`, `SpeechMetrics` and `SpeechAnalyzer.analyze` to this same file. Task 17 writes `FillerList.seed` to `~/.whisp/fillers.txt`.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/SpeechMetricsTests.swift`:

```swift
import Testing
@testable import WhispCore

@Suite struct FillerCountingTests {
    let fillers = ["um", "uh", "like", "you know", "i mean"]

    @Test func countsSingleWordFillers() {
        let counts = SpeechAnalyzer.countFillers(in: "Um, so uh I think um yes", fillers: fillers)
        #expect(counts["um"] == 2)
        #expect(counts["uh"] == 1)
    }

    @Test func matchesWholeWordsOnly() {
        // "likely" and "umbrella" must NOT count.
        let counts = SpeechAnalyzer.countFillers(in: "That is likely an umbrella", fillers: fillers)
        #expect(counts["like"] == nil)
        #expect(counts["um"] == nil)
    }

    @Test func countsMultiWordPhrases() {
        let counts = SpeechAnalyzer.countFillers(in: "You know, I mean, you know it works",
                                                 fillers: fillers)
        #expect(counts["you know"] == 2)
        #expect(counts["i mean"] == 1)
    }

    @Test func isCaseInsensitiveAndIgnoresPunctuation() {
        let counts = SpeechAnalyzer.countFillers(in: "UM... uh! Um?", fillers: fillers)
        #expect(counts["um"] == 2)
        #expect(counts["uh"] == 1)
    }

    @Test func omitsZeroCounts() {
        let counts = SpeechAnalyzer.countFillers(in: "A clean sentence.", fillers: fillers)
        #expect(counts.isEmpty)
    }

    @Test func handlesEmptyInputs() {
        #expect(SpeechAnalyzer.countFillers(in: "", fillers: fillers).isEmpty)
        #expect(SpeechAnalyzer.countFillers(in: "um um", fillers: []).isEmpty)
    }
}

@Suite struct FillerListTests {
    @Test func parsesOnePerLineIgnoringCommentsAndBlanks() {
        let text = """
        # comment
        um

        you know
           uh
        """
        #expect(FillerList.parse(text) == ["um", "you know", "uh"])
    }

    @Test func seedContainsTheCommonFillers() {
        let parsed = FillerList.parse(FillerList.seed)
        #expect(parsed.contains("um"))
        #expect(parsed.contains("you know"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter FillerCountingTests`
Expected: FAIL — cannot find `SpeechAnalyzer` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/SpeechMetrics.swift`:

```swift
import Foundation

/// Parses `~/.whisp/fillers.txt`, using the same convention as vocabulary.txt:
/// one term per line, `#` comments, blank lines ignored.
public enum FillerList {
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static let seed = """
    # Whisp filler words — one term per line. Lines starting with # are ignored.
    # These are counted against your practice transcripts. Multi-word phrases work.

    um
    uh
    er
    ah
    like
    you know
    i mean
    sort of
    kind of
    basically
    actually
    literally
    right
    so yeah

    """
}

public enum SpeechAnalyzer {
    /// Lowercase, punctuation to spaces, collapse whitespace, split to words.
    /// Tokenizing both sides is what makes whole-word matching fall out for
    /// free: "likely" tokenizes to ["likely"], which never equals ["like"].
    static func tokenize(_ s: String) -> [String] {
        let mapped = s.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Counts each filler term. Terms with zero occurrences are omitted.
    /// Multi-word phrases are matched as consecutive token runs.
    public static func countFillers(in transcript: String, fillers: [String]) -> [String: Int] {
        let words = tokenize(transcript)
        guard !words.isEmpty else { return [:] }

        var out: [String: Int] = [:]
        for filler in fillers {
            let needle = tokenize(filler)
            guard !needle.isEmpty, needle.count <= words.count else { continue }
            var count = 0
            for start in 0...(words.count - needle.count) {
                if Array(words[start..<(start + needle.count)]) == needle { count += 1 }
            }
            if count > 0 { out[filler.lowercased()] = count }
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/whisp && swift test --filter FillerCountingTests && swift test --filter FillerListTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/SpeechMetrics.swift Tests/WhispCoreTests/SpeechMetricsTests.swift
git commit -m "feat(core): filler-word list parsing and whole-word counting"
```

---

### Task 6: Pauses, durations, and the SpeechMetrics rollup

**Files:**
- Modify: `Sources/WhispCore/SpeechMetrics.swift`
- Test: `Tests/WhispCoreTests/SpeechMetricsTests.swift`

**Interfaces:**
- Consumes: `SpeechAnalyzer.countFillers` and `SpeechAnalyzer.tokenize` from Task 5.
- Produces: `Pause { startSec, durationSec }`, `SpeechMetrics { wordCount, durationSec, speakingDurationSec, wpm, fillerCounts, totalFillers, fillerRate, pauses, pauseCount, longestPauseSec, silenceRatio }`, and `SpeechAnalyzer.analyze(transcript:envelope:binSeconds:fillers:silenceThreshold:minPauseSec:) -> SpeechMetrics`. Task 9 stores `SpeechMetrics` on sessions and reads `wpm`/`fillerRate`/`pauseCount` for trends.

- [ ] **Step 1: Write the failing test**

Append to `Tests/WhispCoreTests/SpeechMetricsTests.swift`:

```swift
@Suite struct PauseDetectionTests {
    // 0.05s bins. loud = 0.5, quiet = 0.01, threshold 0.06.
    func env(_ pattern: [(Float, Int)]) -> [Float] {
        pattern.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test func findsAPauseLongerThanTheThreshold() {
        // 1s loud, 1.5s quiet, 1s loud → one 1.5s pause starting at 1.0s.
        let e = env([(0.5, 20), (0.01, 30), (0.5, 20)])
        let pauses = SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                           silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].startSec - 1.0) < 0.001)
        #expect(abs(pauses[0].durationSec - 1.5) < 0.001)
    }

    @Test func ignoresGapsShorterThanTheThreshold() {
        // 0.5s quiet gap, below a 1.0s threshold.
        let e = env([(0.5, 20), (0.01, 10), (0.5, 20)])
        #expect(SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }

    @Test func ignoresLeadingAndTrailingSilence() {
        // Silence before the first and after the last speech is dead air, not a
        // pause in delivery.
        let e = env([(0.01, 40), (0.5, 20), (0.01, 40)])
        #expect(SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }

    @Test func findsMultiplePauses() {
        let e = env([(0.5, 10), (0.01, 25), (0.5, 10), (0.01, 30), (0.5, 10)])
        let pauses = SpeechAnalyzer.pauses(envelope: e, binSeconds: 0.05,
                                           silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(pauses.count == 2)
    }

    @Test func handlesAllSilentAndEmptyEnvelopes() {
        #expect(SpeechAnalyzer.pauses(envelope: env([(0.01, 100)]), binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
        #expect(SpeechAnalyzer.pauses(envelope: [], binSeconds: 0.05,
                                      silenceThreshold: 0.06, minPauseSec: 1.0).isEmpty)
    }
}

@Suite struct SpeechMetricsTests {
    func env(_ pattern: [(Float, Int)]) -> [Float] {
        pattern.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test func computesWpmOverSpeakingDurationOnly() {
        // 2s lead-in silence, 60s speech, 2s trailing silence = 64s total.
        // 120 words over 60s of speaking = 120 WPM (NOT 112.5 over 64s).
        let e = env([(0.01, 40), (0.5, 1_200), (0.01, 40)])
        let transcript = Array(repeating: "word", count: 120).joined(separator: " ")
        let m = SpeechAnalyzer.analyze(transcript: transcript, envelope: e, binSeconds: 0.05,
                                       fillers: ["um"], silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.wordCount == 120)
        #expect(abs(m.durationSec - 64.0) < 0.001)
        #expect(abs(m.speakingDurationSec - 60.0) < 0.001)
        #expect(abs(m.wpm - 120.0) < 0.5)
    }

    @Test func fillerRateIsPerHundredWords() {
        // 50 words, 5 of them "um" → 10 per 100 words.
        let words = Array(repeating: "word", count: 45) + Array(repeating: "um", count: 5)
        let e = env([(0.5, 600)])  // 30s
        let m = SpeechAnalyzer.analyze(transcript: words.joined(separator: " "), envelope: e,
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.totalFillers == 5)
        #expect(abs(m.fillerRate - 10.0) < 0.001)
    }

    @Test func reportsSilenceRatioAndLongestPause() {
        let e = env([(0.5, 20), (0.01, 40), (0.5, 20)])  // 1s + 2s + 1s
        let m = SpeechAnalyzer.analyze(transcript: "a b c", envelope: e, binSeconds: 0.05,
                                       fillers: [], silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(abs(m.silenceRatio - 0.5) < 0.001)
        #expect(abs(m.longestPauseSec - 2.0) < 0.001)
        #expect(m.pauseCount == 1)
    }

    @Test func silentRecordingYieldsZeroesNotNaN() {
        let m = SpeechAnalyzer.analyze(transcript: "", envelope: env([(0.01, 200)]),
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.wordCount == 0)
        #expect(m.wpm == 0)
        #expect(m.fillerRate == 0)
        #expect(m.speakingDurationSec == 0)
        #expect(!m.wpm.isNaN)
    }

    @Test func emptyEnvelopeYieldsZeroesNotNaN() {
        let m = SpeechAnalyzer.analyze(transcript: "hello there", envelope: [],
                                       binSeconds: 0.05, fillers: [],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        #expect(m.durationSec == 0)
        #expect(m.wpm == 0)
        #expect(!m.silenceRatio.isNaN)
    }

    @Test func roundTripsThroughJSON() throws {
        let m = SpeechAnalyzer.analyze(transcript: "um hello", envelope: env([(0.5, 20)]),
                                       binSeconds: 0.05, fillers: ["um"],
                                       silenceThreshold: 0.06, minPauseSec: 1.0)
        let decoded = try JSONDecoder().decode(SpeechMetrics.self, from: JSONEncoder().encode(m))
        #expect(decoded == m)
    }
}
```

Add `import Foundation` at the top of the test file if it is not already there.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/whisp && swift test --filter PauseDetectionTests`
Expected: FAIL — no member `pauses` on `SpeechAnalyzer`.

- [ ] **Step 3: Implement**

Append to `Sources/WhispCore/SpeechMetrics.swift`:

```swift
public struct Pause: Codable, Equatable, Sendable {
    public let startSec: Double
    public let durationSec: Double
    public init(startSec: Double, durationSec: Double) {
        self.startSec = startSec
        self.durationSec = durationSec
    }
}

public struct SpeechMetrics: Codable, Equatable, Sendable {
    public let wordCount: Int
    public let durationSec: Double
    /// Total duration minus LEADING and TRAILING silence only. Internal pauses
    /// stay counted — they are part of delivery pace, and excluding them would
    /// hide the exact problem being measured.
    public let speakingDurationSec: Double
    public let wpm: Double
    public let fillerCounts: [String: Int]
    public let totalFillers: Int
    /// Fillers per 100 words. The headline number.
    public let fillerRate: Double
    public let pauses: [Pause]
    public let pauseCount: Int
    public let longestPauseSec: Double
    public let silenceRatio: Double
}

extension SpeechAnalyzer {
    /// Index of the first and last bin at or above the speech threshold.
    static func speechBounds(envelope: [Float], silenceThreshold: Float) -> (first: Int, last: Int)? {
        guard let first = envelope.firstIndex(where: { $0 >= silenceThreshold }),
              let last = envelope.lastIndex(where: { $0 >= silenceThreshold }) else { return nil }
        return (first, last)
    }

    /// Silent runs of at least `minPauseSec`, BETWEEN the first and last speech.
    /// Leading and trailing silence is dead air, not a pause in delivery.
    public static func pauses(envelope: [Float], binSeconds: Double,
                              silenceThreshold: Float, minPauseSec: Double) -> [Pause] {
        guard let bounds = speechBounds(envelope: envelope, silenceThreshold: silenceThreshold),
              bounds.last > bounds.first else { return [] }

        var out: [Pause] = []
        var runStart: Int?
        for i in bounds.first...bounds.last {
            if envelope[i] < silenceThreshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                let duration = Double(i - s) * binSeconds
                if duration >= minPauseSec {
                    out.append(Pause(startSec: Double(s) * binSeconds, durationSec: duration))
                }
                runStart = nil
            }
        }
        // No trailing flush needed: bounds.last is speech by definition, so any
        // open run was closed by the loop.
        return out
    }

    public static func analyze(transcript: String, envelope: [Float], binSeconds: Double,
                               fillers: [String], silenceThreshold: Float,
                               minPauseSec: Double) -> SpeechMetrics {
        let words = tokenize(transcript)
        let durationSec = Double(envelope.count) * binSeconds

        let speakingDurationSec: Double
        if let b = speechBounds(envelope: envelope, silenceThreshold: silenceThreshold) {
            speakingDurationSec = Double(b.last - b.first + 1) * binSeconds
        } else {
            speakingDurationSec = 0
        }

        let wpm = speakingDurationSec > 0
            ? Double(words.count) / (speakingDurationSec / 60.0)
            : 0

        let counts = countFillers(in: transcript, fillers: fillers)
        let totalFillers = counts.values.reduce(0, +)
        let fillerRate = words.isEmpty ? 0 : Double(totalFillers) / Double(words.count) * 100.0

        let ps = pauses(envelope: envelope, binSeconds: binSeconds,
                        silenceThreshold: silenceThreshold, minPauseSec: minPauseSec)

        let silentBins = envelope.filter { $0 < silenceThreshold }.count
        let silenceRatio = envelope.isEmpty ? 0 : Double(silentBins) / Double(envelope.count)

        return SpeechMetrics(
            wordCount: words.count,
            durationSec: durationSec,
            speakingDurationSec: speakingDurationSec,
            wpm: wpm,
            fillerCounts: counts,
            totalFillers: totalFillers,
            fillerRate: fillerRate,
            pauses: ps,
            pauseCount: ps.count,
            longestPauseSec: ps.map(\.durationSec).max() ?? 0,
            silenceRatio: silenceRatio
        )
    }
}
```

Every division is guarded against a zero denominator — a silent or empty recording must produce zeroes, never `NaN`, because `NaN` would poison the JSON encoding and the trend chart.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/whisp && swift test`
Expected: PASS — all suites, including the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/SpeechMetrics.swift Tests/WhispCoreTests/SpeechMetricsTests.swift
git commit -m "feat(core): pause detection, WPM, filler rate, SpeechMetrics rollup"
```

---

### Task 7: PracticePrompt and PromptStore

**Files:**
- Create: `Sources/WhispCore/PracticePrompt.swift`
- Test: `Tests/WhispCoreTests/PromptStoreTests.swift`

**Interfaces:**
- Produces: `PracticePrompt { id: UUID, title: String, text: String, createdAt: Date }`, `PromptStore` with `.all`, `.load(from:)`, `.encoded()`, `.upsert(_:)`, `.delete(id:)`, `.prompt(id:) -> PracticePrompt?`, and `PromptStore.seed: [PracticePrompt]`. Tasks 15, 16 and 17 consume it.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/PromptStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import WhispCore

@Suite struct PromptStoreTests {
    func makeStore() -> PromptStore {
        PromptStore(prompts: [
            PracticePrompt(title: "Why hire you", text: "Answer in 90 seconds."),
            PracticePrompt(title: "Niruron pitch", text: "Pitch the offer."),
        ])
    }

    @Test func roundTripsThroughJSON() throws {
        let store = makeStore()
        let decoded = try PromptStore.load(from: store.encoded())
        #expect(decoded.all.count == 2)
        #expect(decoded.all[0].title == "Why hire you")
    }

    @Test func upsertAddsThenUpdatesInPlace() {
        let store = makeStore()
        var p = PracticePrompt(title: "Cold open", text: "30 seconds.")
        store.upsert(p)
        #expect(store.all.count == 3)

        p.title = "Cold open v2"
        store.upsert(p)
        #expect(store.all.count == 3)
        #expect(store.prompt(id: p.id)?.title == "Cold open v2")
    }

    @Test func deleteRemovesOnlyTheTarget() {
        let store = makeStore()
        let target = store.all[0].id
        store.delete(id: target)
        #expect(store.all.count == 1)
        #expect(store.prompt(id: target) == nil)
    }

    @Test func deletingAnUnknownIDIsANoOp() {
        let store = makeStore()
        store.delete(id: UUID())
        #expect(store.all.count == 2)
    }

    @Test func seedIsNonEmptyAndUnique() {
        let ids = Set(PromptStore.seed.map(\.id))
        #expect(!PromptStore.seed.isEmpty)
        #expect(ids.count == PromptStore.seed.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter PromptStoreTests`
Expected: FAIL — cannot find `PromptStore` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/PracticePrompt.swift`:

```swift
import Foundation

/// A thing to practise saying. Sessions are tagged to one so metrics compare
/// like with like across attempts at the same answer.
public struct PracticePrompt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

/// Mirrors SnippetStore deliberately — same shape, same method names — so
/// there is one storage pattern in this codebase, not two.
public final class PromptStore {
    private(set) public var prompts: [PracticePrompt]

    public init(prompts: [PracticePrompt]) { self.prompts = prompts }

    public var all: [PracticePrompt] { prompts }

    public static func load(from data: Data) throws -> PromptStore {
        PromptStore(prompts: try JSONDecoder().decode([PracticePrompt].self, from: data))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(prompts)
    }

    public func prompt(id: UUID) -> PracticePrompt? {
        prompts.first { $0.id == id }
    }

    public func upsert(_ p: PracticePrompt) {
        if let i = prompts.firstIndex(where: { $0.id == p.id }) { prompts[i] = p }
        else { prompts.append(p) }
    }

    public func delete(id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    public static let seed: [PracticePrompt] = [
        PracticePrompt(title: "Tell me about yourself",
                       text: "Two minutes. Where you are now, what you do, what you want next."),
        PracticePrompt(title: "Why should we hire you?",
                       text: "90 seconds. Lead with the result, not the resume."),
        PracticePrompt(title: "Walk me through a campaign you ran",
                       text: "Situation, what you changed, the number it moved, what you'd do differently."),
        PracticePrompt(title: "Niruron pitch",
                       text: "60 seconds. Who it's for, the problem, the offer, the proof."),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter PromptStoreTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/PracticePrompt.swift Tests/WhispCoreTests/PromptStoreTests.swift
git commit -m "feat(core): PracticePrompt model and PromptStore"
```

---

### Task 8: PracticeSession model

**Files:**
- Create: `Sources/WhispCore/PracticeSession.swift`
- Test: `Tests/WhispCoreTests/PracticeStoreTests.swift`

**Interfaces:**
- Consumes: `SpeechMetrics` from Task 6.
- Produces: `TranscriptSegment { text: String, startMS: Int, endMS: Int }`, `SessionStatus { .pending, .ready, .failed(String) }`, `PracticeSession { id, promptID: UUID?, promptTitle, startedAt, durationSec, audioFilename, envelope, status, transcript, segments, metrics, coachFeedback }`. Tasks 9, 14, 16 and 18 all consume this.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/PracticeStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import WhispCore

@Suite struct PracticeSessionTests {
    @Test func roundTripsThroughJSONIncludingFailedStatus() throws {
        let s = PracticeSession(promptID: UUID(), promptTitle: "Niruron pitch",
                                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                durationSec: 42.5, audioFilename: "abc.wav",
                                envelope: [0.1, 0.9, 0.0],
                                status: .failed("whisper_full failed (rc=-1)"))
        let decoded = try JSONDecoder().decode(PracticeSession.self,
                                               from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(decoded.status == .failed("whisper_full failed (rc=-1)"))
    }

    @Test func defaultsToPendingWithNoTranscript() {
        let s = PracticeSession(promptID: nil, promptTitle: "Free-form",
                                startedAt: Date(), durationSec: 10,
                                audioFilename: "x.wav", envelope: [])
        #expect(s.status == .pending)
        #expect(s.transcript == nil)
        #expect(s.metrics == nil)
        #expect(s.coachFeedback == nil)
    }

    @Test func segmentsRoundTrip() throws {
        var s = PracticeSession(promptID: nil, promptTitle: "Free-form",
                                startedAt: Date(), durationSec: 3,
                                audioFilename: "x.wav", envelope: [])
        s.segments = [TranscriptSegment(text: "hello", startMS: 0, endMS: 900),
                      TranscriptSegment(text: " there", startMS: 900, endMS: 1_800)]
        s.status = .ready
        let decoded = try JSONDecoder().decode(PracticeSession.self,
                                               from: JSONEncoder().encode(s))
        #expect(decoded.segments?.count == 2)
        #expect(decoded.segments?[1].startMS == 900)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter PracticeSessionTests`
Expected: FAIL — cannot find `PracticeSession` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/PracticeSession.swift`:

```swift
import Foundation

/// One transcribed span with whole-session timing. Timestamps are offset back
/// into whole-session time when chunks are stitched (see AudioChunker).
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startMS: Int
    public let endMS: Int

    public init(text: String, startMS: Int, endMS: Int) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
    }
}

public enum SessionStatus: Codable, Equatable, Sendable {
    /// Audio is on disk; transcription has not finished.
    case pending
    case ready
    case failed(String)
}

/// One practice recording plus everything derived from it.
///
/// `promptTitle` is denormalized on purpose: deleting a prompt must not orphan
/// the label on months of past sessions.
public struct PracticeSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let promptID: UUID?
    public let promptTitle: String
    public let startedAt: Date
    public let durationSec: Double
    /// Filename only, relative to `~/.whisp/recordings/`. Never an absolute
    /// path — the home directory can move, and this file is portable.
    public let audioFilename: String
    /// 20 Hz RMS envelope. Drives pause detection and the review scrubber.
    public let envelope: [Float]

    public var status: SessionStatus
    public var transcript: String?
    public var segments: [TranscriptSegment]?
    public var metrics: SpeechMetrics?
    public var coachFeedback: String?

    public init(id: UUID = UUID(), promptID: UUID?, promptTitle: String,
                startedAt: Date, durationSec: Double, audioFilename: String,
                envelope: [Float], status: SessionStatus = .pending,
                transcript: String? = nil, segments: [TranscriptSegment]? = nil,
                metrics: SpeechMetrics? = nil, coachFeedback: String? = nil) {
        self.id = id
        self.promptID = promptID
        self.promptTitle = promptTitle
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.audioFilename = audioFilename
        self.envelope = envelope
        self.status = status
        self.transcript = transcript
        self.segments = segments
        self.metrics = metrics
        self.coachFeedback = coachFeedback
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter PracticeSessionTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/PracticeSession.swift Tests/WhispCoreTests/PracticeStoreTests.swift
git commit -m "feat(core): PracticeSession model with pending/ready/failed status"
```

---

### Task 9: PracticeStore with per-prompt trends

**Files:**
- Create: `Sources/WhispCore/PracticeStore.swift`
- Test: `Tests/WhispCoreTests/PracticeStoreTests.swift`

**Interfaces:**
- Consumes: `PracticeSession`, `SessionStatus`, `SpeechMetrics`.
- Produces: `PracticeStore` with `.all`, `.load(from:)`, `.encoded()`, `.append(_:)`, `.update(_:)`, `.delete(id:) -> PracticeSession?`, `.sessions(forPrompt: UUID?) -> [PracticeSession]`, `.trend(forPrompt: UUID?) -> [TrendPoint]`; and `TrendPoint { date, wpm, fillerRate, pauseCount }`. Tasks 14 and 16 consume it.

- [ ] **Step 1: Write the failing test**

Append to `Tests/WhispCoreTests/PracticeStoreTests.swift`:

```swift
@Suite struct PracticeStoreTests {
    func metrics(wpm: Double, fillerRate: Double, pauseCount: Int) -> SpeechMetrics {
        SpeechMetrics(wordCount: 100, durationSec: 60, speakingDurationSec: 60, wpm: wpm,
                      fillerCounts: [:], totalFillers: 0, fillerRate: fillerRate,
                      pauses: [], pauseCount: pauseCount, longestPauseSec: 0, silenceRatio: 0)
    }

    func session(prompt: UUID?, day: Int, wpm: Double = 140,
                 fillerRate: Double = 3, pauseCount: Int = 2) -> PracticeSession {
        var s = PracticeSession(promptID: prompt, promptTitle: "P",
                                startedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                                durationSec: 60, audioFilename: "\(day).wav", envelope: [])
        s.status = .ready
        s.metrics = metrics(wpm: wpm, fillerRate: fillerRate, pauseCount: pauseCount)
        return s
    }

    @Test func appendUpdateDeleteRoundTrip() throws {
        let store = PracticeStore(sessions: [])
        let a = session(prompt: nil, day: 1)
        store.append(a)
        #expect(store.all.count == 1)

        var updated = a
        updated.transcript = "hello"
        updated.status = .ready
        store.update(updated)
        #expect(store.all.count == 1)
        #expect(store.all[0].transcript == "hello")

        let decoded = try PracticeStore.load(from: store.encoded())
        #expect(decoded.all[0].transcript == "hello")

        let removed = store.delete(id: a.id)
        #expect(removed?.audioFilename == "1.wav")
        #expect(store.all.isEmpty)
        #expect(store.delete(id: a.id) == nil)
    }

    @Test func updateOfAnUnknownSessionIsANoOp() {
        let store = PracticeStore(sessions: [session(prompt: nil, day: 1)])
        store.update(session(prompt: nil, day: 99))
        #expect(store.all.count == 1)
    }

    @Test func sessionsForPromptFilterAndSortChronologically() {
        let p = UUID(), other = UUID()
        let store = PracticeStore(sessions: [
            session(prompt: p, day: 3),
            session(prompt: other, day: 2),
            session(prompt: p, day: 1),
        ])
        let mine = store.sessions(forPrompt: p)
        #expect(mine.count == 2)
        #expect(mine[0].audioFilename == "1.wav")   // oldest first
        #expect(mine[1].audioFilename == "3.wav")
    }

    @Test func freeFormSessionsAreQueriedWithNil() {
        let store = PracticeStore(sessions: [
            session(prompt: nil, day: 1),
            session(prompt: UUID(), day: 2),
        ])
        #expect(store.sessions(forPrompt: nil).count == 1)
    }

    @Test func trendIsChronologicalAndSkipsUnfinishedSessions() {
        let p = UUID()
        var pending = session(prompt: p, day: 2)
        pending.status = .pending
        pending.metrics = nil

        let store = PracticeStore(sessions: [
            session(prompt: p, day: 3, wpm: 150, fillerRate: 1, pauseCount: 1),
            pending,
            session(prompt: p, day: 1, wpm: 130, fillerRate: 5, pauseCount: 4),
        ])
        let t = store.trend(forPrompt: p)
        #expect(t.count == 2)               // the pending one has no metrics
        #expect(t[0].wpm == 130)            // oldest first
        #expect(t[1].wpm == 150)
        #expect(t[0].fillerRate == 5)
        #expect(t[1].pauseCount == 1)
    }

    @Test func trendIsEmptyWhenNothingHasMetrics() {
        let store = PracticeStore(sessions: [])
        #expect(store.trend(forPrompt: UUID()).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter PracticeStoreTests`
Expected: FAIL — cannot find `PracticeStore` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/PracticeStore.swift`:

```swift
import Foundation

/// One point on a per-prompt improvement chart.
public struct TrendPoint: Equatable, Sendable {
    public let date: Date
    public let wpm: Double
    public let fillerRate: Double
    public let pauseCount: Int
}

public final class PracticeStore {
    private(set) public var sessions: [PracticeSession]

    public init(sessions: [PracticeSession]) { self.sessions = sessions }

    public var all: [PracticeSession] { sessions }

    public static func load(from data: Data) throws -> PracticeStore {
        PracticeStore(sessions: try JSONDecoder().decode([PracticeSession].self, from: data))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(sessions)
    }

    public func append(_ s: PracticeSession) { sessions.append(s) }

    /// Replaces by id. Unknown ids are ignored rather than appended — a late
    /// transcription result for a session the user already deleted must not
    /// resurrect it.
    public func update(_ s: PracticeSession) {
        guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions[i] = s
    }

    /// Returns the removed session so the caller can delete its WAV.
    @discardableResult
    public func delete(id: UUID) -> PracticeSession? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        return sessions.remove(at: i)
    }

    /// Oldest first. `nil` selects free-form sessions.
    public func sessions(forPrompt promptID: UUID?) -> [PracticeSession] {
        sessions.filter { $0.promptID == promptID }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Oldest first. Sessions without metrics (still transcribing, or failed)
    /// are skipped — a missing point is honest, a zeroed point is a lie that
    /// would look like a catastrophic regression on the chart.
    public func trend(forPrompt promptID: UUID?) -> [TrendPoint] {
        sessions(forPrompt: promptID).compactMap { s in
            guard let m = s.metrics else { return nil }
            return TrendPoint(date: s.startedAt, wpm: m.wpm,
                              fillerRate: m.fillerRate, pauseCount: m.pauseCount)
        }
    }
}
```

`SpeechMetrics` needs a public memberwise initializer for the test helper to compile. Add this to `Sources/WhispCore/SpeechMetrics.swift` inside the `SpeechMetrics` struct:

```swift
    public init(wordCount: Int, durationSec: Double, speakingDurationSec: Double,
                wpm: Double, fillerCounts: [String: Int], totalFillers: Int,
                fillerRate: Double, pauses: [Pause], pauseCount: Int,
                longestPauseSec: Double, silenceRatio: Double) {
        self.wordCount = wordCount
        self.durationSec = durationSec
        self.speakingDurationSec = speakingDurationSec
        self.wpm = wpm
        self.fillerCounts = fillerCounts
        self.totalFillers = totalFillers
        self.fillerRate = fillerRate
        self.pauses = pauses
        self.pauseCount = pauseCount
        self.longestPauseSec = longestPauseSec
        self.silenceRatio = silenceRatio
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/whisp && swift test`
Expected: PASS — all suites.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/PracticeStore.swift Sources/WhispCore/SpeechMetrics.swift Tests/WhispCoreTests/PracticeStoreTests.swift
git commit -m "feat(core): PracticeStore with per-prompt improvement trends"
```

---

### Task 10: AudioChunker — split long audio at quiet points

**Files:**
- Create: `Sources/WhispCore/AudioChunker.swift`
- Test: `Tests/WhispCoreTests/AudioChunkerTests.swift`

**Interfaces:**
- Produces: `AudioChunk { samples: [Float], startMS: Int }` and `AudioChunker.chunk(samples:sampleRate:envelope:binSeconds:maxChunkSec:searchWindowSec:) -> [AudioChunk]`. Task 11 drives whisper with these and offsets segment timestamps by `startMS`.

- [ ] **Step 1: Write the failing test**

Create `Tests/WhispCoreTests/AudioChunkerTests.swift`:

```swift
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

    @Test func fallsBackToTheHardBoundaryWhenThereIsNoQuietPoint() {
        let chunks = AudioChunker.chunk(samples: samples(45), sampleRate: rate,
                                        envelope: envelope(45), binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.count == 2)
        // Uniformly loud: the minimum is the window's first bin, i.e. 25s.
        let firstLenSec = Double(chunks[0].samples.count) / Double(rate)
        #expect(firstLenSec >= 25.0 && firstLenSec <= 30.0)
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
        // A truncated envelope must not crash or drop audio.
        let input = samples(45)
        let chunks = AudioChunker.chunk(samples: input, sampleRate: rate,
                                        envelope: envelope(5), binSeconds: 0.05,
                                        maxChunkSec: 30, searchWindowSec: 5)
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == input.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/whisp && swift test --filter AudioChunkerTests`
Expected: FAIL — cannot find `AudioChunker` in scope.

- [ ] **Step 3: Implement**

Create `Sources/WhispCore/AudioChunker.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/whisp && swift test --filter AudioChunkerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/WhispCore/AudioChunker.swift Tests/WhispCoreTests/AudioChunkerTests.swift
git commit -m "feat(core): AudioChunker cuts long recordings at quiet points"
```

---

### Task 11: WhisperTranscriber gains timestamped, verbatim transcription

**Files:**
- Modify: `Sources/Whisp/WhisperTranscriber.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` (Task 8), `AudioChunk` (Task 10).
- Produces: `WhisperTranscriber.transcribeSegments(_ chunks: [AudioChunk], progress: @Sendable (Double) -> Void) async throws -> [TranscriptSegment]`.

**This task must not touch `transcribe(_:)`.** Verify with `git diff` before committing.

- [ ] **Step 1: Add the segment-transcription path**

Append to the `WhisperTranscriber` class in `Sources/Whisp/WhisperTranscriber.swift`:

```swift
    /// Transcribes chunks in order, returning whole-session-timed segments.
    ///
    /// Takes and releases the context lock ONCE PER CHUNK rather than holding it
    /// for the whole recording. A 3-minute practice clip would otherwise block
    /// every dictation attempt for its full ~60s of CPU work; this way dictation
    /// waits at most one chunk.
    ///
    /// Parameters differ from `transcribe(_:)` on purpose (see practiceParams):
    /// dictation wants Whisper's clean output, practice wants the disfluencies.
    func transcribeSegments(_ chunks: [AudioChunk],
                            progress: @Sendable @escaping (Double) -> Void) async throws
        -> [TranscriptSegment] {
        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            let segs: [TranscriptSegment] = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        cont.resume(returning: try self.segmentsSync(chunk))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            all.append(contentsOf: segs)
            progress(Double(i + 1) / Double(chunks.count))
            // Yield between chunks so a queued dictation can take the lock.
            await Task.yield()
        }
        return all
    }

    /// Biases decoding toward verbatim output. Whisper is trained to emit clean
    /// readable text and drops disfluencies; a disfluent initial_prompt plus
    /// unsuppressed non-speech tokens recovers much (NOT all) of it. Filler
    /// counts will still undercount reality — the trend stays honest because
    /// the bias is identical across sessions.
    private static let practicePrompt =
        "Um, so, uh, I mean, like, you know, it's basically, uh, kind of what I wanted to say."

    private func segmentsSync(_ chunk: AudioChunk) throws -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        guard !chunk.samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = false          // segments need timing
        params.suppress_non_speech_tokens = false
        params.translate = false
        params.single_segment = false

        func run() -> Int32 {
            chunk.samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        let rc: Int32 = "en".withCString { lang in
            params.language = lang
            return Self.practicePrompt.withCString { ip in
                params.initial_prompt = ip
                return run()
            }
        }
        guard rc == 0 else {
            throw NSError(domain: "Whisp.Transcriber", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "whisper_full failed in practice mode (rc=\(rc))"])
        }

        var out: [TranscriptSegment] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            // whisper timestamps are in centiseconds; ×10 → ms, then offset into
            // whole-session time.
            let t0 = Int(whisper_full_get_segment_t0(ctx, i)) * 10 + chunk.startMS
            let t1 = Int(whisper_full_get_segment_t1(ctx, i)) * 10 + chunk.startMS
            out.append(TranscriptSegment(text: String(cString: raw), startMS: t0, endMS: t1))
        }
        return out
    }
```

- [ ] **Step 2: Verify the build compiles and dictation is untouched**

Run: `cd ~/whisp && swift build -c release --product Whisp`
Expected: builds with no errors.

Run: `cd ~/whisp && git diff Sources/Whisp/WhisperTranscriber.swift | grep -E '^-' | grep -v '^---'`
Expected: **no output.** Any deleted line means the existing dictation path was modified — revert it. Only additions are permitted in this file.

- [ ] **Step 3: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/WhisperTranscriber.swift
git commit -m "feat: timestamped verbatim transcription for practice mode"
```

---

### Task 12: AudioRecorder produces an envelope; recordings are written as WAV

**Files:**
- Modify: `Sources/Whisp/AudioRecorder.swift`
- Modify: `Sources/Whisp/Paths.swift`

**Interfaces:**
- Consumes: `EnvelopeBuilder` (Task 4), `WavCodec` (Task 3).
- Produces: `AudioRecorder.stopWithEnvelope() -> (samples: [Float], envelope: [Float])`, `Paths.recordingsDir`, `Paths.sessionsFile`, `Paths.promptsFile`, `Paths.fillersFile`, `Paths.loadFillers() -> [String]`, `Paths.recordingURL(filename:) -> URL`, `Paths.writeRecording(samples:filename:) throws`.

`stop()` keeps its exact current signature and behavior so dictation is unaffected.

- [ ] **Step 1: Add envelope accumulation to AudioRecorder**

In `Sources/Whisp/AudioRecorder.swift`, add `import WhispCore` at the top, then add these stored properties beside the existing ones:

```swift
    // Protected by `lock`. Built from the same RMS the tap already computes, so
    // there is no extra DSP cost. Dictation ignores it.
    private var _envelope = EnvelopeBuilder()
    private var _framesSeen: Int = 0
```

In `start()`, reset them alongside `_buffers`:

```swift
        lock.lock()
        _buffers.removeAll()
        _inputFormat = nil
        _envelope = EnvelopeBuilder()
        _framesSeen = 0
        lock.unlock()
```

In the tap closure, feed the envelope inside the existing locked section. Replace the closure's locked block with:

```swift
            let cb: (Float) -> Void = self.lock.withLock {
                if let copy { self._buffers.append(copy) }
                // Sample-clock time, not wall-clock: exact and monotonic.
                let seconds = Double(self._framesSeen) / fmt.sampleRate
                self._framesSeen += Int(buf.frameLength)
                self._envelope.add(level: rms, atSeconds: seconds)
                return self._level
            }
```

Then add a new method beside `stop()`:

```swift
    /// Practice-mode variant of `stop()`. Returns the same samples plus the
    /// 20 Hz envelope accumulated during capture.
    func stopWithEnvelope() -> (samples: [Float], envelope: [Float]) {
        let envelope = lock.withLock { _envelope.finish() }
        return (stop(), envelope)
    }
```

Read the envelope BEFORE calling `stop()`: `stop()` removes the tap, and reading first guarantees every level the tap already delivered is included.

- [ ] **Step 2: Add the practice paths**

In `Sources/Whisp/Paths.swift`, add to the `Paths` enum:

```swift
    static var recordingsDir: String { dir + "/recordings" }
    static var sessionsFile: String { dir + "/sessions.json" }
    static var promptsFile: String { dir + "/prompts.json" }
    static var fillersFile: String { dir + "/fillers.txt" }

    static func recordingURL(filename: String) -> URL {
        URL(fileURLWithPath: recordingsDir + "/" + filename)
    }

    /// Writes 16 kHz mono samples as a 16-bit PCM WAV.
    static func writeRecording(samples: [Float], filename: String) throws {
        try FileManager.default.createDirectory(atPath: recordingsDir,
                                                withIntermediateDirectories: true)
        try WavCodec.encode(samples: samples).write(to: recordingURL(filename: filename))
    }

    static func loadFillers() -> [String] {
        guard let text = try? String(contentsOfFile: fillersFile, encoding: .utf8) else {
            return FillerList.parse(FillerList.seed)
        }
        return FillerList.parse(text)
    }

    static func loadPrompts() throws -> PromptStore {
        let data = try Data(contentsOf: URL(fileURLWithPath: promptsFile))
        return try PromptStore.load(from: data)
    }

    static func loadSessions() throws -> PracticeStore {
        let data = try Data(contentsOf: URL(fileURLWithPath: sessionsFile))
        return try PracticeStore.load(from: data)
    }
```

Extend `ensureSeeded()` — add before its closing brace:

```swift
        try fm.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: fillersFile) {
            try FillerList.seed.write(toFile: fillersFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: promptsFile) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(PromptStore.seed).write(to: URL(fileURLWithPath: promptsFile))
        }
        if !fm.fileExists(atPath: sessionsFile) {
            try Data("[]".utf8).write(to: URL(fileURLWithPath: sessionsFile))
        }
```

- [ ] **Step 3: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp && swift test`
Expected: build succeeds, all Core tests still pass.

- [ ] **Step 4: Verify dictation's stop() path is unchanged**

Run: `cd ~/whisp && git diff Sources/Whisp/AudioRecorder.swift`
Expected: review by eye — the `stop()` function body must have zero changed lines. Only `start()`, the tap closure, the new properties and the new `stopWithEnvelope()` may differ.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/AudioRecorder.swift Sources/Whisp/Paths.swift
git commit -m "feat: RMS envelope capture and practice file paths"
```

---

### Task 13: PracticeHotkey — Carbon global hotkey

**Files:**
- Create: `Sources/Whisp/PracticeHotkey.swift`

**Interfaces:**
- Consumes: `HotkeySpec` (Task 2).
- Produces: `PracticeHotkey(spec: HotkeySpec, onFire: @Sendable @escaping () -> Void)`, `.register() -> Bool`, `.unregister()`.

- [ ] **Step 1: Implement**

Create `Sources/Whisp/PracticeHotkey.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import WhispCore

/// A keycode-based global hotkey via Carbon's RegisterEventHotKey.
///
/// Deliberately a DIFFERENT mechanism from HotkeyMonitor's Fn CGEventTap: the
/// two cannot interfere, cannot double-fire, and Practice Mode cannot regress
/// dictation's latency. Carbon is the only supported API for a system-wide
/// hotkey that works without Accessibility permission.
@MainActor
final class PracticeHotkey {
    private let spec: HotkeySpec
    private let onFire: @Sendable () -> Void
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Carbon fires into a C callback with no context pointer we control per
    /// instance, so the active instance is looked up here. Whisp registers
    /// exactly one practice hotkey.
    @MainActor private static var active: PracticeHotkey?

    init(spec: HotkeySpec, onFire: @Sendable @escaping () -> Void) {
        self.spec = spec
        self.onFire = onFire
    }

    /// Returns false if the key is already claimed by another app, which Carbon
    /// reports rather than silently losing.
    @discardableResult
    func register() -> Bool {
        unregister()

        guard let keyCode = Self.virtualKeyCode(for: spec.key) else {
            Diag.log("practice hotkey: no virtual keycode for '\(spec.key)'")
            return false
        }

        var mods: UInt32 = 0
        if spec.control { mods |= UInt32(controlKey) }
        if spec.option { mods |= UInt32(optionKey) }
        if spec.command { mods |= UInt32(cmdKey) }
        if spec.shift { mods |= UInt32(shiftKey) }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { PracticeHotkey.active?.onFire() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard installStatus == noErr else {
            Diag.log("practice hotkey: InstallEventHandler failed (\(installStatus))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x57485350), id: 1)  // 'WHSP'
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Diag.log("practice hotkey: \(spec.display) is unavailable (status \(status)) — another app owns it")
            return false
        }

        Self.active = self
        Diag.log("practice hotkey: \(spec.display) registered")
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if Self.active === self { Self.active = nil }
    }

    /// ANSI virtual keycodes. Layout-independent for the physical key positions
    /// Whisp cares about; a Dvorak user editing practiceHotkey gets the ANSI
    /// position, which is the same trade every Mac app with a fixed default makes.
    private static func virtualKeyCode(for key: Character) -> Int? {
        let map: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        return map[key]
    }
}
```

- [ ] **Step 2: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/PracticeHotkey.swift
git commit -m "feat: Carbon global hotkey for practice mode"
```

---

### Task 14: PracticeController — the orchestration

**Files:**
- Create: `Sources/Whisp/PracticeController.swift`

**Interfaces:**
- Consumes: `AudioRecorder.stopWithEnvelope()` (12), `WhisperTranscriber.transcribeSegments` (11), `AudioChunker` (10), `PracticeStore`/`PracticeSession` (8, 9), `SpeechAnalyzer.analyze` (6), `Paths.writeRecording` (12).
- Produces: `PracticeController` with `.isRecording: Bool`, `.toggle()`, `.setPrompt(_ prompt: PracticePrompt?)`, `.sessionsChanged: () -> Void`, `.store: PracticeStore`. Tasks 15, 16 and 17 consume it.

- [ ] **Step 1: Implement**

Create `Sources/Whisp/PracticeController.swift`:

```swift
import AppKit
import WhispCore

/// Owns the practice capture lifecycle. Deliberately separate from
/// SpeechPipeline: no DeepSeek cleanup (it strips the fillers being measured)
/// and no PasteInserter (nothing is ever typed at the cursor).
@MainActor
final class PracticeController {
    private let recorder: AudioRecorder
    private let transcriber: WhisperTranscriber
    /// Used ONLY by the opt-in coach feedback in Task 18. The practice
    /// transcription path never calls it — cleanup strips fillers, which are
    /// exactly what is being measured.
    private let cleaner: Cleaning
    private let config: WhispConfig

    private(set) var isRecording = false
    private var startedAt = Date()
    private var currentPrompt: PracticePrompt?
    private var sessionID = UUID()

    private(set) var store: PracticeStore
    private(set) var prompts: PromptStore

    /// Fired on the main actor whenever a session is added or updated, so an
    /// open review window can refresh.
    var sessionsChanged: () -> Void = {}
    /// Fired with a HUD-facing status string.
    var onStatus: (String) -> Void = { _ in }

    init(recorder: AudioRecorder, transcriber: WhisperTranscriber, cleaner: Cleaning,
         config: WhispConfig, store: PracticeStore, prompts: PromptStore) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.config = config
        self.store = store
        self.prompts = prompts
    }

    /// Tags the in-flight session. The picker never gates the mic, so this can
    /// arrive seconds after recording began.
    func setPrompt(_ prompt: PracticePrompt?) {
        currentPrompt = prompt
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard !isRecording else { return }
        sessionID = UUID()
        startedAt = Date()
        currentPrompt = nil
        // Deliberately does NOT touch `recorder.level`. AppDelegate assigns that
        // handler once at startup to feed the HUD, and reassigning it here would
        // permanently steal the level feed from dictation — the handler is a
        // single slot, not a list of observers.
        do {
            try recorder.start()
            isRecording = true
            Diag.log("practice: recording started \(sessionID)")
        } catch {
            Diag.log("practice: failed to start recording — \(error.localizedDescription)")
            onStatus("Mic unavailable")
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false

        let (samples, envelope) = recorder.stopWithEnvelope()
        let duration = Date().timeIntervalSince(startedAt)
        let filename = "\(sessionID.uuidString).wav"
        let prompt = currentPrompt

        // Write the audio FIRST. A whisper crash, a quit, or a power loss may
        // cost a transcript; it must never cost the recording.
        do {
            try Paths.writeRecording(samples: samples, filename: filename)
        } catch {
            Diag.log("practice: FAILED to write \(filename) — \(error.localizedDescription)")
            onStatus("Could not save recording")
            return
        }

        let session = PracticeSession(
            id: sessionID, promptID: prompt?.id,
            promptTitle: prompt?.title ?? "Free-form",
            startedAt: startedAt, durationSec: duration,
            audioFilename: filename, envelope: envelope, status: .pending)
        store.append(session)
        persist()
        sessionsChanged()
        onStatus("Saved — transcribing…")

        Task { await self.transcribe(session: session, samples: samples, envelope: envelope) }
    }

    private func transcribe(session: PracticeSession, samples: [Float], envelope: [Float]) async {
        var updated = session
        do {
            let chunks = AudioChunker.chunk(
                samples: samples, sampleRate: 16_000, envelope: envelope,
                binSeconds: EnvelopeBuilder.defaultBinSeconds)

            let segments = try await transcriber.transcribeSegments(chunks) { pct in
                MainActor.assumeIsolated {
                    self.onStatus("Transcribing \(Int(pct * 100))%")
                }
            }
            let transcript = segments.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            updated.segments = segments
            updated.transcript = transcript
            updated.metrics = SpeechAnalyzer.analyze(
                transcript: transcript, envelope: envelope,
                binSeconds: EnvelopeBuilder.defaultBinSeconds,
                fillers: Paths.loadFillers(),
                silenceThreshold: Float(config.silenceRMSThreshold),
                minPauseSec: config.pauseThresholdSec)
            updated.status = .ready
            onStatus("Practice session ready")
        } catch {
            updated.status = .failed(error.localizedDescription)
            Diag.log("practice: transcription failed — \(error.localizedDescription)")
            onStatus("Transcription failed")
        }

        // update() ignores unknown ids, so a session deleted while this ran is
        // not resurrected. The WAV stays on disk either way.
        store.update(updated)
        persist()
        sessionsChanged()
    }

    func deleteSession(id: UUID) {
        guard let removed = store.delete(id: id) else { return }
        try? FileManager.default.removeItem(
            at: Paths.recordingURL(filename: removed.audioFilename))
        persist()
        sessionsChanged()
    }

    func savePrompts() {
        do {
            try prompts.encoded().write(to: URL(fileURLWithPath: Paths.promptsFile))
        } catch {
            Diag.log("practice: failed to save prompts — \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try store.encoded().write(to: URL(fileURLWithPath: Paths.sessionsFile))
        } catch {
            Diag.log("practice: failed to save sessions — \(error.localizedDescription)")
        }
    }

    /// Total bytes used by every recording on disk.
    func recordingsDiskBytes() -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.recordingsDir) else { return 0 }
        return names.reduce(Int64(0)) { total, name in
            let attrs = try? fm.attributesOfItem(atPath: Paths.recordingsDir + "/" + name)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }
}
```

- [ ] **Step 2: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/PracticeController.swift
git commit -m "feat: PracticeController orchestrates capture, transcription, metrics"
```

---

### Task 15: HUD practicing state and the prompt picker

**Files:**
- Modify: `Sources/Whisp/HUDWindow.swift`
- Create: `Sources/Whisp/PromptPickerView.swift`

**Interfaces:**
- Consumes: `PracticePrompt`, `PromptStore` (Task 7), `PracticeController` (Task 14).
- Produces: `HUDWindow.showPractice(elapsed: TimeInterval, level: Float)`, `HUDWindow.showPracticeStatus(_ text: String)`, and `PromptPickerPanel(prompts:onPick:)` with `.present()` / `.dismiss()`.

- [ ] **Step 1: Add the practising HUD state**

`HUDWindow.show(_:)` switches over `PipelineStatus`. Add parallel entry points rather than extending that enum — `PipelineStatus` belongs to dictation, and widening it would force every dictation switch site to handle practice cases.

These use `HUDWindow`'s existing private members exactly as `show(_:)` does: `setGlyph(_:_:)`, `label.stringValue`, `wave.setMode(_:)`, `positionBottomCenter()`, `present()`, `scheduleHide(after:)` and `hideWork`. The mic level already flows through the existing public `setLevel(_:)`, so practice needs no new level plumbing.

Add to `HUDWindow`, directly after `show(_:)`:

```swift
    /// Practice recording: amber glyph and an elapsed timer, so there is never
    /// a doubt about which mode is capturing. The live waveform is fed by the
    /// existing `setLevel(_:)`, same as dictation.
    func showPractice(elapsed: TimeInterval) {
        hideWork?.cancel()
        setGlyph("record.circle", Theme.amber)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        label.stringValue = String(format: "Practice  %d:%02d", mins, secs)
        wave.setMode(.live)
        positionBottomCenter()
        present()
    }

    /// Post-recording practice status ("Saved — transcribing…", "Transcribing 40%").
    func showPracticeStatus(_ text: String, done: Bool = false) {
        hideWork?.cancel()
        setGlyph(done ? "checkmark.circle.fill" : "waveform", done ? Theme.mint : Theme.aqua)
        label.stringValue = text
        wave.setMode(done ? .idle : .shimmer)
        positionBottomCenter()
        present()
        if done { scheduleHide(after: 1.6) }
    }
```

`record.circle` is available on macOS 13. If the build reports it missing, substitute `"largecircle.filled.circle"`.

- [ ] **Step 2: Build the prompt picker**

Create `Sources/Whisp/PromptPickerView.swift`:

```swift
import AppKit
import SwiftUI
import WhispCore

/// A small panel listing practice prompts, shown the moment recording starts.
/// The mic is ALREADY HOT when this appears — picking only tags the in-flight
/// session, so nothing said in the first seconds is lost while choosing.
@MainActor
final class PromptPickerPanel {
    private var window: NSWindow?
    private let prompts: [PracticePrompt]
    private let onPick: (PracticePrompt?) -> Void

    init(prompts: [PracticePrompt], onPick: @escaping (PracticePrompt?) -> Void) {
        self.prompts = prompts
        self.onPick = onPick
    }

    func present() {
        dismiss()
        let view = PromptPickerView(prompts: prompts) { [weak self] picked in
            self?.onPick(picked)
            self?.dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "What are you practising?"
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

struct PromptPickerView: View {
    let prompts: [PracticePrompt]
    let onPick: (PracticePrompt?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording has already started.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(prompts) { p in
                    Button {
                        onPick(p)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.body)
                            Text(p.text).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Free-form (Esc)") { onPick(nil) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
```

- [ ] **Step 3: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/HUDWindow.swift Sources/Whisp/PromptPickerView.swift
git commit -m "feat(ui): practice HUD state and prompt picker"
```

---

### Task 16: PracticeWindow — the review UI

**Files:**
- Create: `Sources/Whisp/PracticeWindow.swift`

**Interfaces:**
- Consumes: `PracticeController` (14), `PracticeStore`/`TrendPoint` (9), `PracticeSession`/`SpeechMetrics` (8, 6), `Paths.recordingURL` (12).
- Produces: `PracticeWindow.shared.show(controller:)`.

- [ ] **Step 1: Implement**

Create `Sources/Whisp/PracticeWindow.swift`:

```swift
import AppKit
import SwiftUI
import AVFoundation
import WhispCore

@MainActor
final class PracticeWindow {
    static let shared = PracticeWindow()
    private var window: NSWindow?

    func show(controller: PracticeController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = PracticeRootView(controller: controller)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Practice"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// Plays back a recording. One shared player so starting a second clip stops
/// the first instead of layering two voices.
@MainActor
final class SessionPlayer: ObservableObject {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(session: PracticeSession) {
        if playingID == session.id {
            player?.stop(); player = nil; playingID = nil
            return
        }
        player?.stop()
        let url = Paths.recordingURL(filename: session.audioFilename)
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            Diag.log("practice: cannot play \(session.audioFilename)")
            return
        }
        player = p
        playingID = session.id
        p.play()
    }
}

struct PracticeRootView: View {
    let controller: PracticeController
    @State private var selectedPrompt: UUID?
    @State private var selectedSession: PracticeSession?
    @State private var refreshToken = UUID()
    @StateObject private var player = SessionPlayer()

    private var prompts: [PracticePrompt] { controller.prompts.all }
    private var sessions: [PracticeSession] {
        controller.store.sessions(forPrompt: selectedPrompt).reversed()
    }
    private var trend: [TrendPoint] { controller.store.trend(forPrompt: selectedPrompt) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPrompt) {
                Section("Prompts") {
                    ForEach(prompts) { p in
                        Text(p.title).tag(Optional(p.id))
                    }
                    Text("Free-form").tag(Optional<UUID>.none)
                }
            }
            .frame(minWidth: 200)
        } content: {
            List(sessions, selection: Binding(
                get: { selectedSession?.id },
                set: { id in selectedSession = sessions.first { $0.id == id } }
            )) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(statusLine(s)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(s.id)
            }
            .frame(minWidth: 240)
        } detail: {
            if let s = selectedSession {
                SessionDetailView(session: s, controller: controller,
                                  player: player, trend: trend)
            } else {
                ContentUnavailableView("No session selected",
                                       systemImage: "waveform",
                                       description: Text("Press the practice hotkey to record one."))
            }
        }
        .id(refreshToken)
        .onAppear {
            controller.sessionsChanged = { refreshToken = UUID() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(diskUsage()).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
    }

    private func statusLine(_ s: PracticeSession) -> String {
        switch s.status {
        case .pending: return "Transcribing…"
        case .failed(let why): return "Failed: \(why)"
        case .ready:
            guard let m = s.metrics else { return "Ready" }
            return String(format: "%.0f WPM · %.1f fillers/100w · %d pauses",
                          m.wpm, m.fillerRate, m.pauseCount)
        }
    }

    private func diskUsage() -> String {
        let bytes = controller.recordingsDiskBytes()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + " of recordings on disk"
    }
}

struct SessionDetailView: View {
    let session: PracticeSession
    let controller: PracticeController
    @ObservedObject var player: SessionPlayer
    let trend: [TrendPoint]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(player.playingID == session.id ? "Stop" : "Play") {
                        player.toggle(session: session)
                    }
                    Text(String(format: "%.0fs", session.durationSec))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        controller.deleteSession(id: session.id)
                    }
                }

                EnvelopeView(envelope: session.envelope,
                             pauses: session.metrics?.pauses ?? [],
                             binSeconds: EnvelopeBuilder.defaultBinSeconds)
                    .frame(height: 56)

                if let m = session.metrics {
                    MetricTiles(metrics: m)
                }

                if let t = session.transcript, !t.isEmpty {
                    GroupBox("Transcript") {
                        Text(t).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if trend.count > 1 {
                    GroupBox("Across your attempts at this prompt") {
                        TrendSparkline(points: trend)
                            .frame(height: 80)
                    }
                }
            }
            .padding(16)
        }
    }
}

struct MetricTiles: View {
    let metrics: SpeechMetrics

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150))]
        LazyVGrid(columns: columns, spacing: 12) {
            tile("Pace", String(format: "%.0f", metrics.wpm), "words per minute")
            tile("Fillers", String(format: "%.1f", metrics.fillerRate), "per 100 words")
            tile("Pauses", "\(metrics.pauseCount)",
                 String(format: "longest %.1fs", metrics.longestPauseSec))
            tile("Silence", String(format: "%.0f%%", metrics.silenceRatio * 100), "of the session")
        }
    }

    private func tile(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The recorded envelope with detected pauses shaded.
struct EnvelopeView: View {
    let envelope: [Float]
    let pauses: [Pause]
    let binSeconds: Double

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(envelope.count) * binSeconds, 0.001)
            ZStack(alignment: .leading) {
                ForEach(Array(pauses.enumerated()), id: \.offset) { _, p in
                    Rectangle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: geo.size.width * (p.durationSec / total))
                        .offset(x: geo.size.width * (p.startSec / total))
                }
                Path { path in
                    guard !envelope.isEmpty else { return }
                    let step = geo.size.width / CGFloat(envelope.count)
                    for (i, v) in envelope.enumerated() {
                        let x = CGFloat(i) * step
                        let h = CGFloat(v) * geo.size.height
                        path.move(to: CGPoint(x: x, y: geo.size.height / 2 - h / 2))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height / 2 + h / 2))
                    }
                }
                .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

/// Filler rate over time — lower is better, so a falling line means progress.
struct TrendSparkline: View {
    let points: [TrendPoint]

    var body: some View {
        GeometryReader { geo in
            let values = points.map(\.fillerRate)
            let maxV = max(values.max() ?? 1, 0.001)
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    i == 0 ? path.move(to: CGPoint(x: x, y: y))
                           : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
    }
}
```

- [ ] **Step 2: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp`
Expected: builds with no errors. If `ContentUnavailableView` is unavailable on the macOS 13 deployment target, replace it with a plain `Text("No session selected").foregroundStyle(.secondary)`.

- [ ] **Step 3: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/PracticeWindow.swift
git commit -m "feat(ui): practice review window with playback, metrics, trend"
```

---

### Task 17: Wire it into AppDelegate

**Files:**
- Modify: `Sources/Whisp/AppDelegate.swift`

**Interfaces:**
- Consumes: everything from Tasks 12–16.

- [ ] **Step 1: Wire up**

In `AppDelegate`, add stored properties:

```swift
    private var practice: PracticeController?
    private var practiceHotkey: PracticeHotkey?
    private var promptPicker: PromptPickerPanel?
    private var practiceTimer: Timer?
```

**Placement matters.** `transcriber` and `cleaner` are **locals** declared around `AppDelegate.swift:53-55`, inside the `do` block that builds the pipeline — they are not stored properties. The practice wiring must go **inside that same `do` block, after `pipeline` is assigned**, or those names are out of scope.

Reuse the SAME `AudioRecorder`, `WhisperTranscriber` and `DeepSeekCleaner` instances dictation already uses. A second whisper context would cost another ~150 MB of resident RAM for no benefit, and a second `AudioRecorder` would fight over the input node.

Add inside that `do` block:

```swift
        // Practice Mode.
        let promptStore = (try? Paths.loadPrompts()) ?? PromptStore(prompts: PromptStore.seed)
        let sessionStore = (try? Paths.loadSessions()) ?? PracticeStore(sessions: [])
        let controller = PracticeController(recorder: recorder, transcriber: transcriber,
                                            cleaner: cleaner, config: config,
                                            store: sessionStore, prompts: promptStore)
        controller.onStatus = { [weak self] text in
            MainActor.assumeIsolated { self?.hud.showPracticeStatus(text) }
        }
        practice = controller

        // Fall back to the default if the config value is malformed, so a typo
        // degrades to a working hotkey instead of a silently dead feature.
        let spec = HotkeySpec.parse(config.practiceHotkey)
            ?? HotkeySpec.parse(WhispConfig.defaults.practiceHotkey)!
        if HotkeySpec.parse(config.practiceHotkey) == nil {
            Diag.log("config: practiceHotkey '\(config.practiceHotkey)' is malformed — using \(spec.display)")
        }
        let hotkey = PracticeHotkey(spec: spec) { [weak self] in
            MainActor.assumeIsolated { self?.togglePractice() }
        }
        hotkey.register()
        practiceHotkey = hotkey
```

Also validate the dictation hotkey so the field stops being silently dead:

```swift
        if config.hotkey.lowercased() != "fn" {
            Diag.log("config: hotkey '\(config.hotkey)' is not supported — dictation is Fn-only; using Fn")
        }
```

Add the toggle and the menu item:

```swift
    private func togglePractice() {
        guard let practice else { return }
        practice.toggle()

        if practice.isRecording {
            let picker = PromptPickerPanel(prompts: practice.prompts.all) { [weak self] picked in
                self?.practice?.setPrompt(picked)
            }
            picker.present()
            promptPicker = picker

            // Ticks the elapsed timer. The waveform is already live: the
            // `recorder.level` handler assigned at startup (AppDelegate.swift:30)
            // feeds hud.setLevel for BOTH modes, which is why neither
            // PracticeController nor this method reassigns it.
            let started = Date()
            practiceTimer?.invalidate()
            practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.practice, p.isRecording else { return }
                    self.hud.showPractice(elapsed: Date().timeIntervalSince(started))
                }
            }
        } else {
            practiceTimer?.invalidate()
            practiceTimer = nil
            promptPicker?.dismiss()
            promptPicker = nil
        }
    }
```

In the menu construction (`AppDelegate.swift:114-121`), add between the "Edit Snippets…" and "Settings…" items:

```swift
        menu.addItem(NSMenuItem(title: "Practice…", action: #selector(openPractice), keyEquivalent: "p"))
```

and the action, beside the existing `openSnippets` / `openSettings`:

```swift
    @objc private func openPractice() {
        guard let practice else { return }
        PracticeWindow.shared.show(controller: practice)
    }
```

The app stays `.accessory` throughout — do not add an activation-policy flip when opening this window. v1 deliberately removed that so no Dock icon ever appears.

- [ ] **Step 2: Verify the build and bundle**

Run: `cd ~/whisp && swift build -c release --product Whisp && ./build.sh`
Expected: both succeed, `Whisp.app` is produced.

- [ ] **Step 3: Verify the whole test suite still passes**

Run: `cd ~/whisp && swift test`
Expected: PASS — every suite.

- [ ] **Step 4: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/AppDelegate.swift
git commit -m "feat: wire practice mode into the app (hotkey, HUD, menu)"
```

---

### Task 18: Coach feedback (opt-in, transcript only)

**Files:**
- Modify: `Sources/Whisp/PracticeController.swift`
- Modify: `Sources/Whisp/PracticeWindow.swift`
- Modify: `Sources/WhispCore/TranscriptCleaner.swift`

**Interfaces:**
- Consumes: `DeepSeekCleaner` (existing), `TranscriptCleaner` prompt-building style (existing).
- Produces: `TranscriptCleaner.coachPrompt(transcript:promptTitle:metrics:) -> [ChatMessage]`, `PracticeController.requestCoachFeedback(for:) async`.

**Constraint:** this sends the transcript **text** only. It must never send samples, an envelope, or a file path.

- [ ] **Step 1: Add the prompt builder**

Append to `Sources/WhispCore/TranscriptCleaner.swift`:

```swift
    /// Builds a coaching critique request. Sends the TRANSCRIPT TEXT ONLY —
    /// never audio, never an envelope, never a file path.
    public static func coachPrompt(transcript: String, promptTitle: String,
                                   metrics: SpeechMetrics) -> [ChatMessage] {
        let stats = String(
            format: "Pace %.0f wpm. Fillers %.1f per 100 words. %d pauses, longest %.1fs.",
            metrics.wpm, metrics.fillerRate, metrics.pauseCount, metrics.longestPauseSec)
        return [
            ChatMessage(role: "system", content: """
                You are a speaking coach. The user practised answering: "\(promptTitle)".
                Give at most 5 short bullets of specific, actionable feedback on their \
                delivery and structure. Quote their own words when pointing at a problem. \
                No preamble, no praise padding, no em dashes. Be direct.
                """),
            ChatMessage(role: "user", content: "\(stats)\n\nTranscript:\n\(transcript)"),
        ]
    }
```

Match the existing `ChatMessage` initializer signature in that file; read it first and mirror it exactly.

- [ ] **Step 2: Add the controller method**

The `cleaner: Cleaning` property already exists from Task 14 (it is the same `DeepSeekCleaner` instance dictation uses); this is its first and only use. Append to `PracticeController` in `Sources/Whisp/PracticeController.swift`:

```swift
    /// Opt-in. The ONLY egress in Practice Mode, and it carries transcript text
    /// alone. Never called automatically.
    func requestCoachFeedback(for id: UUID) async {
        guard var s = store.all.first(where: { $0.id == id }),
              let transcript = s.transcript, let metrics = s.metrics else { return }
        onStatus("Asking the coach…")
        do {
            let messages = TranscriptCleaner.coachPrompt(
                transcript: transcript, promptTitle: s.promptTitle, metrics: metrics)
            s.coachFeedback = try await cleaner.complete(messages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onStatus("Coach feedback ready")
        } catch {
            s.coachFeedback = "Coach unavailable: \(error.localizedDescription)"
            onStatus("Coach unavailable")
        }
        store.update(s)
        persist()
        sessionsChanged()
    }
```

- [ ] **Step 3: Add the button**

In `SessionDetailView` in `Sources/Whisp/PracticeWindow.swift`, add after the transcript `GroupBox`:

```swift
                if session.metrics != nil {
                    GroupBox("Coach feedback") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let f = session.coachFeedback {
                                Text(f).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("Sends the transcript text to DeepSeek. Audio never leaves your Mac.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Get feedback") {
                                Task { await controller.requestCoachFeedback(for: session.id) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
```

- [ ] **Step 4: Verify the build**

Run: `cd ~/whisp && swift build -c release --product Whisp && swift test`
Expected: both succeed.

- [ ] **Step 5: Commit**

```bash
cd ~/whisp
git add Sources/Whisp/PracticeController.swift Sources/Whisp/PracticeWindow.swift Sources/WhispCore/TranscriptCleaner.swift Sources/Whisp/AppDelegate.swift
git commit -m "feat: opt-in coach feedback on practice transcripts"
```

---

### Task 19: Documentation, calibration, and the live-verification checklist

The harness cannot drive a microphone, a global hotkey, or audio playback. This task produces the artifacts Neil needs to verify the feature himself, and calibrates the one number that was a guess.

**Files:**
- Modify: `README.md`
- Modify: `config.example.json`
- Create: `docs/practice-mode-verification.md`

- [ ] **Step 1: Update config.example.json**

```json
{
  "deepseekKey": "sk-your-key-here",
  "hotkey": "fn",
  "practiceHotkey": "ctrl+opt+cmd+r",
  "whisperModel": "ggml-base.en",
  "snippetsPath": "~/.whisp/snippets.json",
  "pauseThresholdSec": 1.0,
  "silenceRMSThreshold": 0.06
}
```

- [ ] **Step 2: Add a Practice Mode section to README.md**

```markdown
## Practice Mode

Press `⌃⌥⌘R` to start a practice recording, press it again to stop. Pick what
you're practising from the prompt list that appears — the mic is already live,
so nothing is lost while you choose.

Recordings are saved to `~/.whisp/recordings/` as 16 kHz mono WAV, roughly
1.9 MB per minute, and **never leave your Mac**. Each session is transcribed
on-device and scored on pace (WPM), filler rate, pauses, and silence ratio.
Open the review window from the menu bar → **Practice…** to play a session
back, read the transcript, and see how your metrics on that prompt have moved
across attempts.

Edit the prompt list at `~/.whisp/prompts.json` and the counted filler words at
`~/.whisp/fillers.txt` (one per line, `#` for comments).

**A caveat on filler counts:** Whisper is trained to produce clean text and
drops some disfluencies. Whisp biases decoding toward verbatim output, but
absolute filler counts still run lower than reality. The bias is the same every
session, so the trend across attempts is trustworthy even where the absolute
number reads low.

Change the hotkey by editing `practiceHotkey` in `~/.whisp/config.json`
(e.g. `"ctrl+cmd+p"`) and relaunching. The dictation hotkey is Fn-only.
```

- [ ] **Step 3: Write the verification checklist**

Create `docs/practice-mode-verification.md`:

```markdown
# Practice Mode — Live Verification

Run after `./build.sh && open Whisp.app`. Everything here needs a real mic,
a real keyboard, and real speakers, so it can't be automated.

## Capture
- [ ] `⌃⌥⌘R` starts recording from any app; the HUD shows "Practice 0:0X" in amber with a moving waveform.
- [ ] The prompt picker appears immediately. Speak while choosing, then pick a prompt — the words spoken during selection ARE in the final transcript.
- [ ] `Esc` in the picker files the session as "Free-form".
- [ ] `⌃⌥⌘R` again stops it. The HUD switches to "Saved — transcribing…".
- [ ] A `.wav` appears in `~/.whisp/recordings/` immediately on stop, before transcription finishes.

## Non-interference (the critical one)
- [ ] While a 3-minute practice session is transcribing, hold **Fn** and dictate. Text appears at the cursor within a couple of seconds — it does NOT wait for the practice transcription to finish.
- [ ] Nothing from a practice session is ever pasted at the cursor.
- [ ] Dictation latency feels unchanged from before this feature.

## Results
- [ ] Menu bar → Practice… opens the review window.
- [ ] The session appears under the prompt it was filed against, with WPM / fillers / pauses.
- [ ] Play plays back the recording. Pressing Play on a second session stops the first.
- [ ] The envelope strip shows shaded bands where you actually paused.
- [ ] Delete removes the row AND the `.wav` from `~/.whisp/recordings/`.
- [ ] Record the same prompt three times; the trend line appears and moves.

## Calibrate silenceRMSThreshold
- [ ] Record a session with three deliberate 2-second pauses.
- [ ] Check the detected pause count in the review window.
- [ ] If pauses are missed, RAISE `silenceRMSThreshold` in `~/.whisp/config.json`. If pauses are invented mid-sentence, LOWER it. Relaunch and re-record.
- [ ] Once a value detects all three and invents none, put it in `Config.swift` as the new default and commit.

## Config
- [ ] Set `practiceHotkey` to `"ctrl+cmd+p"`, relaunch — the new chord works and `⌃⌥⌘R` no longer fires.
- [ ] Set it to garbage (`"banana"`), relaunch — Whisp logs the problem to `~/.whisp/whisp.log` and falls back to `⌃⌥⌘R` rather than losing the feature.
- [ ] Delete `practiceHotkey` from the file entirely, relaunch — the default is used and nothing crashes.

## Privacy
- [ ] With Coach Feedback never pressed, no network request carries anything from a practice session.
- [ ] Pressing "Get feedback" returns bullets and stores them on the session.
```

- [ ] **Step 4: Commit**

```bash
cd ~/whisp
git add README.md config.example.json docs/practice-mode-verification.md
git commit -m "docs: practice mode usage and live-verification checklist"
```

- [ ] **Step 5: Final full verification**

Run: `cd ~/whisp && swift test && swift build -c release --product Whisp && ./build.sh`
Expected: all tests pass, release build clean, `Whisp.app` produced.

Then hand `docs/practice-mode-verification.md` to Neil. Do not claim the feature works until he has run it — the harness cannot drive a microphone, and every claim about capture, playback, or hotkey behavior is unverified until he says otherwise.
