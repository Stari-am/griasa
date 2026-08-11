# Changelog

## 1.0 — 2026-08-10

First public release. [Download](https://github.com/Stari-am/griasa/releases/latest) —
signed with a Developer ID, notarized by Apple, universal (Apple silicon and Intel).

**Dictation.** Hold a key and talk; the words appear in whatever app has focus,
while you are still speaking, and are replaced once by a polished version on
release. Speech recognition is local — Apple's recogniser or `whisper.cpp`
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
engine; without it the app says so and keeps working on Apple's recogniser.
