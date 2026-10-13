import Foundation

// Checks for meetings recorded before the model was ready. Each must be
// summarized exactly once when it arrives, oldest first.

func runPendingChecks() -> Int {
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
let a = UUID(), b = UUID(), c = UUID()
var queue = PendingSummaries(ids: [])
queue.add(a); queue.add(b); queue.add(a)
check(queue.ids == [a, b], rule: "adding twice keeps one, in arrival order",
      meaning: "a meeting summarized twice gets its promises twice", saw: "\(queue.ids)")
check(queue.next(existing: [a, b], alreadySummarized: []) == a,
      rule: "oldest first", meaning: "people read their week in order", saw: "\(String(describing: queue.next(existing: [a, b], alreadySummarized: [])))")
check(queue.next(existing: [b], alreadySummarized: []) == b,
      rule: "a deleted meeting is skipped", meaning: "nothing to summarize", saw: "wrong")
check(queue.next(existing: [a, b], alreadySummarized: [a]) == b,
      rule: "a meeting re-summarized by hand meanwhile is skipped",
      meaning: "doing it again would add its promises a second time", saw: "wrong")
check(queue.next(existing: [a, b], alreadySummarized: [a, b]) == nil, rule: "nothing left → nil", meaning: "the loop stops", saw: "not nil")
queue.add(c); queue.remove(b)
let round = PendingSummaries.load(from: queue.encoded())
check(round == queue && round.ids == [a, c], rule: "the queue survives a restart",
      meaning: "a download can outlast the session that started it", saw: "\(round.ids)")
check(PendingSummaries.load(from: Data("junk".utf8)).ids.isEmpty && PendingSummaries.load(from: nil).ids.isEmpty,
      rule: "a damaged or missing queue is empty, not a crash", meaning: "launch must never fail on it", saw: "not empty")
// Skipping and owed promises
var q = PendingSummaries(ids: [a, b, c])
check(q.next(existing: [a, b, c], alreadySummarized: [], skipping: [a]) == b,
      rule: "a meeting being worked on by hand is skipped this round, and the next one runs",
      meaning: "one click in History must not stop the whole catch-up",
      saw: "\(String(describing: q.next(existing: [a, b, c], alreadySummarized: [], skipping: [a])))")
q.summarySaved(a)
check(q.next(existing: [a, b, c], alreadySummarized: [a]) == a && q.needsOnlyExtraction(a, alreadySummarized: [a])
        && !q.needsOnlyExtraction(b, alreadySummarized: [a]),
      rule: "a meeting whose summary was saved but whose promises failed is still due, for its promises only",
      meaning: "its History text is no longer raw, so without this it looks done and its promises are never collected",
      saw: "next \(String(describing: q.next(existing: [a, b, c], alreadySummarized: [a])))")
q.prune(existing: [a, b, c], alreadySummarized: [a, b])
check(q.ids == [a, c],
      rule: "pruning drops a meeting summarized by hand meanwhile, and keeps one whose promises are owed",
      meaning: "the owed one would lose its promises; the hand-done one would get its promises twice",
      saw: "\(q.ids)")
q.prune(existing: [c], alreadySummarized: [])
check(q.ids == [c] && q.extractionOwed.isEmpty,
      rule: "a deleted meeting goes, owed promises and all",
      meaning: "nothing left to collect from", saw: "\(q.ids) \(q.extractionOwed)")
let old = Data(#"{"ids":["\#(a.uuidString)"]}"#.utf8)
check(PendingSummaries.load(from: old).ids == [a],
      rule: "a queue saved by 1.0.16 (no owed-promises list) still loads",
      meaning: "failing to decode would silently drop every meeting waiting for a summary",
      saw: "\(PendingSummaries.load(from: old).ids)")
var owedRound = PendingSummaries(ids: [a, b]); owedRound.summarySaved(b)
check(PendingSummaries.load(from: owedRound.encoded()) == owedRound,
      rule: "owed promises survive a restart", meaning: "the next launch's catch-up must still collect them",
      saw: "\(PendingSummaries.load(from: owedRound.encoded()).extractionOwed)")

var manual = PendingSummaries(ids: [a, b]); manual.summarySaved(a)
manual.promisesCollected(a); manual.promisesCollected(b)
check(manual.ids == [b] && manual.extractionOwed.isEmpty,
      rule: "promises collected by hand settle a meeting that owed only them, and leave one still waiting for its summary",
      meaning: "the catch-up would otherwise collect them again (reworded, so not deduplicated), or never rebuild the summary",
      saw: "\(manual.ids)")

return failures
}
