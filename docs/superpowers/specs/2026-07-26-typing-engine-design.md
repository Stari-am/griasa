# Live-typing engine redesign

**Date:** 2026-07-26
**Status:** approved
**Built on:** `2026-07-26-typing-diagnostics-design.md` and three runs of that harness

## What the measurements changed

The first design for this work assumed the transport was the problem: that
synthetic keyboard events were being dropped at speed, and that an
Accessibility-authoritative editing path was needed to know the target's real
state. The harness refuted both.

- **Event loss is not real.** 120 of 120 characters landed at every pacing —
  8 ms, 3 ms, 1 ms, 500 µs and no delay at all — in Telegram, Slack and
  TextEdit. Pacing does not belong in the production path.
- **The full retype is cheap and correct.** Replaying a realistic partial
  sequence and then the polished correction sent 15 backspaces plus 17
  characters, completed in 0.00 s, and left the right text in all three apps.
- **Accessibility can't be the authority.** `AXSelectedText` writes land only in
  TextEdit. Telegram declares the attribute read-only; Slack declares it
  settable and then does nothing. Worse, `AXValue` isn't a faithful mirror of a
  rich composer: Telegram reports emoji as U+FFFC, Slack as newlines, and both
  NFC-normalize. A design that reads Accessibility to validate its own model of
  the text cannot work in the two apps that matter most for dictation.

One transport defect was confirmed, and it is decisive: chunking on a fixed 16
UTF-16 units split a surrogate pair in Telegram into U+FFFD and dropped the four
characters that followed it. Grapheme-safe chunking fixed it.

A second was confirmed but matters less than claimed: one Delete removes a
UTF-16 unit in Telegram and Slack, and a whole grapheme cluster in TextEdit. A
character-based backspace count therefore under-deletes in the chat apps,
leaving fragments behind. But units and characters are identical for all-BMP
text — Latin, Cyrillic, punctuation — so this only bites on emoji and combining
marks, which ASR output essentially never contains. Not worth per-app
calibration; worth knowing about for snippet and AI-generated text.

So the transport needs one fix, and the real defects are in the layers above it.

## The actual defects

All four are certain from the code, and none of them are measurable from
outside — which is why the harness came back clean on a feature the user
describes as losing text.

1. **Language legs leapfrog.** `DictationEngine.emitPartial` picks the active
   recognizer by text length on every partial. The English and Russian legs
   overtake each other mid-utterance, the diff's common prefix collapses to
   nothing, and the whole line is deleted and retyped. This is the flicker.
2. **Partials are applied out of order.** `AppState.bootstrap` dispatches each
   partial in a fresh `Task { @MainActor }`, and those have no ordering
   guarantee. Once two are transposed, `liveInserted` no longer describes what
   is in the field, and every later diff is computed against a fiction.
3. **The final correction rewrites everything.** `LiveTyper.applyDiff` diffs on
   common prefix alone, so an AI pass that changes the first word's
   capitalization retypes the utterance. Harmless in isolation (measured), but
   it is the mechanism by which the next defect destroys text.
4. **Nothing notices the user.** The correction lands seconds after the hotkey
   is released — after Whisper and the AI pass — with no check that focus is
   still in the same app or that the user hasn't started typing. That is the
   reported "corrected text overwrites what I'm typing".

## Design

Three layers. No Accessibility path: it is dead in Telegram and Slack, and
unnecessary in TextEdit.

### PartialStabilizer — makes the stream safe to type

A struct owned by `DictationEngine`, mutated only on its `stateQueue`. Turns the
recognizers' unstable output into a monotonically growing string.

Two rules carry it. **Leg locking:** the leading leg is locked once it has
produced 10 characters, after which the other language's recognizer can no
longer take over. Below that threshold a switch costs a few characters, so it
stays free. **Word freezing:** a word stops being rewritable once two more words
follow it. A later partial that revises an early word is ignored rather than
replayed as delete-and-retype.

The output can still shrink, but only within the unfrozen tail — at most the
last two words. That is where genuine corrections happen, so the flicker becomes
bounded and meaningful instead of whole-line.

`absorb(legs:)` returns nil when nothing changed, which also replaces the
existing `lastPartialSent` dedup.

`finish()` keeps choosing the final transcription by recognition confidence
rather than the locked leg: accuracy of the final text matters more than
agreeing with what was typed live, and the retype that a disagreement causes is
measured as harmless.

### TypingSession — serializes edits and defends the user's text

Owns what production currently keeps in `AppState.liveInserted`.

**Ordering** is fixed by making submission thread-safe and order-independent
rather than by trusting task scheduling. `submit(_:)` is `nonisolated`, appends
under a lock, and schedules a drain. The drain takes the *last* queued value and
clears the queue — safe because the stabilizer guarantees monotonic growth, and
strictly cheaper, since a burst of partials collapses into one edit. Order can
no longer be lost because it is carried by the array, not by the scheduler.

**Interference** is detected two ways. The frontmost application's PID is
snapshotted at `begin()` and re-checked before every edit, which covers app
switching completely. A global `NSEvent` monitor for `.keyDown` and mouse-down
covers the user acting inside the same app; Griasa's own synthetic events are
excluded by tagging them (see below). Modifier keys arrive as `.flagsChanged`,
so holding the dictation hotkey is not mistaken for typing.

On interference the session is **abandoned**: no further live edits, and the
final correction does not run. Whatever the user has is left exactly as it is,
and `SnippetHUD` says so. The polished text still reaches History, so nothing is
lost — it just isn't forced into a document that has moved on. Overwriting
someone's typing to deliver a better transcript is not a trade worth making.

`finish(with:)` returns one of three outcomes so `AppState` knows what to do:
`corrected` (the in-place replacement ran), `keptAsTyped` (abandoned — leave the
text alone), `nothingTyped` (live typing was off or produced nothing, so paste
the polished text as before).

### LiveTyper — one transport fix, one new obligation

`type(_:)` switches to grapheme-safe chunking, which is the confirmed fix for
the surrogate-pair loss. The measured-irrelevant pacing is not added.

Every event Griasa posts is tagged by setting `userData` on the `CGEventSource`,
readable back through `CGEvent`'s `.eventSourceUserData` field. Without this the
interference monitor would see Griasa's own typing and abandon every session
immediately. An event whose `cgEvent` is nil is treated as ours; the PID guard
remains as the independent check.

Undo grouping is dropped from the plan. It was in the first design, and it is
not achievable for another process through synthetic events — claiming otherwise
was wrong. Fewer events is the only lever available, and coalescing provides it.

## Files

| File | Change |
| --- | --- |
| `PartialStabilizer.swift` | new — leg locking, word freezing, monotonic output |
| `TypingSession.swift` | new — ordered submission, interference guard, outcome API |
| `LiveTyper.swift` | grapheme-safe by default; tag posted events |
| `DictationEngine.swift` | `emitPartial` delegates to the stabilizer; drop `lastPartialSent` |
| `AppState.swift` | route partials and the correction through the session; drop `liveInserted` and `handleLivePartial` |

## Verification

The harness cannot see any of this — it measures the transport, which was
already sound. Verification is behavioural, in Telegram and Slack: dictate a
long bilingual phrase and watch for mid-utterance mass deletion (defect 1);
dictate while the AI pass is slow and start typing before the correction lands,
then confirm the typed text survives and the HUD explains why (defect 4). The
chunking fix is already verified by the harness — re-running it in Telegram
should turn the fixed-16 failure into a pass for the shipping path.

## Out of scope

No Accessibility editing path. No pacing. No per-app backspace calibration —
the granularity difference only affects emoji and combining marks, which
dictation does not produce.
