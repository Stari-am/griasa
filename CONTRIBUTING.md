# Contributing

This started as one person's tool and is public because the engineering in it is
worth reading. Patches are welcome. So is a fork — under GPL-3.0 you owe nobody
permission, and for something this opinionated a fork is often the honest answer.

Before writing code, please open an issue describing what you intend to change.
Not for ceremony: several parts of this app look arbitrary until you know which
measurement produced them, and an issue lets me point you at that before you
spend an evening.

## Build and check

```sh
./build.sh        # Griasa.app, signed locally, amber DEV icon
./test.sh         # the invariant checks
open Griasa.app
```

Both must be clean. **Zero warnings is the standard**, verified at deployment
targets 14.0, 15.0 and 26.0 — a warning here has already been a hard error once,
so they are not decoration. `swiftc` is used directly rather than SwiftPM so the
build works on a machine with only the Command Line Tools; `Package.swift`
describes the same build if you prefer `swift build`.

No dependencies. Swift, SwiftUI and Apple frameworks only. A pull request that
adds a package will be declined regardless of how good the package is — the whole
argument of this app is that it runs on your machine with nothing else involved.

## The rules a patch is most likely to break

**Every prompt lives in `Prompts.swift`.** All 14 of them. Reading that one file
tells you exactly what the app asks a model to do; inlining a prompt at a call
site takes that away. Runtime values are `{{named}}` placeholders, and an
unsupplied placeholder is deliberately left visible in the output rather than
blanked, so a mistake shows itself.

**Every model call goes through `AIFormatter.complete(system:user:tier:…)`** with
`tier: .fast` or `.smart`. No model names and no API keys at call sites. Six
providers sit behind that function, including two that answer through a CLI you
already subscribe to, and each new hardcoded model string breaks one of them.

**New UI is a hub tab, not a new window.** There are 12 tabs in
`HubWindow.swift`; add a case and a view. Only Settings, system dialogs and the
region-capture overlay live outside. A busy moment — recording a call while
setting a reminder — must stay one window rather than three fighting for focus.

**Background work never steals keyboard focus.** `HubController.open(tab,
activate: false)` exists for exactly that. The pre-meeting brief appears while
you are typing; if it takes focus it is worse than nothing.

**An invariant belongs in `Tests/StabilizerChecks.swift`, not in a comment.** A
comment cannot fail a build — this project shipped a regression that proved it,
where a refactor preserved a comment saying "append only, never rewrite" and
broke the rule underneath it. If your change relies on a rule, add a check.

**Failure messages state the reason.** Every check takes the rule as a sentence,
what it means for the person using the app, and what actually happened.
"Expected true, got false" tells whoever reads the failure nothing, and the
reader is usually not the person who wrote the check.

**Measure before designing around another app's behaviour.** The typing engine is
built the way it is because eight measurements across three applications
contradicted the documentation: one app declares its text field writable and
silently discards writes, another reports emoji as a placeholder character. The
harness is in the app — Settings → Dictation → *Typing reliability* — and its
output beats any reasoning about what should happen.

**Don't change the bundle identifier**, and don't replace the local signing
certificate casually. macOS keys privacy grants to the signature, so both cost
you and everyone testing your branch a fresh round of four permission dialogs.

**American spelling**, throughout code, comments and documentation. The mix was
cleaned up in one pass; please don't reintroduce it.

## Personal data

`transcripts/`, `*.caf` and `dist/` are ignored, and that is not tidiness. The
author's own copy of this app holds real recorded meetings with real colleagues.
When contributing:

- Never commit a screenshot taken against real data. Invent people and meetings.
  `Griasa --open <tab> --shoot out.png --size WxH` makes reproducible captures.
- Remember that names also live in **UserDefaults**, not only in the JSON files —
  the participant roster is stored there, and it appears in the People tab and the
  sidebar of nearly every screen. A screenshot taken after swapping only the JSON
  files still shows real colleagues. This has happened; check every image by eye
  before it goes anywhere.
- `~/Library/Application Support/Griasa/` holds history, commitments, people and
  projects. Back it up before running anything that writes there.

## Reporting a bug

The useful attachment is `~/Documents/Griasa Diagnostics/typing-trace.log`. It
records what the typing engine actually did — `NSLog` reaches nowhere at all from
an app launched by the Finder, which is why that file exists.

Include the app version (menu → About, or Settings → System), your macOS version,
and which provider is configured. For a typing problem, name the target
application: behaviour differs sharply between native AppKit apps and Electron
ones, and "it doesn't work in my editor" is not diagnosable without the editor.

## What is deliberately missing

Say so in an issue if you disagree, but these are choices rather than oversights:

- **No test framework and no CI.** `test.sh` compiles the unit under test with
  `swiftc` and exits non-zero. It runs on a bare machine and takes a second.
- **Swift 6 language mode is off.** Forcing it leaves one error and eighteen
  warnings that only surface once compilation gets past the typing session; that
  is its own project, not a cleanup.
- **No sandbox, so never the App Store.** The app drives other applications
  through the accessibility APIs and spawns `whisper-server`. Those are the
  features.
- **No licence keys.** Under GPL-3.0 anyone holding the source may legally remove
  such a check and share the result, so what is sold is convenience — signed,
  notarized, no toolchain — not access.

## Licence

Contributions are accepted under GPL-3.0, the same terms as the rest of the
project. By opening a pull request you agree your work ships under that licence.
