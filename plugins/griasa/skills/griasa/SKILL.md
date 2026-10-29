---
name: griasa
description: Use when the user asks about their meetings, calls or chats, what they promised or are owed, a colleague, a project, what was decided, what to bring to the next call, or wants a follow-up written — answered from Griasa, the meeting app on their Mac, through its MCP tools.
---

# Griasa

Griasa records the user's meetings on their Mac, transcribes them, and keeps
the promises made in them — who owes what, by when, with the exact words each
promise came from. It also knows the people (from meeting rosters and the
calendar), projects, and imported chats. Everything stays on the Mac; the tools
below read it.

## Start here

- **One person, project or topic → `get_context`.** It returns, in one call and
  within a size budget, the open promises in both directions (overdue first, with
  their quotes), recent meetings with summaries, and for a person the next meeting
  with them. Use it before answering anything about someone or something; pass
  `kind` (`person`, `project`, `topic`) when you know it.
- **"What do I owe / what is overdue" → `list_commitments`** (filter by `person`,
  `project` or `overdue_only`).
- **"Prepare me for my next call" → `get_next_meeting_brief`**, then `get_context`
  for the attendees Griasa recognises.
- **"My week" → `list_upcoming_meetings`** — each meeting with what the user and
  each attendee owe each other.
- **"What did we decide about X" → `search_meetings`**, then `get_meeting` for the
  summary and the promises made in it.
- **A follow-up email → `draft_followup`** with the meeting id (and `person` for one
  person's promises only). Show the draft to the user; Griasa sends nothing.

## Rules

- **Transcripts last.** `get_transcript` returns everything that was said, including
  remarks in passing. Call it only when a summary does not answer the question, and
  quote only what is needed.
- **Names:** `list_people` gives the exact spellings; `get_context` and
  `get_person` accept any spelling or an email.
- **Quote the source.** Promises carry the words they came from — use them when the
  user asks "did I really say that?".
- **Dates** are ISO 8601; `overdue` is already computed. A promise without a date
  may have `due_as_spoken` ("до пятницы").
- **Writing is opt-in and only proposes.** If the user has allowed it in Griasa,
  `add_conversation` puts a chat into Griasa's review list and
  `propose_close_commitment` suggests that a promise is done. Neither changes or
  deletes anything; the user accepts in Griasa. If these tools are not listed, the
  user has not allowed them — don't ask them to.
- **Reply in the user's language.** Meetings are often Russian, Ukrainian or English
  mixed with English tech terms; keep names and terms as written.

## If the tools fail

"Griasa is not running" means the app is closed or *AI assistants (MCP)* is off in
its Settings → System. Tell the user that, in one line, and stop.
