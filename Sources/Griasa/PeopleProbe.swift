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
    /// `--attendance-probe`: for each of the most recent recordings, works out
    /// which calendar event it overlapped and how many roster names that would
    /// tick. Counts only — no names, no titles.
    static func attendance(limit: Int) async -> Never {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa Recordings", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)

        print("calendar access: \(Permissions.calendarGranted)")
        print("roster: \(PersonStore.shared.candidates.count) known people")
        print("recordings to check: \(folders.count)\n")

        var matched = 0, ticked = 0
        for (index, folder) in folders.enumerated() {
            guard let window = AppState.window(of: folder) else {
                print("  \(index + 1). folder name is not a timestamp — skipped")
                continue
            }
            let minutes = Int(window.upperBound.timeIntervalSince(window.lowerBound) / 60)
            let events = MeetingPrepWatcher.events(overlapping: window)
            guard let event = MeetingAttendance.event(for: window, among: events) else {
                print("  \(index + 1). \(minutes) min, \(events.count) overlapping events — no match")
                continue
            }
            matched += 1
            let names = MeetingAttendance.preselected(
                from: event, roster: PersonStore.shared.candidates)
            ticked += names.count
            print("  \(index + 1). \(minutes) min, \(events.count) overlapping events — "
                + "matched one with \(event.attendees.count) attendees, "
                + "\(names.count) already on the roster")
        }
        print("\nrecordings matched to an event: \(matched) of \(folders.count)")
        print("names that would be ticked in total: \(ticked)")
        exit(0)
    }

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

        // ── The closure suggestion lifecycle, against the real store ────────
        let promises = CommitmentStore.shared
        let before = promises.commitments.count
        let probe = Commitment(text: "Probe promise ZZ", owner: keep, isMine: false,
                               sourceTitle: "Probe meeting ZZ")
        _ = promises.add(probe)

        promises.suggestClosure(probe.id, quote: "shipped it on Tuesday")
        let flagged = promises.commitments.first { $0.id == probe.id }
        check(flagged?.suggestedDoneQuote == "shipped it on Tuesday" && flagged?.done == false,
              "a detected closure is recorded with its quote and does not close anything",
              "quote \(String(describing: flagged?.suggestedDoneQuote)), done \(flagged?.done ?? true)")
        check(promises.suggestedDone.contains { $0.id == probe.id },
              "the suggestion appears in the list the panel reads",
              "it does not")

        promises.dismissSuggestion(probe.id)
        let dismissed = promises.commitments.first { $0.id == probe.id }
        check(dismissed?.suggestedDoneQuote == nil && dismissed?.done == false,
              "dismissing clears the suggestion and leaves the promise open",
              "quote \(String(describing: dismissed?.suggestedDoneQuote)), done \(dismissed?.done ?? true)")

        promises.suggestClosure(probe.id, quote: "shipped it on Tuesday")
        promises.acceptSuggestion(probe.id)
        let accepted = promises.commitments.first { $0.id == probe.id }
        check(accepted?.done == true && accepted?.doneAt != nil
              && accepted?.suggestedDoneQuote != nil,
              "accepting closes the promise and keeps the quote as the reason",
              "done \(accepted?.done ?? false), quote kept \(accepted?.suggestedDoneQuote != nil)")
        check(!promises.suggestedDone.contains { $0.id == probe.id },
              "a closed promise stops being suggested",
              "it is still suggested")

        promises.delete(probe.id)
        check(promises.commitments.count == before,
              "no real promise was added or lost",
              "\(before) before, \(promises.commitments.count) after")

        print(failures == 0 ? "\nprobe: all passed" : "\nprobe: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
