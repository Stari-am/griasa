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

    /// The read tools. What the Claude Desktop extension is built from, so it
    /// never carries a tool that depends on a switch.
    static var listings: [[String: Any]] { readOnly.map(\.listing) }

    /// What `tools/list` answers now: the read tools, plus the two that add
    /// when — and only when — the person's switch is on and no organisation key
    /// forbids it. Asked on every request, so turning the switch off removes
    /// them at once.
    static var liveListings: [[String: Any]] {
        listings + AssistantWrites.listings(open: AssistantWrites.isOpenNow)
    }

    /// Runs one tool by name; nil when there is none.
    static func invoke(_ name: String, _ arguments: [String: JSONValue]) -> [String: Any]? {
        let current = renamed[name] ?? name
        if let tool = readOnly.first(where: { $0.name == current }) { return tool.run(arguments) }
        let written = AssistantWrites.invoke(name, arguments, open: AssistantWrites.isOpenNow, context: writeContext)
        if name == AssistantWrites.addToolName, written?["queued"] as? Bool == true {
            NotificationCenter.default.post(name: .conversationReviewChanged, object: nil)
        }
        return written
    }

    private static var openedStore: ConversationStore?

    /// One connection for the additions, opened when first needed.
    static func conversationStore() -> ConversationStore? {
        if openedStore == nil { openedStore = try? ConversationStore.live() }
        return openedStore
    }

    private static var writeContext: AssistantWrites.Context {
        AssistantWrites.Context(
            store: { conversationStore() },
            commitment: { id in CommitmentStore.shared.commitments.first { $0.id == id } },
            propose: { id, quote in CommitmentStore.shared.suggestClosure(id, quote: quote) })
    }

    /// Names a tool used to have. Not listed, still answered: a Claude Desktop
    /// extension installed before the rename keeps calling the old name until it
    /// is added again.
    static let renamed = ["next_meeting_brief": "get_next_meeting_brief"]

    static var readOnly: [Tool] { [commitments, person, searchMeetings, meeting,
                                   transcript, brief, upcoming, followUp, context, people, projects] }

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
        summary: "Find recorded meetings by words in the title or text, optionally with one "
               + "participant. Words match in any order and in any grammatical form, and, when the "
               + "user has turned on search by meaning, by meaning across languages; best matches "
               + "first, otherwise newest first. Returns "
               + "id, title, date, participants, summary and, when text matched, a short "
               + "'matched' excerpt — never the transcript. Use the id with get_meeting or "
               + "get_transcript.",
        schema: object([
            "query": string("Words to look for in the title or text, in any order."),
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
        // With words to look for, the best matches come first and say where they
        // matched; without, the newest meetings do.
        let ranked: [(entry: HistoryEntry, matched: String?)]
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = SemanticSearch.shared.rankMeetings(query, among: Array(hits), limit: limit)
                .map { ($0.entry, $0.matched) }
        } else {
            ranked = hits.prefix(limit).map { ($0, nil) }
        }
        let meetings = ranked.map { item -> [String: Any] in
            var row: [String: Any] = [
                "id": item.entry.id.uuidString,
                "title": item.entry.title,
                "date": ISO8601DateFormatter().string(from: item.entry.date),
                "participants": item.entry.participants ?? [],
                "summary": MeetingPrepWatcher.summarySection(of: item.entry.text) ?? ""]
            if let matched = item.matched, !matched.isEmpty { row["matched"] = matched }
            return row
        }
        return ["meetings": meetings, "returned": meetings.count]
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

    static let followUp = Tool(
        name: "draft_followup",
        title: "Follow-up draft",
        summary: "A follow-up email for one meeting, written from Griasa's notes: the summary "
               + "and who promised what for all participants, or, with person, only what that "
               + "person and the user promised. Returns subject, body, the addresses Griasa "
               + "knows and a mailto link. Griasa sends nothing: hand the link to the user or "
               + "send the draft with the user's own mail tool after they confirm. Meeting id "
               + "from search_meetings.",
        schema: object([
            "id": string("Meeting id from search_meetings."),
            "person": string("Only this participant's promises and the user's, addressed to them."),
        ], required: ["id"]),
        output: result(["found": "boolean"])
    ) { params in
        guard let entry = entry(for: params) else { return ["found": false] }
        let draft = params["person"]?.stringValue.map { FollowUpActions.personDraft(entry, person: $0) }
            ?? FollowUpActions.meetingDraft(entry)
        return ["found": true, "subject": draft.subject, "body": draft.body, "to": draft.to,
                "mailto": FollowUp.mailto(draft).url.absoluteString]
    }

    static let upcoming = Tool(
        name: "list_upcoming_meetings",
        title: "Upcoming meetings",
        summary: "The user's calendar meetings in the next days, soonest first, each with its "
               + "attendees and the open promises between the user and them: what the user "
               + "promised them and what they promised the user. Use for \"what's my week\", "
               + "\"what do I owe the people I'm meeting\". Only events with other people or a "
               + "call link; all-day events are left out. Needs calendar access; returns "
               + "available=false with a reason without it. For the very next call in detail, "
               + "get_next_meeting_brief.",
        schema: object([
            "days": integer("How many days ahead to look. Default 7, at most 14."),
            "limit": integer("Most meetings to return. Default 20."),
        ]),
        output: result(["available": "boolean"])
    ) { params in
        let days = min(max(params["days"]?.intValue ?? 7, 1), 14)
        let limit = min(max(params["limit"]?.intValue ?? 20, 1), 50)
        guard let briefs = MeetingPrepWatcher.shared.upcomingBriefs(days: days, limit: limit) else {
            return ["available": false,
                    "reason": "Griasa has no calendar access (System Settings → Privacy & Security → Calendars)."]
        }
        let iso = ISO8601DateFormatter()
        return ["available": true,
                "meetings": briefs.map { brief in
                    ["title": brief.title,
                     "starts": iso.string(from: brief.start),
                     "ends": iso.string(from: brief.end),
                     "call_link": brief.videoURL?.absoluteString ?? "",
                     "attendees": brief.attendees.map { attendee in
                         ["name": attendee.name, "recognised_as": attendee.knownName ?? ""] },
                     "you_promised_them": brief.youPromised.map(describe),
                     "they_promised_you": brief.theyPromised.map(describe)] as [String: Any]
                }]
    }

    static let context = Tool(
        name: "get_context",
        title: "Context pack",
        summary: "Everything Griasa knows about one person, project or topic, in one call and "
               + "within a size budget: open promises in both directions (overdue first), recent "
               + "meetings with their summaries, and for a person the next meeting with them. "
               + "Use it before answering a question about someone or something; follow up with "
               + "get_meeting or get_transcript only for detail it leaves out. When the budget "
               + "is tight, the oldest meetings are left out first and `omitted` says how many.",
        schema: object([
            "about": string("A person's name or email, a project name, or topic words."),
            "kind": string("person, project or topic. Omit to let Griasa decide: a known person, then a project, then a topic."),
            "budget_chars": integer("Roughly how much text to return. Default 12000, at most 40000."),
        ], required: ["about"]),
        output: result(["found": "boolean", "kind": "string"])
    ) { params in
        guard let about = params["about"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !about.isEmpty else { return ["error": "about is required"] }
        let wanted = params["kind"]?.stringValue?.lowercased()
        let budget = min(max(params["budget_chars"]?.intValue ?? 12_000, 1_000), 40_000)
        let iso = ISO8601DateFormatter()
        let meetings = HistoryStore.shared.entries.filter { $0.kind == .meeting }.sorted { $0.date > $1.date }

        func line(_ item: Commitment) -> String {
            var text = (item.isMine ? "I owe" : "\(item.owner) owes") + ": " + item.text
            if let due = item.dueDate { text += " (due \(iso.string(from: due))\(due < Date() ? ", overdue" : ""))" }
            else if let hint = item.dueHint, !hint.isEmpty { text += " (\(hint))" }
            if let quote = item.sourceQuote { text += " — \"\(quote)\"" }
            text += " [\(item.sourceTitle)]"
            return text
        }
        @MainActor func meetingLine(_ entry: HistoryEntry) -> String {
            let summary = MeetingPrepWatcher.summarySection(of: entry.text) ?? ""
            return "\(iso.string(from: entry.date)) \(entry.title) (id \(entry.id.uuidString)): \(summary)"
        }
        func overdueFirst(_ items: [Commitment]) -> [Commitment] {
            items.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        }
        @MainActor func pack(kind: String, name: String, sections: [ContextBudget.Section], extra: [String: Any]) -> [String: Any] {
            let (fitted, omitted) = ContextBudget.fit(sections, budget: budget)
            var payload: [String: Any] = ["found": true, "kind": kind, "name": name, "omitted": omitted]
            for section in fitted { payload[section.key] = section.items }
            for (key, value) in extra { payload[key] = value }
            return payload
        }

        // A person: the brief's own scoping of promises, so the pack agrees with it.
        if wanted == nil || wanted == "person",
           let person = PersonIdentity.resolve(name: about, email: about, among: PersonStore.shared.candidates)?.name {
            let buckets = MeetingPrepWatcher.buckets(forAttendees: [person]).flatMap(\.items)
            let withThem = meetings.filter { ($0.participants ?? []).contains { PromiseOwner.sameName($0, person) } }
            var extra: [String: Any] = ["notes": PersonStore.shared.person(named: person)?.notes ?? ""]
            if let next = MeetingPrepWatcher.shared.upcomingBriefs(days: 14, limit: 50)?
                .first(where: { $0.attendees.contains { $0.knownName == person } }) {
                extra["next_meeting"] = ["title": next.title, "starts": iso.string(from: next.start)]
            }
            return pack(kind: "person", name: person, sections: [
                .init(key: "i_owe_them", items: overdueFirst(buckets.filter(\.isMine)).map(line)),
                .init(key: "they_owe_me", items: overdueFirst(buckets.filter { !$0.isMine }).map(line)),
                .init(key: "recent_meetings", items: withThem.prefix(10).map(meetingLine)),
            ], extra: extra)
        }
        if wanted == "person" { return ["found": false, "known_names": PersonStore.shared.allNames.sorted()] }

        // A project, by name.
        if wanted == nil || wanted == "project",
           let project = ProjectStore.shared.projects.first(where: { $0.name.caseInsensitiveCompare(about) == .orderedSame }) {
            let inIt = meetings.filter { inProject($0, project.id) }
            let ids = Set(inIt.map(\.id))
            let open = CommitmentStore.shared.commitments.filter { !$0.done && ($0.sourceEntryID.map(ids.contains) ?? false) }
            return pack(kind: "project", name: project.name, sections: [
                .init(key: "open_promises", items: overdueFirst(open).map(line)),
                .init(key: "recent_meetings", items: inIt.prefix(10).map(meetingLine)),
            ], extra: [:])
        }
        if wanted == "project" { return ["found": false, "projects": ProjectStore.shared.projects.map(\.name)] }

        // A topic: meetings that mention it, and the promises they produced.
        let hits = SemanticSearch.shared.rankMeetings(about, among: meetings, limit: 10).map(\.entry)
        guard !hits.isEmpty else { return ["found": false, "kind": "topic"] }
        let ids = Set(hits.map(\.id))
        let open = CommitmentStore.shared.commitments.filter { !$0.done && ($0.sourceEntryID.map(ids.contains) ?? false) }
        return pack(kind: "topic", name: about, sections: [
            .init(key: "open_promises", items: overdueFirst(open).map(line)),
            .init(key: "meetings", items: hits.prefix(10).map(meetingLine)),
        ], extra: [:])
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
