# Whisp — Design Spec

**Date:** 2026-06-26
**Owner:** Neil Busque
**Status:** Approved design, pre-implementation

A local-first voice dictation app for macOS, in the spirit of Wispr Flow / Blip AI. Hold a key, speak, and cleaned-up text is pasted at your cursor in any app. Audio is transcribed fully on-device; only the transcript text is sent to an LLM for polish. Includes voice-triggered snippets (long stored prompts/templates expanded by a spoken keyword).

---

## 1. Goals

- **Dictate anywhere:** hold a hotkey, speak, release → cleaned text drops in at the cursor of the focused app.
- **Local transcription:** audio never leaves the Mac (privacy is the point — dictation captures everything you say).
- **Smart cleanup:** strip filler ("um/uh"), fix grammar, add punctuation, format.
- **Voice snippets:** speak a keyword to expand a long stored prompt/template — either verbatim or AI-generated from it.
- **Fast enough for 100×/day use.**

## 2. Non-Goals (v2, explicitly out of v1)

- Format modes (Email / Bullets / Code / Raw) — architecture left ready, not built.
- Dictation history list.
- Custom dictionary / vocabulary correction.
- Multi-language (v1 is English; default model `ggml-base.en`).
- Streaming partial results during recording.
- Any GitHub remote / cloud sync / multi-machine.

## 3. Key Decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| STT engine | **Local `whisper.cpp`** | Private, offline, free. Audio stays on device. |
| Whisper integration | **Vendored source, compiled via SwiftPM with Metal, model warm-resident in RAM** | Fastest (~0.5–1s/sentence), no per-call model reload. Keeps "no fetched deps." |
| Cleanup engine | **DeepSeek cloud** (`deepseek-chat`, OpenAI-compatible SSE) | Proven in Neil's stack; smartest cleanup; only transcript text (not audio) leaves device; ~$0.0001/dictation. |
| Snippet behavior | **Both modes** — verbatim paste OR AI-template generation, tagged per snippet | Covers boilerplate and dynamic generation. |
| Trigger UX | **Hold-to-talk** (Fn default, configurable) | Walkie-talkie; no risk of leaving mic open. |
| v1 extra | **Floating HUD only** | Cheap, big UX win. Other extras deferred. |
| App name | **Whisp** | bundle `com.busqueneil.whisp`, repo `~/whisp`, config `~/.whisp/`. |

## 4. Architecture

Mirrors the proven Cockpit Copilot / FlowBar pattern.

- **Swift 6**, **Command Line Tools only** (no Xcode.app), SwiftPM. No *fetched* package dependencies; `whisper.cpp` is **vendored source** in-repo, compiled as a C/C++ target.
- **Two SwiftPM targets:**
  - `WhispCore` — pure logic, no UI/AV. Fully unit-tested (Swift Testing).
  - `Whisp` — executable. AppKit/SwiftUI/AVFoundation menu-bar app, `LSUIElement` (no Dock icon).
- `build.sh` → `Whisp.app`, ad-hoc-or-self-signed. A **self-signed cert** in a dedicated keychain (Cockpit Copilot's trick) makes Microphone + Accessibility grants persist across rebuilds instead of re-prompting.
- Repo `~/whisp`, local git, **no GitHub remote** (FlowBar-style local install).
- Config `~/.whisp/config.json` (gitignored; `config.example.json` committed): `deepseekKey`, `hotkey`, `whisperModel`, `snippetsPath`.
- Snippets `~/.whisp/snippets.json` (gitignored; seeded with examples on first launch).

### 4.1 Module boundaries

| Module | Target | Does | Depends on |
|---|---|---|---|
| `Config` | Core | Load/save/validate `config.json`; defaults | Foundation |
| `SnippetStore` | Core | Load/save snippets; match spoken keyword to a snippet; classify verbatim vs ai-template; normalize keywords | Foundation |
| `TranscriptCleaner` | Core | Build the DeepSeek polish prompt; parse response; strip filler as a fallback if offline | (no network in Core — see note) |
| `DeepSeekClient` | App | HTTP/SSE call to DeepSeek; injected into cleanup flow | Foundation/URLSession |
| `SpeechPipeline` | App | Orchestrates: record → transcribe → (snippet? → expand) → clean → insert; drives HUD state | all below |
| `HotkeyMonitor` | App | CGEventTap on Fn (`maskSecondaryFn`); hold = record, release = stop; configurable fallback key | Carbon/CoreGraphics |
| `AudioRecorder` | App | AVAudioEngine capture → 16kHz mono Float/WAV buffer in memory | AVFoundation |
| `Transcriber` | App | Swift wrapper over vendored `whisper.cpp` C API; loads model once, keeps `whisper_context` resident; transcribes a buffer | whisper.cpp (C target) |
| `Inserter` | App | Save current pasteboard → set text → synthesize ⌘V → restore pasteboard | AppKit/CoreGraphics |
| `HUDWindow` | App | Borderless `NSWindow` near bottom-center; states idle/listening(+mic level)/polishing/done/error | AppKit/SwiftUI |
| `MenuBarController` | App | Status item: open Snippets manager, Settings, Quit | AppKit |
| `SnippetsManagerView` | App | SwiftUI window to add/edit/delete snippets and set mode | SwiftUI |

> **Core-vs-App network note:** `TranscriptCleaner` (Core) builds the prompt and parses/validates responses (testable, pure). The actual network call lives in `DeepSeekClient` (App) and is injected as a closure/protocol, so Core stays network-free and unit-testable.

## 5. Data Flow

```
Hold Fn ─► AudioRecorder starts (HUD: listening, mic level)
Release Fn ─► AudioRecorder stops → 16kHz mono buffer
   └─► Transcriber.whisper(buffer) → raw transcript        [on-device]
        └─► SnippetStore.match(rawTranscript)
             ├─ verbatim match  → expanded text = stored text (skip LLM)
             ├─ ai-template match → DeepSeek(prompt=template + surrounding dictation) → text
             └─ no match         → DeepSeek(polish prompt, rawTranscript) → cleaned text   [HUD: polishing]
                  └─► Inserter.paste(text) at cursor          [HUD: done → fade]
```

- **Offline / DeepSeek failure:** fall back to `TranscriptCleaner` local filler-strip + capitalization, insert that, HUD shows a subtle "offline" note. Never lose the user's words.
- **Empty/failed transcription:** HUD shows error, nothing pasted, prior clipboard untouched.

## 6. Snippets

`snippets.json` schema:
```json
[
  {
    "id": "uuid",
    "keyword": "bug report template",
    "mode": "verbatim",        // "verbatim" | "ai"
    "content": "## Bug Report\n**Steps:**\n...",
    "enabled": true
  },
  {
    "id": "uuid",
    "keyword": "cold email",
    "mode": "ai",
    "content": "Write a short, friendly cold email. No em dashes. 70-110 words..."
  }
]
```
- **Matching:** spoken transcript is normalized (lowercased, punctuation/whitespace collapsed). A snippet fires when the transcript *starts with* or *equals* the normalized keyword (start-anchored to avoid accidental mid-sentence triggers). The remainder after the keyword is the "surrounding dictation" passed to AI-template mode.
- **verbatim:** paste `content` exactly. No LLM call.
- **ai:** DeepSeek prompt = `content` (the instruction) + the remainder of what was said. Output pasted.
- Managed in `SnippetsManagerView`; seeded with 2 examples on first launch.

## 7. Permissions

One-time, made persistent by the self-signed signing cert:
- **Microphone** — recording.
- **Accessibility** — global Fn capture (CGEventTap) and synthesized ⌘V paste.

`build.sh` sets up/uses the signing keychain so these don't re-prompt on every rebuild.

## 8. Hotkey detail

- Default: **Fn** via `CGEventTap` watching `flagsChanged` for `maskSecondaryFn` (Fn is not a Carbon `RegisterEventHotKey` modifier).
- Hold = recording on; release = stop + process.
- **Configurable fallback** (`config.json`): a standard key/combo (e.g. Right-Option) for users who remap Fn or whose keyboard lacks it. Implemented via the same event tap or Carbon hotkey as appropriate.
- Debounce: ignore <150ms taps (accidental).

## 9. Text insertion

- `Inserter`: read & stash current `NSPasteboard` contents (all types where feasible, else string) → write the result string → post synthesized **⌘V** via CGEvent → after a short delay, **restore** the stashed contents.
- Rationale: paste is faster and more reliable than per-character key synthesis, and handles Unicode/emoji/newlines. Clipboard save/restore keeps the user's clipboard intact.
- Edge: if Accessibility not granted, HUD prompts to grant; nothing pasted.

## 10. Build & Run

- `./build.sh` → compiles `whisper.cpp` (Metal), builds both targets, assembles `Whisp.app` (LSUIElement, bundle id `com.busqueneil.whisp`), copies default model into Resources (or references `~/.whisp/models/`), signs with the self-signed cert.
- First run: prompts Mic + Accessibility, seeds `~/.whisp/config.json` + `snippets.json`, downloads/locates default model `ggml-base.en` if absent.
- `Whisp.app/` gitignored.

## 11. Testing

`WhispCore` (Swift Testing) unit tests — the testable surface:
- `SnippetStore`: keyword normalization; start-anchored match; verbatim vs ai routing; remainder extraction; enable/disable; load/save round-trip.
- `TranscriptCleaner`: polish-prompt construction; response parsing; offline filler-strip + capitalization fallback.
- `Config`: defaults, load/save, validation of missing keys.
- `Inserter` clipboard save/restore logic (pure parts; the CGEvent post is exercised live).

GUI / audio / hotkey / Whisper-on-Metal / paste-at-cursor / TCC grants are **verified live by Neil** (the harness can't drive the mic, Accessibility, or focused-app insertion) — same constraint as Cockpit Copilot.

## 12. Risks / Open items

- **Metal whisper.cpp build via SwiftPM CLT-only** — the one piece with real build complexity (.metal shader compilation, Objective-C++ bridging). Mitigation: if the Metal/SwiftPM build proves painful, fall back to the bundled-binary approach (decision B) without changing any other module — `Transcriber` is the only affected unit.
- **Fn key capture reliability** across keyboards — mitigated by the configurable fallback key.
- **Model size / first-run download UX** — default to `base.en` (~150MB); document `small`/`medium` swap in config.
- **DeepSeek latency on the polish step** — acceptable (~300–800ms); verbatim snippets and offline fallback skip it.

## 13. v1 Definition of Done

Hold Fn → speak → cleaned text appears at cursor in TextEdit / a browser / Slack; a spoken verbatim keyword expands exactly; a spoken ai keyword generates tailored text; HUD reflects each state; clipboard is preserved; Mic+Accessibility granted once and persist across a rebuild; `WhispCore` tests green; `./build.sh` clean.
