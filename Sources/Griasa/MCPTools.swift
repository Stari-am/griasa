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
        /// Display name for a client's tool list.
        var title: String
        var summary: String
        var schema: [String: Any]
        /// Describes the result's top-level shape. Deliberately loose — types of
        /// the fields that are always there, nothing required — because a schema
        /// stricter than the code is a result the client rejects.
        var output: [String: Any]
        var run: ([String: JSONValue]) -> [String: Any]

        /// Every tool only reads. Stated once here, so a future write tool has to
        /// build its own entry rather than inherit a claim it does not meet.
        /// `openWorldHint` is false: the data is the user's own stores, nothing
        /// outside this Mac.
        var listing: [String: Any] {
            ["name": name, "title": title, "description": summary,
             "inputSchema": schema, "outputSchema": output,
             "annotations": ["title": title, "readOnlyHint": true, "destructiveHint": false,
                             "idempotentHint": true, "openWorldHint": false]]
        }
    }

    static var listings: [[String: Any]] { readOnly.map(\.listing) }

    /// Runs one tool by name; nil when there is none.
    static func invoke(_ name: String, _ arguments: [String: JSONValue]) -> [String: Any]? {
        let current = renamed[name] ?? name
        return readOnly.first { $0.name == current }?.run(arguments)
    }

    /// Names a tool used to have. Not listed, still answered: a Claude Desktop
    /// extension installed before the rename keeps calling the old name until it
    /// is added again.
    static let renamed = ["next_meeting_brief": "get_next_meeting_brief"]

    static var readOnly: [Tool] { [commitments, person, searchMeetings, meeting,
                                   transcript, brief, people, projects] }

    // MARK: - Schemas

    private static func object(_ properties: [String: [String: Any]],
                              required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
    private static func string(_ note: String) -> [String: Any] { ["type": "string", "description": note] }
    private static func integer(_ note: String) -> [String: Any] { ["type": "integer", "description": note] }
    private static func boolean(_ note: String) -> [String: Any] { ["type": "boolean", "description": note] }

    private static func result(_ properties: [String: String]) -> [String: Any] {
        ["type": "object", "properties": properties.mapValues { ["type": $0] }]
    }
    private static let noArguments = object([:])

    // MARK: - Tools

    static let commitments = Tool(
        name: "list_commitments",
        title: "Open promises",
        summary: "Open promises from recorded meetings, newest first, in two lists: 'mine' "
               + "(what the user owes) and 'waiting_on_others' (what others owe the user); "
               + "finished ones are left out. Use for \"what do I owe\", \"what is overdue\", "
               + "\"what is Anna still waiting on\". For one colleague's whole picture use "
               + "get_person; to get a name's exact spelling first, list_people.",
        schema: object([
            "person": string("Only promises owned by this person: the exact name as list_people returns it, case-insensitive. Omit for everyone."),
            "overdue_only": boolean("Only promises past their due date."),
            "project": string("Only promises from meetings filed under this project id, from list_projects."),
            "limit": integer("Most items in each of the two lists. Default 50; older promises past the limit are left out."),
        ]),
        output: result(["mine": "array", "waiting_on_others": "array"])
    ) { params in
        let person = params["person"]?.stringValue
        let overdueOnly = params["overdue_only"]?.boolValue ?? false
        let project = params["project"]?.stringValue.flatMap(UUID.init(uuidString:))
        let entries = Dictionary(HistoryStore.shared.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let limit = params["limit"]?.intValue ?? 50
        let store = CommitmentStore.shared

        func filter(_ items: [Commitment]) -> [[String: Any]] {
            items
                .filter { person == nil || $0.owner.caseInsensitiveCompare(person!) == .orderedSame }
                .filter { !overdueOnly || ($0.dueDate.map { $0 < Date() } ?? false) }
                .filter { item in
                    guard let project else { return true }
                    guard let id = item.sourceEntryID, let entry = entries[id] else { return false }
                    return inProject(entry, project)
                }
                .prefix(limit)
                .map(describe)
        }
        return ["mine": filter(store.openMine), "waiting_on_others": filter(store.openTheirs)]
    }

    static let person = Tool(
        name: "get_person",
        title: "Person",
        summary: "Everything known about one colleague: notes, email addresses, their open "
               + "promises, and the last recorded meeting with them. Accepts a name or email "
               + "in any spelling; if nobody matches, returns the known names.",
        schema: object(["name": string("Name or email address of the person.")], required: ["name"]),
        output: result(["found": "boolean"])
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
        title: "Search meetings",
        summary: "Find recorded meetings by title or text, optionally with one participant, "
               + "newest first. Returns id, title, date, participants and summary — never the "
               + "transcript. Use the id with get_meeting or get_transcript.",
        schema: object([
            "query": string("Words to look for in the title or text."),
            "person": string("Only meetings this person took part in."),
            "project": string("Only meetings filed under this project id, from list_projects."),
            "limit": integer("Most meetings to return. Default 10."),
        ]),
        output: result(["meetings": "array", "returned": "integer"])
    ) { params in
        let query = params["query"]?.stringValue
        let person = params["person"]?.stringValue
        let project = params["project"]?.stringValue.flatMap(UUID.init(uuidString:))
        let limit = params["limit"]?.intValue ?? 10
        let hits = HistoryStore.shared.entries
            .filter { $0.kind == .meeting }
            .filter { project == nil || inProject($0, project!) }
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
        title: "Meeting",
        summary: "One meeting by id: summary, participants and the promises made in it. "
               + "Does not include the transcript; use get_transcript for what was said.",
        schema: object(["id": string("Meeting id from search_meetings.")], required: ["id"]),
        output: result(["found": "boolean"])
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
        title: "Meeting transcript",
        summary: "The full transcript of one meeting: everything said, including remarks "
               + "in passing. Long and sensitive; call it only when get_meeting's summary "
               + "is not enough.",
        schema: object(["id": string("Meeting id from search_meetings.")], required: ["id"]),
        output: result(["found": "boolean"])
    ) { params in
        guard let entry = entry(for: params) else { return ["found": false] }
        return ["found": true, "title": entry.title, "text": entry.text]
    }

    static let brief = Tool(
        name: "get_next_meeting_brief",
        title: "Next meeting brief",
        summary: "Prep for the user's next calendar meeting: attendees, what each side "
               + "promised the other, and what was discussed last time. Built from the "
               + "calendar and recorded meetings; returns available=false with a reason when "
               + "no meeting is coming up. Use before a call; for a meeting that already "
               + "happened use search_meetings and get_meeting.",
        schema: noArguments,
        output: result(["available": "boolean"])
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
        title: "People",
        summary: "Everyone Griasa knows by name, with how many of their promises are still "
               + "open. Use to find the exact spelling before get_person or list_commitments.",
        schema: noArguments,
        output: result(["people": "array"])
    ) { _ in
        ["people": PersonStore.shared.allNames.sorted().map { name in
            ["name": name, "open_promises": CommitmentStore.shared.open(for: name).count]
        }]
    }

    /// An entry with no project is in the Inbox, whose id list_projects never shows
    /// but a caller may still pass.
    nonisolated private static func inProject(_ entry: HistoryEntry, _ id: UUID) -> Bool {
        (entry.projectID ?? Project.inboxID) == id
    }

    static let projects = Tool(
        name: "list_projects",
        title: "Projects",
        summary: "List every project the user files recordings and notes under, with id and "
               + "name, in the order the user keeps them in Settings; unfiled items sit in an "
               + "Inbox that is not listed. Use to answer what the user is working on or to match a meeting to "
               + "a project; pass an id as project to search_meetings or list_commitments.",
        schema: noArguments,
        output: result(["projects": "array"])
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
