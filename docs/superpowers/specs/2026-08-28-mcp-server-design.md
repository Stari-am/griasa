# Griasa as an MCP server

**Status:** design, approved in conversation 2026-08-28. Implementation not started.

## Why

Griasa holds the one thing no other tool on the machine holds: who promised what,
across months of calls, tied to the people the user actually works with. Today
that is reachable only by opening Griasa. Meanwhile the user already has an AI
assistant open — Claude Code, Codex, Cursor — and asks it questions all day.

Exposing Griasa over MCP turns it from an app the user visits into a source the
assistant they already use can read. That is the difference between another icon
in the menu bar and a hub.

It also answers the strategic worry that started this: dictation, inline
rewriting and meeting summaries are being absorbed by the operating system and by
twenty funded products. A record of obligations between named people is not, and
making it reachable from every agent on the machine is how that record becomes
the product rather than a feature of one.

## Scope

**In:** an MCP server hosted by the running app, a read surface, a narrow write
surface behind human confirmation, and email as the identity key that makes
people resolvable across systems.

**Out, each its own spec later:**

- MCP *client* — consuming tracker servers (Linear, Jira) and reconciling spoken
  commitments against tickets. Depends on the identity key delivered here.
- Markdown export into an existing knowledge base (Obsidian and similar) — a
  one-way projection extending the existing `transcriptMirrorFolder`.
- Apple Foundation Models as a provider rung, for a free on-device model where
  macOS 26 and Apple Intelligence are present.
- SQLite/FTS5 as a rebuildable search index. Deliberately deferred: at 83 entries
  and 841 KB there is no performance problem, and the only real benefit —
  ranked results and snippets for `search_meetings` — can be added later without
  migrating anything, because the index would be derived from the JSON rather
  than replacing it.

## Decisions taken, and what was rejected

**The running app hosts the server on loopback HTTP.** Two alternatives were
considered and rejected.

A separate process speaking stdio (`Griasa --mcp`) would have been the easiest to
configure — one `claude mcp add` — but it makes a second owner of the same JSON
files. The app keeps `HistoryStore` and `CommitmentStore` in memory; a second
process writing those files is invisible to it until relaunch, and simultaneous
writes are the class of race that cost this project a crash in the audio path a
day earlier. Decisively: a stdio subprocess has no window, so it cannot ask the
user to confirm anything, and confirmation is a requirement rather than a
nicety.

A thin stdio proxy forwarding to the app would give easy setup *and* single
ownership, and is the right next step if setup-by-URL turns out to put people
off. It is three moving parts instead of two, so it is not built first.

**Reads are broad, writes are narrow and always confirmed by a human.** The
reason is the one the user gave for trackers: automatically creating tasks out of
things overheard in a conversation is the fastest way to make a tool resented.

## Transport, access and lifecycle

Off by default. A toggle in Settings turns the server on; a second, separate
toggle turns writes on, and writes stay off until asked for. Reads and writes are
different levels of trust and must not share a switch.

Bind `127.0.0.1` only. Preferred port 8179, incrementing upward if taken — 8178
is already the local whisper server. The chosen URL and token are written to
`~/Library/Application Support/Griasa/mcp.json` with mode `0600`; Settings shows
the URL and a button that copies a ready client configuration.

A 32-byte random token, generated when the server is first enabled, is required
as `Authorization: Bearer`. No exemption for local callers.

`Origin` and `Host` are validated on every request. This is not belt-and-braces:
localhost servers are routinely attacked by DNS rebinding, where a page in the
browser resolves its own domain to 127.0.0.1 and then talks to the server with
the page's privileges. The token defends against it, but tokens end up in logs,
so the headers are checked as well.

A button rotates the token. Without one, a configuration that leaks once can
never be revoked.

## Protocol surface

Tools only. MCP also defines resources and prompts; neither is implemented in
this version, because everything wanted here is a question with an answer rather
than a document to browse. Resources may be worth revisiting once markdown
export exists, when meeting notes are files with stable paths.

When the app is not running there is no server, and the client fails to connect.
That is correct rather than unfortunate: writes need a window to confirm in, and
a menu-bar app that is not running has nothing to confirm with.

## Read surface

Tools are shaped like a manager's questions, not like the tables underneath, and
they return small derived answers rather than dumps — the caller is a model with a
finite context window.

| Tool | Returns |
|---|---|
| `list_commitments` | Open promises, filtered by person, state or overdue; split into mine and waiting-on-others |
| `get_person` | Notes, open promises, meetings with them, what the last conversation was about, known email addresses |
| `search_meetings` | Titles, dates, participants and the summary section for matching meetings. No transcripts |
| `get_meeting` | Summary, key points, commitments from that meeting. No transcript |
| `get_transcript` | The full text of one meeting |
| `next_meeting_brief` | The pre-meeting brief, as data |
| `list_people`, `list_projects` | Enumerations |

`get_transcript` is deliberately separate. A transcript is the most sensitive
thing in the app, and an agent should have to ask for it explicitly rather than
receive months of conversation as a side effect of "check my commitments".

## A consequence that must be stated out loud

The project page says audio never leaves the Mac. That stays true. But everything
an agent reads goes wherever that agent sends its context — to Anthropic or
OpenAI, if the user works through them.

This is not an argument against MCP. It is an argument for saying it plainly next
to the toggle in Settings and in the README, because a product that calls itself
private by definition cannot let a user discover this for themselves. The
`get_meeting` / `get_transcript` split exists for the same reason.

## Write surface

Four tools, nothing more: complete a commitment, add a commitment, append to a
person's notes, create a reminder. No deletion, no renaming people, no editing
transcripts.

Completing a commitment is the dangerous one. A falsely closed promise destroys
the record that something is outstanding, which is the thing the app exists to
keep.

Every write opens a panel in the hub — the same mechanism as the existing
"who was on the call?" question — and the tool response is deferred until the
person decides. The panel shows exactly what will change, verbatim, not as the
agent's summary of it. A request to close five commitments is one panel with five
rows and one decision, not five dialogs.

After sixty seconds without an answer the agent is told the write was not
confirmed, and the proposal stays in the hub as pending. Nothing is silently
dropped, and nothing hangs forever.

Every write records its origin: which client asked, and when. A commitment shows
"closed via MCP by Claude Code, 28 Aug". If an agent gets something wrong, the
user has to be able to see that it was the agent rather than themselves six
months ago.

## Email as the identity key

`Person` gains `emails: [String]` and `handles: [String: String]`. Plural
addresses because work and personal both turn up and a tracker may know either;
handles (`linear`, `slack`, `github`) for systems that expose no address.

Addresses come from calendar attendees — `EKParticipant.url` is a `mailto:` URL
that the current code discards, reading only `name` — and from manual entry on
the person's page. An automatically discovered address is appended if absent and
never overwrites one entered by hand.

Matching order changes. Exact case-insensitive address match first, and it is
authoritative; the existing name-token comparison second, and only as a
suggestion. Today matching is guesswork: `PersonStore.match` treats one name as
matching another when its tokens are a subset, so "Ivan Petrov" from a calendar
collapses onto "Ivan" from the roster, and two colleagues called Ivan cannot be
told apart at all.

This is what later makes tracker reconciliation possible without heuristics: one
key joins the calendar attendee, the Linear assignee, the Slack user and the
Griasa person.

The design must not depend on an address existing. Many corporate calendars
deliver attendees as display names only, and some list a meeting room as a
participant. Addresses are exploited when present, never required.

## Testing

Two things go into `test.sh`, which compiles the units under test directly and
needs no framework:

**Person matching.** Pure logic, so it is reachable in isolation. An address wins
over a name that would otherwise match a different person; two people with the
same name are separated by address; an attendee with no address falls back to
name matching correctly.

**Decoding the existing `people.json`.** Adding a field with a default value to a
`Codable` struct is a place where Swift does not behave the way people expect: a
missing key can throw rather than fall back to the default, and if it throws the
whole file fails to decode and the user loses every person at once. This is not
asserted from memory — it is checked by decoding the real current file.

Both checks must be shown to fail before they are trusted, by mutation, as with
the stabilizer and silence checks.

Header validation and token rejection are checked by hand against a running
server: no token, wrong token, and a request carrying a browser `Origin`.
