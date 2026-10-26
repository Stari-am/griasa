import Foundation

/// A promise in text captured with Remind me — "Иван: скину схему до пятницы"
/// selected in a chat. The reminder parser reports it; Griasa only offers it,
/// and the person decides whether to track it.
struct CapturedPromise: Equatable {
    var task: String
    var owner: String
    var isMine: Bool
    var dueHint: String?
    var dueDate: Date?
    var quote: String

    /// From the parser's `promise` object. Nil when there is none, when the task
    /// is empty, or when the quoted words are not in what was captured — the same
    /// rule meeting promises follow, so a promise the model made up is never offered.
    static func from(_ object: Any?, capturedText: String, myName: String,
                     parseDate: (String) -> Date?) -> CapturedPromise? {
        guard let fields = object as? [String: Any],
              let task = (fields["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty,
              let quote = (fields["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty,
              QuoteMatch.contains(QuoteMatch.prepare(capturedText), quote: quote)
        else { return nil }
        let named = PromiseOwner.normalizeOwner(fields["owner"] as? String)
        let mine = PromiseOwner.isMe(named, myName: myName)
        let owner = mine ? (myName.isEmpty ? "You" : myName) : (named.isEmpty ? "Them" : named)
        let hint = (fields["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = fields["dueDateISO"] as? String
        return CapturedPromise(task: task, owner: owner, isMine: mine,
                               dueHint: hint?.isEmpty == false ? hint : nil,
                               dueDate: iso.flatMap { $0.isEmpty ? nil : parseDate($0) },
                               quote: quote)
    }
}
