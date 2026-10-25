# Gold audit, 2026-10-24

The first full run (local single, local chunked, cloud) scored 45–60% precision
on the long meetings for every variant, the cloud model included. That pointed
at the measurement. This file records how the gold was checked and what changed.

## What was done

1. **Scorer.** Tasks are compared by word stems (lower case, ё→е, no punctuation
   or quotes, a short ru/uk/en stop-word list, first five letters of a word),
   owner/task pairs are ranked best-first, and when one quoted line covers two
   gold promises the same owner and the closer task decide which is which.
2. **Extras.** Every `extra` prediction of the saved run, rescored with the new
   scorer, was read against the transcript and classified:
   - **A** — a real promise missing from gold: added to `gold.json`.
   - **B** — an existing gold promise: a duplicate, a part of it, the same
     promise with the wrong owner, or a paraphrase the scorer still does not
     match. Gold unchanged; the extra stays an extra.
   - **C** — not a promise: deferred, conditional, declined, a wish, a decision
     with no owner, an existing trap the model paraphrased. Trap-like lines were
     added to `traps`.
3. **Own scan.** Each long transcript (c, d, e, f) and the extras of a and b
   were read for promises no variant found, so the gold does not lean towards
   what the models happened to say.
4. **Aliases.** Meetings a and c gained the Latin forms the models wrote
   (Vanya, Anya, Danya, Danila): the same people, not wrong owners.

## The rule applied

A promise is someone committing to do something, with or without a date.
A request counts for whoever accepted it. "I can X" counts when the meeting
then acts on it (someone answers "please do", or supplies what was needed).
A commitment to an ongoing practice counts ("from today I will…", "every
day I review…"), as the existing gold already did ("from now on" in d).
Not promises: deferrals ("let's discuss it at the retro / on Monday"),
conditionals ("if they reply, add it"), declined or cancelled offers, wishes
("I'd want to double-check"), hedges ("we can probably do it in January"),
and decisions nobody owns.

Borderline calls are marked **(?)**.

## c-sprint-incident-ru (+7 gold, 27 total)

| Line | Decision | Item | Reason |
|---|---|---|---|
| [16:15] | A | Майя — decide with the account managers what to do for affected corporate clients | "дальше я уже с аккаунт-менеджерами решу" takes the follow-up. (?) |
| [35:52] | A | Анна — test the new pushes on staging | Answers "who tests the pushes?" with "Я". |
| [47:20] | A | Даниил — clone the prod DB, upgrade to 16, run the heavy queries, next week | A dated promise beside the migration plan. |
| [76:22] | A | Олег — show the new pushes on the demo from his phone | Maya's request, Oleg: "Окей". (?) |
| [76:50] | A | Анна — show the synthetic search check on the demo | Accepts Maya's request. (?) |
| [77:08] | A | Майя — show the postmortem summary on the demo | Accepts Alex's suggestion: "его и покажем". |
| [81:39] | A | Даниил — file a task to switch off anything enabled temporarily for debugging | "Я сам так буду делать с сегодняшнего дня." |
| [05:01] / [07:18] | B | ILM, health check, disk alerts (single: "Danila") | Part of Даниил's ILM promise; single's wording and stems still miss. |
| [09:40] / [03:50] | B | Circuit-breaker details, feature flag, retry backoff | Part of Иван's circuit-breaker promise. |
| [27:09] / [35:25] | B | Bulk edit API, push grouping (single: "Vanya", from the readback) | Second copies of Иван's promises. |
| [16:09] | B | Corporate-accounts export, single gives it to Майя | Даниил's promise, wrong owner. |
| [39:08] | B | Иван — channel as a parameter of grouping | Part of the push grouping promise. |
| [51:47] | B | Даниил — balancer's maintenance response as a step in the plan | Part of the migration plan. |
| [62:27] | B | Alex — validation as a separate module | Part of Alex's validation promise. |
| [14:01] | B | Alex — "HR about on-call rotation" (single) | Garbled duplicate of the HR compensation promise. |
| [35:35] | C | Олег — start the 10% rollout next sprint | A team plan; the rollout date is left to the next planning at [79:07]. (?) |
| [38:45] | C | Майя — critical-notifications list in the spec | Where the list lives, not a task; she declines to approve it alone. (?) |
| [47:40] | C | Иван — "Можно я тоже план посмотрю?" | Asks to see the plan; everyone reviews it Thursday anyway. (?) |
| [79:01] | C | Иван — back up Олег during the rollout | Existing trap, paraphrased by the cloud model. |
| [60:04] | C | Олег — answer App Store reviews (single) | Put in the backlog. Added as a trap. |
| [74:26] | — | Даниил — prod-only filter for the deploys channel | Moved to the retro. Added as a trap. |
| [69:43] | C | Майя — goals draft "пойдёт черновиком" to leadership | Passive, no commitment stated. (?) |

## d-roadmap-q1-mixed (+8 gold, 28 total)

| Line | Decision | Item | Reason |
|---|---|---|---|
| [09:53] | A | Maya — every sales request outside the roadmap goes through her | A standing commitment, like Priya's "from now on". |
| [17:10] | A | Иван — personal access tokens for v1.5, before the emails | Alex fits it into the guide work, Иван: "Логично". (?) |
| [18:51] / [19:48] | A | Иван — generous rate limits on v1 for the notice period, from a month of logs | "I want to add … rate limits", in the decisions at [95:26]. |
| [39:10] | A | Maya — buyer-data question and minimum count to legal | "It goes on the list for legal … I'd rather ask now." |
| [88:34] | A | Иван — entitlements in January | His plan, confirmed at [97:12]. |
| [88:34] | A | Иван — undo and scheduled changes in February, help the new engineer | Same line, confirmed at [97:22]. |
| [84:17] | A | Tom — one-page KMP proposal for the Q2 session | Alex's request, Tom: "Sounds good". |
| [97:51] | A | Alex — add a "what does the data say" step to the session template | Agrees to Priya's and Maya's request; he runs the sessions. (?) |
| [35:02] | B | Priya — metric definitions (single "Define analytics metrics", cloud long version) | Same promise; tasks share too few stems (0.29 single). |
| [46:24] / [46:59] | B | Shopnest call, NDA, Иван's questions (single, chunked) | Same promises; duplicates or a paraphrase below the threshold. |
| [50:58] / [46:59] | B | "[55:35] Alex" questionnaire and Shopnest API (single) | The single variant put a timestamp in the owner field; the scorer cannot read it. |
| [58:51] | B | Maya — pricing deck (cloud) | Same promise; stems 0.25. |
| [59:20] | B | Priya — sanity-check revenue (chunked, quoted Maya's line) | Duplicate. |
| [81:27] | B | Даниил — SOC 2 gaps (single, cloud) | Same promise; "gap"/"gaps" differ, stems below threshold. |
| [82:19] | B | Pipeline design mentions ClickHouse for SOC 2 (chunked: Даниил) | Part of Alex's pipeline design, wrong owner. |
| [85:25] / [85:45] | B | Starter tasks: review them, one in analytics | Part of Иван's starter-tasks promise. |
| [89:52] | B | Tom — Marek's extension (single) | Same promise, reworded. |
| [96:03] | B | Readback duplicates (chunked: v1 list, definitions doc, pipeline design) | Second copies of promises already matched. |
| [97:12] | B | Иван — "confirm the plan" (chunked) | Readback of the January/February promises. |
| [12:57] / [13:10] | C | Tom's deprecation plan, Даниил's emulators | Existing traps (cancelled). |
| [19:38] | B | Count the normal maximum before limiting (chunked: Даниил; cloud: Иван "assess traffic") | Part of Иван's rate-limit promise; chunked has the wrong owner, cloud's task shares too few stems. |
| [21:21] | C | Maya — call the big integrators first | Conditional on the list showing someone big. |
| [37:30] | C | Maya — tell sales "early access in spring" | A stance, not a task. (?) |
| [55:18] | C | Maya — check Shopnest's commercial terms | An aside, no commitment. (?) |
| [59:15] | C | Tom — check the mobile parts of the deck | A wish to review. (?) |
| [70:22] | C | Иван — tell the vacation dates | He gives "end of February" at once. |
| [70:11] / [77:28] | C | Alex's conference recording, Maya's interview topic | Existing traps, paraphrased. |
| [73:34] / [78:22] | C | Priya — re-check the tablet numbers, the EAN share | Wishes, nobody asks. Added as a trap. |
| [89:52] | C | Alex & Maya — decide the contractor budget | Tom hands it back; nobody takes it. Added as a trap. |
| [04:42] | C | Tom & Иван — mobile PDF in January | "we can probably do it in January": hedged. (?) |

## e-customer-escalation-en (+5 gold, 25 total)

| Line | Decision | Item | Reason |
|---|---|---|---|
| [10:34] | A | Rachel — her team bulk-cancels the fully oversold orders today | "Then we do it today." |
| [37:01] | A | Marcus — push Black Friday prices the evening before | "We can do it the evening before"; Daniel: "That's much better". (?) |
| [34:36] | A | Marcus — connector identifier in the user agent in the rewrite | Accepts Priya's request. |
| [47:05] | A | Rachel — send the Black Friday email in waves | "Okay. Waves it is." (?) |
| [60:59] | A | Alex — full resync after a sync incident in the runbook | "Let's put it in our runbook"; he runs engineering. (?) |
| [20:44] / [21:03] | B | Fix tested under load, duplicate-payment check | Parts of Daniel's fix and Priya's alert. |
| [21:41] | B | Stock buffer, chunked gives it to Daniel | Marcus's promise, wrong owner. |
| single, all | B | Alert (Daniel), escalation (Marcus), refund (Priya), invite, credit, report | Gold promises with the wrong owner or reworded; the single variant gave no quotes. |
| [62:55]–[64:19] | B | Readback duplicates (chunked) | Second copies. |
| [67:48] | B | Maya — argue for 10% | Part of the service credit promise. |
| [09:08] | C | Rachel — confirm the duplicates list | Only in Alex's readback; Rachel never says it. (?) |
| [22:28] | C | Marcus — buffer back after the promo | A question; "the warehouse team's call". |
| [39:25] | C | Waiting room decided on Monday | Deferred. Added as a trap. |
| [40:40] / [69:08] | C | 10-second stock cache | Deferred to the architecture review. Added as a trap. |
| [38:26] | C | Payment provider limit with Finance (single: Alex) | Rachel's "let's talk after this call", no task. |
| [68:02] | C | Alex backs Maya up | Existing trap. |
| [70:14] | C | "Before Black Friday" checklist | Explicitly not assigned today. |
| [71:05] | C | Maya — v1 risk into the roadmap notes | "Already in my notes": done. (?) |

## f-localisation-uk (+3 gold, 21 total)

| Line | Decision | Item | Reason |
|---|---|---|---|
| [17:23] | A | Тарас — dark theme in profile and order history with the localisation work | The second half of the dark-theme line. |
| [21:32] | A | Ірина — translate the six screenshot headings | Accepts Олена's ask. |
| [22:49] | A | Ірина — review the untranslated-strings list daily | "а я раз на день переглядаю". |
| [02:03] | B | Олена — rules in the Figma component descriptions | Part of the components promise. |
| [10:13] | B | Тарас — plurals while extracting strings | Already in the strings promise. |
| [23:31] | B | Stale-translation tracking (chunked: Ірина) | Part of Тарас's CI setting, wrong owner. |
| [24:21] | B | Богдан — links to the Jira bugs in the channel | Part of his bug-filing promise. |
| [24:07] | B | Alex — add Майя to the channel | Part of the channel promise. |
| [26:00] / [26:57] | B | Ірина — "ви" and style rules in the glossary | Part of the glossary promise. |
| [27:18] | B | Readback duplicates (chunked) | Second copies. |
| [13:16] | C | Ірина — check date forms "when I go through the app" | A passing remark. (?) |
| [09:49] | — | "Можна зробити тестовий акаунт" | No owner. Added as a trap. |
| [12:15] | — | Address validation | Backlog. Added as a trap. |

## a-webhooks-sync-ru (+0) and b-onboarding-review-en (+2 gold, 22 total)

Only the extras were audited here; both meetings were already near 90–100%
precision.

| Meeting | Line | Decision | Item | Reason |
|---|---|---|---|---|
| a | [08:56] | B | Майя — Brightmoor letter, "в ближайшие дни" | The same letter as the gold one at [08:41]. |
| a | [11:00] | C | Майя — add Brightmoor's reply to the postmortem if important | Conditional. Added as a trap. |
| b | [06:50] | A | Olena — per-country "required fields" hint | "I can add … but I need the list"; Maya sends the list. (?) |
| b | [10:58] | A | Olena — copy for the three onboarding emails | Accepts Maya's request. |
| b | [04:56] | C | Tom — mock the endpoint Thursday | Conditional. Added as a trap. |
| b | [07:58] | C | Olena — use icons | A decision (the trap's cancellation), not a task. |
| b | [07:20] | B | Legal wording, single gives it to Olena | Maya's promise, wrong owner. |

## Count

25 gold promises added (a 0, b 2, c 7, d 8, e 5, f 3): 116 → 141. Of the 95
extras left after rescoring, 62 are B and 33 are C. B is mostly two things:
second copies of a promise (the chunked variant's readback lines, the
single variant's recap quotes) and the right promise under the wrong owner.
Those are the models' errors and stay counted. A smaller part of B is the
scorer: a paraphrase whose stems overlap below 0.3 ("gap" against "gaps",
long task descriptions). The single variant also wrote "[55:35] Alex" as an
owner on d; the scorer reads that as nobody.

## Dataset check

`Tests/BenchmarkChecks.swift` now asks for at least 8 gold promises per meeting
(the cap of 20 is gone).
