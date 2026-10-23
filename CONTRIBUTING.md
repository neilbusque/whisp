# Contributing to Whisp

Bug reports, focused fixes, documentation improvements, and accessibility feedback
are welcome. For a substantial feature or change in behavior, open an issue first
so the scope can be discussed before implementation.

## Set up

Use macOS 13 or later with Swift 6 and Apple's Command Line Tools or Xcode.

```bash
git clone https://github.com/neilbusque/whisp.git
cd whisp
./scripts/fetch-whisper.sh
swift test -j 2
./build.sh
```

The fetch script downloads the local speech model and prepares the pinned
whisper.cpp source. OpenAI features require your own API key, but unit tests use
fake providers and do not need one. Do not put credentials in source files or test
fixtures.

For repeated local installs, use a signing identity you already own. Set
`WHISP_SIGNING_IDENTITY` for one build, or save the certificate name or SHA-1 with
`git config --local whisp.signingIdentity "Your signing identity"`. This setting
stays in your local checkout. Reusing an identity helps keep macOS permissions
consistent; changing it can require approving the app again.

## Make and verify a change

1. Create a branch and keep the change focused.
2. Add a regression test for behavior changes, especially command interpretation,
   edit targeting, cancellation, and audio boundaries.
3. Run `swift test -j 2`, then `./build.sh`. Run heavy checks sequentially on machines
   with limited memory.
4. For UI or recording changes, inspect the app and test the affected flow with
   synthetic text or a recording you are comfortable sharing.
5. Open a pull request describing the problem, resulting behavior, checks run, and
   any live paths you could not verify.

There is no separate lint command. Swift compilation checks types and concurrency;
`git diff --check` catches whitespace errors. Avoid unrelated reformatting.

## Use an isolated profile

Whisp normally writes to `~/.whisp/`. Use a temporary profile when testing so your
normal corrections, history, and settings stay separate:

```bash
profile_dir="$(mktemp -d -t whisp-test)"
open -n ./Whisp.app --args --data-dir "$profile_dir" --no-hotkeys --show-workspace
```

`--no-hotkeys` disables global shortcuts and launch-at-login changes. It does not
disable manual recording or network features. Keep your normal Whisp instance
closed when testing microphone capture or text insertion. Add `--appearance dark`
to inspect dark mode without changing the system setting.

Quit the test instance when finished and remove the temporary profile only after
checking that you no longer need its recordings. Never upload a profile containing
a real API key or private dictation. Replacing a locally signed build may require
refreshing Microphone or Accessibility permission in System Settings.

## Behaviors to preserve

- Local recognition and ordinary Fast cleanup must work without an OpenAI key.
- Cloud audio upload must remain an explicit recognition choice.
- Partial transcripts may prepare writing but must never edit the user's document.
- A speculative result is reusable only for the exact final prompt and active session.
- Follow-up edits must verify the target app, field, document, and cursor or selection.
- Failed or incomplete required rewrites must leave the target unchanged.
- Keep completed dictation on the clipboard even when automatic insertion fails.
  Never restore the older clipboard afterward or overwrite a newer user copy.
  Deletion and cancelled dictation must not clear the clipboard.
- Logs and tests must not expose credentials or personal dictation.

## Issues and security

For a bug, include your macOS version, Mac architecture, Whisp version, reproduction
steps, expected behavior, and actual behavior. Share a short synthetic example
instead of a private transcript. Remove secrets and personal information from logs
or screenshots.

Report vulnerabilities using the private process in [SECURITY.md](SECURITY.md), not
a public issue. Contributions are submitted under the project's [MIT license](LICENSE).
