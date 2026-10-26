import AppKit

/// Where a follow-up's facts come from — the meeting's notes, its promises and
/// the participants' addresses — and how a draft reaches the mail app. Shared
/// by the History tab, the MCP tool and the snippet placeholders.
@MainActor
enum FollowUpActions {
    /// The "made with Griasa" line under a follow-up. On by default; the person
    /// sees it in the draft and can switch it off.
    static var footer: Bool {
        get { UserDefaults.standard.object(forKey: "followUpFooter") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "followUpFooter") }
    }

    static func promises(of entry: HistoryEntry) -> [FollowUp.Promise] {
        CommitmentStore.shared.commitments
            .filter { $0.sourceEntryID == entry.id && !$0.done }
            .map { FollowUp.Promise(owner: $0.owner, isMine: $0.isMine, task: $0.text, due: dueText($0)) }
    }

    static func emails(_ names: [String]) -> [String] {
        names.compactMap { PersonStore.shared.person(named: $0)?.emails.first }
    }

    static func language(of entry: HistoryEntry) -> String {
        LanguageGuess.byScript(entry.text) ?? "en"
    }

    static func meetingDraft(_ entry: HistoryEntry) -> FollowUp.Draft {
        FollowUp.meeting(title: entry.title, date: entry.date,
                         summary: MeetingPrepWatcher.summarySection(of: entry.text),
                         promises: promises(of: entry), to: emails(entry.participants ?? []),
                         language: language(of: entry), footer: footer)
    }

    static func personDraft(_ entry: HistoryEntry, person: String) -> FollowUp.Draft {
        FollowUp.forPerson(person, title: entry.title, date: entry.date, promises: promises(of: entry),
                           to: emails([person]), language: language(of: entry), footer: footer)
    }

    /// Opens the draft in the mail app; nothing is sent. A body too long for a
    /// mailto: link goes on the clipboard instead, and the person is told so.
    static func open(_ draft: FollowUp.Draft) {
        let (url, included) = FollowUp.mailto(draft)
        if !included {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft.body, forType: .string)
        }
        NSWorkspace.shared.open(url)
        if !included {
            PopupController.shared.showMessage(
                title: "✉️ Follow-up",
                message: "The text is too long for a mail link, so it is on the clipboard — paste it into the message.")
        }
    }

    /// The newest meeting, or the newest one with this person in it.
    static func lastMeeting(with person: String? = nil) -> HistoryEntry? {
        HistoryStore.shared.entries
            .filter { $0.kind == .meeting }
            .filter { entry in
                guard let person else { return true }
                return (entry.participants ?? []).contains { PromiseOwner.sameName($0, person) }
            }
            .max { $0.date < $1.date }
    }

    /// Open promises owned by this person, from any meeting.
    static func openPromises(of person: String) -> [FollowUp.Promise] {
        CommitmentStore.shared.commitments
            .filter { !$0.done && !$0.isMine && PromiseOwner.sameName($0.owner, person) }
            .map { FollowUp.Promise(owner: $0.owner, isMine: false, task: $0.text, due: dueText($0)) }
    }

    private static func dueText(_ item: Commitment) -> String? {
        if let due = item.dueDate { return due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return item.dueHint.flatMap { $0.isEmpty ? nil : $0 }
    }
}
