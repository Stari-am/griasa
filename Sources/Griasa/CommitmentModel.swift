import Foundation

/// One promise made in a meeting — the user's own ("My promises") or someone
/// else's ("Waiting on others"), so follow-ups don't get lost.
///
/// Foundation only, and moved here the moment it needed a new field, for the
/// reason `Person` was moved: Swift's synthesized decoder throws
/// `keyNotFound` for a missing key *even when the property has a default*, the
/// whole array is decoded in one go, and a file written before the field
/// existed would therefore take every promise on it down. The decoder below is
/// written by hand and `CommitmentChecks` decodes the real file on disk to
/// prove it.
struct Commitment: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    /// Display name of whoever made the promise.
    var owner: String
    var isMine: Bool
    /// The phrasing of the deadline as spoken ("by Friday"), when any.
    var dueHint: String?
    /// The deadline resolved to a real date, when the model was confident.
    var dueDate: Date?
    /// Meeting the promise came from; empty for manually added items.
    var sourceTitle: String
    var sourceEntryID: UUID?
    var date = Date()
    var done = false
    var doneAt: Date?

    /// The phrase from a later conversation that says this was finished.
    ///
    /// Stored rather than acted on. Closing a promise the user still owes is a
    /// far worse error than leaving a finished one open — the first is found out
    /// by the person who was promised, the second is a line of noise — so a
    /// detection waits here, with its evidence, until somebody agrees.
    var suggestedDoneQuote: String?
    var suggestedDoneAt: Date?

    var hasClosureSuggestion: Bool { !done && suggestedDoneQuote != nil }

    init(id: UUID = UUID(), text: String, owner: String, isMine: Bool,
         dueHint: String? = nil, dueDate: Date? = nil, sourceTitle: String,
         sourceEntryID: UUID? = nil, date: Date = Date(), done: Bool = false,
         doneAt: Date? = nil, suggestedDoneQuote: String? = nil,
         suggestedDoneAt: Date? = nil) {
        self.id = id
        self.text = text
        self.owner = owner
        self.isMine = isMine
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.sourceTitle = sourceTitle
        self.sourceEntryID = sourceEntryID
        self.date = date
        self.done = done
        self.doneAt = doneAt
        self.suggestedDoneQuote = suggestedDoneQuote
        self.suggestedDoneAt = suggestedDoneAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
        isMine = try container.decodeIfPresent(Bool.self, forKey: .isMine) ?? true
        dueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        sourceEntryID = try container.decodeIfPresent(UUID.self, forKey: .sourceEntryID)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        doneAt = try container.decodeIfPresent(Date.self, forKey: .doneAt)
        suggestedDoneQuote = try container.decodeIfPresent(String.self, forKey: .suggestedDoneQuote)
        suggestedDoneAt = try container.decodeIfPresent(Date.self, forKey: .suggestedDoneAt)
    }
}
