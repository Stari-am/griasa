import Foundation

// Checks for decisions and the team view: a decisions file written before a
// field existed still loads, repeats are not kept twice, search finds them, and
// what each direct report owes comes out in the right order with a usable
// check-in note.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runDecisionChecks() -> Int {
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

// Decoding.
do {
    let old = #"[{"text":"Go with Postgres","sourceTitle":"Sync"}]"#
    let decoded = try? JSONDecoder().decode([Decision].self, from: Data(old.utf8))
    check(decoded?.first?.text == "Go with Postgres" && decoded?.first?.alternatives == [] && decoded?.first?.reversed == false,
          rule: "a decisions file with only text and title loads, with empty defaults",
          meaning: "a missing key must not take every decision with it", saw: "\(String(describing: decoded))")
    let full = Decision(text: "Move launch to May", why: "QA", decidedBy: "Maya", alternatives: ["April"],
                        quote: "we move it to May", at: "12:03", sourceTitle: "Roadmap", sourceEntryID: UUID(),
                        revisitDate: Date(timeIntervalSince1970: 1_800_000_000), reversed: true, reversedNote: "back to April")
    let round = (try? JSONEncoder().encode([full])).flatMap { try? JSONDecoder().decode([Decision].self, from: $0) }
    check(round?.first == full, rule: "a decision with every field survives a save and load",
          meaning: "nothing typed or extracted may be lost on the way to disk", saw: "\(String(describing: round?.first))")
}

// Revisiting.
do {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let due = Decision(text: "a", sourceTitle: "", revisitDate: yesterday)
    let later = Decision(text: "b", sourceTitle: "", revisitDate: tomorrow)
    let reversed = Decision(text: "c", sourceTitle: "", revisitDate: yesterday, reversed: true)
    check(due.needsRevisit(on: today, calendar: calendar) && !later.needsRevisit(on: today, calendar: calendar)
          && !reversed.needsRevisit(on: today, calendar: calendar) && !Decision(text: "d", sourceTitle: "").needsRevisit(on: today),
          rule: "a decision is due for a look on its revisit day or after, unless it was reversed",
          meaning: "the morning brief lists exactly these", saw: "")
}

// Duplicates.
do {
    let meeting = UUID(), other = UUID()
    let kept = [Decision(text: "We go with Postgres.", quote: "Let's go with Postgres", sourceTitle: "", sourceEntryID: meeting)]
    check(DecisionRules.isDuplicate(Decision(text: "we go with postgres", sourceTitle: "", sourceEntryID: meeting), of: kept),
          rule: "the same decision in other case and punctuation is a repeat",
          meaning: "re-processing a meeting must not double its decisions", saw: "")
    check(DecisionRules.isDuplicate(Decision(text: "Postgres it is", quote: "let's go with Postgres!", sourceTitle: "",
                                             sourceEntryID: meeting), of: kept),
          rule: "a decision quoting the same words is a repeat",
          meaning: "a model rephrases a decision between runs; the quote does not change", saw: "")
    check(!DecisionRules.isDuplicate(Decision(text: "We go with Postgres.", sourceTitle: "", sourceEntryID: other), of: kept),
          rule: "the same words in another meeting are another decision",
          meaning: "deciding it again later is history worth keeping", saw: "")
}

// Search.
do {
    let decisions = [
        Decision(text: "Перенести запуск на май", why: "не успевает QA", sourceTitle: "", date: Date(timeIntervalSince1970: 1)),
        Decision(text: "Use Postgres for billing", alternatives: ["MongoDB"], sourceTitle: "", date: Date(timeIntervalSince1970: 2)),
    ]
    check(DecisionRules.search("запуск", in: decisions, limit: 5).map(\.text) == ["Перенести запуск на май"]
          && DecisionRules.search("mongodb", in: decisions, limit: 5).count == 1,
          rule: "decisions are found by their words and by the options they rejected",
          meaning: "\"did we ever consider Mongo?\" has to find the decision that rejected it", saw: "")
    check(DecisionRules.search("", in: decisions, limit: 5).first?.text == "Use Postgres for billing",
          rule: "with no query the newest decisions come first", meaning: "the journal opens on what is recent", saw: "")
}

// Team.
do {
    let calendar = Calendar.current
    let now = Date()
    let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!
    let nextWeek = calendar.date(byAdding: .day, value: 7, to: now)!
    let items = [
        Commitment(text: "Send the schema", owner: "Ivan Petrov", isMine: false, dueDate: nextWeek, sourceTitle: ""),
        Commitment(text: "Fix the export", owner: "ivan petrov", isMine: false, dueDate: lastWeek, sourceTitle: ""),
        Commitment(text: "Done already", owner: "Ivan Petrov", isMine: false, sourceTitle: "", done: true),
        Commitment(text: "Mine", owner: "Ivan Petrov", isMine: true, sourceTitle: ""),
        Commitment(text: "Draft the plan", owner: "Olena", isMine: false, sourceTitle: ""),
    ]
    let members = TeamDigest.members(names: ["Olena", "Ivan Petrov", "Maya"], commitments: items, lastMet: { _ in nil }, now: now)
    check(members.map(\.name) == ["Ivan Petrov", "Maya", "Olena"],
          rule: "people with something overdue come first, then everyone by name",
          meaning: "the view opens on who needs a nudge", saw: "\(members.map(\.name))")
    check(members.first?.owed.map(\.text) == ["Fix the export", "Send the schema"] && members.first?.overdue == 1,
          rule: "a report's list is their open promises, overdue first, never the user's own or finished ones",
          meaning: "this is what they owe the user, not what the user owes them", saw: "\(members.first?.owed.map(\.text) ?? [])")
    check(members.first(where: { $0.name == "Maya" })?.owed.isEmpty == true,
          rule: "a report with nothing open is still listed", meaning: "the team is everyone marked, not only the late", saw: "")
    let nudge = TeamDigest.nudge(to: "Ivan Petrov", about: members.first!.owed)
    check(nudge.hasPrefix("Hi Ivan,") && nudge.contains("• Fix the export") && nudge.contains("• Send the schema"),
          rule: "a check-in note greets by first name and lists what they said they would do",
          meaning: "it is pasted into a chat as is", saw: nudge)
    let ru = TeamDigest.nudge(to: "Иван", about: [Commitment(text: "Скинуть схему", owner: "Иван", isMine: false,
                                                            dueHint: "до пятницы", sourceTitle: "")])
    let uk = TeamDigest.nudge(to: "Олена", about: [Commitment(text: "Перевірити переклад", owner: "Олена", isMine: false, sourceTitle: "")])
    check(ru.hasPrefix("Иван, привет") && ru.contains("(до пятницы)") && uk.hasPrefix("Олена, привіт"),
          rule: "the note is in Russian or Ukrainian when the promises are",
          meaning: "a check-in in the wrong language reads like a form letter", saw: ru + " | " + uk)
    check(TeamDigest.nudge(to: "X", about: []).isEmpty, rule: "nothing owed, no note",
          meaning: "an empty check-in is not sent", saw: "")
}

// Benchmark scoring.
do {
    let gold = [
        BenchmarkScore.GoldDecision(text: "Move the launch to May", by: nil, quote: "so we move the launch to May", reversed: false),
        BenchmarkScore.GoldDecision(text: "Deprecate the v1 API this quarter", by: "Tom", quote: "we deprecate v1 this quarter", reversed: true),
        BenchmarkScore.GoldDecision(text: "Keep Postgres", by: nil, quote: "we keep Postgres", reversed: false),
    ]
    let predicted = [
        BenchmarkScore.DecisionPrediction(text: "Launch moves to May", quote: "So we move the launch to May.", reversed: false),
        BenchmarkScore.DecisionPrediction(text: "Deprecate v1 API this quarter", quote: nil, reversed: true),
        BenchmarkScore.DecisionPrediction(text: "Hire two designers", quote: "hire two designers", reversed: false),
    ]
    let result = BenchmarkScore.scoreDecisions(gold: gold, predicted: predicted)
    check(result.matched == 2 && result.gold == 3 && result.predicted == 3,
          rule: "a decision matches by its quote, or else by the words of its text, one to one",
          meaning: "recall and precision for decisions are counted like those for promises", saw: "\(result)")
    check(result.reversedFound == 1 && result.goldReversed == 1 && result.reversedCorrect == 2,
          rule: "a reversed decision found as reversed is counted",
          meaning: "keeping a decision that was taken back as if it stood is the costly mistake", saw: "\(result)")
    let legacy = #"{"promises":[],"traps":[]}"#
    check((try? JSONDecoder().decode(BenchmarkScore.GoldFile.self, from: Data(legacy.utf8)))?.decisions == nil,
          rule: "a gold file without decisions still loads", meaning: "the promise benchmark must not break", saw: "")
}

// People.
do {
    let old = #"[{"name":"Ivan"}]"#
    let person = (try? JSONDecoder().decode([Person].self, from: Data(old.utf8)))?.first
    check(person?.isDirectReport == false, rule: "a person saved before the team flag existed is not a report",
          meaning: "nobody joins the team without being marked", saw: "\(String(describing: person?.isDirectReport))")
    var a = Person(name: "Ivan"); a.isDirectReport = true
    let b = Person(name: "Ваня")
    check(b.absorbing(a).isDirectReport && a.absorbing(b).isDirectReport,
          rule: "merging two records of one person keeps the team flag",
          meaning: "a merge must not quietly take someone off the team", saw: "")
}

return failures
}
