import Foundation

/// `Griasa --closure-scan [n]` runs the closure question against the notes of
/// the n most recently recorded meetings without changing anything, and reports
/// only counts.
///
/// It exists to answer one question honestly — does this feature find anything
/// on a real store — and it prints no titles, quotes or names, because the
/// answer is a number and the content is nobody's business but the user's.
@MainActor
enum ClosureScan {
    /// The control experiment: an invented promise and a note that plainly says
    /// it was finished, using the promise's own words.
    ///
    /// Without it, a scan that finds nothing is ambiguous — the corpus may hold
    /// no closures, or the prompt and the plumbing may be incapable of finding
    /// one. This distinguishes those, and it costs a single request.
    static func selfTest() async -> Never {
        let promises = CommitmentStore.shared
        let before = promises.commitments.count
        let probe = Commitment(text: "send the pricing model ZZ to Finance",
                               owner: "Probe Person ZZ", isMine: false,
                               sourceTitle: "Probe meeting ZZ")
        _ = promises.add(probe)

        let note = """
        ## Summary

        Probe Person ZZ said at the start that he did send the pricing model ZZ to \
        Finance on Monday, so that one is finished and off the list. The rest of \
        the call was about staffing for next quarter, which nobody committed to.
        """

        let result = await CommitmentExtractor.detectClosures(
            markdown: note, participants: ["Probe Person ZZ"], persist: false)

        switch result {
        case nil:
            print("FAIL: the provider gave no usable answer at all")
        case let detection?:
            print("proposed: \(detection.proposed)")
            print("kept:     \(detection.found.count)")
            print("discarded — out of range \(detection.rejectedOutOfRange), "
                + "too short \(detection.rejectedTooShort), "
                + "not in the notes \(detection.rejectedNotInNotes)")
            let hit = detection.found.contains { $0.id == probe.id }
            print(hit
                  ? "PASS: an obviously closed promise is detected, with a quote from the note"
                  : "FAIL: even an obvious closure was not detected")
        }

        promises.delete(probe.id)
        print("store restored: \(promises.commitments.count == before)")
        exit(0)
    }

    static func run(limit: Int, fromTranscript: Bool = false) async -> Never {
        let meetings = HistoryStore.shared.entries
            .filter { $0.kind == .meeting && !$0.text.isEmpty }
            .prefix(limit)
        let open = CommitmentStore.shared.commitments.filter { !$0.done }

        print("provider configured: \(AIFormatter.isConfigured)")
        print("open promises in the store: \(open.count)")
        print("meetings to scan: \(meetings.count)")
        print("source: \(fromTranscript ? "the transcript on disk" : "the meeting notes")\n")

        guard AIFormatter.isConfigured else {
            print("No provider — nothing can be asked, and a zero here would mean nothing.")
            exit(2)
        }

        var asked = 0, unanswered = 0, totalFound = 0
        var withFindings = 0
        var proposed = 0, outOfRange = 0, tooShort = 0, notInNotes = 0
        for (index, entry) in meetings.enumerated() {
            let participants = entry.participants ?? []
            // The notes are what the recording pipeline passes. The transcript
            // on disk holds the same notes plus what was actually said, and a
            // completion is far more likely to be spoken than summarised — so
            // which of the two is fed is worth measuring rather than assuming.
            var source = entry.text
            if fromTranscript, let path = entry.filePath,
               let full = try? String(contentsOfFile: path, encoding: .utf8) {
                source = full
            }
            let started = Date()
            let result = await CommitmentExtractor.detectClosures(
                markdown: source, participants: participants, persist: false)
            let seconds = Date().timeIntervalSince(started)
            asked += 1
            switch result {
            case nil:
                unanswered += 1
                print(String(format: "  %2d. %5d chars, %d participants — no answer (%.1fs)",
                             index + 1, source.count, participants.count, seconds))
            case let detection?:
                totalFound += detection.found.count
                proposed += detection.proposed
                outOfRange += detection.rejectedOutOfRange
                tooShort += detection.rejectedTooShort
                notInNotes += detection.rejectedNotInNotes
                if !detection.found.isEmpty { withFindings += 1 }
                print(String(format: "  %2d. %5d chars, %d participants — proposed %d, kept %d (%.1fs)",
                             index + 1, source.count, participants.count,
                             detection.proposed, detection.found.count, seconds))
            }
        }

        print("\nasked about \(asked) meetings")
        print("no answer from the provider: \(unanswered)")
        print("meetings that closed something: \(withFindings)")
        print("promises the model proposed as done: \(proposed)")
        print("  discarded — number out of range: \(outOfRange)")
        print("  discarded — quote too short: \(tooShort)")
        print("  discarded — quote not found in the notes: \(notInNotes)")
        print("promises kept as suggestions: \(totalFound)")
        print("\nNothing was written. Re-run the app normally to have new meetings"
            + " propose closures as they are recorded.")
        exit(0)
    }
}
