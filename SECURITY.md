# Security

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/neilbusque/whisp/security/advisories/new)
for security issues. Do not put a vulnerability, API key, private transcript, or
recording in a public issue.

Include the affected version, macOS version, reproduction steps, likely impact,
and a minimal example using synthetic data. Do not send a working API key. If a
credential was exposed, revoke it with its provider.

Security fixes target the latest release and the default development branch.
Older versions may require upgrading. This is a community project; no response-time
or long-term support guarantee is offered.

## Data and permissions

Whisp needs Microphone access to record and Accessibility access to handle Fn and
insert or edit text. Follow-up edits check the target field and text before
replacement, but app compatibility varies.

The profile directory, normally `~/.whisp/`, can contain an OpenAI API key, dictated
text, writing context, corrections, and recordings. The API key is stored as
plaintext in `config.json`. Saving settings attempts to restrict this file to its owner;
Whisp does not encrypt this file or store the key in Keychain. Do not share the
profile or commit it to Git.

Local recognition and ordinary Fast cleanup do not send audio or transcripts to a
provider. OpenAI streaming sends captured dictation audio and vocabulary hints.
AI writing features send the relevant text and context. Automatic polish may send
partial transcripts while you are speaking, even if the resulting draft is later
discarded. Practice audio stays local; requested coaching sends the transcript,
prompt title, and metrics. See the [README privacy table](README.md#privacy-and-local-files)
for details.

Whisp's writing requests use `store: false`. Provider-side handling and retention
depend on the OpenAI account and applicable terms. Disabling local history stops
future saves but does not remove existing entries or provider-side data.

## Builds and dependencies

Current releases provide source. A default locally built app is not Apple-notarized.
The local recognition source is pinned to whisper.cpp v1.7.4; model files are
downloaded separately. Dependency updates should preserve license notices and be
reviewed alongside changes to recording, networking, and text insertion.
