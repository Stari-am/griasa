# Changelog

## 1.0.2 — 2026-08-13

**A person's name can be corrected.** Names are typed in a hurry, in the question
that appears the moment a recording stops — so typos happen, and until now one was
permanent: nothing could change it, and the misspelling was offered again after the
next call. The pencil beside the name on a person's page now fixes it in the four
places a name is stored: the page, the participant list of every meeting they were
on, the owner of their promises, and the remembered roster. It is all four at once
because the only thing joining them is the name itself — rename in one and the page
loses its meetings while the old spelling comes back next week.

Recorded transcripts keep the original spelling. A transcript is a record of what
was said, and rewriting it would make the notes disagree with the audio they came
from. Renaming onto a name that already exists is refused rather than merged: two
people becoming one means deciding what happens to two sets of notes and two
dossiers, which is your decision, not the app's. Changing only case or spacing is
allowed, since that is the most common correction of all.

**The rules live typing must never break are now checked, not described.** `./test.sh`
replays recognizer hypotheses and fails if emitted text ever stops growing, if a
hypothesis that re-worded the start of an utterance extends its end, or if the
language leg stops holding. Two of those were regressions that actually shipped in
earlier builds. `release.sh` runs the checks before it will build anything, so a
broken invariant costs a second instead of two notarization round trips — this is
the first release that had to pass them.

## 1.0.1 — 2026-08-11

**Meeting notes read as notes.** The detail pane was printing its own source —
`## Summary` and `**Dana**` instead of a heading and a name. Headings, bullets,
quotes and emphasis now render. Copy and Export still hand over the Markdown,
which is what Notion, Obsidian and git want.

**The history list is scannable again.** Every meeting's preview line read
"## Summary", so the column you scan by said the same thing on every row. It now
shows the first line that carries content. History also opens on your newest
entry instead of an empty pane asking you to click first.

**The transcript mirror folder no longer defaults to somebody else's directory.**
1.0 shipped with `~/work/wispr/transcripts` as the default — the author's own
path, under the project's former name. The setting is now *Transcript mirror
folder* (Settings → Folders) and is **empty by default**: copying your meeting
notes to a second location should be something you ask for. If you set your own
path, it is untouched.

**New: `--open <tab>` and `--shoot <path>`.** `Griasa --open commitments` opens
that tab directly; `--shoot out.png --size 1280x880` saves a picture of it and
quits. For documentation, and for saying which screen you mean.

## 1.0 — 2026-08-10

First public release. [Download](https://github.com/Stari-am/griasa/releases/latest) —
signed with a Developer ID, notarized by Apple, universal (Apple silicon and Intel).

**Dictation.** Hold a key and talk; the words appear in whatever app has focus,
while you are still speaking, and are replaced once by a polished version on
release. Speech recognition is local — Apple's recognizer or `whisper.cpp`
(large-v3-turbo, installed on first launch). Two or three languages run as
parallel recognition legs and the winner is locked in for the utterance.

**Meetings.** Records the microphone and everything the Mac plays, together, into
timestamped session folders, and produces a Markdown transcript with speakers,
summary and your own live notes woven in.

**Follow-through.** Promises made on a call are extracted automatically — who
took what on and by when — split into yours and other people's, exportable to
Apple Reminders or as tasks Todoist, Things and Linear can split into rows.
A page per colleague, built from the meeting roster. A brief a few minutes before
each calendar event, without stealing keyboard focus.

**Capture, anywhere.** Select text or drag a rectangle over the screen and turn it
into a reminder, plain text via OCR, or a reply drafted from the visible thread.

**Snippets.** Typed abbreviations that expand in place with live values —
genuinely free calendar slots, your open commitments, clipboard contents, or the
answer to a question asked inline with `;ai … ;;`.

**Your choice of AI.** Anthropic, OpenAI, Gemini, any OpenAI-compatible endpoint
including Ollama, or the `claude` / `codex` CLI you already pay for — no API key
in that last case. With Ollama plus local Whisper, nothing leaves the Mac at all.

**Requires** macOS 14 or later. Homebrew only if you want the local Whisper
engine; without it the app says so and keeps working on Apple's recognizer.
