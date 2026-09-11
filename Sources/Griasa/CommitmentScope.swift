import Foundation

/// Which promises belong in front of you before a particular meeting, and why.
///
/// Foundation only, so `test.sh` can reach it — the same reason `PersonIdentity`
/// and `SilenceLevel` live on their own. It matters here because these rules
/// decide what a manager sees minutes before a call: a rule that hides the wrong
/// thing is worse than no grouping at all.
enum CommitmentScope {

    // MARK: - Meeting identity, derived rather than stored

    /// What kind of meeting a set of participants describes.
    ///
    /// The list holds everybody *besides* the user, which is why one name means
    /// a one-to-one. Counting is deliberate: nothing is stored, nothing has to
    /// be migrated, and it cannot disagree with the meeting it describes.
    enum Shape: Equatable {
        case oneToOne
        case group
        /// No participants recorded — meetings from before the roster existed,
        /// and anything added by hand.
        case unknown
    }

    static func shape(of participants: [String]) -> Shape {
        switch normalized(participants).count {
        case 0: return .unknown
        case 1: return .oneToOne
        default: return .group
        }
    }

    /// The identity of a recurring meeting: its exact participant set.
    ///
    /// Exact, not similar. Measured against a real store: titles never repeat
    /// between recordings, so they are useless as an identity, while the same
    /// exact participant set accounts for a large share of meetings. Matching at
    /// 60% overlap instead joins almost everything into one cluster, which would
    /// put every meeting in every other meeting's "this meeting".
    ///
    /// Returns nil when there is nothing to key on, so a caller cannot
    /// accidentally treat two participant-less meetings as the same series.
    static func seriesKey(_ participants: [String]) -> String? {
        let names = normalized(participants)
        guard !names.isEmpty else { return nil }
        return names.sorted().joined(separator: "\u{1F}")
    }

    private static func normalized(_ participants: [String]) -> Set<String> {
        Set(participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    // MARK: - What needs a human to look at it

    /// How old an undated promise gets before it is worth asking about.
    ///
    /// Chosen by measuring a real store rather than from a feeling. Two things
    /// that measurement showed: hardly anything open was old enough for the
    /// "three months and forgotten" case to exist, and most open promises carry
    /// no date at all — which is the real reason the list only grows, because a
    /// dated promise surfaces itself when it comes due and an undated one never
    /// surfaces. Thirty days left a batch somebody will actually work through;
    /// two weeks left several times as many, which is another list nobody reads.
    static let reviewAfterDays = 30

    /// Whether a promise should be put in front of the user to confirm it is
    /// still real.
    ///
    /// Undated only, on purpose: a promise with a date already appears under
    /// Overdue when the date passes, and asking about it as well would show the
    /// same item in two places for two different reasons.
    ///
    /// - Parameters:
    ///   - ageDays: how long ago the promise was made.
    ///   - hasDueDate: whether a real date was resolved for it.
    ///   - reviewedDaysAgo: how long since the user last said it was still
    ///     open, or nil if they never have.
    static func needsReview(ageDays: Int, hasDueDate: Bool,
                            reviewedDaysAgo: Int?) -> Bool {
        guard !hasDueDate, ageDays >= reviewAfterDays else { return false }
        // Saying "still open" has to buy silence for a while, or the same
        // question comes back tomorrow and the answer stops being given.
        if let reviewedDaysAgo, reviewedDaysAgo < reviewAfterDays { return false }
        return true
    }

    // MARK: - Which promises to ask about

    /// Orders open promises for the question "which of these did this meeting
    /// close": the ones tied to the people in that meeting first, then the rest
    /// by recency.
    ///
    /// Ranking by recency alone was the first version and it is backwards for
    /// anything but the meeting that just ended: once there are more open
    /// promises than fit in the prompt, an older meeting can only ever be
    /// offered promises made after it. Both halves keep their own order, so a
    /// re-run over the same meeting proposes the same candidates.
    ///
    /// Takes tuples rather than the store's model, and the history lookup as an
    /// argument rather than reaching for it, which is what lets this be checked.
    static func rankedCandidates(
        _ open: [(id: UUID, owner: String, date: Date, sourceEntryID: UUID?)],
        near participants: [String],
        participantsByEntry: [UUID: Set<String>]
    ) -> [UUID] {
        let byRecency = open.sorted { $0.date > $1.date }
        let room = Set(participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        guard !room.isEmpty else { return byRecency.map(\.id) }

        let related = byRecency.filter { item in
            if room.contains(item.owner.lowercased()) { return true }
            guard let source = item.sourceEntryID,
                  let people = participantsByEntry[source] else { return false }
            return !people.isDisjoint(with: room)
        }
        let relatedIDs = Set(related.map(\.id))
        return related.map(\.id) + byRecency.filter { !relatedIDs.contains($0.id) }.map(\.id)
    }

    // MARK: - Bucketing

    /// What the rules need to know about one promise. Deliberately not
    /// `Commitment`: the store's model carries SwiftUI-adjacent concerns and a
    /// UUID identity that these rules have no use for, and keeping the input
    /// small is what makes every case below writable as a test.
    struct Item: Equatable {
        var owner: String
        var isMine: Bool
        var dueDate: Date?
        /// Participants of the meeting this promise came out of. Empty for one
        /// added by hand, or recorded before participants were stored.
        var sourceParticipants: [String]

        init(owner: String, isMine: Bool, dueDate: Date? = nil,
             sourceParticipants: [String] = []) {
            self.owner = owner
            self.isMine = isMine
            self.dueDate = dueDate
            self.sourceParticipants = sourceParticipants
        }
    }

    /// Why you are being shown a promise before this meeting.
    enum Bucket: String, Equatable, CaseIterable {
        /// Past its date. Cuts across the others and belongs on top: a missed
        /// deadline outranks tidy grouping.
        case overdue
        /// From a previous occurrence of the meeting about to start.
        case thisMeeting
        /// From a one-to-one with somebody in the room.
        case personal
        /// Involves somebody in the room, but from neither of the above.
        case general
        /// Involves nobody in the room. Not shown.
        case hidden

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .thisMeeting: return "This meeting"
            case .personal: return "Personal"
            case .general: return "General"
            case .hidden: return "Hidden"
            }
        }
    }

    /// - Parameters:
    ///   - attendees: who is on the call about to start.
    ///   - seriesKey: `seriesKey` of the meeting about to start, or nil when it
    ///     has no participants to key on.
    ///   - now: passed in rather than read, so "overdue" is testable.
    static func bucket(_ item: Item, attendees: [String], seriesKey series: String?,
                       now: Date) -> Bucket {
        let room = normalized(attendees)
        guard !room.isEmpty else { return .hidden }

        // Relevance first. A promise nobody in the room is party to is the whole
        // reason this function exists — the panel used to show every open
        // promise globally, which for a weekly meeting is a list nobody reads.
        let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fromParticipants = normalized(item.sourceParticipants)
        let ownedByAttendee = !item.isMine && room.contains(owner)
        let sharesMeeting = !fromParticipants.isDisjoint(with: room)
        guard ownedByAttendee || sharesMeeting else { return .hidden }

        // Overdue wins over origin, on purpose: before a call, a date that has
        // passed is the thing to raise regardless of which meeting produced it.
        if let due = item.dueDate, due < now { return .overdue }

        if let series, let itemSeries = seriesKey(item.sourceParticipants),
           itemSeries == series {
            return .thisMeeting
        }
        if shape(of: item.sourceParticipants) == .oneToOne, sharesMeeting {
            return .personal
        }
        return .general
    }
}
