# Promise benchmark

Six meetings, written for this benchmark, with the promises in each marked by
hand. They measure the one thing Griasa most needs to get right: after a meeting,
does the list of who promised what match what was actually promised?

**Every person, company and customer here is invented.** Maya, Daniel, Priya,
Tom, Ivan, Olena, Rachel and the rest, Harbor Lane Foods, Brightmoor, Shopnest —
none of them exist, and no line comes from a real recording. Nothing in this
folder was taken from anyone's meetings, and the probe that scores it reads
nothing but this folder.

## The meetings

| Folder | Language | Characters | Gold promises (yours) | Traps | What happens |
|---|---|---:|---:|---:|---|
| `a-webhooks-sync-ru` | Russian with English tech terms | 11,568 | 18 (7) | 5 | A short sync after lost payment webhooks. Fits one request. |
| `b-onboarding-review-en` | English | 14,506 | 20 (5) | 5 | A design review of a new onboarding flow, with typed notes. |
| `c-sprint-incident-ru` | Russian with English tech terms | 73,503 | 20 (5) | 9 | An incident review, then sprint planning, a database migration, hiring. |
| `d-roadmap-q1-mixed` | Russian and English, switching | 88,435 | 20 (4) | 11 | A roadmap session where a decision is reversed an hour later and the promises built on it are cancelled. |
| `e-customer-escalation-en` | English | 64,609 | 20 (4) | 9 | A customer escalation after a promo-day outage, then an internal debrief. |
| `f-localisation-uk` | Ukrainian | 25,575 | 18 (3) | 5 | Planning the Ukrainian and Polish localisation. |

The user is always "You" and is called Alex. Everyone on the call is "Them",
exactly as Griasa records it: the microphone is one track and everything the
computer played is the other, so who among "Them" said a line has to be worked
out from what is said — people address each other, introduce themselves,
answer a question put to them by name.

Each folder holds:

- `transcript-raw.txt` — in exactly the format Griasa writes beside every
  recording: `[mm:ss] You: …`, `[mm:ss] Them: …`, and typed notes as
  `[mm:ss] 📝 NOTE: …`. Minutes keep counting past 59.
- `meta.json` — `title`, `language`, `myName`, `participants` (the people other
  than the user, as Griasa's "who was on the call" list holds them) and, where a
  meeting uses more than one spelling of a name, `aliases` (`"Иван": ["Ваня",
  "Ivan"]`).
- `gold.json` — `promises`: each with `owner`, `isMine`, `task`, `due` (as said,
  or null) and `quote`, the exact words of the transcript the promise is made in;
  and `traps`: lines that look like promises and are not, each with its `quote`
  and a `note` saying why.

## What counts as a promise

Someone taking on a specific piece of work: "I'll send the list by Thursday",
"я до пятницы допишу идемпотентность". A request is not a promise until someone
accepts it, and then the promise is the person who accepted it — when Alex asks
"Priya, can you pull the list?" and Priya says yes, the promise is Priya's, and
Alex's question is a trap. A promise counts once: repeating it later, or in the closing
summary, does not make a second one. The gold quote is the clearest place it is
made; a prediction quoting another mention still matches by owner and task.

The traps are the lines a careless reader turns into promises:

- **Declined** requests ("No, not this quarter").
- **Cancelled** promises. A promise that is withdrawn later in the same meeting —
  Tom's deprecation plan in `d`, after the decision behind it is reversed;
  Marcus's connector rewrite in `e`; Ivan's weekend PDF export in `c` — is **not
  gold**. It is a trap: a prediction that lands on it is unmatched, so it lowers
  precision, and it is also counted in the *traps hit* column. Someone reading
  the list after the meeting would be told they owe something they no longer
  owe, which is the error this app most wants to avoid.
- Someone else's work asked for in the user's voice ("can you do X, Anna?").
- Wishes and someday talk ("когда-нибудь переедем на Kubernetes"), conditional
  offers, jokes.

Lines that are arguable were rewritten until they were not: the benchmark is
meant to measure the model, not the marker's judgement.

## Scoring

`BenchmarkScore` (in `Sources/Griasa/BenchmarkScore.swift`, with its checks in
`Tests/BenchmarkChecks.swift`) matches the promises found against the gold ones,
one to one, greedily:

1. **By quote first.** A found promise matches a gold one when its quote and the
   gold quote are the same words — one found in the other by `QuoteMatch` (the
   same tolerant comparison the app uses to keep a promise at all), either way
   round, or five words in a row in common.
2. **Then by owner and task.** For gold promises still unmatched, a found promise
   with the same owner — the user in any form ("You", "Alex", "Алекс"), or the
   same name in any script or by a listed alias — and a task sharing enough words
   matches. Tasks are compared as sets of word stems (Jaccard ≥ 0.3): lower
   case, "ё" as "е", no punctuation or quotes, no words under three letters or
   on a short ru/uk/en stop-word list, and each word cut to its first five
   letters, so "в мобильном приложении" and "в мобильное приложение" are the
   same words. Every candidate pair is ranked and the most similar pairs are
   taken first.

One found promise matches one gold promise at most. Then:

- **Recall** — matched ÷ gold.
- **Precision** — matched ÷ found. Anything found that is not gold counts
  against it, traps included.
- **Mine/theirs** — among matches, how often the found promise is on the right
  side of "yours" and "someone else's". This is what decides whose list a
  promise lands on.
- **Owner** — among matches, how often the owner is the right person.
- **Traps hit** — unmatched found promises that quote a trap.

Due dates are not scored; they are in the gold for anyone who wants to.

## Running it

```sh
./build.sh
"Griasa Dev.app/Contents/MacOS/Griasa" --benchmark benchmark/meetings              # all six, local only
"Griasa Dev.app/Contents/MacOS/Griasa" --benchmark benchmark/meetings --only a,b   # the two short ones
"Griasa Dev.app/Contents/MacOS/Griasa" --benchmark benchmark/meetings --cloud anthropic
```

Run it from the repository root. It needs a local model downloaded for Griasa's
own engine (Settings → AI & Actions). For each meeting it runs the same three
variants as `--long-meeting-eval`:

- **single** — today's single request on the local model, truncated as it is in
  the app for a meeting too long to fit;
- **chunked** — the long-meeting path: the transcript read in parts, merged;
- **cloud** — a cloud model reading the whole transcript at once. Only with
  `--cloud <provider>`; the selected provider is never used on its own.

It writes to `dist/benchmark-<date>/`: per meeting, the notes and promises each
variant produced, `timing.json` and `score.json` (what matched what, what was
missed, what was extra); and `RESULTS.md`, the table it also prints, with the
Mac, its memory, and the models used. A long meeting on a local model takes
several minutes per variant.

The validity of the data is itself checked by `./test.sh`: every file decodes,
every transcript line is a line the recorder could have written, in time order,
and every gold and trap quote is exact words of its transcript that `QuoteMatch`
finds.

## Adding a meeting

A new folder with the same three files. Keep it invented, keep the quotes exact
(copy them from the transcript), and give each promise you are unsure about the
trap treatment or rewrite the line until you are sure. `./test.sh` expects six
meetings; change that count in `Tests/BenchmarkChecks.swift` with them.
