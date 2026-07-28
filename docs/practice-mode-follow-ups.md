# Practice Mode: known follow-ups

Everything here was found during code review of the Practice Mode branch and
deliberately deferred. None of it loses audio. Ordered by what would bite first.

## Worth doing soon

**`sessions.json` is written non-atomically and resets to empty when corrupt.**
`PracticeController.persist()` writes without `.atomic`, and `AppDelegate` loads
with `try?` falling back to an empty store. Kill the app or fill the disk
mid-write and the file truncates; on next launch the decode error is swallowed,
the store starts empty, and the first `persist()` overwrites the damaged file
with `[]`. Session history is gone permanently. The WAVs survive as orphaned
UUIDs with no index and no way to reach them from the UI, while still counting
toward the disk-usage readout. Fix: write with `.atomic`, and on decode failure
rename to `sessions.json.corrupt-<timestamp>` and log loudly instead of starting
empty.

**A session interrupted mid-transcription stays `.pending` forever.**
Quit while a transcription is running and nothing at launch re-drives it. The
review window shows "Transcribing…" permanently for a session that never will,
and the only affordance is Delete, which also destroys the audio. Fix: at store
load, rewrite `.pending` to `.failed("interrupted")`, and add a Retry button.
The WAV and `WavCodec.decode` are both already there.

**A wrong-typed value in `config.json` silently blanks the DeepSeek key.**
`decodeIfPresent` throws on a present-but-wrong-*type* key, so
`Paths.loadConfig()` propagates, `AppDelegate` catches and falls back to
`WhispConfig.defaults`, which has an empty `deepseekKey`. Dictation keeps
working but quietly degrades to the offline cleaner with no visible signal.
`"pauseThresholdSec": "1.0"` is exactly the typo a human makes, and the README
now tells you to hand-edit this file. Cheapest fix: surface config-load failure
in the menu-bar title, matching the existing model-error pattern.

**`recordingsDiskBytes()` runs a full directory stat sweep inside SwiftUI `body`.**
Every selection change and every reload re-stats the whole recordings directory,
synchronously on the main actor. There is no auto-prune by design, so that
directory grows without bound. Fix: compute once in `reload()` into `@State`.

## Smaller

- **No prompt CRUD in the UI.** `PromptStore.upsert`/`delete` exist and are
  tested; `PracticeController.savePrompts()` is never called. The sidebar is
  read-only and prompts are edited by hand in `~/.whisp/prompts.json`. Either
  wire it up or drop `savePrompts()`.
- **Two competing durations.** `session.durationSec` is wall-clock from the
  hotkey press; `metrics.durationSec` is `envelope.count * binSeconds`. They
  disagree by the engine-start latency. Pick one.
- **A failed chunk discards the whole transcript.** Whisper failing on chunk 3
  of 5 throws away chunks 1 and 2. A partial transcript would beat none.
- **Deleting a WAV outside the app gives no feedback.** Play logs to
  `whisp.log` and does nothing visible.
- **`ObjectIdentifier` pointer-reuse in the playback finish guard.**
  `SessionPlayer.audioPlayerDidFinishPlaying` compares `ObjectIdentifier`s
  rather than holding a strong reference, so in principle a freed player's
  address could be reused by a new one and cause a false match. Requires a
  human-timescale click to race one queued main-actor hop plus an allocator
  address reuse in that instant. Capturing the player strongly would remove the
  hazard structurally.
- **`silenceRMSThreshold: 0.06` ships uncalibrated.** It is the input to speech
  bounds, so it moves WPM, speaking duration, silence ratio and pause counts:
  three of the four metric tiles. Run the calibration section of
  `practice-mode-verification.md` before trusting any number.

## Testability note

`PracticeController` holds the feature's headline durability guarantee, that the
WAV is written before the session is appended, and it has no automated coverage
because it reaches `Paths` (hardcoded `~/.whisp`) directly. Injecting a base
directory or a small storage protocol would make the ordering guarantee, the
disk-full branch and the corrupt-index branch all unit-testable. Everything else
uncovered here (AppKit, microphone, Carbon, SwiftUI) is genuinely untestable in
this harness.
