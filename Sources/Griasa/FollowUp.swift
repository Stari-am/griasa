import Foundation

/// The follow-up after a meeting, as text: the summary and who promised what for
/// everyone, or one person's share. Griasa writes the draft; the person sends it
/// from their own mail app. Foundation only, so the wording rules are checked.
enum FollowUp {
    struct Promise: Equatable {
        var owner: String
        var isMine: Bool
        var task: String
        var due: String?
    }

    struct Draft: Equatable {
        var subject: String
        var body: String
        var to: [String]
    }

    static let siteURL = "https://stari-am.github.io/griasa/"

    /// For everyone on the call: the summary, then each person's promises.
    static func meeting(title: String, date: Date, summary: String?, promises: [Promise],
                        to: [String], language: String, footer: Bool) -> Draft {
        let words = Words(language)
        var body = ""
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            body += summary + "\n\n"
        }
        if !promises.isEmpty {
            body += words.whoDoesWhat + "\n" + lines(promises, words) + "\n"
        }
        if body.isEmpty { body = words.nothing + "\n" }
        return Draft(subject: "\(words.followUp): \(title), \(day(date, language))",
                     body: body + signature(footer, words), to: to)
    }

    /// For one person: what they promised in this meeting and what the user promised.
    static func forPerson(_ name: String, title: String, date: Date, promises: [Promise],
                          to: [String], language: String, footer: Bool) -> Draft {
        let words = Words(language)
        let theirs = promises.filter { !$0.isMine && PromiseOwner.sameName($0.owner, name) }
        let mine = promises.filter(\.isMine)
        var body = ""
        if !theirs.isEmpty { body += words.yourPromises + "\n" + lines(theirs, words, withOwner: false) + "\n\n" }
        if !mine.isEmpty { body += words.myPromises + "\n" + lines(mine, words, withOwner: false) + "\n\n" }
        if body.isEmpty { body = words.nothing + "\n\n" }
        return Draft(subject: "\(words.followUp): \(title), \(day(date, language))",
                     body: body.trimmingCharacters(in: .newlines) + "\n" + signature(footer, words), to: to)
    }

    /// `mailto:` with the body when it fits. Mail apps truncate or refuse long
    /// links, so past `limit` characters of body the link carries the subject
    /// only and the caller puts the body on the clipboard.
    static func mailto(_ draft: Draft, limit: Int = 1800) -> (url: URL, bodyIncluded: Bool) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to.joined(separator: ",")
        let fits = draft.body.count <= limit
        components.queryItems = [URLQueryItem(name: "subject", value: draft.subject)]
            + (fits ? [URLQueryItem(name: "body", value: draft.body)] : [])
        // URLComponents leaves "+" alone, which mail apps read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return (components.url ?? URL(string: "mailto:")!, fits)
    }

    /// Promises as a list, for pasting into any text (snippets).
    static func list(_ promises: [Promise], language: String, withOwner: Bool = true) -> String {
        lines(promises, Words(language), withOwner: withOwner)
    }

    // MARK: - Pieces

    private static func lines(_ promises: [Promise], _ words: Words, withOwner: Bool = true) -> String {
        promises.map { item in
            var line = "- "
            if withOwner { line += (item.isMine ? words.me : item.owner) + ": " }
            line += item.task
            if let due = item.due, !due.isEmpty { line += " — " + due }
            return line
        }.joined(separator: "\n")
    }

    private static func signature(_ footer: Bool, _ words: Words) -> String {
        footer ? "\n—\n\(words.madeWith) \(siteURL)\n" : ""
    }

    private static func day(_ date: Date, _ language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "en" ? "en_US" : language)
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    private struct Words {
        let followUp, whoDoesWhat, yourPromises, myPromises, me, nothing, madeWith: String
        init(_ language: String) {
            switch language {
            case "ru":
                (followUp, whoDoesWhat, yourPromises, myPromises, me, nothing, madeWith) =
                    ("Итоги", "Кто что делает:", "Что ты обещал(а):", "Что обещал(а) я:", "Я",
                     "Обещаний на этой встрече не было.", "Заметки собраны Griasa, локально на моём Mac —")
            case "uk":
                (followUp, whoDoesWhat, yourPromises, myPromises, me, nothing, madeWith) =
                    ("Підсумки", "Хто що робить:", "Що ти пообіцяв(-ла):", "Що пообіцяв(-ла) я:", "Я",
                     "Обіцянок на цій зустрічі не було.", "Нотатки зібрано Griasa, локально на моєму Mac —")
            default:
                (followUp, whoDoesWhat, yourPromises, myPromises, me, nothing, madeWith) =
                    ("Follow-up", "Who does what:", "What you promised:", "What I promised:", "Me",
                     "No promises were made in this meeting.", "Notes made with Griasa, on my Mac —")
            }
        }
    }
}
