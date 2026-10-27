import Foundation

/// What an assistant may *add* to Griasa, and the one switch that lets it.
///
/// Foundation only, with the stores passed in, so the rules can be checked
/// without a socket or a window. The two tools here are the only write surface
/// the MCP server has, and they are built to be small:
///
/// - `add_conversation` puts a chat batch on the **review list**. Nothing is
///   stored as a message, summarized or turned into a promise until the person
///   accepts it, so text planted in a chat cannot act on its own.
/// - `propose_close_commitment` fills the closure-suggestion fields a meeting
///   can fill, which is what the "Looks done" card shows. It never sets `done`.
///
/// Neither can read the review list, change an existing promise beyond that
/// suggestion, or delete anything.
enum AssistantWrites {
    static let switchKey = "assistantsMayAdd"
    static let addToolName = "add_conversation"
    static let proposeToolName = "propose_close_commitment"
    static let names: Set<String> = [addToolName, proposeToolName]

    /// The longest reason or quote `propose_close_commitment` takes. A promise
    /// is one sentence; this is room for the sentence that closes it.
    static let maxQuote = 500

    /// Whether assistants may add anything now: the person's own switch, and
    /// no organisation key closing the door. That includes `mcpEnabled` forced
    /// off: the add side runs on the same local listener, so an organisation
    /// that turned assistants off has turned this off too. Both MCP tools and the
    /// HTTP route ask this one question, so they cannot disagree.
    static func isOpen(userSwitch: Bool, policy: ManagedPolicy) -> Bool {
        userSwitch && policy.conversationsEnabled && policy.conversationIngestAllowed
            && !policy.mcpForcedOff
    }

    static var isOpenNow: Bool {
        isOpen(userSwitch: UserDefaults.standard.bool(forKey: switchKey), policy: .live)
    }

    // MARK: - Tools

    private static let write: [String: Any] = [
        "readOnlyHint": false, "destructiveHint": false,
        "idempotentHint": true, "openWorldHint": false,
    ]

    /// The write tools' `tools/list` entries: none unless the switch is open.
    static func listings(open: Bool) -> [[String: Any]] {
        guard open else { return [] }
        var annotations = write
        annotations["title"] = "Add a conversation"
        let add: [String: Any] = [
            "name": addToolName, "title": "Add a conversation",
            "description": "Offers a chat (or part of one) to Griasa. It goes to a review list and "
                + "nothing is read, summarized or turned into a promise until the user accepts it in "
                + "the Conversations tab. Messages already offered add nothing. Mark the user's own "
                + "messages with is_mine, or pass `me` (their name or id in that chat). Adds only: it "
                + "cannot read, change or delete anything.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "enum": ConversationIngest.sources,
                               "description": "Where the chat comes from."],
                    "chat": ["type": "object",
                             "properties": [
                                "id": ["type": "string", "description": "A stable id for the chat in its source."],
                                "title": ["type": "string"],
                                "type": ["type": "string", "description": "For example private, group, channel."],
                             ], "required": ["id", "title"]],
                    "me": ["type": "string", "description": "The user's own name or id in this chat."],
                    "messages": ["type": "array",
                                 "description": "At most \(ConversationIngest.maxMessages) messages.",
                                 "items": ["type": "object",
                                           "properties": [
                                            "id": ["type": "string", "description": "Stable per message; offering it again adds nothing."],
                                            "author_id": ["type": "string"],
                                            "author": ["type": "string"],
                                            "at": ["type": "string", "description": "ISO-8601, e.g. 2026-10-26T14:30:00Z."],
                                            "text": ["type": "string"],
                                            "is_mine": ["type": "boolean"],
                                            "forwarded_from": ["type": "string"],
                                           ], "required": ["id", "author", "at", "text"]]],
                ],
                "required": ["source", "chat", "messages"],
            ],
            "outputSchema": ["type": "object",
                             "properties": ["queued": ["type": "boolean"], "review_id": ["type": "integer"]]],
            "annotations": annotations,
        ]
        var closeAnnotations = write
        closeAnnotations["title"] = "Propose that a promise is done"
        let close: [String: Any] = [
            "name": proposeToolName, "title": "Propose that a promise is done",
            "description": "Suggests that an open promise is finished, with the exact quote or reason "
                + "that says so. It appears under \"Looks done\" and only the user closes it; this tool "
                + "cannot mark anything done, edit or delete. The id is from list_commitments.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The promise's id, from list_commitments."],
                    "quote_or_reason": ["type": "string",
                                        "description": "The words that show it is done, quoted exactly, or the reason. At most \(maxQuote) characters."],
                ],
                "required": ["id", "quote_or_reason"],
            ],
            "outputSchema": ["type": "object",
                             "properties": ["proposed": ["type": "boolean"], "id": ["type": "string"]]],
            "annotations": closeAnnotations,
        ]
        return [add, close]
    }

    /// What the tools reach: the conversations store and the promise list.
    struct Context {
        var store: () -> ConversationStore?
        var commitment: (UUID) -> Commitment?
        var propose: (UUID, String) -> Void
        var now: () -> Date = { Date() }
    }

    /// Runs a write tool; nil — an unknown tool — when it is not one, or the
    /// switch is closed. Both read the same as "there is no such tool".
    static func invoke(_ name: String, _ arguments: [String: JSONValue], open: Bool,
                       context: Context) -> [String: Any]? {
        guard open, names.contains(name) else { return nil }
        switch name {
        case addToolName: return add(arguments, context)
        default: return propose(arguments, context)
        }
    }

    private static func fail(_ why: String) -> [String: Any] { ["error": why] }

    private static func add(_ arguments: [String: JSONValue], _ context: Context) -> [String: Any] {
        let batch: IngestBatch
        do {
            let raw = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.raw))
            batch = try JSONDecoder().decode(IngestBatch.self, from: raw)
        } catch {
            return fail("The conversation is not shaped as described: \(shapeProblem(error))")
        }
        guard let store = context.store() else { return fail("Griasa's conversations are not available right now.") }
        switch queue([batch], entrance: "mcp", store: store, now: context.now()) {
        case .success(let ids): return ["queued": true, "review_id": Int(ids[0])]
        case .failure(let why): return fail(why.message)
        }
    }

    private static func propose(_ arguments: [String: JSONValue], _ context: Context) -> [String: Any] {
        guard let raw = arguments["id"]?.stringValue, let id = UUID(uuidString: raw) else {
            return fail("id must be a promise id from list_commitments.")
        }
        let quote = (arguments["quote_or_reason"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return fail("quote_or_reason is required.") }
        guard quote.count <= maxQuote else { return fail("quote_or_reason is too long (at most \(maxQuote) characters).") }
        guard let item = context.commitment(id) else { return fail("No promise with that id.") }
        guard !item.done else { return fail("That promise is already done.") }
        context.propose(id, quote)
        return ["proposed": true, "id": id.uuidString]
    }

    // MARK: - The review list

    enum QueueFailure: Error, Equatable {
        case invalid(String)
        case empty
        case full
        case storage

        var message: String {
            switch self {
            case .invalid(let why): return why
            case .empty: return "There is nothing to add: no message has any text."
            case .full: return "The review list is full. The user needs to accept or reject what is waiting in Griasa first."
            case .storage: return "Griasa could not store that right now."
            }
        }
    }

    /// Checks batches and puts each on the review list. Nothing else: no
    /// message is stored, no day queued, no model asked. Returns the review ids.
    static func queue(_ batches: [IngestBatch], entrance: String, store: ConversationStore,
                      now: Date) -> Result<[Int64], QueueFailure> {
        let checked: [IngestBatch]
        switch ConversationIngest.validate(batches) {
        case .failure(let why): return .failure(.invalid(why.errorDescription ?? "The request is not valid."))
        case .success(let ok): checked = ok.filter { !$0.messages.isEmpty }
        }
        guard !checked.isEmpty else { return .failure(.empty) }
        do {
            let totals = try store.reviewTotals()
            let incoming = checked.reduce(0) { $0 + $1.messages.count }
            guard ConversationIngest.reviewAdmit(count: totals.count + checked.count - 1,
                                                 messages: totals.messages, newMessages: incoming) else {
                return .failure(.full)
            }
            var ids: [Int64] = []
            for batch in checked {
                let payload = try JSONEncoder().encode(batch)
                ids.append(try store.addReview(entrance: entrance, payload: payload,
                                               messageCount: batch.messages.count,
                                               source: batch.source, sourceChatID: batch.chat.id,
                                               receivedAt: now))
            }
            return .success(ids)
        } catch {
            return .failure(.storage)
        }
    }

    /// Where a decoding failed, by field name only — never the value, which is
    /// somebody's message.
    static func shapeProblem(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "it is not valid JSON." }
        func at(_ path: [CodingKey]) -> String {
            let parts = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return parts.isEmpty ? "the top level" : String(parts.drop { $0 == "." })
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "\(at(context.codingPath + [key])) is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(at(context.codingPath)) has the wrong type."
        default: return "it is not valid JSON."
        }
    }
}
