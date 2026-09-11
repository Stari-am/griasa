import Foundation

/// Working out, from the calendar, who was probably on a recording that has
/// just ended.
///
/// Foundation only so `test.sh` can reach it: the EventKit lookup is glue, but
/// deciding *which* event a recording belongs to and *who* on it is already
/// known is the part that can be quietly wrong, and a wrong answer here ticks
/// boxes on somebody's behalf.
enum MeetingAttendance {

    /// The calendar reduced to what this decision needs. Not `EKEvent`: the
    /// rules below would then be untestable, and they are the whole point.
    struct Event: Equatable {
        var title: String
        var start: Date
        var end: Date
        /// Attendees other than the user, as the calendar gives them — a
        /// display name, an address, often only one of the two.
        var attendees: [Attendee]

        struct Attendee: Equatable {
            var name: String?
            var email: String?
        }
    }

    /// The shortest overlap worth believing.
    ///
    /// Without a floor, a meeting that ended as the recording began overlaps by
    /// a second and wins, which would attribute a call to the wrong event and
    /// tick the wrong names. A minute is long enough to exclude that and short
    /// enough to keep a recording started late.
    static let minimumOverlap: TimeInterval = 60

    /// The calendar event a recording most likely belongs to: the one sharing
    /// the most time with it.
    ///
    /// Ties break towards the earlier start, so the answer does not depend on
    /// the order EventKit happened to return.
    static func event(for recording: ClosedRange<Date>, among events: [Event]) -> Event? {
        // Written out rather than chained: as one expression the type checker
        // gives up on it.
        var best: (event: Event, overlap: TimeInterval)?
        for candidate in events {
            let shared = overlap(recording, candidate)
            guard shared >= minimumOverlap else { continue }
            guard let current = best else {
                best = (candidate, shared)
                continue
            }
            if shared > current.overlap
                || (shared == current.overlap && candidate.start < current.event.start) {
                best = (candidate, shared)
            }
        }
        return best?.event
    }

    private static func overlap(_ recording: ClosedRange<Date>, _ event: Event) -> TimeInterval {
        let start = max(recording.lowerBound, event.start)
        let end = min(recording.upperBound, event.end)
        return max(0, end.timeIntervalSince(start))
    }

    /// Which roster names to tick, given an event's attendees.
    ///
    /// Only people already on the roster. An attendee who resolves to nobody is
    /// dropped rather than offered: a large meeting brings a long list of names
    /// that were never worth remembering, and filling the panel with them makes
    /// the question harder to answer, not easier.
    ///
    /// Returned in roster order rather than attendee order, so the ticks appear
    /// where the eye already is.
    static func preselected(from event: Event,
                            roster: [PersonIdentity.Candidate]) -> [String] {
        var matched = Set<String>()
        for attendee in event.attendees {
            guard let person = PersonIdentity.resolve(name: attendee.name,
                                                      email: attendee.email ?? "",
                                                      among: roster) else { continue }
            matched.insert(person.name)
        }
        return roster.map(\.name).filter { matched.contains($0) }
    }
}
