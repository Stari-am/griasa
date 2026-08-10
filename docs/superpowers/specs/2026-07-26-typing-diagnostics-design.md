# Typing diagnostics harness

**Date:** 2026-07-26
**Status:** approved

## Why

Live dictation typing is the first thing anyone evaluating Griasa will try, and
today it misbehaves in three visible ways: text flickers and gets mass-deleted
mid-utterance, characters go missing, and the post-release correction sometimes
overwrites what the user has since typed themselves.

A code read of the typing path (`DictationEngine.emitPartial` →
`AppState.handleLivePartial` → `LiveTyper.applyDiff`) turns up ten candidate
causes. Four of them are certain from the code alone; six depend on how the
*target application* behaves under synthetic events, which cannot be settled by
reading Griasa's source. Rewriting the engine on assumptions risks fixing the
wrong things and shipping a second broken design.

This spec covers only the measurement step. The engine redesign is a separate
spec, written from the numbers this harness produces.

## Candidate causes, and what needs measuring

Certain from code — no measurement needed, listed so the harness doesn't
duplicate work:

1. `DictationEngine.emitPartial` picks the active language leg by text length,
   so the English and Russian legs leapfrog mid-utterance and the diff's common
   prefix collapses to nothing.
2. `AppState.handleLivePartial` is dispatched via a fresh `Task { @MainActor }`
   per partial, and those tasks have no ordering guarantee.
3. `LiveTyper.applyDiff` diffs on common prefix only, with no common suffix and
   no word granularity, so a changed first word retypes the whole utterance.
4. Nothing verifies that focus and caret are still where the session started.

Unknown, and what the harness must answer:

| Question | Why it decides the design |
| --- | --- |
| At what inter-event pacing do apps stop dropping synthetic events? | Sets the floor for typing throughput, and whether live typing is viable at all in Electron apps. |
| Which apps actually accept Accessibility text writes? | Determines how large the atomic-replacement path can be versus the keystroke fallback. |
| Does the fixed 16-UTF-16-unit chunking in `LiveTyper.type` really corrupt surrogate pairs? | Confirms or kills candidate cause #5. |
| Does one synthetic Delete remove a grapheme cluster or a UTF-16 unit? | Decides what unit backspace counts must be computed in. |
| Do apps normalize typed text (NFC/NFD)? | A normalizing target makes Griasa's model of "what I typed" wrong by construction. |

## Approach

The harness lives inside Griasa rather than as a standalone CLI, for two
reasons. Accessibility is TCC-scoped per binary: Griasa already holds it, a new
unsigned CLI would not, and granting it is friction with no payoff. And
measurements must run through the same `LiveTyper` code the product uses —
a reimplementation would measure the reimplementation.

**Readback channel.** After each test the harness synthesizes ⌘A then ⌘C and
compares the pasteboard against what should have been typed. This works in
almost every target, including Terminal and Electron apps where Accessibility
reads are unavailable, which makes it the one channel usable across the whole
matrix. `SelectionGrabber.grab()` is unsuitable — it trims whitespace and maps
empty to `nil`, both of which destroy measurements — so the harness gets its own
byte-exact readback. The user's pasteboard is saved once at the start of a run
and restored once at the end.

**Trigger.** The user opens the Typing Test hub tab and presses Start, which
begins a five-second countdown. During it they switch to the target app and put
the caret in an empty text field. When the countdown reaches zero the harness
captures whatever is frontmost and runs the battery against it. Griasa never
activates itself during a run — the floating hub panel stays visible, so results
stream in while focus remains in the target.

## Components

`TypingDiagnostics` (new, `Sources/Griasa/TypingDiagnostics.swift`) — an
observable run controller holding the countdown, the result rows, and the report
path. Owns the battery and the byte-exact readback.

`TypingDiagnosticsView` (same file) — the hub tab: preflight checklist, Start
button, live result table, Copy report and Reveal buttons.

`LiveTyper` (modified) — gains paced, policy-parameterized variants:

```swift
enum ChunkPolicy {
    case fixedUTF16(Int)          // current shipping behaviour, boundary-blind
    case graphemeSafe(maxUnits: Int)  // never splits a grapheme cluster
}
static func typeBlocking(_ text: String, pacingMicros: UInt32, chunking: ChunkPolicy)
static func backspaceBlocking(_ count: Int, pacingMicros: UInt32)
```

The existing `type(_:)`, `backspace(_:)` and `applyDiff(from:to:)` signatures
and behaviour are left exactly as they are: the harness must be able to measure
today's shipping behaviour, and production call sites must not shift under this
change. The blocking variants are called from `Task.detached` so pacing uses
`usleep` — accurate at sub-millisecond scale, where `Task.sleep` is not — and so
posting never blocks the main actor.

## The battery

Every test clears the field with ⌘A + Delete before it runs, rather than
appending, so one test's failure cannot corrupt the next.

1. **Target identity** — app name, bundle id, PID, and the Accessibility role of
   the focused element. Informational.
2. **Accessibility probe** — can `AXValue` be read, can `AXSelectedTextRange` be
   read, is `AXSelectedText` declared settable, and does writing it actually
   land. Declared-settable and actually-works are reported separately, because
   they disagree in practice.
3. **Readback channel** — type a known marker and read it back. If this fails,
   tests 4–8 are reported as unmeasurable rather than as failures.
4. **Pacing sweep** — a 120-character ASCII sample at 8 ms, 3 ms, 1 ms, 500 µs
   and 0 µs pacing, slowest first so an early failure makes the threshold
   obvious. Reports exact match and Levenshtein distance per step.
5. **Unicode integrity** — Cyrillic, an emoji with a skin-tone modifier, a
   precomposed `é`, a decomposed `e` + combining acute, and CJK. Exact match is
   a pass; equal only after NFC normalization is a warning, since it means the
   target rewrites what Griasa typed.
6. **Chunk boundary** — 15 ASCII characters followed by an emoji, so the
   surrogate pair straddles the 16-unit boundary. Run under both chunk policies;
   the pair of results confirms or kills candidate cause #5.
7. **Backspace granularity** — type `ab😀` and `abé` (decomposed), send one
   Delete, and report whether a grapheme cluster or a UTF-16 unit was removed.
8. **ASR replay** — replay a realistic partial sequence (`привет` → `привет как`
   → `привет как дела` → polished `Привет, как дела?`) through today's
   `applyDiff` at realistic inter-partial delays, then compare the end state
   against the final string and record elapsed time. This is the end-to-end
   reproduction of the user-visible bug.

## Safety

The harness types into a real application, so: it refuses to run when
`IsSecureEventInputEnabled()` is true, keeping it out of password fields; the tab
states plainly that the target field must be empty and that its contents will be
cleared; and it clears rather than appends, so a mid-run abort leaves an empty
field instead of a half-typed mess.

## Output

Results render live in the tab and are written to
`~/Documents/Griasa Diagnostics/typing-<app>-<timestamp>.md`, with Copy report
and Reveal buttons. Running the battery across Telegram, Slack, Safari (both a
plain input and a `contenteditable`), Notes, Mail, Terminal, VS Code and TextEdit
produces the app × test matrix that the engine redesign is specified from.

## Out of scope

No change to `DictationEngine`, `AppState`, or the shipping behaviour of
`LiveTyper` — the four code-certain defects above are fixed in the redesign, not
here. Fixing them now would mean measuring an engine that is already changing.
