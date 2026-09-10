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
    /// Exact, not similar. Measured on 46 real meetings: 49 titles across 49
    /// meetings never repeat, so titles are useless as an identity, while five
    /// exact participant sets account for 23 of the meetings. Matching at 60%
    /// overlap instead joins 39 of those 46 into a single cluster of eleven,
    /// which would put every meeting in every other meeting's "this meeting".
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
