# Changelog

## 0.7.1 · 2026-10-24

- Keep note titles fully visible when reading long pages in compact windows.

## 0.7.0 · 2026-10-24

- Add a local SQLite notebook with dated Markdown pages, voice recording, audio playback, search, and export.
- Learn source-linked personal preferences and project context from notes, with edit, pause, and forget controls.
- Add a local stdio MCP connector for assistants to search and update the notebook.
- Keep original audio and transcripts when optional AI organization is unavailable.
- Use saved writing context for automatic polish, interpreted corrections, and AI snippets as well as explicit rewrites.
- Keep speculative polish and final dictation on the same context so exact-match reuse stays fast.
- Treat profile context as background for names and style, preserving the current dictation and avoiding unsolicited personal details.
- Document context reload behavior and which writing requests send it to OpenAI.

## 0.6.7 · 2026-10-23

- Remove the completion checkmark from dictation and practice.
- Fade the waveform away as soon as work finishes.

## 0.6.6 · 2026-10-23

- Make dark notifications smaller with tighter padding and typography.
- Dismiss short notifications after two seconds and longer guidance after 2.8 seconds.
- Use a quicker fade while preserving the recording indicator and recovery instructions.

## 0.6.5 · 2026-10-23

- Present dictation guidance in one compact charcoal notification matching Copilot and Replay Coach.
- Use a clear heading, useful recovery instructions, and a small status icon.
- Keep the speaking waveform transparent and restore it cleanly after a notification.

## 0.6.4 · 2026-10-23

- Replace the microphone orb with an audio waveform in cyan, blue, and violet gradients.
- Remove the background entirely, leaving only the floating waveform.
- Add a soft gradient glow that follows the waveform.
- React to speech and settle during silence, without a looping recording animation.
- Keep recording, processing, and polishing free of status text and microphone icons.
- Preserve readable errors, clipboard recovery, and focus-safe automatic paste.
- Respect Reduce Motion and stop animation when hidden.

## 0.6.3 · 2026-10-23

- Replace the recording label and wide waveform with a compact animated activity icon.
- Add a blue, cyan, and violet gradient, voice-responsive motion, and distinct
  listening, processing, polishing, practice, and success states.
- Keep actionable errors readable and distinguish practice failures from success.
- Respect Reduce Motion, stop animations when hidden, and keep the indicator
  click-through and unable to take keyboard focus.

## 0.6.2 · 2026-10-23

- Keep completed dictation and rewritten text on the clipboard for Command + V recovery,
  including when automatic insertion is blocked by a changed field or permissions.
- Preserve newer user copies and leave the clipboard alone for deletion or cancellation.
- Isolate synthetic paste shortcuts from the normal input state, release the simulated
  Command modifier, and allow physical mouse and keyboard input throughout.
- Ignore Whisp's own synthetic events in the Fn monitor.

## 0.6.1 · 2026-10-23

- Publish Whisp as open source under the MIT license, with third-party notices.
- Add current build instructions, a contribution guide, and a security policy.
- Document cloud data flow, plaintext local API-key storage, and additional speculative requests.
- Use generic defaults for new profiles while preserving existing user settings.
- Make local signing optional and configurable for source builds.

## 0.6.0 · 2026-10-23

- Prepare OpenAI writing from partial transcripts while Fn is held. Reuse completed
  or in-flight work only when the full prompt exactly matches the final transcript.
- Bound speculative requests, discard stale sessions, and keep partial text out of
  the document. Selection-dependent edits still require a final command and verified target.
- Finish text insertion as soon as Accessibility confirms the expected text and
  cursor, with a bounded fallback for unsupported fields.
- Keep streaming finalization ahead of local audio conversion and history work.

A short-audio development benchmark reached about 0.51 seconds from release to
polished text, compared with about 1.5 seconds without speculative polish. A separate
live microphone-to-cursor run took about 2.2 seconds. Results vary with audio,
network, provider response, and the destination app. Speculation can increase API usage.

## 0.5.0 · 2026-10-22

- Add a unified native workspace for dictation, recent history, corrections, snippets,
  practice, and settings, with light and dark appearances.
- Add automatic OpenAI polish for fillers, grammar, and rambling while preserving meaning.
- Expand natural editing commands for tone changes, targeted removals, and follow-up rewrites.
- Require an explicit selection for “remove this part,” and verify the target before editing.
- Keep required rewrites from replacing text when OpenAI returns an error or incomplete output.

## Earlier development

Earlier versions introduced hold-Fn dictation, local whisper.cpp recognition,
OpenAI streaming, voice snippets, local corrections, reviewed-example exports,
dictation history, and speaking practice with optional AI feedback. Older DeepSeek
credentials remain readable for configuration migration but are not used for requests.
