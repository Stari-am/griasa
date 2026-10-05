import Foundation

// Checks for importing meeting notes made by another tool. The notes can be
// weeks old, and two things that are harmless for a meeting recorded just now
// become wrong for an old one: where it sits in the history, and whether it is
// allowed to close promises made after it.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runImportChecks() -> Int {
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

let fromHeading = ImportedNotes.title(from: "\n\n# Meeting notes — Checkout weekly\n\nWe agreed…")
check(fromHeading == "Checkout weekly",
      rule: "the title comes from the first heading, without a boilerplate prefix",
      meaning: "every tool starts its notes the same way; a history where every row begins \"Meeting notes\" cannot be scanned",
      saw: fromHeading)

let fromLine = ImportedNotes.title(from: "Sync with Dana about the vendor\nThey will hold the rate")
let blank = ImportedNotes.title(from: "  \n \n")
let long = ImportedNotes.title(from: String(repeating: "x", count: 200))
check(fromLine == "Sync with Dana about the vendor" && blank == "Imported meeting" && long.count == 80,
      rule: "with no heading the first line is used, nothing gives a fallback, and a long one is cut",
      meaning: "an empty title is a row nobody can find; a 200-character one breaks the list",
      saw: "line \(fromLine), blank \(blank), long \(long.count) chars")

check(ImportedNotes.clean("\u{FEFF}line one\r\nline two\r\n\n") == "line one\nline two",
      rule: "Windows line endings and a byte-order mark are normalised away",
      meaning: "notes exported from other tools often carry both, and the BOM would land in the title",
      saw: ImportedNotes.clean("\u{FEFF}line one\r\nline two\r\n\n").debugDescription)

let day: TimeInterval = 86_400
let now = Date(timeIntervalSince1970: 1_800_000_000)
let history = [now, now - day, now - 10 * day]          // newest first
check(ImportedNotes.insertionIndex(of: now + 60, in: history) == 0
        && ImportedNotes.insertionIndex(of: now - 5 * day, in: history) == 2
        && ImportedNotes.insertionIndex(of: now - 30 * day, in: history) == 3
        && ImportedNotes.insertionIndex(of: now, in: []) == 0,
      rule: "an imported meeting goes where its date puts it in a newest-first history",
      meaning: "readers take the first meeting to be the latest; a month-old import on top would become \"last time\" in every brief",
      saw: "indices \(ImportedNotes.insertionIndex(of: now + 60, in: history)), \(ImportedNotes.insertionIndex(of: now - 5 * day, in: history)), \(ImportedNotes.insertionIndex(of: now - 30 * day, in: history))")

check(!ImportedNotes.mayDetectClosures(meetingDate: now - 20 * day, newestOtherMeeting: now - day),
      rule: "notes older than the latest meeting are not asked which promises they closed",
      meaning: "they would offer to close promises made after that conversation took place, quoting a sentence that cannot be about them",
      saw: "an old import was allowed to close promises")

check(ImportedNotes.mayDetectClosures(meetingDate: now, newestOtherMeeting: now - day)
        && ImportedNotes.mayDetectClosures(meetingDate: now, newestOtherMeeting: nil),
      rule: "the latest meeting, imported or recorded, may close promises",
      meaning: "importing yesterday's ChatGPT notes should work like having recorded the call",
      saw: "a current import was refused")

let tagged = ImportedNotes.provenance(source: "ChatGPT Record")
check(tagged.contains("Imported into Griasa from ChatGPT Record") && !ImportedNotes.provenance(source: " ").contains("from"),
      rule: "imported notes say where they came from",
      meaning: "a reader, the brief and the MCP endpoint should be able to tell these were not a Griasa recording",
      saw: tagged)

return failures
}
