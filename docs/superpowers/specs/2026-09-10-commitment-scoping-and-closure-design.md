# Commitments: scoped to the meeting, and closed when the conversation says so

2026-09-10

## The complaint

Three things, from use rather than from a wish list:

1. Commitments only ever accumulate. Nothing notices when a conversation says a
   promise was kept, so the list grows until it is ignored.
2. Promises from one-to-ones and from group meetings sit in one pile, so the
   brief before a group call shows private follow-ups next to team ones.
3. The brief shows every open promise involving an attendee, globally. For a
   meeting that happens every week, what matters is what was promised in *that*
   meeting, not everything ever.

## What the data says

Measured against a real store before designing, because two of the obvious
designs are refuted by it. The measurements were run in place and the counts stay
there; what is recorded here is what they showed:

- **Titles do not repeat.** Every recorded meeting had a distinct title, so a
  recurring meeting cannot be identified by name — titles are typed after the
  call and are never the same twice.
- **Participant sets do repeat.** A substantial share of meetings are a
  recurrence of the same small group. Exact set match works, and works
  retroactively on everything already recorded.
- **Fuzzy participant matching is useless here.** At 60% overlap almost every
  meeting joins one large cluster. It would merge every meeting with every other.
- **One-to-ones are recognisable by counting participants**, with nothing new to
  store.

## Design

### Meeting identity is derived, never stored

Neither "this is a one-to-one" nor "this belongs to a series" becomes a field on
`Commitment`. Both follow from the meeting a commitment came from:
`sourceEntryID` → `HistoryEntry.participants`.

- one-to-one = exactly one participant besides the user
- series key = the exact participant set, lowercased, trimmed and sorted

This matters beyond tidiness. Adding a field to `Commitment` means writing its
decoder by hand — the synthesized one throws on a missing key and takes the whole
file with it — and migrating every record already stored. Deriving costs
nothing and cannot fall out of sync with the meeting it describes. Commitments
added by hand have no source and land in *General*.

### Four buckets, and a fifth that is hidden

The brief groups by *why you are being shown this*:

| Bucket | Rule |
| --- | --- |
| **Overdue** | Relevant, and past its date. Cuts across the rest and sits on top: a missed deadline outranks tidy grouping. |
| **This meeting** | Its source meeting has the same participant set as the one about to start. |
| **Personal** | Its source meeting was a one-to-one with somebody in the room. |
| **General** | Relevant, but from neither. |
| *(hidden)* | Involves nobody in the room. Not shown at all. |

Relevant means: the promise is owed by an attendee, or it came out of a meeting
one of the attendees was in. Everything else is the answer to "I do not want to
see all commitments globally in a meeting panel".

### Closure is proposed with evidence, not performed silently

The extraction pass that already reads finished meeting notes gets a second
question: which of the currently open commitments does this conversation say are
done? The model must return the phrase that says so.

A detected closure is stored on the commitment as a suggestion — the quote and
when it was noticed — and shown as "looks done", with the quote, and one click to
accept or dismiss.

It is not silent by default, because the errors are not symmetric. Wrongly
closing means forgetting something you owe and being told by the person you owed
it to. Wrongly leaving open means a line of noise. A setting can turn on silent
closing for high-confidence detections; it ships off.

This is the same rule already applied to the MCP endpoint: reading freely, and a
narrow set of writes behind an explicit human confirmation.

### Where the code goes

- `CommitmentScope.swift` — new, Foundation only: meeting shape, series key,
  bucket rules. Reachable from `test.sh` and mutation-tested, like
  `PersonIdentity` and `SilenceLevel`.
- `CommitmentModel.swift` — new, Foundation only: `Commitment` moved out of the
  SwiftUI file so its decoder can be tested, with an explicit `init(from:)` and
  the two suggestion fields.
- `MeetingPrep.swift` / `PrepView.swift` — build and render the buckets.
- `Prompts.swift` — one new key for the closure question.
- `Commitments.swift` — the store keeps its suggestion API; extraction gains the
  second pass.

## Rejected

- **Title similarity for series identity.** Refuted by the data: no title repeats.
- **Fuzzy participant matching.** Refuted by the data: it merges everything.
- **A `kind` field on `Commitment`.** Derivable, and a field means a migration
  and a hand-written decoder for no gain.
- **"Raised but never promised"** — recurring topics that come back every week
  with no commitment attached. Genuinely useful and in no tracker, and still a
  separate feature; not in this one.
