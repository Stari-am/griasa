import Foundation

// Checks for finding meetings by the words of a query: any order, inflected
// forms, folded case, whole-word starts, and the ranking callers rely on.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runWordSearchChecks() -> Int {
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

func doc(_ title: String, _ text: String) -> WordSearch.Document { .init(title: title, text: text) }
func found(_ query: String, _ documents: [WordSearch.Document], limit: Int = 10) -> [Int] {
    WordSearch.rank(query, in: documents, limit: limit).map(\.index)
}

let meetings = [
    doc("Weekly sync", "Обсудили миграцию авторизации на новый сервис до конца квартала."),
    doc("Auth migration plan", "We will migrate auth after the release."),
    doc("Маркетинг", "Бюджет на маркетинг урезали на двадцать процентов."),
    doc("Онбординг", "Домовились перенести авторизацію на новий сервіс."),
    doc("Planning", "The planet of plans: three planning sessions."),
]

do {
    let hits = found("миграция авторизации", meetings)
    check(hits == [0], rule: "an inflected Russian query finds the meeting that used another case",
          meaning: "people type the nominative; meetings say «миграцию авторизации»",
          saw: "\(hits)")
}
do {
    let hits = found("migration auth", meetings)
    check(hits.first == 1, rule: "words match in any order, and a title match ranks first",
          meaning: "the old search wanted the exact phrase and missed reordered words",
          saw: "\(hits)")
}
do {
    let hits = found("АВТОРИЗАЦИЯ", meetings)
    check(Set(hits) == [0, 3], rule: "case is folded and the stem reaches the Ukrainian form",
          meaning: "«авторизацію» and «авторизации» share the stem «авторизац»",
          saw: "\(hits)")
}
do {
    let hits = found("net", [doc("x", "The planet is round"), doc("y", "Network outage")])
    check(hits == [1], rule: "a word matches only where a word begins",
          meaning: "«net» must not find «planet»",
          saw: "\(hits)")
}
do {
    let hits = found("бюджет космос", meetings)
    check(hits == [2], rule: "when no document has every word, those with some are returned",
          meaning: "one unknown word should not empty the result",
          saw: "\(hits)")
}
do {
    let hits = found("сервис квартал", meetings)
    check(hits == [0], rule: "documents with every word beat those with some",
          meaning: "the meeting that has both words is the one asked about",
          saw: "\(hits)")
}
do {
    let hits = found("и в на", meetings)
    check(WordSearch.terms("и в на") == ["и", "в", "на"],
          rule: "a query of only common words keeps them",
          meaning: "dropping every word would answer nothing", saw: "\(WordSearch.terms("и в на")) \(hits)")
    check(WordSearch.terms("план и бюджет") == ["план", "бюджет"],
          rule: "common words are dropped next to meaningful ones",
          meaning: "«и» matches every Russian meeting", saw: "\(WordSearch.terms("план и бюджет"))")
}
do {
    let same = [doc("a", "release notes"), doc("b", "release notes"), doc("c", "release notes")]
    let hits = found("release", same)
    check(hits == [0, 1, 2], rule: "ties keep the order passed in",
          meaning: "callers pass newest first, so equal matches stay newest first",
          saw: "\(hits)")
    check(found("release", same, limit: 2).count == 2, rule: "the limit is honoured",
          meaning: "an assistant asked for two meetings", saw: "\(found("release", same, limit: 2))")
}
do {
    let long = String(repeating: "слово ", count: 40) + "Ключевое решение: переезд на Postgres. " + String(repeating: "хвост ", count: 40)
    let hit = WordSearch.rank("postgres", in: [doc("x", long)], limit: 1).first
    let snippet = hit?.snippet ?? ""
    check(snippet.contains("Postgres") && snippet.count < 200 && snippet.hasPrefix("…") && snippet.hasSuffix("…"),
          rule: "the snippet shows the original words around the match, trimmed",
          meaning: "an assistant sees why a meeting matched without its transcript",
          saw: snippet)
    let titleOnly = WordSearch.rank("onboarding", in: [doc("Onboarding", "nothing here")], limit: 1).first
    check(titleOnly?.snippet == "", rule: "a title-only match has no snippet",
          meaning: "a snippet must show the match, not random text", saw: "\(String(describing: titleOnly))")
}
do {
    check(found("", meetings).isEmpty && found("   ", meetings).isEmpty,
          rule: "an empty query finds nothing", meaning: "callers treat no query as no filter themselves",
          saw: "\(found("", meetings))")
    check(WordSearch.stem("ёлки") == WordSearch.stem("елки"), rule: "ё and е are the same letter",
          meaning: "transcripts write either", saw: "\(WordSearch.stem("ёлки")) \(WordSearch.stem("елки"))")
}

return failures
}
