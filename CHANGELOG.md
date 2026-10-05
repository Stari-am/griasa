# Changelog

## Unreleased

**Old recording audio can be deleted on a schedule.** Recordings keep two audio
tracks for every meeting, and they add up: audio is nearly all of the space a
recordings folder takes, and the transcript and notes made from it are a tiny
fraction. *Settings → Meetings → Recordings on disk* can now delete the audio of
transcribed recordings after a day, a week, a month or three months. The
transcript and the notes stay, and re-summarizing still works; only running
speech recognition again needs the audio.

A recording without a finished transcript is never touched, however old — for a
recording whose transcription failed or never ran, the audio is the only copy
of the meeting there is — and neither is the one in progress. Choosing a period
says how much will go before anything does, and it is off unless turned on.
Deletion is permanent: moving a hundred gigabytes to the Trash would free none
of it. An organisation can set the period with MDM (`audioRetentionDays`).

**Recordings can live with their project.** With *Keep recordings in their
project's folder* on, each recording folder moves beside its project's meeting
notes — `Documents/Griasa/Projects/<project>/Recordings/` — and follows the
meeting when it is moved to another project. Unsorted ones go to Inbox, and
turning it off moves them back. The history finds a recording again by its
folder's name whenever a folder moves underneath it: a project renamed or
deleted, or a tidy-up in Finder.

Merging a deleted project's folder into Inbox used to move only the top level
and then delete the source regardless. Harmless while project folders held
Markdown files; with recordings inside them, a `Recordings` folder already in
Inbox would have made the move fail silently and the deletion take the
recordings with it. Folders now merge recursively, a name that still clashes is
kept under a new name, and the source is removed only once it is empty.

## 1.0.14 — 2026-10-01

**A new install uses the local model.** Griasa says it keeps your meetings on
your Mac, and that was true only for people who changed it: an install that never
touched the provider picker was on Anthropic, so anybody who pasted a key had
transcripts going to a cloud vendor by default. A security review put it in one
line — announced as local, configured as cloud. The default is now a local model
through Ollama, with no address to type in first.

If no local model is running, the first AI action you take says so and how to
fix it — install Ollama, pull the model — and names the cloud as a separate,
explicit choice with its cost stated: text sent there leaves this Mac. If a cloud
provider is also available, that action asks before sending this one request
through it, and your setting stays as it is. Background work — dictation
cleanup, promise extraction, sorting into projects — never asks: without the
local model it simply does not run, and dictation falls back to its built-in
cleanup.

Nothing changes for anybody who already chose. A saved provider is kept, and an
install from before this change that holds a cloud key but never saved a
provider keeps that one too: being on the old default and pasting a key into it
was a choice, and moving that person to a model they never installed would break
every AI feature they use.

**API keys are kept in the keychain.** They used to be ordinary preferences —
plain text in a file every program running as you could read, and copied into
every backup. They now live in the macOS login keychain, encrypted at rest, and
another program asking for one gets a system prompt instead of the key.

Existing keys move across by themselves at the first launch, and each one leaves
the preferences file only after it has been written to the keychain and read
back unchanged — a key that stays in plain text for one more launch is a smaller
harm than a key that is gone. A key found in the preferences file later, typed
into an older version after a downgrade, replaces the keychain copy as the most
recent one entered.

**Speech models are checked before anything loads them.** They come from
Hugging Face, and a download used to be accepted as long as the server answered:
a file replaced upstream, cut short on the way, or altered by anything on the
connection would have gone straight to the model parser, which has a history of
memory-safety bugs. Each model is now pinned to a repository commit rather than
a branch, so it cannot change underneath the app, and checked against a SHA-256
and size written into the app before it is moved into place. A file that does
not match is not installed, and the message says which way it was wrong.

Models already on disk are checked once after the update — under a second for
the large one — and remembered until the file changes. One that fails is renamed
rather than deleted, and a verified copy is downloaded in its place.

**Companies can manage Griasa with MDM.** A configuration profile for
`am.stari.griasa` can pin the AI provider, point it at a model server the
company runs, turn the MCP endpoint off, and — with `allowCloudAI` set to false —
close every path that sends text off the Mac: cloud providers disappear from
Settings, a cloud provider saved earlier is replaced by the on-device one, and
nobody is offered a cloud fallback. Each setting a profile controls is shown as
locked in Settings, with a line saying the organization set it. A ready profile
and a short guide for IT are in `Support/mdm`.

A profile can also allow one vendor and not another: each cloud provider has
its own switch, and a vendor's API and its subscription CLI are separate ones —
a company API account and somebody's personal Claude or ChatGPT subscription are
different contracts. A provider that is closed and was already saved falls back
to the on-device one, never to a different vendor.

For everybody without a profile, nothing changes. And a switch that cannot be
read as yes counts as no, so the common profile typo closes a provider rather
than leaving it open.

**A reminder to tell people they are being recorded.** Griasa records the other
side of a call through the Mac's own audio, so only the person running it sees
a recording indicator. Whether that needs consent depends on where everybody
is, and the app cannot decide it — but it can make asking the easy thing to do.
With *Settings → Meetings → Remind me to tell everyone the call is recorded* on,
starting a recording shows a ready sentence with a Copy button, for the call's
chat. The default says the call is recorded and offers a way to object; it can
be changed.

It is off unless somebody turns it on. An organisation can turn it on for
everybody, and set the wording, with an MDM profile — and a profile value that
cannot be read as a clear no counts as on, so a typo produces one reminder too
many rather than a call nobody was told about.

## 1.0.13 — 2026-09-28

**The live panel no longer thanks everybody on your behalf.** Live notes cut each
track into short windows and sent every one of them to Whisper whole — including
the microphone windows in which you were listening rather than talking. Those
hold nothing but the room, and Whisper turns the room into "Thank you.", so the
panel showed a thank-you under your name after every block of somebody else's
speech, on a clock. 1.0.12 fixed the same thing in the finished transcript; the
live path goes around it.

A live window now goes through the same voice detector as a finished meeting.
If nobody spoke in it, nothing is sent at all, and what is transcribed is
cleaned by the meeting rules rather than dictation's. Checked against a real
microphone track: the detector finds speech exactly in the minutes somebody was
talking, and nowhere else.

## 1.0.12 — 2026-09-23

**Meeting transcripts no longer thank nobody.** A cough, a keyboard or a chair
scraping is sometimes let through by the voice detector as a short stretch of
"speech", and Whisper decodes a sub-second burst of noise as the phrase it has
seen most often in its training subtitles: "Thank you." The transcript then read
as a series of people thanking someone who was not in it.

Sent to the server on their own, those regions came back as exactly that phrase,
and neither of the server's own confidence signals could tell them apart from
real speech — the no-speech probability was zero for every region, genuine or
not, and the log-probabilities overlapped completely. So the rule is about the
whole segment: in a recorded meeting, a region whose entire text is "thank you",
"thanks" or "спасибо" is dropped. "Okay, thank you, next item" is untouched, and
dictation is untouched entirely, because there "thank you" is very often the
whole message.

That will occasionally drop a real, isolated "thank you" from a meeting. It
carries no fact, no decision and no promise, and a transcript punctuated by
pleasantries nobody said is exactly the thing that makes it unreadable.

## 1.0.11 — 2026-09-22

**The microphone was not being recorded at all, and nothing said so.** Recordings
were coming out with no microphone track on them — the meeting captured with only
the other side of the call. The cause is one cached value: `AVAudioEngine`
remembers the format of the input device it first saw, and Griasa kept a single
engine for the life of the app, so after any input device
change — a Bluetooth headset arriving is the everyday one — the engine still
described the microphone that was there at launch. The tap is then built for a
device that is no longer attached and **no audio arrives at all**.

Read out of the system log and then reproduced on demand, it fails in two
different ways, and the second is the dangerous one: with the engine at 48 kHz
against hardware at 24 kHz, `start()` threw -10868; in another attempt it
returned successfully and then delivered nothing for three seconds. Nothing
thrown, nothing logged, half a conversation recorded.

A new engine is now built at the moment the microphone is opened, which reads the
device that is actually there. The two formats are compared anyway before the tap
goes on, because recording silence is worse than refusing. And the first sound is
waited for: a tap that opens and stays silent is now reported in the menu like
any other failure, instead of being discovered when the transcript turns out to
have one voice in it.

Two consequences of the same fault are fixed with it. A device that changed
*during* a recording left a microphone track a few seconds long — the file's
format is fixed by its first buffer, and every later write was refused — so the
track now resamples into the format it was opened with and stays one continuous
recording. And the silence question was firing a minute into meetings where
somebody was talking the whole time: it only ever heard the system-audio track,
because the microphone side was never arriving.

Speaker attribution was collateral damage rather than a separate problem. "You"
is the microphone track and "Them" is everything else; with no microphone track
there was no "You" at all, and every voice in the room arrived through one
channel with nothing to separate them by.

`Griasa --mic-probe [seconds]` opens the microphone the way a recording does and
says what arrived — the question the app could not answer for itself.

**The site and the README describe the app that now exists** — the brief grouped
by why each promise is being shown, closure from evidence, the review of undated
promises, addresses and merging on a person's page, and the MCP endpoint, which
was not mentioned anywhere on the site at all. The screenshots are regenerated,
and can now be regenerated by anybody: `GRIASA_STORE` points every store at
another directory, so `Support/shoot-docs.sh` photographs an invented company
instead of somebody's real meetings.

## 1.0.10 — 2026-09-11

**The "who was on this call" question has a search box, and ticks what it can
work out for itself.** The roster grows past what fits in the list, and scrolling
for one name after every meeting is the kind of small friction that ends with the
question being skipped. It filters as you type, and a name you have already
ticked stays visible whatever you type — a tick you cannot see is a name on a
transcript that nobody chose.

It also looks at the calendar. If a meeting overlapped the recording, the people
on that invitation who are already on your list are ticked when the question
appears, with a line saying which meeting they came from, because boxes that tick
themselves without explanation are worse than boxes you tick by hand. Only people
already on the list: a large invitation carries a long tail of names that were
never worth remembering, and adding them would make the question harder to
answer, not easier.

The event is chosen by how much time it shares with the recording, not by how
near it starts, and an overlap under a minute does not count — back-to-back calls
are normal, and the meeting that ended as yours began would otherwise tick an
entirely different set of people. Without calendar access, or with no matching
event, the question is exactly what it always was.

## 1.0.9 — 2026-09-10

**Old promises with no date now get asked about.** Most promises never carry a
date, and an undated promise never surfaces by itself, which is why the list only
ever grows. Anything undated and
made over a month ago is now offered for review, oldest first, eight at a time:
still open, done, or it was never a commitment. Saying it is still open puts it
away for another month rather than for ever.

No model is involved. It is arithmetic on dates, so it is instant, works with no
provider and no network, and cannot be wrong about anything except the calendar.

**The brief before a meeting is now about that meeting.** It used to list every
open promise involving anybody on the call, globally, with one-to-one follow-ups
mixed into group meetings — for a call that happens every week, a list nobody
reads. Promises are now grouped by why you are being shown them: overdue,
promised in an earlier meeting with exactly these people, from a one-to-one with
somebody on this call, or with these people from somewhere else. A promise
involving nobody in the room is not shown at all, and each group is capped with a
link to the full list.

Two obvious ways to recognise a recurring meeting were ruled out by measurement
first. Titles do not repeat between recordings — they are typed after the call —
so a series cannot be identified by name. And matching participants loosely, at
60% overlap, collapses unrelated meetings into one large cluster, which would
make every meeting part of every other meeting's history. An exact participant
set does repeat, and it works on everything already recorded. Neither "one-to-one" nor "which series" is
stored on a promise — both follow from the meeting it came out of, so there is
nothing to migrate and nothing that can drift out of step.

**And promises can now close themselves — with your agreement.** The pass that
already reads finished meeting notes gets a second question: which of the open
promises does this conversation say are done? Each answer must come with the
sentence from the notes that says so, and that sentence is checked against the
notes word for word — evidence the model wrote itself would be the one thing that
makes a suggestion impossible to judge.

Nothing is closed automatically. A detection appears as "Looks done" with its
quote, and one button closes it while the other says it is still open. The errors
here are not symmetric: wrongly closing a promise means forgetting something you
owe and hearing about it from the person you owed it to, while wrongly leaving one
open costs a line of noise.

## 1.0.8 — 2026-09-08

**Starting a recording could abort the app.** It happened twice in a week, on
1.0.6 and again on 1.0.7, and the reason was one line: the microphone tap was
installed with the format the input node had cached. That value goes stale when
the audio device changes while nothing is recording — AirPods connecting is
enough — and AVFoundation then compares it against the live hardware and raises
an exception. Measured from the crash: the node was reporting 24000 Hz while the
hardware was at 48000. An exception from a C++ library cannot be caught in
Swift, so there was nothing to handle and the process aborted on the first click
of Start Recording.

No format is passed now, which means there is nothing to disagree with the
hardware. Nothing downstream changed: every consumer already took its format
from the buffer it was handed, and the accessor that exposed the stale value had
no callers at all — it is gone rather than corrected. A device that reports no
channels is now refused with an ordinary error instead of reaching the exception.

**One local speech server, not several.** An abort skips the shutdown path, so
the `whisper-server` subprocess survived it. The next launch has no handle to
that orphan and decides whether to start one from a health check with a
one-second timeout, which a server busy transcribing does not answer in time —
so a second was launched. Both then held the same port, and requests were split
between them. On this machine two were listening, one of them started 40 days
earlier and still carrying that day's vocabulary. Any leftover is now cleared at
launch, before the first request.

## 1.0.7 — 2026-09-02

**A person's addresses are visible and editable, and a person can be removed.**
The addresses were being learned silently from calendar invitations and shown
nowhere, so a wrong one could not be found and a right one could not be added by
hand — which mattered most for colleagues whose name transliterates differently
from the way they write it themselves. They now sit on the person's page, one
line each, with a field to add one and a button to forget one. A typed string
that is not shaped like an address is refused, because the matching rules fall
back to comparing the local part against a name, and a shapeless one becomes a
way to attach one colleague's meetings to another. An address already held by
somebody else is refused too, and says who has it.

**Two entries for one human can be merged.** This is the ordinary accident here:
the names are typed in a hurry the moment a call ends, so a second spelling makes
a second person. Merging moves their meetings, their promises, their addresses
and their roster entry onto the person you keep, and keeps the notes from both.
The dossier does not merge — the newer one is kept whole, because half of one
description followed by half of another would read as a single account of
somebody and be false.

Deleting is offered as well, underneath, and says what it leaves behind: the page
goes, the name leaves the list offered after a call, and any recorded meetings
and promises keep the name without a page behind it. That is why merging comes
first — reaching for delete to fix a duplicate is how the duplicate's half of the
history gets thrown away.

## 1.0.6 — 2026-09-02

**The silence question was dismissing itself with its own beep.** It appeared,
sounded the alert that is meant to reach you in another room, and vanished about
a second later — then came back a minute later and did it again, never on screen
long enough to click. The cause was measured rather than guessed: the alert
sound comes back in through the system-audio capture at -16.9 dBFS, 23 dB above
the level that counts as somebody talking, so the watch heard itself and
concluded the meeting had resumed. `excludesCurrentProcessAudio` does not help,
because macOS does not play the alert as this app's audio.

Sound now has to keep going for four seconds before it counts as a conversation
resuming. The longest alert sound macOS ships is 2.16 s, so no beep can clear
that bar — and neither can a notification chime, a cough or a door, all of which
used to cancel the question just as effectively. A recording is also no longer
stopped in the middle of a sound: if something is arriving as the countdown ends,
it gets another moment to turn into speech, because the one thing this feature
must never do is cut off a meeting that has started again.

Two smaller things found while measuring. "Keep recording" was marked as the
default action, but the panel is borderless and can never become the key window,
so Return reached nothing — the button keeps its emphasis and no longer promises
a key that does not work. And `Griasa --silence-probe` now exists: it plays the
beep, measures what each input hears, and reports whether the question survives.

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

**A recording no longer runs all night.** A session left running overnight filled
the disk until macOS flagged the process for exceeding its write limit. Nothing
in the app had any opinion about a recording nobody was speaking into.

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
