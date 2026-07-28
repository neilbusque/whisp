# Whisp

Local-first voice dictation for macOS. Hold **Fn**, speak, and cleaned-up text is pasted
at your cursor in any app. Transcription runs on-device via whisper.cpp (CPU/Accelerate backend);
only the transcript text goes to DeepSeek for polish. Voice-triggered snippets expand a spoken
keyword into stored text (verbatim) or LLM-generated text (AI template).

## Setup

```bash
./scripts/setup-signing.sh    # one-time: persistent Mic/Accessibility grants
./scripts/fetch-whisper.sh    # vendor whisper.cpp + download ggml-base.en model
./build.sh && open Whisp.app
```

Then open **Settings…** from the 🎙 menu, paste your DeepSeek key, relaunch, and grant
Microphone and Accessibility.

## Use

- **Hold Fn**, speak, release → cleaned text at cursor.
- Say a snippet keyword (e.g. "bug report template") to expand it.
- **Edit Snippets…** / **Settings…** from the menu bar.

## Practice Mode

Press `⌃⌥⌘R` to start a practice recording, press it again to stop. Pick what
you're practising from the prompt list that appears. The mic is already live,
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

**A caveat on capture:** Practice Mode and dictation share one audio recorder.
Starting one while the other is already recording is refused and logged, not
crashed: holding Fn while a practice recording is running does nothing, and
pressing the practice hotkey while dictating shows "Finish dictating first"
instead of starting a second capture. Stopping whichever side is already
running is never blocked. See `docs/practice-mode-verification.md` to verify
this live.

Change the practice hotkey by editing `practiceHotkey` in `~/.whisp/config.json`
(e.g. `"ctrl+cmd+p"`) and relaunching. An unparseable value logs a warning to
`~/.whisp/whisp.log` and falls back to `⌃⌥⌘R`.

The dictation hotkey field (`hotkey`) is validated and Fn-only: any value other
than `"fn"` logs a warning to `~/.whisp/whisp.log` and falls back to Fn.

## Architecture

- `WhispCore`, pure logic (config, snippets, cleaner prompts, `SpeechPipeline`), unit-tested.
- `Whisp`, the menu-bar app: AVAudioEngine recorder, vendored whisper.cpp transcriber,
  DeepSeek cleaner, paste inserter, Fn hotkey, floating HUD, SwiftUI managers.

## Test

```bash
swift test
```

## Roadmap (v2)

Format modes (email, bullets, code), dictation history, custom dictionary, multi-language.
