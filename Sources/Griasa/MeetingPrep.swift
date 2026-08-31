import EventKit
import SwiftUI
import AppKit

/// Everything worth glancing at before a call, assembled instantly from local
/// data — no AI request stands between you and a meeting that starts in 5 min.
struct PrepBrief {
    var title: String
    var start: Date
    var end: Date
    var videoURL: URL?
    var attendees: [Attendee]
    /// Most recent recorded meeting shared with any of the attendees.
    var lastMeeting: PastMeeting?
    var youPromised: [Commitment]
    var theyPromised: [Commitment]

    struct Attendee: Identifiable {
        var id: String { name }
        var name: String
        /// The roster/People-page name this attendee resolved to, when known.
        var knownName: String?
        var notesPreview: String?
        var openCommitments: Int
        /// The address from the invitation, kept so an unrecognised attendee can
        /// be linked to a colleague by hand — once — after which every future
        /// invitation resolves by address instead of by comparing names.
        var email: String?
    }

    struct PastMeeting {
        var title: String
        var date: Date
        var summary: String?
        var filePath: String?
    }
}

/// Watches the calendar and opens the "📋 Prep" tab shortly before a call —
/// without stealing keyboard focus from whatever the user is typing.
@MainActor
final class MeetingPrepWatcher: ObservableObject {
    static let shared = MeetingPrepWatcher()

    enum PrepState {
        case empty(String)
        case brief(PrepBrief)
    }

    @Published var state: PrepState = .empty("No meeting selected yet.")

    private let store = EKEventStore()
    private var timer: Timer?
    /// The event the current brief was built from, so it can be rebuilt after the
    /// user links an attendee to somebody. Rebuilding is the honest way to show
    /// the result: linking one person can fill in the last meeting and both
    /// commitment lists, which no in-place row edit could produce.
    private var currentEvent: EKEvent?
    /// Occurrences already shown this run, so a brief fires once per event.
    private var shown: Set<String> = []

    // Nonisolated: both only read UserDefaults, and Permissions asks whether the
    // brief is on from the launch path, before anything is on the main actor.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "prepBriefEnabled") as? Bool ?? true
    }
    nonisolated static var leadMinutes: Int {
        UserDefaults.standard.object(forKey: "prepLeadMinutes") as? Int ?? 5
    }

    func start() {
        guard timer == nil else { return }
        // Access is asked for once, here, rather than by the timer: the brief is
        // on by default, so something has to ask, and launch is the only moment
        // where a dialog is not an interruption. Without this the watcher below
        // returns at its first guard on every tick, forever, in silence.
        Permissions.requestCalendarIfNeeded()
        if Self.isEnabled, !Permissions.calendarGranted,
           EKEventStore.authorizationStatus(for: .event) != .notDetermined {
            // Denied, and the brief is switched on. Say so in the tab instead of
            // doing nothing — the user has no other way to find out, because an
            // app in this state does not appear in Privacy & Security at all.
            state = .empty("The pre-meeting brief is on, but Griasa has no calendar access. "
                         + "Grant it in System Settings → Privacy & Security → Calendars, "
                         + "or turn the brief off in Settings → Meetings.")
        }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MeetingPrepWatcher.shared.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// The automatic path: only ever runs with access already granted — the
    /// permission prompt belongs to explicit user actions, not a background timer.
    private func tick() {
        guard Self.isEnabled,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(TimeInterval(Self.leadMinutes * 60))
        guard let event = upcomingEvents(from: now, to: horizon)
            .first(where: { isMeeting($0) && !shown.contains(occurrenceKey($0)) }) else { return }
        shown.insert(occurrenceKey(event))
        currentEvent = event
        state = .brief(buildBrief(for: event))
        HubController.shared.open(.prep, activate: false)
    }

    /// The menu action: may prompt for calendar access, looks 12 hours ahead
    /// and takes any timed event — even one with no attendees.
    func prepNextMeeting() {
        Task { @MainActor in
            guard (try? await store.requestFullAccessToEvents()) == true else {
                state = .empty("Calendar access is needed to see your next meeting. Grant it in System Settings → Privacy & Security → Calendars.")
                HubController.shared.open(.prep)
                return
            }
            let now = Date()
            let events = upcomingEvents(from: now, to: now.addingTimeInterval(12 * 3600))
            if let event = events.first(where: isMeeting) ?? events.first {
                currentEvent = event
                state = .brief(buildBrief(for: event))
            } else {
                state = .empty("No meetings in the next 12 hours 🎉")
            }
            HubController.shared.open(.prep)
        }
    }

    /// Binds an invitation address to a colleague, then rebuilds the brief.
    ///
    /// This is the reliable half of recognising people. Transliterating names
    /// catches the easy cases, but ICU's transliteration is not the one people
    /// use for their own names — "Айк" comes out "Ajk" where the person writes
    /// "Aik" — so some colleagues can only be joined up by being told once.
    func link(email: String, to name: String) {
        PersonStore.shared.addEmail(email, for: name)
        guard let event = currentEvent else { return }
        state = .brief(buildBrief(for: event))
    }

    /// Who can be offered as the answer. The roster plus anyone with a page,
    /// which is the same set matching already searches.
    var linkableNames: [String] {
        PersonStore.shared.allNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func upcomingEvents(from: Date, to: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > from && $0.availability != .free }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Worth a brief = there are other humans or a call link.
    private func isMeeting(_ event: EKEvent) -> Bool {
        (event.hasAttendees && (event.attendees?.contains { !$0.isCurrentUser } ?? false))
            || Self.videoURL(in: event) != nil
    }

    private func occurrenceKey(_ event: EKEvent) -> String {
        "\(event.eventIdentifier ?? event.title ?? "?")-\(event.startDate.timeIntervalSince1970)"
    }

    // MARK: - Brief assembly

    private func buildBrief(for event: EKEvent) -> PrepBrief {
        // The address is read as well as the name. EKParticipant.url is a
        // mailto: URL, which the previous version discarded — and it is the only
        // identifier in a calendar invite that means the same thing in a tracker
        // or a chat account.
        let invited = (event.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType == .person }
            .map { (name: $0.name, email: $0.url.absoluteString) }

        var attendees: [PrepBrief.Attendee] = []
        var knownNames: [String] = []
        let candidates = PersonStore.shared.candidates
        for (rawName, rawEmail) in invited {
            // Fall back to the address as the display name: an invite with an
            // address and no name is common, and dropping the attendee entirely
            // would quietly shrink the brief.
            let address = PersonIdentity.normalize(email: rawEmail)
            guard let raw = rawName ?? (address.isEmpty ? nil : address) else { continue }
            let match = PersonIdentity.resolve(name: rawName, email: rawEmail, among: candidates)
            let known = match?.name
            if let known {
                knownNames.append(known)
                // Learn the address, so the next invite resolves by fact rather
                // than by a comparison of names. Safe because an ambiguous name
                // no longer matches at all.
                PersonStore.shared.addEmail(rawEmail, for: known)
            }
            let person = known.flatMap { PersonStore.shared.person(named: $0) }
            let notesLine = person?.notes
                .split(separator: "\n").first.map(String.init)
            attendees.append(PrepBrief.Attendee(
                name: raw,
                knownName: known,
                notesPreview: (notesLine?.isEmpty ?? true) ? nil : notesLine,
                openCommitments: known.map { CommitmentStore.shared.open(for: $0).count } ?? 0,
                email: address.isEmpty ? nil : address))
        }

        // A calendar event with only a call link still deserves a brief —
        // match its title words against known people as a fallback.
        if attendees.isEmpty {
            for name in PersonStore.shared.allNames
            where (event.title ?? "").localizedCaseInsensitiveContains(name) {
                knownNames.append(name)
                attendees.append(PrepBrief.Attendee(
                    name: name, knownName: name,
                    notesPreview: PersonStore.shared.person(named: name)?.notes
                        .split(separator: "\n").first.map(String.init),
                    openCommitments: CommitmentStore.shared.open(for: name).count))
            }
        }

        let lastMeeting = knownNames.isEmpty ? nil : Self.lastMeeting(with: knownNames)

        let theirs = knownNames.flatMap { CommitmentStore.shared.open(for: $0) }
        let mine = CommitmentStore.shared.openMine.filter { commitment in
            knownNames.contains { commitment.text.localizedCaseInsensitiveContains($0) }
                || sharesMeeting(commitment, with: knownNames)
        }

        return PrepBrief(
            title: event.title ?? "Meeting",
            start: event.startDate, end: event.endDate,
            videoURL: Self.videoURL(in: event),
            attendees: attendees,
            lastMeeting: lastMeeting,
            youPromised: mine,
            theyPromised: theirs)
    }

    /// Did this commitment come from a meeting with any of these people?
    private func sharesMeeting(_ commitment: Commitment, with names: [String]) -> Bool {
        guard let entryID = commitment.sourceEntryID,
              let participants = HistoryStore.shared.entries
                .first(where: { $0.id == entryID })?.participants else { return false }
        return participants.contains { p in
            names.contains { $0.caseInsensitiveCompare(p) == .orderedSame }
        }
    }

    /// Kept for callers that have a name and nothing else. The rules now live in
    /// PersonIdentity, where they are reachable from test.sh.
    static func match(attendee: String, against known: [String]) -> String? {
        PersonIdentity.matchByName(attendee, among: known)
    }

    static func lastMeeting(with names: [String]) -> PrepBrief.PastMeeting? {
        let entry = HistoryStore.shared.entries.first { entry in
            guard entry.kind == .meeting else { return false }
            if let participants = entry.participants {
                return participants.contains { p in
                    names.contains { $0.caseInsensitiveCompare(p) == .orderedSame }
                }
            }
            return names.contains { entry.text.localizedCaseInsensitiveContains($0) }
        }
        guard let entry else { return nil }
        return PrepBrief.PastMeeting(title: entry.title, date: entry.date,
                                     summary: summarySection(of: entry.text),
                                     filePath: entry.filePath)
    }

    /// The "## Summary" section of the meeting notes, if present.
    static func summarySection(of markdown: String) -> String? {
        var lines: [String] = []
        var inSummary = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inSummary { break }
                inSummary = line.lowercased().contains("summary")
                continue
            }
            if inSummary { lines.append(String(line)) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func videoURL(in event: EKEvent) -> URL? {
        var haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.joined(separator: "\n")
        if haystack.isEmpty { return nil }
        haystack = haystack.replacingOccurrences(of: "<[^>]+>", with: " ",
                                                 options: .regularExpression)
        let pattern = #"https://[^\s<>"')\]]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|around\.co|meet\.jit\.si|jitsi)[^\s<>"')\]]*"#
        guard let range = haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return URL(string: String(haystack[range]))
    }
}
