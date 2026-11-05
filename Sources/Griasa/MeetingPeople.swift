import Foundation

/// "Meetings with Anna", "meetings with Anna and Ivan": which meetings had
/// these people in them. Shared by History's people filter and the assistants'
/// `search_meetings`, so both answer the same question the same way.
///
/// Foundation only, so `test.sh` can reach the rules.
enum MeetingPeople {
    /// Whether one of the asked-for people must be there, or all of them.
    enum Mode: String, Equatable { case all, any }

    /// Whether `person` is among `participants`. Names compare the way the
    /// rest of Griasa compares them (`PersonIdentity.latinTokens`): case,
    /// accents and alphabet do not matter, and one name's words being part of
    /// the other's is a match, so "Priya" finds "Priya Shah" and "Анна" finds
    /// "Anna".
    static func includes(_ participants: [String], _ person: String) -> Bool {
        let wanted = PersonIdentity.latinTokens(person)
        guard !wanted.isEmpty else { return false }
        return participants.contains { name in
            let tokens = PersonIdentity.latinTokens(name)
            return !tokens.isEmpty && (wanted.isSubset(of: tokens) || tokens.isSubset(of: wanted))
        }
    }

    /// Whether a meeting matches. With no people asked for, every meeting does.
    /// A meeting without a participant list (an import, an old recording) is
    /// judged by whether its text names the person, which is the best there is.
    static func matches(participants: [String]?, text: String, people: [String], mode: Mode) -> Bool {
        let people = cleaned(people)
        guard !people.isEmpty else { return true }
        let roster = participants ?? []
        let present: (String) -> Bool = roster.isEmpty
            ? { text.localizedCaseInsensitiveContains($0) }
            : { includes(roster, $0) }
        switch mode {
        case .all: return people.allSatisfy(present)
        case .any: return people.contains(where: present)
        }
    }

    /// Names as asked: trimmed, blanks dropped, repeats dropped, order kept.
    static func cleaned(_ people: [String]) -> [String] {
        var seen = Set<String>()
        return people
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The people who come up in meetings, most frequent first, for a picker.
    static func roster(_ meetings: [[String]]) -> [String] {
        var counts: [String: Int] = [:]
        for participants in meetings {
            for name in Set(participants.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value
                                                     : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map(\.key)
    }
}
