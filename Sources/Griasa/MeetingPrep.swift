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
    /// Occurrences already shown this run, so a brief fires once per event.
    private var shown: Set<String> = []

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "prepBriefEnabled") as? Bool ?? true
    }
    static var leadMinutes: Int {
        UserDefaults.standard.object(forKey: "prepLeadMinutes") as? Int ?? 5
    }

    func start() {
        guard timer == nil else { return }
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
                state = .brief(buildBrief(for: event))
            } else {
                state = .empty("No meetings in the next 12 hours 🎉")
            }
            HubController.shared.open(.prep)
        }
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
        let attendeeNames = (event.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType == .person }
            .compactMap(\.name)

        var attendees: [PrepBrief.Attendee] = []
        var knownNames: [String] = []
        for raw in attendeeNames {
            let known = Self.match(attendee: raw, against: PersonStore.shared.allNames)
            if let known { knownNames.append(known) }
            let person = known.flatMap { PersonStore.shared.person(named: $0) }
            let notesLine = person?.notes
                .split(separator: "\n").first.map(String.init)
            attendees.append(PrepBrief.Attendee(
                name: raw,
                knownName: known,
                notesPreview: (notesLine?.isEmpty ?? true) ? nil : notesLine,
                openCommitments: known.map { CommitmentStore.shared.open(for: $0).count } ?? 0))
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

    /// "Ivan Petrov" (calendar) ↔ "Ivan" (roster): match when one name's
    /// tokens are a subset of the other's.
    static func match(attendee: String, against known: [String]) -> String? {
        let attendeeTokens = Set(attendee.lowercased().split(separator: " ").map(String.init))
        guard !attendeeTokens.isEmpty else { return nil }
        return known.first { name in
            let tokens = Set(name.lowercased().split(separator: " ").map(String.init))
            return !tokens.isEmpty
                && (tokens.isSubset(of: attendeeTokens) || attendeeTokens.isSubset(of: tokens))
        }
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
