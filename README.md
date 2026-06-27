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

## Architecture

- `WhispCore` — pure logic (config, snippets, cleaner prompts, `SpeechPipeline`), unit-tested.
- `Whisp` — menu-bar app: AVAudioEngine recorder, vendored whisper.cpp transcriber,
  DeepSeek cleaner, paste inserter, Fn hotkey, floating HUD, SwiftUI managers.

## Test

```bash
swift test
```

## Roadmap (v2)

Format modes (email, bullets, code), dictation history, custom dictionary, multi-language.
