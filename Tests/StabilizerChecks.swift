import Foundation

// Checks for the two regressions that live typing actually shipped, plus the
// rules that stop them coming back. Run with ./test.sh; release.sh runs it too,
// so a broken invariant fails a build instead of reaching someone's screen.
//
// Every failure message states the rule that broke and what it means for the
// person using the app. "Expected true, got false" teaches whoever reads the
// failure nothing, and the reader is usually not the person who wrote the check.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runStabilizerChecks() -> Int {
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

/// Feeds hypotheses in one at a time and returns every non-nil emission.
func emissions(_ stabilizer: inout PartialStabilizer,
               _ hypotheses: [[(locale: String, text: String)]]) -> [String] {
    hypotheses.compactMap { stabilizer.absorb(legs: $0) }
}

func en(_ text: String) -> [(locale: String, text: String)] { [("en-US", text)] }

// ── The regression that shipped: a shorter hypothesis collapsed the line ──────
// Apple's recognizer re-segments constantly and routinely returns a hypothesis
// shorter than the one before. The old design emitted a frozen prefix plus the
// current hypothesis's tail, so a short hypothesis meant an empty tail and the
// visible text jumped backwards — deleting words the user had watched appear.
do {
    var stabilizer = PartialStabilizer()
    let out = emissions(&stabilizer, [
        en("the quick brown"),
        en("the quick brown fox"),
        en("the quick"),                     // the shrink that broke it
        en("the quick brown fox jumps"),
        en("the quick brown fox jumps"),
    ])
    var monotonic = true
    var previous = ""
    var offender = ""
    for text in out {
        if !text.hasPrefix(previous) {
            monotonic = false
            offender = "\"\(previous)\" then \"\(text)\""
            break
        }
        previous = text
    }
    check(monotonic,
          rule: "Emitted text is append-only: every emission extends the last one.",
          meaning: "Anything else is characters being deleted from a text field the user is still typing in, including text they typed themselves.",
          saw: monotonic ? "" : "emission stopped being an extension: \(offender)")

    check(out.allSatisfy { !$0.isEmpty },
          rule: "A stabilizer never emits an empty line.",
          meaning: "Emitting empty means erasing everything typed so far.",
          saw: "emissions: \(out)")
}

// ── The subtler regression: a re-worded opening spliced onto a committed prefix
// Agreement was computed by position, so word five of a new hypothesis could be
// appended after word two of the old one. The result was a grammatical sentence
// that nobody had said — the worst kind of wrong, because it reads as correct.
do {
    var stabilizer = PartialStabilizer()
    _ = stabilizer.absorb(legs: en("send it by friday"))
    let committed = stabilizer.absorb(legs: en("send it by friday please"))
    let afterRewording = stabilizer.absorb(legs: en("send them by friday please and thanks"))

    check(committed == "send it by friday",
          rule: "Words agreed on by two consecutive hypotheses are committed.",
          meaning: "If nothing is ever committed, live typing shows nothing at all.",
          saw: "committed: \(committed ?? "nil")")

    check(afterRewording == nil,
          rule: "A hypothesis that re-words the start of the utterance may not extend its end.",
          meaning: "Splicing a later word onto a prefix it never followed invents a sentence the speaker did not say, and a dropped word does not announce itself.",
          saw: "emitted \(afterRewording ?? "nil") after the opening changed from \"it\" to \"them\"")

    check(stabilizer.diverged,
          rule: "Divergence is recorded when the recognizer contradicts committed text.",
          meaning: "Without it, \"live typing stopped early\" and \"the recognizer changed its mind\" look identical in a trace, and the wrong one gets debugged.",
          saw: "diverged = \(stabilizer.diverged)")
}

// ── The language leg locks once, so a line is never rewritten in another tongue
do {
    var stabilizer = PartialStabilizer()
    _ = stabilizer.absorb(legs: [("en-US", "hello there"), ("ru-RU", "привет там")])
    let first = stabilizer.absorb(legs: [("en-US", "hello there friend"), ("ru-RU", "привет мир")])
    let second = stabilizer.absorb(legs: [("en-US", "hello there friend indeed"),
                                          ("ru-RU", "привет мир друг")])

    check(stabilizer.lockedLocale == "en-US",
          rule: "The first leg to produce agreed text keeps the line.",
          meaning: "Switching legs mid-utterance rewrites everything already typed, which is the mass-delete this whole component exists to prevent.",
          saw: "locked to \(stabilizer.lockedLocale ?? "nil")")

    check(first == "hello there" && second == "hello there friend",
          rule: "The locked leg keeps extending; the others stop steering the screen.",
          meaning: "The other recognizers still decide the final transcript, but they must not touch what is already visible.",
          saw: "emissions: \(first ?? "nil"), \(second ?? "nil")")
}

// ── Case and stray punctuation are not disagreement ──────────────────────────
// Apple flips "сделай"/"Сделай" and adds commas as context grows. Treating that
// as disagreement stalls commitment on a word the recognizer is sure about.
do {
    let sameWord = PartialStabilizer.agreedWordCount(["сделай"], ["Сделай,"])
    check(sameWord == 1,
          rule: "Two spellings of one word that differ only in case or edge punctuation agree.",
          meaning: "Otherwise commitment stalls on words the recognizer is certain about, and live typing lags far behind the voice for no reason.",
          saw: "agreed word count: \(sameWord)")

    let differentWord = PartialStabilizer.agreedWordCount(["send", "it"], ["send", "them"])
    check(differentWord == 1,
          rule: "Genuinely different words do not agree.",
          meaning: "If they did, the case-insensitive comparison would be hiding real disagreement and committing text nobody said.",
          saw: "agreed word count: \(differentWord)")
}

return failures
}
