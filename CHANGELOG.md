# Changelog

## Unreleased

**The welcome guide had been describing a different app.** It opened on
dictation, and promised three system permissions at a point where Griasa asks
for four — the calendar request that makes the brief work is asked at launch,
so a new user met a dialog the guide had not mentioned. It now leads with
recording a conversation and the promises that come out of it, lists the
calendar row alongside the other three with what declining costs, and says
where the MCP endpoint is and that it is off until you switch it on.

## 1.0.5 — 2026-08-31

**Griasa can be read by the AI assistant you already have open.** Switch on
*Settings → System → AI assistants (MCP)* and Claude Code, Codex, Cursor or
anything else speaking MCP can ask what was promised, by whom, what the last
conversation with somebody was about, and what the next meeting holds — without
opening Griasa.

Eight questions are answered: open promises split into yours and other people's,
one colleague with their notes and last conversation, meetings by search, one
meeting, one transcript, the next brief, people, projects. Reachable only from
this Mac and only with a token, which the settings screen will copy as a ready
client configuration.

Two things are worth knowing before you turn it on. Audio still never leaves your
machine — but whatever an assistant reads goes wherever that assistant sends its
context. That is why the summary of a meeting and the transcript of it are
separate questions: asking about commitments cannot pull months of conversation
into a cloud model by accident. And writes are not in this release at all; an
assistant can read and change nothing.

**The pre-meeting brief works for the other half of your team.** It was showing a
list of attendees and a Join button, with the last meeting and both promise lists
missing — and the reason was alphabet. Names stored in Cyrillic could never match
the Latin ones calendars send, so those colleagues were unrecognised, and every
part of the brief that needs a recognised person stayed empty.

Names are now transliterated before comparison, which catches the common cases,
and colleagues have addresses: an invitation's address is remembered against the
person it belongs to, so the next invitation is recognised by fact rather than by
comparing spellings. An attendee Griasa cannot place now offers *Who is this?* —
choose the colleague once, and every later invitation from that address is
certain.

Two smaller fixes fall out of the same work. An ambiguous name is no longer a
match: with two colleagues called Ivan the old code silently picked one and
attached meetings and promises to whoever happened to be first. And an attendee
who arrives with an address but no display name is shown rather than dropped.

## 1.0.4 — 2026-08-27

**The pre-meeting brief still never appeared, and 1.0.3 was wrong about why.**
That release added the calendar entitlement and said the permission you had
already granted would now be used. For "Remind me" and for `{slots}` that was
true. For the brief it was not, because nothing in the app had ever asked for
calendar access at all.

The request existed in exactly two places, both requiring you to act first: the
`{slots}` snippet, and the "Prep next meeting" menu item. The watcher that is
supposed to open the brief five minutes before a call checks the authorization
status on a timer and — deliberately, so that a background timer never throws a
dialog at somebody mid-sentence — never prompts. Nothing else asked. So the
feature was on by default and silently dead, and because macOS does not list an
app that has never requested a permission, it did not even appear under Privacy
& Security → Calendars for you to grant it by hand.

Griasa now asks for calendar access at launch, once, and only while the brief is
switched on. If access is refused, the Prep tab says so instead of showing
nothing. `release.sh` gained a check, beside the one that compares entitlements
against the source: a feature that runs on its own and is gated on a permission
must have a request on the launch path.

**A recording no longer runs all night.** One session here ran from 19:00 to
05:48 and wrote 8.6 GB before macOS flagged the process for exceeding its
disk-write limit. Nothing in the app had any opinion about a recording nobody was
speaking into.

When neither the microphone nor the Mac's own audio has carried speech for a
while, a small window asks whether to carry on. "Keep recording" restarts the
clock, so the same wait asks again rather than never asking twice. With no answer
at all the recording stops by itself, gets transcribed exactly as a manual stop
would be, and the transcript ends with a line saying it stopped automatically and
after how long. Both intervals are in Settings → Meetings → Silence, and default
to five minutes and two. If speech resumes while the question is on screen, the
question disappears and the recording continues — losing a meeting that was in
progress would be the worst thing this feature could do, so it is the case with
the most tests behind it.

**Fixed a crash in the microphone path.** A crash report showed SIGSEGV with the
program counter at zero on CoreAudio's IO thread, which is not a null object
being read but CoreAudio calling a function pointer that no longer exists. The
tap was being removed before the engine was stopped, so a message already on its
way arrived after its block was freed; the engine was also being mutated from
whichever thread happened to call in, and AVAudioEngine is not thread-safe. Every
engine operation now happens in order on one queue, the engine stops before its
tap is removed, and a change of audio device — sleep and wake, AirPods
connecting, a dock — puts the microphone back instead of leaving the recording
silently dead.

**The window can be pinned.** The hub closed whenever you clicked into another
app, which is right for a popup and wrong for reading history or working through
commitments. The pin beside the tabs keeps it open, and remembers.

## 1.0.3 — 2026-08-13

**Calendar and Reminders work in the signed build.** They never have. Hardened
Runtime — required for notarization — refuses an EventKit call from a process
without the matching entitlement, *even after you have granted permission in
System Settings*, and this app shipped without them. So three advertised features
were dead in every release up to and including 1.0.2:

- **"Remind me" (⌃⌥⌘R)** could not create anything in the Reminders app.
- **`{slot}` and `{slots:3}`** could not read your calendar, so meeting proposals
  had no free time to offer.
- **The pre-meeting brief** never appeared, because the watcher could not see the
  next event.

All three worked in local development builds, which is exactly why it went
unnoticed: a local build has no Hardened Runtime, so nothing was refused. The
entitlements file even said in a comment that calendar and reminders access
needed no entitlement. It was wrong, and a comment cannot be tested.

If you granted Calendar or Reminders access to an earlier version and it did
nothing, that was this. Update, and the permission you already gave will be used.

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
