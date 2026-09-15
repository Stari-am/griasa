#!/usr/bin/env python3
"""Writes an invented team's history, people and promises into a store directory.

Documentation screenshots need a Griasa with something in it, and the only real
Griasa on this machine is somebody's actual working life. So: run the app against
this instead.

    python3 Support/demo-store.py /tmp/griasa-demo
    GRIASA_STORE=/tmp/griasa-demo "Griasa Dev.app/Contents/MacOS/Griasa" \
        --open commitments --size 1080x860 --shoot docs/screenshot-commitments.png

Everybody here is made up. Dates are relative to the moment this runs, so the
"10 hours ago" in a screenshot is true whenever it was taken. Encoded the way the
stores encode themselves: plain JSONEncoder, so a Date is seconds since 2001.
"""

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

REF = datetime(2001, 1, 1, tzinfo=timezone.utc)
NOW = datetime.now(timezone.utc)


def at(days=0, hours=0):
    return ((NOW - timedelta(days=days, hours=hours)) - REF).total_seconds()


def ahead(days=0, hours=0):
    return ((NOW + timedelta(days=days, hours=hours)) - REF).total_seconds()


def uid():
    return str(uuid.uuid4()).upper()


ROSTER = ["Marcus Oyelaran", "Priya Raghunathan", "Tomás Herrera",
          "Sam Okafor", "Dana Whitfield"]

CHECKOUT = [ROSTER[0], ROSTER[1], ROSTER[2]]   # the weekly, and the call ahead

ids = {name: uid() for name in
       ["root-cause", "iOS", "postmortem", "weekly", "1-1-marcus", "1-1-priya",
        "platform", "vendor", "payments", "dictation", "action", "doc"]}

NOTES = """# Meeting notes — Checkout conversion drop, root cause

## Summary
Checkout conversion is down 4.1% week over week, on Android only. The payment gateway is not the cause: p95 for the authorise call is flat at 240 ms across the window. The regression tracks a client-side change that made the card form re-render on every keystroke, which on mid-range Android devices costs about 900 ms of input latency and pushes a measurable share of users to abandon at the CVV field. No flag was used, so the revert is the fix. The funnel dashboard could not show any of this: device class is not a dimension on it, so the shape of the drop was only found by watching replays by hand.

## Key points
- Android only. iOS conversion is flat, which ruled out the gateway early.
- Authorise p95 is 240 ms and unchanged; the gateway was never involved.
- The card form re-renders per keystroke since the validation refactor.
- Measured on a mid-range device: ~900 ms of added input latency at the CVV field.
- The funnel dashboard has no device-class dimension, so the next regression of this shape is invisible again unless that is fixed.
- No flag was used for the change, so the revert is the only lever available.

## Action items
- You: get device class into the funnel dashboard so the next regression is visible without a session replay.
- Marcus Oyelaran: revert the card-form re-render change and ship it.
- Priya Raghunathan: add an input-latency budget to the release checklist, failing CI above 200 ms.
- Tomás Herrera: confirm gateway p95 stays flat after the revert.

## Transcript
[00:00] **Priya Raghunathan:** Conversion is down 4.1% week over week and it is all Android. iOS is flat to two decimal places, which is why I stopped looking at the gateway.

**Tomás Herrera:** Authorise p95 is 240 milliseconds for the whole window. It has not moved. Whatever this is, it is in front of us, not behind us.

[02:30] **Marcus Oyelaran:** I watched about forty replays this morning. People get to the CVV field and the form stutters. It is the validation refactor — the card form re-renders on every keystroke now.

**You:** On what hardware?

**Marcus Oyelaran:** A mid-range Android, three years old. Roughly 900 milliseconds of input latency at that field. On my phone you cannot feel it at all, which is why it passed review.

[06:00] **Priya Raghunathan:** Was it behind a flag?

**Marcus Oyelaran:** No. So the revert is the fix. I can have it out today.

**You:** Do that. And the thing that worries me more is that the dashboard could not tell us any of this. Device class is not a dimension on the funnel, so the only way to see the shape of this drop was to watch replays by hand.

[09:30] **Tomás Herrera:** I will confirm the gateway numbers stay flat after the revert, so we are not congratulating ourselves for the wrong fix.

**Priya Raghunathan:** And I will put an input-latency budget in the release checklist. If it is above 200 milliseconds, CI fails. Otherwise this comes back in six weeks with a different name."""

history = [
    dict(id=ids["root-cause"], date=at(hours=10), kind="meeting",
         title="Checkout conversion drop — root cause", text=NOTES,
         participants=CHECKOUT,
         filePath=os.path.expanduser("~/Documents/Griasa/2026-09-15 checkout.md")),
    dict(id=ids["dictation"], date=at(hours=13), kind="dictation",
         title="Dictation",
         text="Reply to the vendor: we are interested at the 12-month term but "
              "not at the quoted rate, and the security review has to finish "
              "before anything is signed."),
    dict(id=ids["iOS"], date=at(days=1), kind="meeting",
         title="iOS 4.2 go / no-go",
         text="## Summary\nThe build is ready except for the offline cart, which "
              "still double-counts an item added while the device is offline and "
              "then edited once it reconnects. Shipping with the feature flagged "
              "off was agreed, on the grounds that the rest of the release is two "
              "weeks of work nobody wants to hold. Marketing has the wrong date.",
         participants=[ROSTER[1], ROSTER[3]]),
    dict(id=ids["action"], date=at(days=1, hours=4), kind="action",
         title="Summarize",
         text="The vendor will hold the current rate for a 12-month term, not a "
              "24-month one, and wants an answer inside the week."),
    dict(id=ids["postmortem"], date=at(days=2), kind="meeting",
         title="Postmortem — 22-minute checkout outage",
         text="## Summary\nCheckout was unavailable for 22 minutes after a "
              "retired hostname stayed in one config file. The health check "
              "asserted the process was running rather than that the dependency "
              "resolved, so every instance reported healthy throughout.",
         participants=[ROSTER[2], ROSTER[3], ROSTER[0]]),
    dict(id=ids["payments"], date=at(days=3), kind="meeting",
         title="Payments — vendor decision",
         text="## Summary\nThe rate holds only for a twelve-month term, and the "
              "security review has to finish before anything is signed. No "
              "decision was taken, because the comparison against the other two "
              "quotes still exists only in somebody's head.",
         participants=[ROSTER[4], ROSTER[2]]),
    dict(id=ids["doc"], date=at(days=4), kind="document",
         title="PRD — offline cart",
         text="# Offline cart\n\n## Problem\nA cart edited offline and synced on "
              "reconnect can double-count an item, and the resolution rule is "
              "currently whichever write arrives last."),
    dict(id=ids["1-1-marcus"], date=at(days=6), kind="meeting",
         title="1:1 — Marcus",
         text="## Summary\nReview latency is the complaint, and it is not only "
              "his: the median wait for a first review is over a day across the "
              "team. He wants a Platform slot in Q4 and I have not promised one.",
         participants=[ROSTER[0]]),
    dict(id=ids["weekly"], date=at(days=8), kind="meeting",
         title="Checkout — weekly",
         text="## Summary\nConversion was already soft on Android and nobody "
              "could say why. Agreed to look at device class before the next one.",
         participants=CHECKOUT),
    dict(id=ids["1-1-priya"], date=at(days=12), kind="meeting",
         title="1:1 — Priya",
         text="## Summary\nRelease process, and what she would change about it if "
              "nobody argued. The checklist is the lever she wants.",
         participants=[ROSTER[1]]),
    dict(id=ids["platform"], date=at(days=47), kind="meeting",
         title="Platform sync",
         text="## Summary\nOwnership of the payments service, and what the "
              "rollback story actually is if the next deploy goes wrong.",
         participants=[ROSTER[4], ROSTER[2], ROSTER[3]]),
    dict(id=ids["vendor"], date=at(days=39), kind="meeting",
         title="Vendor call — rates",
         text="## Summary\nThey will hold the rate for a longer term. The "
              "comparison against the other two quotes has not been written down "
              "anywhere anybody else can read it.",
         participants=[ROSTER[4]]),
]


def promise(text, owner, mine, source, entry, days_ago, due=None, hint=None,
            quote=None):
    item = dict(id=uid(), text=text, owner=owner or "You", isMine=mine,
                sourceTitle=source, sourceEntryID=entry, date=at(days=days_ago),
                done=False)
    if due is not None:
        item["dueDate"] = due
    if hint:
        item["dueHint"] = hint
    if quote:
        item["suggestedDoneQuote"] = quote
        item["suggestedDoneAt"] = at(hours=9)
    return item


commitments = [
    # Mine, from the call that is about to happen again.
    promise("Get device class into the funnel dashboard so the next regression "
            "is visible without a session replay", "", True,
            "Checkout conversion drop — root cause", ids["root-cause"], 0.42,
            due=ahead(days=3), hint="by Thursday"),
    promise("Tell marketing the release date is the 19th, not the 17th", "", True,
            "iOS 4.2 go / no-go", ids["iOS"], 1, due=at(days=2), hint="today"),
    promise("Get legal to read the new consent line", "", True,
            "iOS 4.2 go / no-go", ids["iOS"], 4,
            quote="Legal came back on the consent line yesterday — they are "
                  "happy with the wording as it stands."),
    promise("Talk to Tomás about a Platform slot for Q4 before promising "
            "anything", "", True, "1:1 — Marcus", ids["1-1-marcus"], 6),
    promise("Look at review latency across the whole team, not just Marcus's",
            "", True, "1:1 — Marcus", ids["1-1-marcus"], 6, due=ahead(days=1),
            hint="before the next one"),
    # Mine, old and undated — what the monthly review asks about.
    promise("Write up the rollback runbook for the payments service", "", True,
            "Platform sync", ids["platform"], 47),
    promise("Send Dana the vendor comparison against the other two quotes", "",
            True, "Vendor call — rates", ids["vendor"], 39),
    promise("Confirm the retirement checklist covers staging too", ROSTER[3],
            False, "Postmortem — 22-minute checkout outage", ids["postmortem"], 34),
    promise("Counter the vendor with a 12-month term at the same rate", "", True,
            "Payments — vendor decision", ids["payments"], 3, due=ahead(days=2),
            hint="before Friday"),
    # Theirs.
    promise("Revert the card-form re-render change and ship it", ROSTER[0],
            False, "Checkout conversion drop — root cause", ids["root-cause"], 0.42,
            due=ahead(hours=6), hint="today"),
    promise("Add an input-latency budget to the release checklist, failing CI "
            "above 200 ms", ROSTER[1], False,
            "Checkout conversion drop — root cause", ids["root-cause"], 0.42,
            due=ahead(days=5), hint="next week"),
    promise("Confirm gateway p95 stays flat after the revert", ROSTER[2], False,
            "Checkout conversion drop — root cause", ids["root-cause"], 0.42,
            due=ahead(days=1), hint="tomorrow"),
    promise("Submit iOS 4.2 to review with the offline cart flagged off",
            ROSTER[1], False, "iOS 4.2 go / no-go", ids["iOS"], 1,
            due=at(days=1), hint="yesterday"),
    promise("Make the health check assert the dependency, not the process",
            ROSTER[2], False, "Postmortem — 22-minute checkout outage",
            ids["postmortem"], 2,
            quote="The health check asserts the dependency now — that went in "
                  "with the revert this morning."),
    promise("Grep every config for retired hostnames and add it to the "
            "retirement checklist", ROSTER[3], False,
            "Postmortem — 22-minute checkout outage", ids["postmortem"], 2),
    promise("Alert on retry-queue depth, not just error rate", ROSTER[0], False,
            "Postmortem — 22-minute checkout outage", ids["postmortem"], 2),
    promise("Say whether the security review can finish before the vendor's "
            "deadline", ROSTER[4], False, "Payments — vendor decision",
            ids["payments"], 3, due=ahead(days=4), hint="next week"),
]

people = [
    dict(id=uid(), name="Dana Whitfield",
         notes="Runs Payments. Decides in the meeting or not at all — send the "
               "numbers the day before or the decision slips a week.",
         emails=["dana.whitfield@example.com", "dwhitfield@example.org"],
         handles={},
         dossierDate=at(days=1),
         dossier="Appears only in payments conversations, and in every one of "
                 "them.\n\n**What she is responsible for.** The "
                 "payments service and the vendor relationship. Every rate "
                 "conversation in the history runs through her, and she is the "
                 "one who asked for the rollback runbook nobody has written "
                 "yet.\n\n**How she works.** Short meetings, decided at the "
                 "table. Twice a decision was deferred because the numbers "
                 "arrived during the call rather than before it.\n\n"
                 "**Open between you.** The rollback runbook, undated since the "
                 "day it was agreed, and the vendor comparison."),
    dict(id=uid(), name="Marcus Oyelaran",
         notes="Strongest debugger on the team. Reviews are his standing "
               "complaint, and he is right about it.",
         emails=["marcus.oyelaran@example.com"], handles={"github": "moyelaran"}),
    dict(id=uid(), name="Priya Raghunathan",
         notes="Owns the release process. Wants the checklist to be the place "
               "rules live, rather than people remembering.",
         emails=["priya@example.com"], handles={}),
    dict(id=uid(), name="Tomás Herrera",
         notes="Platform. Careful about what a health check actually proves.",
         emails=["tomas.herrera@example.com"], handles={}),
    dict(id=uid(), name="Sam Okafor",
         notes="Infrastructure, and the person who finds the config nobody "
               "grepped for.",
         emails=["sam.okafor@example.com"], handles={}),
]

projects = []

target = sys.argv[1] if len(sys.argv) > 1 else "/tmp/griasa-demo"
os.makedirs(target, exist_ok=True)
for name, payload in [("history.json", history),
                      ("commitments.json", commitments),
                      ("people.json", people),
                      ("projects.json", projects),
                      ("roster.json", ROSTER)]:
    with open(os.path.join(target, name), "w") as handle:
        json.dump(payload, handle, ensure_ascii=False)
print("wrote %d meetings, %d promises, %d people to %s"
      % (sum(1 for e in history if e["kind"] == "meeting"), len(commitments),
         len(people), target))
