# Whisp

**Hold Fn. Speak naturally. Release to write.**

Whisp is an open-source macOS dictation app with local speech recognition, optional
OpenAI streaming, automatic writing polish, and voice commands that edit text in place.
It lives in your menu bar and pastes into the focused text field.

Finished dictation also stays on your clipboard. If an app misses the automatic
paste or its text disappears, press **Command + V** to recover it. Copying something
else replaces that clipboard copy; **Copy Last Dictation** remains available in Whisp.

- **Fast dictation:** stream speech to OpenAI while you speak, or transcribe on your Mac with whisper.cpp.
- **Automatic polish:** remove fillers, fix grammar, and tighten rambling without changing your meaning.
- **Voice edits:** change tone, shorten a draft, remove a selected phrase, or correct yourself mid-sentence.
- **Personal vocabulary:** save recurring corrections and names without training a model.
- **Snippets:** expand a spoken keyword into saved text or an AI-generated template.
- **Speaking practice:** record locally, review transcripts, and track pace, fillers, and pauses.

[MIT license](LICENSE) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Build and run

Requirements:

- macOS 13 or later. Apple silicon is the tested platform.
- Swift 6 and Apple's Command Line Tools or Xcode. Check your toolchain with `swift --version`.
- An OpenAI API key for cloud recognition and AI writing. Local dictation does not require a key.

```bash
git clone https://github.com/neilbusque/whisp.git
cd whisp
./scripts/fetch-whisper.sh
./build.sh
open Whisp.app
```

The fetch script prepares whisper.cpp v1.7.4 and downloads the default Small English
model, about 466 MiB, into `~/.whisp/models/`. The build uses the CPU backend with
Apple Accelerate and bundles the model when present. Build concurrency defaults to
two jobs; set `WHISP_BUILD_JOBS` to change it.

This is a source release. The default build is locally signed, not an Apple-notarized
download. You can quit Whisp and move `Whisp.app` to Applications for everyday use.
Rebuilding or moving the app may require refreshing its macOS permissions.

## First launch

1. Open **Settings** from Whisp's menu bar or workspace.
2. Allow **Microphone** access for recording and **Accessibility** access for Fn and text insertion.
3. Choose your recognition and writing options, then **Save changes**.

| Setting | What it does |
| --- | --- |
| **On this Mac** | Recognizes audio locally with the installed Whisper model. |
| **OpenAI streaming** | Streams dictation audio while Fn is held. Requires your API key and internet access. |
| **Fast with spoken edits** | Cleans up ordinary dictation locally. Explicit rewrites and corrections that need interpretation use OpenAI. |
| **Automatic polish with OpenAI** | Polishes every dictation, with local cleanup as a fallback if writing fails. |

New profiles start with local recognition and Fast cleanup. For cloud dictation with
automatic polish, enter your own OpenAI key and select both OpenAI options. Current
defaults are `gpt-live-transcribe` for recognition and `gpt-4.1-nano` for writing.
API usage is billed to your OpenAI account.

Settings apply when Whisp is idle. Existing profiles are preserved, and older
DeepSeek credentials are not used for OpenAI requests. See
[`config.example.json`](config.example.json) for the configuration fields.

## Dictate and edit

Keep a text field focused, hold **Fn / Globe**, speak, then release. Wait for the
insertion to finish before starting the next recording. A recording stops after
five minutes.

| Say | Result |
| --- | --- |
| “Make this better: [your message]” | Rewrites the message you just dictated. |
| “Oh wait, make this more casual please” | Changes the tone of selected text or your last Whisp insertion. |
| “Make it shorter” | Shortens selected or recently inserted text. |
| “Oh wait, remove this part” | Deletes the text you have highlighted. |
| “Remove the part about the budget” | Uses AI to remove that part from the selected or recent text. |
| “Thursday, no, I mean Friday” | Resolves the correction in your dictation. |
| “[Earlier draft]. Start over: [new message]” | Discards the earlier draft in the same utterance and uses the new one. |
| “Start over: [new message]” | Replaces the selected text or last insertion with the new message. |
| “Delete the last word” or “delete the last sentence” | Edits the selected text or your last insertion. |
| “Start from Friday” | Keeps text from that phrase onward when the phrase is unique. |
| A saved snippet keyword | Expands the snippet. |

For follow-up edits, select the target or keep the cursor immediately after Whisp's
last insertion. Whisp checks the app, field, text, and cursor before replacing text.
Some apps do not expose enough Accessibility information for safe edits. Required
AI rewrites leave the target unchanged if the request fails or returns incomplete text.
Quoted or discussed commands are treated as words.

Open **Writing context** in the workspace or **Edit Writing Context…** in the menu bar
to describe your preferred style. This file is included with explicit AI rewrites.

## Speed

OpenAI recognition runs while you speak. With automatic polish enabled, Whisp also
prepares writing from partial transcripts. It reuses that work only when the entire
prompt exactly matches the final transcript's prompt. Preview text is never inserted.
Selection-dependent edits wait for the final command and a verified target.

This reduces the wait after Fn release when the final words are already available.
In a short-audio development benchmark, release-to-polished-text reached about
**0.51 seconds**, compared with about **1.5 seconds** without speculative polish.
A separate live microphone-to-cursor run took about **2.2 seconds**. These are examples,
not a latency guarantee: speech length, network conditions, provider response, and
the receiving app all affect the result.

Speculative polish can make additional OpenAI requests, including requests whose
results are discarded. It is capped at six attempts while speaking and two more
around release, followed by a final request if no matching result exists. Choose
Fast cleanup if you prefer to avoid automatic writing requests for ordinary dictation.

Local recognition starts after release. Smaller installed models favor speed; larger
models favor accuracy. The model stays loaded once used, and inference runs off the
UI thread. Text insertion finishes early when Accessibility confirms the expected
document and cursor, with a bounded wait for fields that cannot confirm it.

## Corrections, history, and snippets

Open **Whisp** from the menu bar for the Dictation, Recent dictations, Corrections,
Snippets, Practice, and Settings views.

In **Corrections**, enter what Whisp heard and the spelling you intended. Saved rules
apply locally to future dictations and supply recognition hints. They match whole
words, ignore case, tolerate extra spaces, and prioritize longer phrases. Replacements
do not cascade. Rules can be paused, removed, imported, exported, and undone.

Add names and terminology to `~/.whisp/vocabulary.txt`, one term per line. Put the
most important terms first because recognition hints have a limited budget. These
features correct recurring mistakes; they do not fine-tune Whisper's acoustic model.

Recent dictations keeps up to 100 entries by default. **Save voice examples** is off
by default and optionally retains audio with that same limit. Disabling history stops
future saves; remove existing entries separately. **Copy Last Dictation** remains
available in memory when disk history is off.

Dataset exports contain corrections and only examples you explicitly reviewed, with
their saved audio if available. Imports merge correction rules and do not import
example history. Review exports before sharing them.

Snippets can insert saved text verbatim or send a template plus your spoken details
to OpenAI. Edit them in **Snippets** or `~/.whisp/snippets.json`.

## Practice

Press **Control + Option + Command + R** to start or stop a practice recording, or use
the **Practice** view. Choose a prompt while recording. Dictation and practice share
one recorder, so finish one before starting the other.

Practice audio is saved locally as mono 16 kHz WAV, about 1.9 MB per minute. Whisp
transcribes it on your Mac and measures pace, filler rate, pauses, and silence ratio.
**Get feedback** is optional and sends the transcript, prompt title, and metrics to
OpenAI. Practice audio is not uploaded by this feature.

Whisper can omit disfluencies, so filler counts are estimates. Use them as one signal
alongside listening to the recording, not as exact counts of everything you said.

Customize prompts in `~/.whisp/prompts.json` and filler words in `~/.whisp/fillers.txt`.
Change `practiceHotkey` in the config and relaunch to use another shortcut. Dictation
currently supports Fn only; invalid hotkey settings fall back to their defaults.

## Privacy and local files

| Feature | What leaves your Mac |
| --- | --- |
| Local recognition and ordinary Fast cleanup | No audio or transcript is sent by these operations. |
| OpenAI streaming | Dictation audio and vocabulary hints go directly to OpenAI. |
| Automatic polish and interpreted corrections | Transcript text and relevant vocabulary go to OpenAI. Partial transcripts may be sent before release. |
| Explicit AI rewrites | Selected, recently inserted, or dictated target text, the instruction, writing context, and vocabulary go to OpenAI. |
| AI snippets | The template, dictated details, and vocabulary go to OpenAI. |
| Practice feedback | Transcript, prompt title, and speaking metrics go to OpenAI when requested. |

OpenAI handles API data under the terms and controls applicable to your account.
Whisp's writing requests set `store: false`; this is not a claim that all provider
retention is disabled.

Your profile lives in `~/.whisp/`:

- `config.json`: settings and your **plaintext API key**. Saving settings attempts to restrict this file to its owner. The key is not encrypted or stored in Keychain by Whisp.
- `context.md`, `vocabulary.txt`, `snippets.json`: writing preferences, terms, and templates.
- `learning.json`, `learning-audio/`: corrections and optional dictation examples.
- `recordings/`, `sessions.json`: practice recordings and reviews.
- `whisp.log`: bounded diagnostic logs that omit dictated text.

Do not commit or share your profile, recordings, exported datasets, or API key. See
[SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Development

```bash
swift test -j 2
./build.sh
```

- `WhispCore`: prompts, command parsing, corrections, metrics, and the speech pipeline.
- `WhispAudio`: audio conversion and streaming PCM support.
- `Whisp`: AppKit/SwiftUI workspace, recording, providers, hotkeys, and text insertion.
- `CWhisper`: whisper.cpp and ggml CPU integration.

Tests cover command routing, exact-match speculation, audio conversion, safe edits,
clipboard transactions, local persistence, and provider contracts with fake transports.
Live microphone and Accessibility behavior still need manual verification. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and isolated profiles.

Whisp is licensed under MIT. Third-party code and downloaded models retain their
respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
The app icon was generated with an image-generation tool;
source artwork is in `Resources/Whisp-icon.png`.
