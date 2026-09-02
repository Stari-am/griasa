import Foundation

/// `Griasa --people-probe` exercises merging and deleting a person against the
/// real stores, using two invented names so it touches nobody's data.
///
/// It exists because these two operations are the only ones in the app that
/// destroy something a person typed, and because they are spread over four
/// stores joined by nothing but a name string — the kind of code where a
/// missing line loses half a colleague's history quietly. Nothing here prints a
/// name that was not invented by this file.
@MainActor
enum PeopleProbe {
    private static let keep = "Probe Survivor ZZ"
    private static let dupe = "Probe Duplicate ZZ"

    /// `async` and called directly rather than through `MainActor.run`. Wrapping
    /// a never-returning function in that closure makes the compiler warn that
    /// the call will never be executed, and this project builds with no
    /// warnings — the enum is already main-actor isolated, so the hop is not
    /// needed for the stores it touches.
    static func run() async -> Never {
        let store = PersonStore.shared
        let roster = ParticipantRoster.shared
        var failures = 0

        func check(_ passed: Bool, _ rule: String, _ saw: String) {
            print(passed ? "  ok  \(rule)" : "  FAIL \(rule)\n       \(saw)")
            if !passed { failures += 1 }
        }

        let peopleBefore = store.people.count
        let rosterBefore = roster.names.count
        print("before: \(peopleBefore) people, \(rosterBefore) roster names")

        // Two entries for one human, the way the accident actually happens: the
        // name typed twice after two different calls.
        roster.remember([keep, dupe])
        store.setNotes("Owns billing", for: keep)
        store.setNotes("Prefers async", for: dupe)
        store.addEmail("survivor@probe.example", for: keep)
        store.addEmail("duplicate@probe.example", for: dupe)

        switch store.merge(dupe, into: keep) {
        case .merged:
            let survivor = store.person(named: keep)
            check(store.person(named: dupe) == nil,
                  "the duplicate's record is gone after the merge",
                  "it is still there")
            check(survivor?.notes.contains("Owns billing") == true
                  && survivor?.notes.contains("Prefers async") == true,
                  "both sets of notes survive the merge",
                  "notes: \((survivor?.notes ?? "").debugDescription)")
            check(survivor?.emails.count == 2,
                  "both addresses survive the merge",
                  "addresses: \(survivor?.emails.count ?? -1)")
            check(!roster.names.contains(where: { $0.caseInsensitiveCompare(dupe) == .orderedSame }),
                  "the duplicate leaves the roster, so it is not offered after the next call",
                  "still in the roster")
            check(roster.names.filter { $0.caseInsensitiveCompare(keep) == .orderedSame }.count == 1,
                  "the survivor is in the roster exactly once",
                  "appears \(roster.names.filter { $0.caseInsensitiveCompare(keep) == .orderedSame }.count) times")
            check(!store.allNames.contains(where: { $0.caseInsensitiveCompare(dupe) == .orderedSame }),
                  "the duplicate has left the People list",
                  "still listed")
        case .unknownTarget, .samePerson:
            check(false, "merging a duplicate into an existing person succeeds", "it refused")
        }

        // Merging into somebody who does not exist must refuse rather than
        // rename the person into a stranger.
        let refused = store.merge(keep, into: "Nobody By This Name ZZ")
        check({ if case .unknownTarget = refused { return true }; return false }(),
              "merging into a name nobody has is refused",
              "it went ahead")

        store.delete(keep)
        check(store.person(named: keep) == nil,
              "deleting removes the record",
              "the record is still there")
        check(!roster.names.contains(where: { $0.caseInsensitiveCompare(keep) == .orderedSame }),
              "deleting takes the name out of the roster",
              "still in the roster")

        // The point of the whole probe: after inventing two people, merging them
        // and deleting the result, the real data has to be exactly as it was.
        check(store.people.count == peopleBefore,
              "no real person was added or lost",
              "\(peopleBefore) people before, \(store.people.count) after")
        check(roster.names.count == rosterBefore,
              "the roster is back to its original size",
              "\(rosterBefore) names before, \(roster.names.count) after")

        print(failures == 0 ? "\npeople probe: all passed" : "\npeople probe: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
