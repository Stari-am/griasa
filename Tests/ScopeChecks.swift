import Foundation

// Checks for what a manager is shown before a meeting. The thing being guarded
// against is not a crash: it is the panel hiding a promise that mattered, or
// filling up with promises that had nothing to do with the people in the room —
// which is the complaint this code exists to answer.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runScopeChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

typealias Scope = CommitmentScope

// ── Meeting shape ────────────────────────────────────────────────────────────

// The participant list holds everybody besides the user, so one name is a
// one-to-one. If this miscounts, private follow-ups get filed as team ones.
do {
    let cases: [([String], Scope.Shape)] = [
        ([], .unknown),
        (["Petrov"], .oneToOne),
        (["Petrov", "Ivanova"], .group),
        (["  ", ""], .unknown),
        (["Petrov", "  "], .oneToOne),
        (["Petrov", "petrov"], .oneToOne),
    ]
    let wrong = cases.filter { Scope.shape(of: $0.0) != $0.1 }
    check(wrong.isEmpty,
          rule: "one name besides the user is a one-to-one, two or more is a group",
          meaning: "the whole point of separating personal from general is this count; "
                 + "getting it wrong shows private follow-ups in a team meeting",
          saw: "wrong: \(wrong.map { "\($0.0) → \(Scope.shape(of: $0.0))" })")
}

// The same person listed twice is still one person. Without this, a duplicated
// name silently promotes a one-to-one into a group.
do {
    check(Scope.shape(of: ["Petrov", "PETROV ", "petrov"]) == .oneToOne,
          rule: "the same name repeated does not make a meeting a group",
          meaning: "names arrive typed by hand after a call, so a duplicate is normal — "
                 + "and it must not change what kind of meeting this was",
          saw: "\(Scope.shape(of: ["Petrov", "PETROV ", "petrov"]))")
}

// ── Series identity ──────────────────────────────────────────────────────────

do {
    let a = Scope.seriesKey(["Petrov", "Ivanova", "Sidorov"])
    let b = Scope.seriesKey(["  sidorov", "PETROV", "Ivanova  "])
    check(a != nil && a == b,
          rule: "the same people in any order and any case are the same series",
          meaning: "the roster spelling varies between recordings; if the key varies with "
                 + "it, a weekly meeting never recognises its own previous occurrence",
          saw: "\(String(describing: a)) vs \(String(describing: b))")
}

// The measured refutation, kept as a rule: matching loosely joined 39 of 46 real
// meetings into one cluster, so a set that merely overlaps is NOT the series.
do {
    let four = Scope.seriesKey(["Petrov", "Ivanova", "Sidorov", "Kuznetsov"])
    let three = Scope.seriesKey(["Petrov", "Ivanova", "Sidorov"])
    check(four != three,
          rule: "a participant set that only overlaps is a different series",
          meaning: "measured on the real store: at 60% overlap, 39 of 46 meetings collapse "
                 + "into a single cluster of eleven, and every meeting becomes every other "
                 + "meeting's history",
          saw: "four-person key equals three-person key: \(four == three)")
}

do {
    check(Scope.seriesKey([]) == nil && Scope.seriesKey(["", " "]) == nil,
          rule: "a meeting with no participants has no series",
          meaning: "otherwise every meeting recorded before participants were stored counts "
                 + "as a recurrence of every other one",
          saw: "empty → \(String(describing: Scope.seriesKey([]))), "
             + "blank → \(String(describing: Scope.seriesKey(["", " "])))")
}

// ── Buckets ──────────────────────────────────────────────────────────────────

let now = Date(timeIntervalSince1970: 1_800_000_000)
let yesterday = now.addingTimeInterval(-86_400)
let tomorrow = now.addingTimeInterval(86_400)
let team = ["Petrov", "Ivanova", "Sidorov"]
let teamKey = Scope.seriesKey(team)

func bucket(_ item: Scope.Item, attendees: [String] = team,
            series: String? = nil) -> Scope.Bucket {
    Scope.bucket(item, attendees: attendees, seriesKey: series ?? teamKey, now: now)
}

// The complaint that started this: a promise involving nobody in the room used
// to be listed anyway.
do {
    let outsider = Scope.Item(owner: "Nikolaev", isMine: false,
                              sourceParticipants: ["Nikolaev"])
    check(bucket(outsider) == .hidden,
          rule: "a promise involving nobody in the room is not shown",
          meaning: "a weekly meeting's panel filled with every open promise globally is a "
                 + "list nobody reads, which is the state this replaces",
          saw: "\(bucket(outsider))")
}

do {
    let sameSeries = Scope.Item(owner: "Petrov", isMine: false, sourceParticipants: team)
    check(bucket(sameSeries) == .thisMeeting,
          rule: "a promise from a previous occurrence of this meeting is 'this meeting'",
          meaning: "for a meeting that happens every week, what was promised in it last "
                 + "time is the thing you actually need",
          saw: "\(bucket(sameSeries))")
}

do {
    let oneToOne = Scope.Item(owner: "Petrov", isMine: false, sourceParticipants: ["Petrov"])
    check(bucket(oneToOne) == .personal,
          rule: "a promise from a one-to-one with somebody in the room is 'personal'",
          meaning: "mixing private follow-ups into a group brief is the second half of the "
                 + "original complaint",
          saw: "\(bucket(oneToOne))")
}

// A one-to-one with somebody who is not on this call is not personal — it is not
// shown at all. Without the relevance test, "personal" would collect every 1-1.
do {
    let elsewhere = Scope.Item(owner: "Nikolaev", isMine: false,
                               sourceParticipants: ["Nikolaev"])
    check(bucket(elsewhere) == .hidden,
          rule: "a one-to-one with somebody not in the room is not 'personal'",
          meaning: "otherwise the personal section becomes every private conversation you "
                 + "have ever had, in front of a room that has nothing to do with them",
          saw: "\(bucket(elsewhere))")
}

// Reachable only past the relevance test: the owner is in the room, but the
// one-to-one this came out of was with somebody who is not. It is relevant, and
// it is still not "personal" to anybody on this call. Found by mutation — the
// earlier version of this rule could be removed without any check noticing.
do {
    let elsewhere = Scope.Item(owner: "Petrov", isMine: false,
                               sourceParticipants: ["Nikolaev"])
    check(bucket(elsewhere) == .general,
          rule: "'personal' means a one-to-one with somebody on this call, not any one-to-one",
          meaning: "a promise from a private conversation with a third party is not private "
                 + "to the people in this room, and filing it as such implies a confidence "
                 + "about who discussed what that the record does not support",
          saw: "\(bucket(elsewhere))")
}

do {
    let other = Scope.Item(owner: "Petrov", isMine: false,
                           sourceParticipants: ["Petrov", "Kuznetsov"])
    check(bucket(other) == .general,
          rule: "a promise with an attendee from some other group meeting is 'general'",
          meaning: "it is relevant — the person is in the room — but it is not what this "
                 + "meeting is about, so it must not crowd out what is",
          saw: "\(bucket(other))")
}

// Overdue cuts across origin. Before a call, a date that has passed is the thing
// to raise, whichever meeting produced it.
do {
    let late = Scope.Item(owner: "Petrov", isMine: false, dueDate: yesterday,
                          sourceParticipants: team)
    let onTime = Scope.Item(owner: "Petrov", isMine: false, dueDate: tomorrow,
                            sourceParticipants: team)
    check(bucket(late) == .overdue && bucket(onTime) == .thisMeeting,
          rule: "a passed date outranks which meeting the promise came from",
          meaning: "grouping by origin is useful; burying a missed deadline inside it is not",
          saw: "overdue case → \(bucket(late)), future case → \(bucket(onTime))")
}

// A date in the future is not overdue. An off-by-one here marks everything late.
do {
    let exactly = Scope.Item(owner: "Petrov", isMine: false, dueDate: now,
                             sourceParticipants: team)
    check(bucket(exactly) != .overdue,
          rule: "a promise due exactly now is not yet overdue",
          meaning: "'overdue' has to mean the date has passed, or the section fills with "
                  + "things that are due today and stops meaning anything",
          saw: "\(bucket(exactly))")
}

// My own promises are owed BY me, so the owner is never an attendee — their
// relevance comes from the meeting they were made in.
do {
    let mineHere = Scope.Item(owner: "You", isMine: true, sourceParticipants: team)
    let mineElsewhere = Scope.Item(owner: "You", isMine: true,
                                   sourceParticipants: ["Nikolaev"])
    check(bucket(mineHere) == .thisMeeting && bucket(mineElsewhere) == .hidden,
          rule: "my own promise is placed by the meeting it was made in, not by its owner",
          meaning: "the owner of my promises is me, and I am never in the attendee list — "
                 + "testing the owner alone would hide every promise I made",
          saw: "made here → \(bucket(mineHere)), made elsewhere → \(bucket(mineElsewhere))")
}

// A promise owed by an attendee counts even with no source meeting recorded —
// that covers everything added by hand.
do {
    let byHand = Scope.Item(owner: "Ivanova", isMine: false)
    check(byHand.sourceParticipants.isEmpty && bucket(byHand) == .general,
          rule: "a promise added by hand still shows when its owner is in the room",
          meaning: "items typed in by the user have no source meeting, and dropping them "
                 + "would quietly lose the ones somebody bothered to add",
          saw: "\(bucket(byHand))")
}

// No room, nothing to scope against.
do {
    let item = Scope.Item(owner: "Petrov", isMine: false, sourceParticipants: team)
    check(Scope.bucket(item, attendees: [], seriesKey: nil, now: now) == .hidden,
          rule: "with nobody identified on the call, nothing is claimed to be relevant",
          meaning: "a brief for a meeting whose attendees could not be resolved should say "
                 + "nothing rather than guess, which is what the empty state is for",
          saw: "\(Scope.bucket(item, attendees: [], seriesKey: nil, now: now))")
}

// ── What needs a human to look at it ─────────────────────────────────────────

// Undated only. A promise with a date already appears under Overdue when the
// date passes; asking about it as well shows one item twice for two reasons.
do {
    check(!Scope.needsReview(ageDays: 120, hasDueDate: true, reviewedDaysAgo: nil),
          rule: "a promise with a date is never put up for review",
          meaning: "it surfaces itself when it comes due, and showing it in two places for "
                 + "two different reasons is how a list stops being trusted",
          saw: "\(Scope.needsReview(ageDays: 120, hasDueDate: true, reviewedDaysAgo: nil))")
}

// The threshold is the number measured off the real store: at 30 days there are
// 38 to work through, at 14 there would be 137.
do {
    let just = Scope.needsReview(ageDays: Scope.reviewAfterDays,
                                 hasDueDate: false, reviewedDaysAgo: nil)
    let under = Scope.needsReview(ageDays: Scope.reviewAfterDays - 1,
                                  hasDueDate: false, reviewedDaysAgo: nil)
    check(just && !under,
          rule: "review starts exactly at the threshold and not before",
          meaning: "the threshold was chosen because it yields a batch somebody works "
                 + "through rather than another list nobody reads; drifting below it "
                 + "undoes that",
          saw: "at \(Scope.reviewAfterDays) days: \(just), one day under: \(under)")
}

// Saying "still open" has to buy silence, or the answer stops being given.
do {
    let asked = Scope.needsReview(ageDays: 200, hasDueDate: false, reviewedDaysAgo: 1)
    let again = Scope.needsReview(ageDays: 200, hasDueDate: false,
                                  reviewedDaysAgo: Scope.reviewAfterDays)
    check(!asked && again,
          rule: "a promise just confirmed is quiet, and comes back after the same window",
          meaning: "asking again tomorrow trains the user to ignore the question; never "
                 + "asking again turns a confirmation into a permanent exemption",
          saw: "one day after confirming: \(asked), a full window later: \(again)")
}

// ── Which promises get asked about ───────────────────────────────────────────

// The prompt can only carry a few dozen of 339 open promises. Ranking them by
// recency alone means an older meeting is only ever offered promises made after
// it, which is backwards — a meeting can only close something that already
// existed.
do {
    let old = UUID(), recent = UUID(), unrelated = UUID()
    let entry = UUID()
    let items: [(id: UUID, owner: String, date: Date, sourceEntryID: UUID?)] = [
        (recent, "Nikolaev", Date(timeIntervalSince1970: 1_800_000_000), nil),
        (unrelated, "Nikolaev", Date(timeIntervalSince1970: 1_700_000_000), nil),
        (old, "Petrov", Date(timeIntervalSince1970: 1_000_000_000), entry),
    ]
    let ranked = Scope.rankedCandidates(items, near: ["Petrov"],
                                        participantsByEntry: [entry: ["petrov"]])
    check(ranked.first == old,
          rule: "a promise tied to the people in the room is asked about before newer ones",
          meaning: "with 339 open promises and room for a few dozen, ranking by date alone "
                 + "means an old meeting is only ever shown promises made after it — so it "
                 + "can never close anything",
          saw: "first ranked is \(ranked.first == old ? "the related one" : "something else")")
    check(ranked.count == items.count && Set(ranked).count == items.count,
          rule: "ranking keeps every promise exactly once",
          meaning: "a promise dropped here is never asked about, and one duplicated wastes "
                 + "the room the prompt has",
          saw: "\(ranked.count) ranked, \(Set(ranked).count) distinct, of \(items.count)")
}

// With nobody identified, recency is all there is — and it must still be in order.
do {
    let a = UUID(), b = UUID()
    let items: [(id: UUID, owner: String, date: Date, sourceEntryID: UUID?)] = [
        (a, "X", Date(timeIntervalSince1970: 1_000), nil),
        (b, "Y", Date(timeIntervalSince1970: 2_000), nil),
    ]
    check(Scope.rankedCandidates(items, near: [], participantsByEntry: [:]) == [b, a],
          rule: "with no participants to relate to, the newest promise comes first",
          meaning: "the fallback has to be deterministic, or the same meeting proposes a "
                 + "different set of candidates on every run",
          saw: "\(Scope.rankedCandidates(items, near: [], participantsByEntry: [:]) == [b, a])")
}

return failures
}
