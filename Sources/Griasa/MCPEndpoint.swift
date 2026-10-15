import Foundation

/// What the MCP endpoint answers, as a pure function of one request.
///
/// Foundation only, for the same reason as MCPProtocol: version negotiation and
/// header validation are rules, and a rule that needs a socket to exercise is a
/// rule nobody re-checks. MCPServer owns the socket and the stores; this owns
/// the protocol.
///
/// Two eras share the endpoint, picked per request rather than per connection,
/// because 2026-07-28 removed sessions and there is no connection state to hang
/// a choice on:
///
/// - **Modern (2026-07-28).** The request carries its protocol version in
///   `params._meta`, and on HTTP mirrors it, the method and the tool name into
///   headers. Nothing is negotiated; a version we do not speak is an error that
///   lists the ones we do. `server/discover` describes the server.
/// - **Legacy (2025-06-18, 2025-11-25).** `initialize` names a version and gets
///   the best one we share. Every later request is answered the same way a
///   modern one is, because this server keeps no session: that is also why no
///   `Mcp-Session-Id` is ever issued.
///
/// Read-only tools only, so nothing here asks a client for input and no
/// server-initiated message exists.
enum MCPEndpoint {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// Newest first, the order `UnsupportedProtocolVersionError.data.supported`
    /// is read in.
    static let supportedVersions = [modernVersion] + legacyVersions

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    /// A tool list does not change while the app runs, so a client may keep it a
    /// while. Five minutes: long enough to stop a client re-listing on every
    /// turn, short enough that a new version is seen the same session.
    static let listTTLms = 300_000

    static let instructions = """
        Griasa holds the user's recorded meetings, the promises made in them, and \
        what is known about each colleague. Start with list_commitments or \
        next_meeting_brief for "what is open" and "what is next"; use search_meetings \
        and get_meeting for what a meeting decided; ask for get_transcript only when \
        a summary is not enough, since it returns everything that was said. All \
        tools are read-only.
        """

    struct Environment {
        var serverVersion: String
        /// Complete `tools/list` entries: name, title, description, inputSchema,
        /// outputSchema, annotations.
        var tools: [[String: Any]]
        /// Runs a tool by name; nil when there is no such tool.
        var invoke: (String, [String: JSONValue]) -> [String: Any]?
    }

    struct Reply: Equatable {
        var status: Int
        /// nil for a bare 202.
        var body: Data?

        static func == (lhs: Reply, rhs: Reply) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
        }
    }

    // MARK: - Entry point

    static func handle(body: Data, headers: [String: String], environment: Environment) -> Reply {
        let call: JSONRPC.Request
        switch JSONRPC.decode(body) {
        case .failure(let failure):
            return Reply(status: 400, body: JSONRPC.failure(id: nil, failure.code, failure.message))
        case .success(let decoded):
            call = decoded
        }

        // A notification is acknowledged and nothing more. Answering one is a
        // protocol violation that some clients report as a failed session.
        guard !call.isNotification else { return Reply(status: 202, body: nil) }

        let metaVersion = metaProtocolVersion(of: call)
        let headerVersion = headers["mcp-protocol-version"]
        let isModern = metaVersion != nil || call.method == "server/discover"

        // Version check. The body is the source of truth and the header is its
        // mirror, so they must agree; a version we do not speak is the one error
        // the spec says must list what we do.
        let requested = metaVersion ?? headerVersion
        if let requested, !supportedVersions.contains(requested) {
            return Reply(status: 400, body: JSONRPC.failure(
                id: call.id, .unsupportedProtocolVersion, "Unsupported protocol version",
                data: ["supported": supportedVersions, "requested": requested]))
        }
        if isModern {
            if let problem = headerProblem(call: call, headers: headers, metaVersion: metaVersion) {
                return Reply(status: 400, body: JSONRPC.failure(id: call.id, .headerMismatch, problem))
            }
        }

        switch call.method {
        case "initialize" where !isModern:
            return ok(initializeResult(call, environment))
        case "ping" where !isModern:
            // Removed in 2026-07-28; still a question older clients ask.
            return ok(JSONRPC.result(id: call.id, [:]))
        case "server/discover":
            return ok(JSONRPC.result(id: call.id, decorate([
                "supportedVersions": supportedVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": instructions,
                "ttlMs": listTTLms,
                "cacheScope": "public",
            ], modern: true, environment)))
        case "tools/list":
            var result: [String: Any] = ["tools": environment.tools]
            if isModern {
                result["ttlMs"] = listTTLms
                result["cacheScope"] = "public"
            }
            return ok(JSONRPC.result(id: call.id, decorate(result, modern: isModern, environment)))
        case "tools/call":
            return callTool(call, modern: isModern, environment)
        default:
            // 2026-07-28 gives an unknown method an HTTP 404 with a JSON-RPC body,
            // which is how a client tells it apart from a server that does not
            // host the endpoint at all. Older clients got 200 with the error.
            return Reply(status: isModern ? 404 : 200,
                         body: JSONRPC.failure(id: call.id, .methodNotFound,
                                               "unsupported method \(call.method)"))
        }
    }

    // MARK: - Pieces

    private static func ok(_ body: Data) -> Reply { Reply(status: 200, body: body) }

    private static func metaProtocolVersion(of call: JSONRPC.Request) -> String? {
        guard case .object(let meta)? = call.params["_meta"] else { return nil }
        return meta[versionKey] as? String
    }

    /// Modern requests must carry the mirrored headers and they must match the
    /// body (Streamable HTTP, "Server Validation"). Returns what is wrong.
    private static func headerProblem(call: JSONRPC.Request, headers: [String: String],
                                      metaVersion: String?) -> String? {
        if let metaVersion {
            guard let header = headers["mcp-protocol-version"] else {
                return "Header mismatch: MCP-Protocol-Version header is missing"
            }
            if header != metaVersion {
                return "Header mismatch: MCP-Protocol-Version header value '\(header)' does not match body value '\(metaVersion)'"
            }
        }
        guard let method = headers["mcp-method"] else {
            return "Header mismatch: Mcp-Method header is missing"
        }
        if method != call.method {
            return "Header mismatch: Mcp-Method header value '\(method)' does not match body value '\(call.method)'"
        }
        if call.method == "tools/call" {
            guard let raw = headers["mcp-name"] else {
                return "Header mismatch: Mcp-Name header is missing"
            }
            let name = decodeHeaderValue(raw)
            if name != call.params["name"]?.stringValue {
                return "Header mismatch: Mcp-Name header value '\(name ?? raw)' does not match body value"
            }
        }
        return nil
    }

    /// `=?base64?…?=` carries a value that is not plain header text.
    static func decodeHeaderValue(_ raw: String) -> String? {
        let prefix = "=?base64?", suffix = "?="
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix),
              raw.count >= prefix.count + suffix.count else { return raw }
        let inner = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
        guard let data = Data(base64Encoded: inner) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func initializeResult(_ call: JSONRPC.Request, _ environment: Environment) -> Data {
        let asked = call.params["protocolVersion"]?.stringValue
        // Answer with the version the client asked for when it is one we speak
        // and one that still has an initialize handshake; otherwise with the
        // newest of those. The client then decides whether it can live with it.
        let version = asked.flatMap { legacyVersions.contains($0) ? $0 : nil } ?? legacyVersions[0]
        return JSONRPC.result(id: call.id, [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "griasa", "version": environment.serverVersion],
            "instructions": instructions,
        ])
    }

    private static func callTool(_ call: JSONRPC.Request, modern: Bool,
                                 _ environment: Environment) -> Reply {
        guard let name = call.params["name"]?.stringValue else {
            return ok(JSONRPC.failure(id: call.id, .invalidParams, "missing tool name"))
        }
        var arguments: [String: JSONValue] = [:]
        if case .object(let raw)? = call.params["arguments"] {
            for (key, value) in raw { arguments[key] = JSONValue(value) }
        }
        // An unknown tool is invalid params, not an unknown method: the method
        // exists, the argument naming the tool is wrong.
        guard let payload = environment.invoke(name, arguments) else {
            return ok(JSONRPC.failure(id: call.id, .invalidParams, "Unknown tool: \(name)"))
        }
        let text = String(data: (try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8),
                          encoding: .utf8) ?? "{}"
        // A tool that could not do what it was asked says so in the result, where
        // the model can read it and try again, not as a protocol error it never
        // sees. The text block carries the same JSON for clients that ignore
        // structuredContent, as the spec asks.
        let failed = payload.count == 1 && payload["error"] != nil
        return ok(JSONRPC.result(id: call.id, decorate([
            "content": [["type": "text", "text": text]],
            "structuredContent": payload,
            "isError": failed,
        ], modern: modern, environment)))
    }

    /// Modern results say they are complete and who answered.
    private static func decorate(_ result: [String: Any], modern: Bool,
                                 _ environment: Environment) -> [String: Any] {
        guard modern else { return result }
        var result = result
        result["resultType"] = "complete"
        result["_meta"] = [serverInfoKey: ["name": "griasa", "version": environment.serverVersion]]
        return result
    }
}
