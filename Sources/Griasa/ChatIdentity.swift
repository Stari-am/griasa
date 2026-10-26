import Foundation

/// Who a chat message's author is among the people Griasa knows.
///
/// A chat export names its authors twice: a stable account id (`user42`) and a
/// display name the author can change at will ("Ваня Б." today, "Vanya" next
/// month). The id is the better evidence, so a link the person made once —
/// `Person.handles["telegram"] = "user42"` — wins over any name. Names are the
/// fallback, compared the way promises are (`PromiseOwner.sameName`: script,
/// case and first-name tolerant), and a name that fits two people is reported
/// as ambiguous rather than guessed: attributing a promise to the wrong person
/// is worse than asking.
///
/// Foundation only, with the people passed in, so `test.sh` can check it.
enum ChatIdentity {
    enum Match: Equatable {
        /// The account id is in somebody's handles for this source.
        case linked(String)
        /// No id link; exactly one person's name fits.
        case byName(String)
        /// No id link; several people's names fit.
        case ambiguous([String])
        case unknown
    }

    static func person(forAuthorID id: String?, name: String, source: String,
                       people: [(name: String, handles: [String: String])]) -> Match {
        if let id, !id.isEmpty,
           let linked = people.first(where: { $0.handles[source] == id }) {
            return .linked(linked.name)
        }
        let hits = people.filter { PromiseOwner.sameName($0.name, name) }.map(\.name)
        switch hits.count {
        case 0: return .unknown
        case 1: return .byName(hits[0])
        default: return .ambiguous(hits)
        }
    }
}
