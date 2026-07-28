# Whisp — Practice Mode Design Spec

**Date:** 2026-07-27
**Owner:** Neil Busque
**Status:** Approved design, pre-implementation
**Extends:** `2026-06-26-whisp-design.md` (v1 dictation)

A second capture path in Whisp for deliberate speaking practice. Press a global hotkey, pick a prompt, talk for as long as you like, press again to stop. The audio is saved locally, transcribed on-device, and scored on speaking metrics (words per minute, filler rate, pauses) so you can watch your delivery on a specific prompt improve across attempts.

Practice Mode is **parallel to**, not built on, the v1 dictation pipeline. It never pastes at the cursor and never runs the DeepSeek cleanup pass.

---

## 1. Goals

- **One hotkey to rehearse:** `⌃⌥⌘R` starts a recording, pressing it again stops it.
- **Local-only audio:** every recording stays on this Mac as a WAV under `~/.whisp/recordings/`. Audio never leaves the device, with no exception and no opt-in that changes it.
- **Prompt-anchored:** each session is tagged to a practice prompt you maintain ("Why should we hire you," the Niruron pitch), so metrics compare like with like.
- **Coaching metrics:** WPM, filler rate, pause count/length, speaking-vs-silence ratio, and a per-prompt trend across attempts.
- **Never blocks dictation.** Dictation is the daily driver at ~100×/day. Practice Mode must not add latency to it, regress it, or starve it.

## 2. Non-Goals (explicitly out of scope)

- **Script diffing** (comparing delivery against a memorized target script). Considered and cut; needs sequence alignment and is a separate feature.
- **Configurable dictation hotkey.** See §9 — `config.hotkey` stays Fn-only. Only `practiceHotkey` is genuinely parsed.
- **A keybinding-recorder UI.** Hotkeys are edited in `config.json`.
- **Auto-pruning old recordings.** Manual delete only, with a disk-usage readout.
- **Real-time/streaming feedback while speaking.** Metrics land after the fact.
- **Multi-language.** English, `ggml-base.en`, same as v1.
- **Pitch, tone, volume-dynamics or sentiment analysis.**

## 3. Key Decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Feature depth | **Capture + transcript + metrics** | Practice without a scoreboard stops after a week. |
| Hotkey | **`⌃⌥⌘R`, config-driven** | Two-modifier chords are all claimed (`⌥⌘R` collides in Chrome; `⌥⌘` bare is a prefix for dozens of shortcuts). `⌃⌥⌘` is effectively unclaimed by apps. |
| Hotkey mechanism | **Carbon `RegisterEventHotKey`** | Keycode-based and wholly separate from the Fn `CGEventTap`, so the two detectors cannot interfere. |
| Start/stop | **Press-to-start / press-to-stop** | A rehearsal runs minutes; hold-to-talk is wrong for it. |
| Practice shape | **Against a prompt library** | Anchors the trend to a specific answer. Fits the job hunt. |
| Cleanup pass | **None.** Raw Whisper output only | The DeepSeek polish strips fillers, which are the thing being measured. |
| Pause detection | **Audio RMS envelope, not Whisper segment gaps** | Segment boundaries aren't silence detection and drift. The envelope is more accurate, pure math (testable), and doubles as the review-UI waveform. |
| Long transcription | **Chunked at silence boundaries** | Solves lock starvation, progress reporting, and peak memory at once (§6). |
| LLM involvement | **Opt-in, per session, transcript only** | One "Coach feedback" button. Off by default. |

## 4. Architecture

Practice Mode follows v1's split: pure logic in `WhispCore` (unit-tested with Swift Testing), native I/O in `Whisp` (live-verified by Neil).

### New — `WhispCore` (pure, fully unit-tested)

| File | Responsibility |
|---|---|
| `PracticePrompt.swift` | `PracticePrompt { id, title, text, createdAt }`. Mirrors `Snippet`. |
| `PromptStore.swift` | Load/save/CRUD over `prompts.json`. Mirrors `SnippetStore`. |
| `SpeechMetrics.swift` | The math. Pure functions over transcript + segments + envelope → `SpeechMetrics`. |
| `PracticeSession.swift` | The session record and `TranscriptSegment` (§5). Codable. Lives in Core so both targets share the type. |
| `PracticeStore.swift` | Session index: append, load, delete, `trend(forPrompt:)`. |
| `AudioChunker.swift` | Splits samples into ≤30s chunks at silence boundaries using the envelope (§6). |
| `WavCodec.swift` | 16-bit PCM WAV encode/decode. Pure Foundation, so the round-trip is unit-testable. |

### New — `Whisp` (native, live-verified)

| File | Responsibility |
|---|---|
| `PracticeHotkey.swift` | Carbon `RegisterEventHotKey`; parses `"ctrl+opt+cmd+r"` → modifier mask + virtual keycode. |
| *(WAV writing lives in `WhispCore/WavCodec.swift`, not here — pure Foundation keeps it unit-testable. The AVFoundation-backed `WavReader` stays for importing arbitrary audio.)* | |
| `PracticeController.swift` | Orchestrates: start capture → stop → write WAV → enqueue transcription → compute metrics → persist. |
| `PracticeWindow.swift` | Prompt library, session list, session detail, playback, trend. |

### Modified

| File | Change |
|---|---|
| `WhisperTranscriber.swift` | Add `transcribeSegments(_:) -> [TranscriptSegment]` with timestamps enabled and filler-preserving params (§7). **`transcribe()` is left byte-for-byte unchanged** — dictation does not regress for this feature. |
| `AudioRecorder.swift` | Accumulate the existing RMS levels into a 20 Hz envelope; expose it from `stop()`. Dictation ignores it. The tap already fires every 1024 frames (~21 ms at 48 kHz); the envelope takes the **max** RMS within each 50 ms bin, so a brief loud syllable can't be averaged away into looking like silence. |
| `Config.swift` | Add `practiceHotkey` (default `"ctrl+opt+cmd+r"`), `pauseThresholdSec` (default `1.0`), `silenceRMSThreshold` (default `0.06`). |
| `Paths.swift` | Add `recordingsDir`, `sessionsFile`, `promptsFile`, `fillersFile` + first-run seeding. |
| `HUDWindow.swift` | Add a `practicing(elapsed:)` state — reuses `WaveformView`, visually distinct from dictation (amber, with an elapsed timer). |
| `AppDelegate.swift` | Register the practice hotkey; add a "Practice…" menu-bar item. |

## 5. Data Model

```
~/.whisp/prompts.json           practice prompt library
~/.whisp/sessions.json          session index (records + metrics)
~/.whisp/recordings/<uuid>.wav  16 kHz mono 16-bit PCM
~/.whisp/fillers.txt            editable filler list, one per line, # comments
```

`fillers.txt` follows the exact pattern already established by `vocabulary.txt` — one term per line, `#` comments, blanks ignored — so there's one convention to learn, not two.

```swift
struct PracticeSession: Codable {
    let id: UUID
    let promptID: UUID?          // nil = free-form
    let promptTitle: String       // denormalized; survives prompt deletion
    let startedAt: Date
    let durationSec: Double
    let audioFilename: String     // relative to recordingsDir
    let envelope: [Float]         // 20 Hz RMS, ~3600 floats for 3 min
    var status: SessionStatus     // .pending | .ready | .failed(String)
    var transcript: String?
    var segments: [TranscriptSegment]?
    var metrics: SpeechMetrics?
}

struct TranscriptSegment: Codable { let text: String; let startMS: Int; let endMS: Int }
```

**Ordering guarantee:** the WAV is written to disk and the session appended with `status: .pending` **before** transcription starts. A whisper crash, a quit, or a power loss can cost you a transcript — never the audio.

## 6. Metrics

All computed in `SpeechMetrics.swift` as pure functions.

| Metric | Definition |
|---|---|
| `wordCount` | Whitespace-split tokens in the raw transcript. |
| `speakingDurationSec` | Session duration minus **leading and trailing** silence only. Internal pauses stay counted — they are part of your delivery pace, and excluding them would hide the exact problem being measured. |
| `wpm` | `wordCount / (speakingDurationSec / 60)`. |
| `fillerCounts` | Per-term counts from `fillers.txt`, case-insensitive, word-boundary matched. Multi-word phrases ("you know", "sort of") supported. |
| `fillerRate` | Fillers per 100 words. The headline number. |
| `pauses` | Runs where the envelope stays below `silenceRMSThreshold` for ≥ `pauseThresholdSec`. Yields `pauseCount` and `longestPauseSec`. |
| `silenceRatio` | Total silent time ÷ session duration. |

**Trend:** `PracticeStore.trend(forPrompt:)` returns `wpm`, `fillerRate` and `pauseCount` for that prompt's sessions in chronological order. Rendered as sparklines.

### Chunked transcription

`whisper_context` is a single locked resource shared with dictation. A 3-minute practice clip held under that lock for 60 seconds would block every dictation you attempted meanwhile.

`AudioChunker` therefore splits the samples into chunks of ≤30s, cutting at the **quietest point** near each boundary (found via the envelope) so words aren't sliced in half. The transcriber takes the lock per chunk and releases it between chunks, so dictation interleaves with at most one chunk's delay. Segment timestamps are offset back into whole-session time as chunks are stitched. This also gives a real progress percentage for the UI and caps peak memory.

The chunk-boundary selection is pure math and is unit-tested; the interleaving behavior is live-verified.

## 7. Whisper Parameters for Verbatim Capture

**Known limitation, accepted.** Whisper is trained to emit clean readable text and actively drops disfluencies, so "um, I, uh, think" often transcribes as "I think." Practice Mode counters this with:

- `no_timestamps = false` (timestamps are required for segments)
- `suppress_non_speech_tokens = false`
- an `initial_prompt` containing a deliberately disfluent sample, biasing decoding toward verbatim

These recover much of it, not all. **Absolute filler counts will undercount reality.** The bias is consistent across sessions, so the *trend* remains honest even where the absolute number reads low, and the trend is what drives improvement. If verbatim fidelity later proves to be the whole point, the fix is a larger model or a dedicated VAD pass — a v2 conversation, not a v1 patch.

The dictation path is unaffected: it keeps its existing params, where filler suppression is desirable.

## 8. User Flow

1. `⌃⌥⌘R` → **the mic goes hot immediately** and the HUD appears with a prompt picker overlaid. Last-used prompt is preselected; `↩` confirms, `Esc` marks the session free-form. The picker only tags the in-flight session — it never gates recording, so nothing you say in the first two seconds is lost while you choose.
2. HUD shows the live waveform and an elapsed timer while you speak.
3. `⌃⌥⌘R` again → capture stops, WAV written, session appears in the list at once marked "Transcribing…".
4. Chunked transcription runs in the background; metrics fill in when done. Nothing is pasted anywhere at any point.

**Review window** (menu bar → Practice…): prompts on the left, that prompt's attempts on the right, detail pane showing playback with an envelope scrubber, the transcript with fillers highlighted, metric tiles, and per-prompt sparklines. Footer shows total recording disk usage with per-session delete (deleting a session deletes its WAV).

**Coach feedback** is a per-session button that sends *only the transcript text* to DeepSeek for qualitative critique, storing the response on the session. Off by default, never automatic. It is the only thing that ever leaves the device, and it reuses the existing `deepseekKey`.

## 9. Config

```json
{
  "hotkey": "fn",
  "practiceHotkey": "ctrl+opt+cmd+r",
  "pauseThresholdSec": 1.0,
  "silenceRMSThreshold": 0.06
}
```

`silenceRMSThreshold` is compared against the **already-scaled** value `AudioRecorder` produces (`min(1, sqrt(mean) * 4)`), not raw RMS. `0.06` is a starting point; the first implementation task that has real recordings to hand should sanity-check it against a session with known pauses and adjust the default.

`practiceHotkey` is genuinely parsed: `ctrl|control`, `opt|alt|option`, `cmd|command`, `shift`, plus one letter/digit, mapped to Carbon modifiers and a virtual keycode. An unparseable value logs a clear error and falls back to the default rather than leaving the feature silently dead.

**Deviation, stated plainly:** `hotkey` remains **Fn-only**. Making the dictation hotkey arbitrary means replacing the dual-detector Fn approach (`CGEventTap` + `NSEvent`, tuned across inconsistent Mac behavior) with a keycode path — real work that risks the daily driver for no requested benefit. Instead of staying silently dead, it is now **validated**: any value other than `"fn"` logs a warning and falls back to Fn. The wart is removed without endangering dictation.

Missing config keys take defaults, so existing `~/.whisp/config.json` files keep working untouched.

## 10. Testing

**`WhispCore` — Swift Testing, expected to cover:**

- WPM math, including the leading/trailing-silence trim
- Filler matching: case-insensitivity, word boundaries (`"like"` must not match `"likely"`), multi-word phrases, overlapping terms
- Pause detection at threshold boundaries; zero-pause and all-silence inputs
- `silenceRatio` and `speakingDurationSec` on synthetic envelopes
- Edge cases: empty transcript, silent recording, single word, sub-second session
- `PromptStore` and `PracticeStore` CRUD, plus `trend()` chronological ordering and prompt-deletion behavior (denormalized `promptTitle` survives)
- `AudioChunker`: boundary placement at quiet points, timestamp offsetting, single-chunk and shorter-than-one-chunk inputs
- `WavCodec` encode → decode round-trip, asserting sample fidelity within 16-bit quantization error
- Config decoding with missing keys; hotkey-string parsing including malformed input

**Live-verified by Neil** (the harness cannot drive these): hotkey firing globally across apps, mic capture, HUD states, audio playback, window chrome, and confirmation that dictation still fires instantly while a practice transcription runs.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Whisper suppresses fillers, gutting the headline metric | §7 params; trend-over-absolute framing; escalate to a larger model in v2 if it proves insufficient |
| Long transcription starves dictation | Chunked transcription with lock release between chunks (§6) |
| Disk growth (~1.9 MB/min) | Disk-usage readout + manual delete; no silent auto-prune |
| `⌃⌥⌘R` collides with something installed later | `practiceHotkey` is editable in `config.json`; no rebuild needed |
| Practice work regresses dictation | `transcribe()` untouched; separate hotkey mechanism; separate pipeline; dictation re-verified live before shipping |
