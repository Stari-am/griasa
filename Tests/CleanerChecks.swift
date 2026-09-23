import Foundation

// Checks for what the transcript cleaner removes. Removing too little leaves a
// meeting punctuated by pleasantries nobody said — Whisper decodes a sub-second
// burst of noise as "Thank you." Removing too much deletes what somebody meant:
// in dictation, "thank you" is very often the whole message.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runCleanerChecks() -> Int {
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

func texts(_ lines: [String], meeting: Bool) -> [String] {
    TranscriptCleaner.clean(lines.enumerated().map { TranscriptSegment(start: Double($0.offset), text: $0.element) },
                            meeting: meeting).map(\.text)
}

let measured = texts(["We moved the release to Thursday.", "Thank you.", "Who owns the rollout?"], meeting: true)
check(measured == ["We moved the release to Thursday.", "Who owns the rollout?"],
      rule: "in a meeting, a segment that is only \"Thank you.\" is removed",
      meaning: "this is the measured case — noise regions of a real meeting, sent to Whisper on their own, each came back as exactly this, and the transcript read like people thanking nobody",
      saw: "\(measured)")

let russian = texts(["Спасибо.", "Спасибо большое!", "Давай вернёмся к бюджету."], meeting: true)
check(russian == ["Давай вернёмся к бюджету."],
      rule: "the Russian equivalents go the same way",
      meaning: "the meetings are bilingual and Whisper hallucinates in whichever language it decided the audio was in",
      saw: "\(russian)")

let inSentence = texts(["Okay, thank you, next item.", "Спасибо, Марк, отличная работа."], meeting: true)
check(inSentence.count == 2,
      rule: "\"thank you\" inside a longer sentence is never touched",
      meaning: "the rule is about a whole segment being a pleasantry; a substring match would cut real speech out of the middle of what people said",
      saw: "\(inSentence)")

let dictated = texts(["Thank you."], meeting: false)
check(dictated == ["Thank you."],
      rule: "dictation keeps a bare \"Thank you.\"",
      meaning: "typed into a chat, \"thank you\" is often the entire message — dropping it would make the app eat exactly what the person said",
      saw: "\(dictated)")

let defaulted = TranscriptCleaner.clean([TranscriptSegment(start: 0, text: "Thanks!")]).map(\.text)
check(defaulted == ["Thanks!"],
      rule: "the meeting rule is off unless a caller asks for it",
      meaning: "every existing caller of clean() is a dictation or single-file path until proven otherwise; the safe default is to remove less",
      saw: "\(defaulted)")

let credits = texts(["Спасибо за субтитры!", "Real content here."], meeting: false)
check(credits == ["Real content here."],
      rule: "the existing subtitle-credit hallucinations are still removed everywhere",
      meaning: "adding a meeting-only rule must not have weakened the rule that was already there",
      saw: "\(credits)")

return failures
}
