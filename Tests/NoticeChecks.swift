import Foundation

// Checks for the recording-notice reminder. Off by default for everybody;
// when an organisation turns it on, a mistake in how it was turned on must
// produce one reminder too many rather than a call nobody was told about.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runNoticeChecks() -> Int {
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

check(!RecordingNotice.isOn(nil),
      rule: "with nothing set, the reminder is off",
      meaning: "it is opt-in — an install nobody configured must start recordings exactly as before",
      saw: "absent key read as on")

check(RecordingNotice.isOn(true) && !RecordingNotice.isOn(false)
        && RecordingNotice.isOn(NSNumber(value: 1)) && !RecordingNotice.isOn(NSNumber(value: 0)),
      rule: "a real boolean means what it says",
      meaning: "the Settings toggle and a correctly written profile both store booleans",
      saw: "a boolean was read the wrong way round")

check(RecordingNotice.isOn("true") && RecordingNotice.isOn("YES") && RecordingNotice.isOn("enabled")
        && RecordingNotice.isOn(["on"]),
      rule: "anything written that is not a clear no counts as on",
      meaning: "the only reason to write this key is to turn it on; a profile typo must not leave calls recorded without the reminder",
      saw: "a written-but-unusual value was read as off")

check(!RecordingNotice.isOn("false") && !RecordingNotice.isOn(" No ") && !RecordingNotice.isOn("0")
        && !RecordingNotice.isOn("off"),
      rule: "the usual spellings of no turn it off",
      meaning: "fail-safe must not mean impossible to switch off — \"false\" written as a string is still a no",
      saw: "a clear no was read as on")

check(RecordingNotice.text(nil) == RecordingNotice.defaultText
        && RecordingNotice.text("   ") == RecordingNotice.defaultText
        && RecordingNotice.text("  We record our calls.  ") == "We record our calls.",
      rule: "a blank sentence falls back to the default; a custom one is used, trimmed",
      meaning: "an empty reminder would show a box with nothing to paste into the chat",
      saw: "text(nil)=\(RecordingNotice.text(nil).prefix(20))…, text(blank) wrong, or custom not trimmed")

check(RecordingNotice.defaultText.lowercased().contains("recording")
        && RecordingNotice.defaultText.contains("rather I didn't"),
      rule: "the default sentence says the call is recorded and offers a way out",
      meaning: "an announcement without a way to object is not asking — the offer is what makes it closer to consent",
      saw: RecordingNotice.defaultText)

check(ManagedPolicy.lockableKeys.contains(RecordingNotice.enabledKey)
        && ManagedPolicy.lockableKeys.contains(RecordingNotice.textKey),
      rule: "an organisation's profile can lock the reminder on, and its wording",
      meaning: "a toggle a profile has forced that the user can still flip back is exactly the confusion the lock exists to prevent",
      saw: "\(ManagedPolicy.lockableKeys)")

return failures
}
