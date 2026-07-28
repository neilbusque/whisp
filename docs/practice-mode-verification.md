# Practice Mode — Live Verification

Run after `./build.sh && open Whisp.app`. Everything here needs a real mic,
a real keyboard, and real speakers, so it can't be automated. Nothing in this
document has been run. Every box is unverified until you check it yourself.

## Capture
- [ ] `⌃⌥⌘R` starts recording from any app; the HUD shows "Practice 0:0X" in amber with a moving waveform.
- [ ] The prompt picker appears immediately. Speak while choosing, then pick a prompt. The words spoken during selection ARE in the final transcript.
- [ ] `Esc` in the picker files the session as "Free-form".
- [ ] `⌃⌥⌘R` again stops it. The HUD switches to "Saved — transcribing…".
- [ ] A `.wav` appears in `~/.whisp/recordings/` immediately on stop, before transcription finishes.

## Interference (the critical one)

Practice Mode and dictation share **one** `AudioRecorder`, and neither path
guards against the other already being active. `AVAudioEngine` allows only one
tap per bus, so starting a second capture while one is running is expected to
raise a fatal AVFoundation exception and crash the app.

**This is a known, unfixed gap as of this commit.** It is not a surprise if it
happens. It is not something to work around by retrying. Try it deliberately,
in a session where a crash costs you nothing, so you know what it looks like
before you hit it by accident:

- [ ] Start a practice recording (`⌃⌥⌘R`), then, while it's still recording, hold **Fn** to dictate. Note what happens (expected: crash).
- [ ] Relaunch. Hold **Fn** to dictate, then, while still holding it, press `⌃⌥⌘R` to start a practice recording. Note what happens (expected: crash).

If either case does NOT crash, that's worth flagging, it means the failure
mode changed from what the code implies. Either way, until this is fixed,
treat Practice Mode and dictation as mutually exclusive in real use: don't
start one while the other might be running.

## Non-interference (transcription latency)
- [ ] While a 3-minute practice session is transcribing, hold **Fn** and dictate. Text appears at the cursor within a couple of seconds. It does NOT wait for the practice transcription to finish.
- [ ] Nothing from a practice session is ever pasted at the cursor.
- [ ] Dictation latency feels unchanged from before this feature.

(This section is about the background transcription step after a practice
recording has already stopped, a different scenario from the crash risk
above, where the practice mic is still open.)

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

**Filler counts will not move during this calibration, and that's expected.**
`silenceRMSThreshold` only affects pause detection: it has nothing to do with
how fillers are counted. Whisper drops disfluencies during transcription
regardless of this setting, so filler counts read low no matter where you land
the threshold. Don't chase filler accuracy by tuning this number, it isn't
the lever.

## Config
- [ ] Set `practiceHotkey` to `"ctrl+cmd+p"`, relaunch. The new chord works and `⌃⌥⌘R` no longer fires.
- [ ] Set it to garbage (`"banana"`), relaunch. Whisp logs the problem to `~/.whisp/whisp.log` and falls back to `⌃⌥⌘R` rather than losing the feature.
- [ ] Delete `practiceHotkey` from the file entirely, relaunch. The default is used and nothing crashes.
- [ ] Set `hotkey` (the dictation field) to something other than `"fn"`, relaunch. Whisp logs a warning to `~/.whisp/whisp.log` and dictation still runs on Fn.

## Privacy
- [ ] With Coach Feedback never pressed, no network request carries anything from a practice session.
- [ ] Pressing "Get feedback" returns bullets and stores them on the session.

---

Nothing above is confirmed working. This checklist exists because the build
and test harness cannot hold a microphone, press a physical key, or listen to
playback. Run it, then decide for yourself whether Practice Mode is ready to
use day to day, especially the interference gap above.
