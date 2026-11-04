# Griasa — what it does, in the words we use for it

This is the one place every feature is described. The README, the project page,
the registry listings, the in-app "What's new" card and release posts take
their wording from here, so a feature is called the same thing everywhere. When
a feature changes, change it here first.

## How we talk about it

- **Who it is for:** people whose job is meetings: managers, leads, founders.
  Not "everyone who takes notes".
- **The promise, in one line:** *Griasa remembers what was promised in your
  meetings, by whom, and puts it in front of you before the next call.*
- **The tagline** (README, site, store pages): *A promise with a date turns up
  when the date passes. One without a date never turns up at all.*
- **What makes it different:** it runs on your Mac, audio never leaves it, there
  is no account and no server, and every part points at the same people and the
  same history. Say this through facts, not adjectives.
- **Style:** plain, concrete and short. Say what happens and where to find it.
  No "AI-powered", "revolutionary" or "seamless". No emoji in LinkedIn posts.
  No numbers taken from anybody's own meetings.
- **Names:** use the names below exactly as written. The tab is "Today", not
  "dashboard". Use "promises" in text and "Commitments" only for the tab.
  "Brief" is the panel before a call; "morning brief" is the daily one.

## Short descriptions

| Where | Text |
|---|---|
| One line, ≤ 80 characters (Homebrew, social bios) | Remembers what was promised in your meetings, on your Mac. |
| MCP Registry, ≤ 100 characters | Local-first Mac meeting memory: promises, decisions, people, the next-call brief. Read-only. |
| Longer listings (Glama, catalogs) | Local-first meeting memory for the Mac: promises, decisions, people and the brief before your next call. Audio never leaves the machine. |
| Claude plugin and MCP bundle | Your meetings, the promises and decisions made in them, and the people in them, read from Griasa on your Mac. |
| Gemini extension | Meetings, promises, decisions and people from Griasa on your Mac. |

## The features

Each entry has a **name**, a **line** (for menus, cards and lists), a
**description** (for the README and the site), **where** it lives in the app,
and the **first step** a new user takes. The in-app hints use the line and the
first step.

### A manager's day

**Today**
- *Line:* Your day on one screen: meetings, what is overdue, what your team owes you.
- *Description:* The screen to start from. Today's meetings show what you and each table owe each other. Below them are your overdue promises, what is due today, what your team is late on, decisions due for another look, and promises that look done. Under all that, every part of Griasa is a card that shows what is in it.
- *Where:* the ☀️ Today button in the menu, next to History.
- *First step:* open it once; it fills itself from what Griasa already keeps.

**Morning brief**
- *Line:* At 8:00 on weekdays, a banner with the day, and Today opens.
- *Description:* Built from what Griasa already keeps, with no model and nothing sent anywhere. If the Mac was asleep at 8:00, it comes the first minute after. It can also be written to the Apple Notes note "Griasa — Today", so it is on your phone.
- *Where:* Settings → Meetings → Morning brief.
- *First step:* nothing; it is on by default.

**Desktop widget**
- *Line:* Today on the desktop: the next meeting and what is overdue.
- *Description:* "Griasa — Today" comes in small, medium and large sizes, on the desktop and in Notification Center. A click opens the matching tab. It reads a small file the app writes and has no access to your history.
- *Where:* right-click the desktop → Edit Widgets… → Griasa.
- *First step:* add it once.

**Brief before a call**
- *Line:* Minutes before a meeting: who is on it and what is owed between you.
- *Description:* It appears without taking keyboard focus. You see who is on the call, what you last discussed, and the open promises grouped by why they matter now: overdue, from this meeting before, one to one, or with these people elsewhere. Tick a promise that is already done right there. One button joins the call and starts recording.
- *Where:* opens by itself; also the menu → Prep next meeting.
- *First step:* allow Calendar access.

### Meetings

**Meeting recording**
- *Line:* Records both sides of a call, on your Mac.
- *Description:* Your microphone and everything the Mac plays are recorded as two tracks, which is how the transcript knows who spoke. It is transcribed on the Mac, and written up with a summary, the key points and who took what on. Notes typed during the call are woven in at their timecode. A call that goes silent stops recording by itself.
- *Where:* the menu → Record a meeting.
- *First step:* allow the microphone and screen recording.

**Promises (Commitments)**
- *Line:* Who promised what, by when — taken from every meeting.
- *Description:* Promises are taken from each meeting and split into what you owe and what you are owed, each with the words it came from. A later conversation can propose closing one, but only by quoting the sentence that says it is done; nothing closes itself. Old promises without a date get asked about, because nothing else would bring them back.
- *Where:* the Commitments tab.
- *First step:* record or import one meeting.

**Decisions**
- *Line:* What was decided, why, by whom — and when to look at it again.
- *Description:* Each meeting also yields its decisions: what was settled, the reason, who made the call, the options not taken, and the words it was decided in. Give one a date to look at it again, or mark it reversed.
- *Where:* the Decisions tab.
- *First step:* record or import one meeting.

**My team**
- *Line:* What each of your reports owes you, and who is late.
- *Description:* For the people you mark as direct reports: what each owes you, what is late, and when you last met. The morning brief and the widget show what your team is late on.
- *Where:* the My team tab; mark people in People.
- *First step:* open a colleague in People and switch on "Reports to me".

**People**
- *Line:* A page for every colleague, built from your meetings.
- *Description:* Pages appear from the meeting roster with no setup. Each holds the person's notes, open promises in both directions, and your last conversation. Calendar addresses link invitations to the right person, and two entries for the same person can be merged.
- *Where:* the People tab.
- *First step:* nothing; pages appear after the first meeting.

**Import notes**
- *Line:* Notes from Zoom, Meet or ChatGPT become a meeting here.
- *Description:* Paste or drop notes from another tool. Griasa does what it does with any meeting: promises, decisions and people's pages.
- *Where:* the Import notes card on Today.
- *First step:* paste one set of notes.

**Conversations**
- *Line:* Chats you export, summarized, with the promises in them.
- *Description:* A Telegram or other chat export is read day by day: a summary per day, and the promises made in the chat, linked to the message.
- *Where:* the Conversations tab.
- *First step:* import one chat export.

### From the iPhone

**Notes and recordings from the iPhone**
- *Line:* Dictate in the car; it is waiting on the Mac as a meeting.
- *Description:* No iPhone app is needed. Whatever lands in iCloud Drive → Griasa → Inbox is filed as a meeting, so its promises reach Commitments and the people it names. That can be a dictated "Griasa note" Shortcut ("Hey Siri, Griasa note"), a voice memo, or a call recorded on the iPhone. Recordings are transcribed on the Mac.
- *Where:* Settings → iPhone.
- *First step:* switch it on, then make the two-action Shortcut on the phone.

**Promises in Reminders**
- *Line:* Your dated promises on the iPhone, Watch and CarPlay — both ways.
- *Description:* Your promises with a date appear in a "Griasa" list in Apple Reminders. Ticking one there closes it in Griasa, closing it in Griasa ticks it there, and anything added to the list ("Hey Siri, add … to my Griasa list") becomes a promise.
- *Where:* Settings → iPhone.
- *First step:* switch it on and allow Reminders.

### Writing and capture, in any app

**Dictation**
- *Line:* Hold a key, talk, and the words appear where your cursor is.
- *Description:* Text appears while you are still speaking, in whatever app has focus, in any of your languages, and never overwrites what you typed. The speech engine runs on the Mac.
- *Where:* hold Right Option (changeable in Settings → Dictation).
- *First step:* allow the microphone and Accessibility.

**Remind me**
- *Line:* A reminder from anything on screen that remembers where it came from.
- *Description:* Select a line, or drag over anything on screen, and pick a time, or let the model read the deadline from the sentence. The reminder lands in Apple Reminders and links back to the app, window and browser tab it came from.
- *Where:* ⌃⌥⌘R, or the Remind me card.
- *First step:* allow Reminders.

**Snippets and inline answers**
- *Line:* Abbreviations that expand in place, with live values.
- *Description:* `{slots:3}` becomes three free slots from your calendar. `;ai question ;;` is replaced in place by the answer, inside any app.
- *Where:* Settings → Snippets.
- *First step:* type `;slots` in any text field.

**Documents**
- *Line:* A PRD, RFC, one-pager or postmortem drafted from your notes.
- *Description:* Pick a template, give it the context, and get a draft that follows the template's sections. Templates can be edited and added.
- *Where:* the New document card on Today.
- *First step:* pick a template.

**Projects and Ask a project**
- *Line:* Group meetings by project and ask questions across them.
- *Description:* Meetings are sorted into projects, and each project can be asked a question in plain words, answered from its meetings and files.
- *Where:* the Ask a project card; Settings → Projects.
- *First step:* make one project.

**Search**
- *Line:* Find a meeting by its words or by what it was about.
- *Description:* Word search works on any phrasing and word order. Search by meaning (an optional download) also finds meetings that put the same thing in other words.
- *Where:* History; also what assistants use.
- *First step:* nothing for word search; Settings to add search by meaning.

### Your assistant, your models

**Assistants (MCP)**
- *Line:* Claude, Codex or Cursor answer from your meetings.
- *Description:* A local endpoint with its own token lets any MCP assistant read your promises, decisions, people, meetings and the next brief, and Claude Desktop installs it in one click. It is read-only. Summaries and transcripts are separate questions, so asking about promises does not hand months of conversation to a cloud model.
- *Where:* Settings → System → AI assistants (MCP).
- *First step:* switch it on and add it to your assistant.

**Local models**
- *Line:* Runs on a model on your Mac by default.
- *Description:* A new install sets up a local model sized for the Mac's memory. Anthropic, OpenAI or Gemini are used only if you choose them, or the Claude or Codex subscription you already have.
- *Where:* Settings → AI & Actions.
- *First step:* nothing; setup offers it.

**For companies**
- *Line:* Managed settings for IT: which AI may be used, and the recording notice.
- *Description:* Configuration profiles can block cloud AI or allow it provider by provider, and can require a notice before recording. Sample profiles ship with the source.
- *Where:* `Support/mdm`.
