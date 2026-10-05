import Foundation

/// Meeting notes made somewhere else — ChatGPT Record, a Zoom or Meet summary,
/// notes typed by hand — brought into Griasa as a meeting.
///
/// The other tool did the recording; Griasa does what it does with any
/// meeting: who promised what, the page for each person who was there, the
/// brief before the next call with them, the project it belongs to. No
/// integration with the other tool is needed or attempted — none of them
/// offers one — so this is text in, meeting out.
///
/// Foundation only, so `test.sh` can reach the rules.
enum ImportedNotes {
    /// Line endings normalised, a byte-order mark and surrounding blank lines
    /// removed. Nothing else is changed: these are somebody's notes.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A title from the notes: the first heading, else the first line, short
    /// enough for a list. "Meeting notes — " and its relatives are dropped,
    /// because a list where every row starts the same way is a list you
    /// cannot scan.
    static func title(from text: String, fallback: String = "Imported meeting") -> String {
        let lines = clean(text).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = lines.first(where: { $0.hasPrefix("#") })
        var title = (heading ?? lines.first ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
        for prefix in ["Meeting notes — ", "Meeting notes - ", "Meeting notes: ", "Meeting notes",
                       "Notes — ", "Notes: ", "Summary: "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return fallback }
        return title.count > 80 ? String(title.prefix(79)) + "…" : title
    }

    /// Where an entry dated `date` goes in a newest-first list.
    static func insertionIndex(of date: Date, in newestFirst: [Date]) -> Int {
        newestFirst.firstIndex(where: { $0 <= date }) ?? newestFirst.count
    }

    /// Whether this meeting may be asked which promises it closed.
    ///
    /// Only if nothing has happened since. The question is "which open promises
    /// does this conversation say are done" — asked of notes from last month,
    /// it would offer to close promises made after that conversation took
    /// place, with a quote that cannot possibly be about them.
    static func mayDetectClosures(meetingDate: Date, newestOtherMeeting: Date?) -> Bool {
        guard let newestOtherMeeting else { return true }
        return meetingDate >= newestOtherMeeting
    }

    /// Appended to the stored notes, so a reader — and the MCP endpoint, and
    /// the brief — can tell they did not come from a Griasa recording.
    static func provenance(source: String) -> String {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\n\n---\n*Imported into Griasa\(name.isEmpty ? "" : " from \(name)").*"
    }
}
