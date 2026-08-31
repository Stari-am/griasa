import Foundation

/// The read surface: a manager's questions, answered from the local stores.
///
/// Two rules shape every answer. They are small — the caller is a model with a
/// finite context window, so a tool that returns everything is a tool that
/// returns nothing usable. And transcripts are never included by accident:
/// `get_meeting` gives the summary and the promises, and only `get_transcript`
/// hands over what was actually said, so "check my commitments" cannot post
/// months of conversation to somebody's cloud as a side effect.
@MainActor
enum MCPTools {
    /// Declared once and used for both `tools/list` and dispatch, so a tool
    /// cannot be advertised without existing or exist without being advertised.
    struct Tool {
        var name: String
        var summary: String
        var schema: [String: Any]
        var run: ([String: JSONValue]) -> [String: Any]
    }

    static var readOnly: [Tool] { [commitments, person, searchMeetings, meeting,
                                   transcript, brief, people, projects] }

    // MARK: - Schemas

    private static func object(_ properties: [String: [String: Any]],
                              required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
    private static let string: [String: Any] = ["type": "string"]
    private static let integer: [String: Any] = ["type": "integer"]
    private static let boolean: [String: Any] = ["type": "boolean"]

    // MARK: - Tools

    static let commitments = Tool(
        name: "list_commitments",
        summary: "Open promises, split into what you took on and what you are waiting on. "
               + "Optionally filtered to one person, or to overdue items only.",
        schema: object(["person": string, "overdue_only": boolean, "limit": integer])
    ) { params in
        let person = params["person"]?.stringValue
        let overdueOnly = params["overdue_only"]?.boolValue ?? false
        let limit = params["limit"]?.intValue ?? 50
        let store = CommitmentStore.shared

        func filter(_ items: [Commitment]) -> [[String: Any]] {
            items
                .filter { person == nil || $0.owner.caseInsensitiveCompare(person!) == .orderedSame }
                .filter { !overdueOnly || ($0.dueDate.map { $0 < Date() } ?? false) }
                .prefix(limit)
                .map(describe)
        }
        return ["mine": filter(store.openMine), "waiting_on_others": filter(store.openTheirs)]
    }

    static let person = Tool(
        name: "get_person",
        summary: "What is known about one colleague: notes, known addresses, their open "
               + "promises, and what the last recorded conversation with them was about.",
        schema: object(["name": string], required: ["name"])
    ) { params in
        guard let name = params["name"]?.stringValue else {
            return ["error": "name is required"]
        }
        let candidates = PersonStore.shared.candidates
        // The same resolution the brief uses, so an agent can ask by whatever
        // spelling it has rather than by the exact stored string.
        let resolved = PersonIdentity.resolve(name: name, email: name, among: candidates)?.name
        guard let resolved else {
            return ["found": false,
                    "known_names": PersonStore.shared.allNames.sorted()]
        }
        let record = PersonStore.shared.person(named: resolved)
        var payload: [String: Any] = [
            "found": true,
            "name": resolved,
            "notes": record?.notes ?? "",
            "emails": record?.emails ?? [],
            "open_promises_from_them": CommitmentStore.shared.open(for: resolved).map(describe),
        ]
        if let last = MeetingPrepWatcher.lastMeeting(with: [resolved]) {
            payload["last_meeting"] = ["title": last.title,
                                       "date": ISO8601DateFormatter().string(from: last.date),
                                       "summary": last.summary ?? ""]
        }
        return payload
    }

    static let searchMeetings = Tool(
        name: "search_meetings",
        summary: "Recorded meetings matching a query, by title, participant or text. Returns "
               + "titles, dates, participants and the summary section — never the transcript.",
        schema: object(["query": string, "person": string, "limit": integer])
    ) { params in
        let query = params["query"]?.stringValue
        let person = params["person"]?.stringValue
        let limit = params["limit"]?.intValue ?? 10
        let hits = HistoryStore.shared.entries
            .filter { $0.kind == .meeting }
            .filter { entry in
                guard let person else { return true }
                if let names = entry.participants,
                   names.contains(where: { $0.caseInsensitiveCompare(person) == .orderedSame }) {
                    return true
                }
                return entry.text.localizedCaseInsensitiveContains(person)
            }
            .filter { entry in
                guard let query, !query.isEmpty else { return true }
                return entry.title.localizedCaseInsensitiveContains(query)
                    || entry.text.localizedCaseInsensitiveContains(query)
            }
            .prefix(limit)
            .map { entry -> [String: Any] in
                ["id": entry.id.uuidString,
                 "title": entry.title,
                 "date": ISO8601DateFormatter().string(from: entry.date),
                 "participants": entry.participants ?? [],
                 "summary": MeetingPrepWatcher.summarySection(of: entry.text) ?? ""]
            }
        return ["meetings": Array(hits), "returned": hits.count]
    }

    static let meeting = Tool(
        name: "get_meeting",
        summary: "One meeting: its summary, and the promises that came out of it. Use "
               + "get_transcript for what was actually said.",
        schema: object(["id": string], required: ["id"])
    ) { params in
        guard let entry = entry(for: params) else { return ["found": false] }
        let fromHere = CommitmentStore.shared.commitments
            .filter { $0.sourceEntryID == entry.id }
        return ["found": true,
                "title": entry.title,
                "date": ISO8601DateFormatter().string(from: entry.date),
                "participants": entry.participants ?? [],
                "summary": MeetingPrepWatcher.summarySection(of: entry.text) ?? "",
                "commitments": fromHere.map(describe)]
    }

    static let transcript = Tool(
        name: "get_transcript",
        summary: "The full text of one recorded meeting. Everything that was said, including "
               + "anything said in passing — ask for it only when the summary is not enough.",
        schema: object(["id": string], required: ["id"])
    ) { params in
        guard let entry = entry(for: params) else { return ["found": false] }
        return ["found": true, "title": entry.title, "text": entry.text]
    }

    static let brief = Tool(
        name: "next_meeting_brief",
        summary: "The pre-meeting brief for the next call, as data: who is on it, what each of "
               + "you owes the other, and what the last conversation was about.",
        schema: object([:])
    ) { _ in
        switch MeetingPrepWatcher.shared.state {
        case .empty(let message):
            return ["available": false, "reason": message]
        case .brief(let brief):
            return ["available": true,
                    "title": brief.title,
                    "starts": ISO8601DateFormatter().string(from: brief.start),
                    "call_link": brief.videoURL?.absoluteString ?? "",
                    "attendees": brief.attendees.map { attendee in
                        ["name": attendee.name,
                         "recognised_as": attendee.knownName ?? "",
                         "open_promises": attendee.openCommitments]
                    },
                    "you_promised_them": brief.youPromised.map(describe),
                    "they_promised_you": brief.theyPromised.map(describe)]
        }
    }

    static let people = Tool(
        name: "list_people",
        summary: "Everyone Griasa knows, with how many promises of theirs are still open.",
        schema: object([:])
    ) { _ in
        ["people": PersonStore.shared.allNames.sorted().map { name in
            ["name": name, "open_promises": CommitmentStore.shared.open(for: name).count]
        }]
    }

    static let projects = Tool(
        name: "list_projects",
        summary: "The projects everything is filed into.",
        schema: object([:])
    ) { _ in
        ["projects": ProjectStore.shared.projects.map { ["id": $0.id.uuidString, "name": $0.name] }]
    }

    // MARK: - Shared shapes

    /// One promise, in the same shape everywhere. An agent that learns the shape
    /// from one tool can read it in all of them.
    nonisolated private static func describe(_ item: Commitment) -> [String: Any] {
        var payload: [String: Any] = [
            "id": item.id.uuidString,
            "text": item.text,
            "owner": item.owner,
            "mine": item.isMine,
            "made": ISO8601DateFormatter().string(from: item.date),
            "from_meeting": item.sourceTitle,
        ]
        if let due = item.dueDate {
            payload["due"] = ISO8601DateFormatter().string(from: due)
            payload["overdue"] = due < Date()
        }
        if let hint = item.dueHint { payload["due_as_spoken"] = hint }
        return payload
    }

    private static func entry(for params: [String: JSONValue]) -> HistoryEntry? {
        guard let raw = params["id"]?.stringValue, let id = UUID(uuidString: raw) else { return nil }
        return HistoryStore.shared.entries.first { $0.id == id }
    }
}
