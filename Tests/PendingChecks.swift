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
return failures
}
