import Foundation
import Network

/// The socket half of the MCP endpoint: accept a local connection, hand each
/// complete request to the rules in MCPProtocol, and answer.
///
/// Hosted by the running app rather than by a separate process, so there is one
/// owner of the stores and one place that can put a confirmation on screen. The
/// consequence is that the server exists only while Griasa is running, which is
/// correct: a write has to be confirmable, and an app that is not running has
/// nothing to confirm with.
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()

    /// Chosen upward from 8179 because 8178 is already the local whisper server.
    private static let preferredPort: UInt16 = 8179

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = MCPServer.preferredPort
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var token: String = ""

    private var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa/mcp.json")
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    var currentToken: String { token }

    /// The block to paste into a client's configuration. Generated rather than
    /// documented, because a hand-copied token is a token typed wrong.
    var clientConfiguration: String {
        """
        {
          "mcpServers": {
            "griasa": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        lastError = nil
        if token.isEmpty { token = Self.loadOrCreateToken(at: configURL) }
        bind(from: Self.preferredPort, attemptsLeft: 12)
    }

    /// Tries the preferred port and walks upward. A fixed port that happens to be
    /// taken would leave the feature permanently broken with no explanation, and
    /// a random one would make the saved client configuration wrong after every
    /// restart — so: predictable first, then the next free one, written down.
    private func bind(from candidate: UInt16, attemptsLeft: Int) {
        guard attemptsLeft > 0, let nwPort = NWEndpoint.Port(rawValue: candidate) else {
            lastError = "No free port found from \(Self.preferredPort) upward."
            return
        }
        let parameters = NWParameters.tcp
        // Loopback only. Binding every interface would put months of recorded
        // conversation on the local network behind one bearer token.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = candidate
                        self.isRunning = true
                        self.writeConfiguration()
                    case .failed(let error):
                        self.listener?.cancel()
                        self.listener = nil
                        self.isRunning = false
                        // A port in use is not an error worth showing; the next
                        // one up is the answer. Anything else is.
                        if case .posix(.EADDRINUSE) = error {
                            self.bind(from: candidate + 1, attemptsLeft: attemptsLeft - 1)
                        } else {
                            self.lastError = "MCP server could not start: \(error.localizedDescription)"
                        }
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            lastError = "MCP server could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func rotateToken() {
        token = Self.newToken()
        writeConfiguration()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self?.connections[ObjectIdentifier(connection)] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Reads until MCPProtocol says a whole request has arrived, answers it, and
    /// keeps reading — one connection carries many calls.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { connection.cancel(); return }
                var buffer = buffer
                if let chunk, !chunk.isEmpty { buffer.append(chunk) }

                while true {
                    switch HTTPRequest.parse(buffer) {
                    case .incomplete:
                        if isComplete { connection.cancel(); return }
                        self.receive(on: connection, buffer: buffer)
                        return
                    case .refuse(let status, let reason):
                        // Closed only once the reply has actually gone out. The
                        // first version cancelled immediately after handing the
                        // bytes to the connection, and a client sending an
                        // oversized body got a reset instead of the 413 that
                        // explains what happened.
                        self.send(status: status, reason: reason, on: connection,
                                  thenClose: true)
                        return
                    case .complete(let request, let consumed):
                        buffer.removeFirst(consumed)
                        self.answer(request, on: connection)
                        if buffer.isEmpty {
                            if isComplete { connection.cancel(); return }
                            self.receive(on: connection, buffer: Data())
                            return
                        }
                    }
                }
            }
        }
    }

    private func answer(_ request: HTTPRequest.Parsed, on connection: NWConnection) {
        let gate = MCPGate(token: token, port: port)
        if case .refuse(let status, let reason) = gate.verdict(for: request) {
            send(status: status, reason: reason, on: connection)
            return
        }
        switch JSONRPC.decode(request.body) {
        case .failure(let failure):
            send(body: JSONRPC.failure(id: nil, failure.code, failure.message), on: connection)
        case .success(let call):
            // A notification gets an empty 202 and no JSON-RPC reply. Answering
            // one is a protocol violation that some clients report as a failed
            // session rather than ignoring.
            guard !call.isNotification else {
                send(status: 202, reason: "", on: connection)
                return
            }
            send(body: dispatch(call), on: connection)
        }
    }

    private func dispatch(_ call: JSONRPC.Request) -> Data {
        switch call.method {
        case "initialize":
            return JSONRPC.result(id: call.id, [
                // Echoed from the client when it names one, because a server that
                // insists on its own version fails the handshake with anything
                // newer than itself.
                "protocolVersion": call.params["protocolVersion"]?.stringValue ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "griasa", "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"],
            ])
        case "ping":
            return JSONRPC.result(id: call.id, [:])
        case "tools/list":
            return JSONRPC.result(id: call.id, [
                "tools": MCPTools.readOnly.map { tool in
                    ["name": tool.name, "description": tool.summary, "inputSchema": tool.schema]
                }
            ])
        case "tools/call":
            guard let name = call.params["name"]?.stringValue else {
                return JSONRPC.failure(id: call.id, .invalidParams, "missing tool name")
            }
            guard let tool = MCPTools.readOnly.first(where: { $0.name == name }) else {
                return JSONRPC.failure(id: call.id, .methodNotFound, "no tool named \(name)")
            }
            var arguments: [String: JSONValue] = [:]
            if case .object(let raw)? = call.params["arguments"] {
                for (key, value) in raw { arguments[key] = JSONValue(value) }
            }
            let payload = tool.run(arguments)
            let text = String(data: (try? JSONSerialization.data(withJSONObject: payload,
                                                                options: [.sortedKeys])) ?? Data("{}".utf8),
                              encoding: .utf8) ?? "{}"
            // Tool results travel as text content. Structured output exists in
            // newer protocol revisions, but text is what every client reads.
            return JSONRPC.result(id: call.id, [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        default:
            return JSONRPC.failure(id: call.id, .methodNotFound, "unsupported method \(call.method)")
        }
    }

    // MARK: - Writing

    private func send(body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .idempotent)
    }

    private func send(status: Int, reason: String, on connection: NWConnection,
                      thenClose: Bool = false) {
        let body = Data(reason.utf8)
        var head = "HTTP/1.1 \(status) \(Self.phrase(for: status))\r\n"
        head += "Content-Type: text/plain\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(thenClose ? "close" : "keep-alive")\r\n\r\n"
        let completion: NWConnection.SendCompletion = thenClose
            ? .contentProcessed { _ in connection.cancel() }
            : .idempotent
        connection.send(content: Data(head.utf8) + body, completion: completion)
    }

    private static func phrase(for status: Int) -> String {
        switch status {
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }

    // MARK: - Token and configuration file

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreateToken(at url: URL) -> String {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = saved["token"] as? String, token.count == 64 {
            return token
        }
        return newToken()
    }

    /// Written with owner-only permissions, set at creation rather than after:
    /// a file that is briefly world-readable is world-readable.
    private func writeConfiguration() {
        let payload: [String: Any] = ["url": endpoint, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: configURL)
        FileManager.default.createFile(atPath: configURL.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }
}
