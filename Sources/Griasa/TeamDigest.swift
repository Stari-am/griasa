import Foundation

/// What each person on the user's team owes them, and the note that asks
/// about it.
///
/// Built from promises already kept — no model, nothing sent anywhere. The
/// people on the team are the ones marked as direct reports in People; their
/// promises are the open ones they made (not the user's), matched by name the
/// way the rest of Griasa matches owners.
///
/// Foundation only, so the rule is checked without the app.
enum TeamDigest {
    struct Member: Equatable {
        var name: String
        /// Open promises they made, overdue first, then by due date, then newest.
        var owed: [Commitment]
        var overdue: Int
        var lastMet: Date?
    }

    static func members(names: [String], commitments: [Commitment], lastMet: (String) -> Date?,
                        now: Date = Date()) -> [Member] {
        names.map { name in
            let owed = commitments.filter {
                !$0.done && !$0.isMine && $0.owner.caseInsensitiveCompare(name) == .orderedSame
            }
            let ordered = owed.sorted { a, b in
                let lateA = isOverdue(a, now: now), lateB = isOverdue(b, now: now)
                if lateA != lateB { return lateA }
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.date > b.date
                }
            }
            return Member(name: name, owed: ordered, overdue: ordered.filter { isOverdue($0, now: now) }.count,
                          lastMet: lastMet(name))
        }
        // The people with something late first; the rest by name.
        .sorted { a, b in
            if (a.overdue > 0) != (b.overdue > 0) { return a.overdue > 0 }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func isOverdue(_ commitment: Commitment, now: Date, calendar: Calendar = .current) -> Bool {
        guard !commitment.done, let due = commitment.dueDate else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    /// A short check-in to paste into a chat: what they said they would do,
    /// with the deadline they gave. Written in Ukrainian or Russian when the
    /// promises are, otherwise English.
    static func nudge(to name: String, about items: [Commitment]) -> String {
        guard !items.isEmpty else { return "" }
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let texts = items.map(\.text).joined(separator: " ")
        let cyrillic = texts.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let ukrainian = cyrillic && texts.lowercased().contains { "іїєґ".contains($0) }
        let lines = items.prefix(5).map { item -> String in
            let due = item.dueHint ?? item.dueDate.map { $0.formatted(.dateTime.day().month(.abbreviated)) }
            return "• " + item.text + (due.map { " (\($0))" } ?? "")
        }
        let opening = ukrainian ? "\(first), привіт! Як справи ось із цим?"
            : cyrillic ? "\(first), привет! Как дела вот с этим?" : "Hi \(first), how are these going?"
        let closing = ukrainian ? "Якщо щось заважає або терміни зсунулися, скажи."
            : cyrillic ? "Если что-то мешает или сроки поехали, скажи." : "If anything is blocked or the dates moved, let me know."
        return ([opening] + lines + [closing]).joined(separator: "\n")
    }
}
