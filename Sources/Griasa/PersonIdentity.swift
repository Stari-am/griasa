import Foundation

/// The person record and the rules for deciding that a name from somewhere else
/// — a calendar attendee, a tracker assignee, a chat handle — is somebody Griasa
/// already knows.
///
/// Kept free of SwiftUI and AppKit so `test.sh` can reach it, for the same reason
/// PartialStabilizer and SilenceLevel live on their own. That matters more here
/// than elsewhere: this file decides whether two humans are the same human, and
/// it decodes a file whose loss would take every person with it.

/// Everything Griasa knows about a colleague beyond the meeting transcripts:
/// the user's own notes, an AI-written dossier, and the addresses and handles
/// that let the same person be recognised in other systems.
struct Person: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var notes: String = ""
    var dossier: String?
    var dossierDate: Date?

    /// Addresses this person is known by. Plural because work and personal both
    /// turn up, and a tracker may know either one.
    var emails: [String] = []

    /// Handles in systems that expose no address: "linear", "slack", "github".
    var handles: [String: String] = [:]

    /// Decoded explicitly rather than by synthesis. Swift's generated decoder is
    /// the wrong tool for a file that already exists on disk without these keys:
    /// whether a missing key falls back to a property's default is a subtlety
    /// nobody should have to remember, and getting it wrong throws for the whole
    /// array, which loses every person at once. `decodeIfPresent` says what is
    /// meant, and IdentityChecks decodes the real file to prove it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        dossier = try container.decodeIfPresent(String.self, forKey: .dossier)
        dossierDate = try container.decodeIfPresent(Date.self, forKey: .dossierDate)
        emails = try container.decodeIfPresent([String].self, forKey: .emails) ?? []
        handles = try container.decodeIfPresent([String: String].self, forKey: .handles) ?? [:]
    }

    init(name: String, notes: String = "", emails: [String] = [], handles: [String: String] = [:]) {
        self.name = name
        self.notes = notes
        self.emails = emails
        self.handles = handles
    }
}

/// Turning an outside identity into a name Griasa already uses.
enum PersonIdentity {
    /// Addresses are compared as text, so they have to be reduced to one form
    /// first. Case is meaningless in the domain part and, in practice, in the
    /// local part too — every provider a calendar invite comes from treats
    /// "Ivan.Petrov@" and "ivan.petrov@" as one mailbox.
    static func normalize(email: String) -> String {
        var text = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("mailto:") { text.removeFirst("mailto:".count) }
        // Calendar attendees sometimes arrive as `Ivan Petrov <ivan@x.com>`.
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The minimum a candidate has to offer to be matched against. Deliberately
    /// not `Person`: the tracker client will match against rows that are not
    /// Griasa people, and the roster contains names with no record at all.
    struct Candidate: Equatable {
        var name: String
        var emails: [String] = []
    }

    /// How a match was reached. The caller needs to know: an address match is a
    /// fact, a name match is a guess, and the two should not be treated alike —
    /// a guess is fine for showing a suggestion and wrong for silently merging
    /// two people's histories.
    enum Confidence: Equatable {
        case byEmail
        case byName
    }

    struct Match: Equatable {
        var name: String
        var confidence: Confidence
    }

    /// Resolves an outside identity to one of `candidates`.
    ///
    /// Address first, and authoritatively. Before this existed, matching was
    /// nothing but the name comparison below, which treats one name as matching
    /// another when its tokens are a subset — so "Ivan Petrov" from a calendar
    /// collapsed onto "Ivan" from the roster, and two colleagues both called
    /// Ivan could not be told apart at all.
    static func resolve(name: String?, email: String?,
                        among candidates: [Candidate]) -> Match? {
        if let email {
            let wanted = normalize(email: email)
            if !wanted.isEmpty {
                for candidate in candidates
                where candidate.emails.contains(where: { normalize(email: $0) == wanted }) {
                    return Match(name: candidate.name, confidence: .byEmail)
                }
            }
        }
        guard let name, let matched = matchByName(name, among: candidates.map(\.name)) else {
            return nil
        }
        return Match(name: matched, confidence: .byName)
    }

    /// "Ivan Petrov" (calendar) ↔ "Ivan" (roster): a match when one name's
    /// tokens are a subset of the other's. Kept as the fallback because a great
    /// many calendars deliver attendees as display names with no address at all,
    /// and some list a meeting room as a participant.
    ///
    /// Ambiguity is not a match. The previous version took the first candidate
    /// that fit, which with two colleagues both called Ivan silently picked one
    /// of them — and then attached a meeting, a promise, or an address to
    /// whichever happened to be earlier in the list. An unresolved attendee is
    /// merely unhelpful; a confidently wrong one corrupts two people's histories
    /// at once.
    static func matchByName(_ name: String, among known: [String]) -> String? {
        let matches = namesMatching(name, among: known)
        return matches.count == 1 ? matches[0] : nil
    }

    static func namesMatching(_ name: String, among known: [String]) -> [String] {
        let tokens = Set(name.lowercased().split(separator: " ").map(String.init))
        guard !tokens.isEmpty else { return [] }
        return known.filter { candidate in
            let other = Set(candidate.lowercased().split(separator: " ").map(String.init))
            return !other.isEmpty && (other.isSubset(of: tokens) || tokens.isSubset(of: other))
        }
    }
}
