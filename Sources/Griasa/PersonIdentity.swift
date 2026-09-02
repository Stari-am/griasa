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

    /// Combines two records that turn out to be one human, keeping this one's
    /// name and identity.
    ///
    /// The rules live here, in the file the checks can reach, because a merge is
    /// destructive: whatever this drops cannot be got back. So notes from both
    /// sides survive — they are the only part of a record a person typed
    /// themselves. The dossier does not merge: half of one description followed
    /// by half of another would read as a single account of somebody and be
    /// false, so the newer one is kept whole and the older discarded, which is
    /// safe because a dossier can be generated again from the transcripts.
    /// Addresses and handles are unioned, since every one of them is a fact
    /// about where this person can be recognised.
    func absorbing(_ other: Person) -> Person {
        var merged = self

        let mine = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let theirs = other.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Identical notes on both duplicates is the common case when the same
        // thing was typed twice; joining them would double every line.
        merged.notes = mine == theirs ? mine
                                      : [mine, theirs].filter { !$0.isEmpty }.joined(separator: "\n\n")

        if let incoming = other.dossier,
           dossier == nil || (other.dossierDate ?? .distantPast) > (dossierDate ?? .distantPast) {
            merged.dossier = incoming
            merged.dossierDate = other.dossierDate
        }

        var seen = Set(emails.map { PersonIdentity.normalize(email: $0) })
        for email in other.emails {
            let key = PersonIdentity.normalize(email: email)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            merged.emails.append(email)
        }

        for (system, handle) in other.handles where merged.handles[system] == nil {
            merged.handles[system] = handle
        }
        return merged
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

    /// Whether a typed string is worth storing as an address.
    ///
    /// Not validation for its own sake: `resolve` falls back to matching the
    /// local part of an address against a name, so a string with no shape at all
    /// becomes a way to match the wrong person. One @, something either side,
    /// and a dot in the domain is as far as this goes — anything stricter starts
    /// rejecting addresses that exist.
    static func looksLikeEmail(_ text: String) -> Bool {
        let candidate = normalize(email: text)
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last else { return false }
        guard !local.isEmpty, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !candidate.contains(where: { $0 == " " })
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
        if let name, let matched = matchByName(name, among: candidates.map(\.name)) {
            return Match(name: matched, confidence: .byName)
        }
        // Last resort: an invitation carrying an address and no usable name.
        if let email {
            let pieces = tokensFromLocalPart(of: email)
            if !pieces.isEmpty {
                let hits = candidates.map(\.name).filter { candidate in
                    let other = latinTokens(candidate)
                    return !other.isEmpty && (other.isSubset(of: pieces) || pieces.isSubset(of: other))
                }
                if hits.count == 1 { return Match(name: hits[0], confidence: .byName) }
            }
        }
        return nil
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
        let tokens = latinTokens(name)
        guard !tokens.isEmpty else { return [] }
        return known.filter { candidate in
            let other = latinTokens(candidate)
            return !other.isEmpty && (other.isSubset(of: tokens) || tokens.isSubset(of: other))
        }
    }

    /// Names reduced to comparable pieces: transliterated to Latin, stripped of
    /// diacritics, lower-cased, split on anything that is not a letter or digit.
    ///
    /// Transliteration is here because of a measured failure, not a hypothesis.
    /// In one real roster of 21 colleagues, 11 names were stored in Latin and 10
    /// in Cyrillic while the calendar delivers Latin — so those 10 people could
    /// never be recognised from an invitation, and every part of the pre-meeting
    /// brief that depends on recognising somebody stayed empty for half the team.
    ///
    /// It is a partial fix and should not be sold as more. ICU transliteration is
    /// not the transliteration people use for their own names: "Иван Петров"
    /// becomes "Ivan Petrov" and matches, but "Айк Саргсян" becomes "Ajk Sargsan"
    /// where the person spells himself "Aik Sargsian", and no normalising closes
    /// that. The reliable answer is the address, learned once; this catches the
    /// easy half without anybody having to do anything.
    ///
    /// Colliding more often is acceptable precisely because an ambiguous match is
    /// not a match: the failure is an attendee shown as unrecognised, never an
    /// attendee attached to the wrong person.
    static func latinTokens(_ text: String) -> Set<String> {
        let latin = (text as NSString).applyingTransform(.toLatin, reverse: false) ?? text
        let plain = (latin as NSString).applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return Set(plain.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The part of an address before the @, as name-like pieces. Corporate
    /// addresses are usually a transliteration of the name — ivan.petrov@ — which
    /// makes them the only usable identifier when an invitation carries an
    /// address and no display name at all.
    ///
    /// No special guard on how many pieces come out, and that is deliberate. An
    /// earlier version refused a local part that produced a single token, on the
    /// theory that a run with no word boundary invites a wrong answer. A mutation
    /// test showed the guard caught nothing — and reading why showed it was also
    /// wrong: because matching is by subset of token sets, a single run only ever
    /// matches a single-word name it equals exactly. So "petrov@" correctly finds
    /// a colleague stored as "Petrov", while "ipetrov@" finds nobody, because
    /// {ipetrov} is not a subset of {ivan, petrov} in either direction. The guard
    /// was blocking the first case and defending against nothing.
    static func tokensFromLocalPart(of email: String) -> Set<String> {
        let address = normalize(email: email)
        guard let local = address.split(separator: "@").first, !local.isEmpty else { return [] }
        return latinTokens(String(local))
    }
}
