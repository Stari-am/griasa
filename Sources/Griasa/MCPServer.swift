import AppKit
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
    @Published private(set) var lastInstallMessage: String?
    @Published private(set) var isInstalling = false

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var token: String = ""

    private var configURL: URL { StoreRoot.file("mcp.json") }

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

    /// Builds the Claude Desktop extension and hands it to Claude Desktop, which
    /// shows its own install dialog. The file goes in the store folder, next to
    /// mcp.json, so it can be found again; it holds no token — the extension
    /// reads that from mcp.json when it runs.
    func installInClaudeDesktop() {
        guard !isInstalling else { return }
        lastInstallMessage = nil
        isInstalling = true
        let destination = StoreRoot.file(MCPBundle.fileName)
        let tools = Self.bundleTools()
        let version = Self.appVersion
        // Handed over as bytes so it can cross to the background task.
        let state = try? JSONSerialization.data(withJSONObject: Self.bundleSnapshot())
        // The icon is drawn with AppKit, so it is made here; zipping is the slow
        // part and runs off the main actor.
        let icon = Self.iconPNG()

        Task.detached {
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: StoreRoot.url, withIntermediateDirectories: true)
                let snapshot = (state.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                try MCPBundle.build(into: destination, appVersion: version, tools: tools,
                                    iconPNG: icon, staticState: snapshot)
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            await MainActor.run { self.finishInstall(destination, failure: message) }
        }
    }

    private func finishInstall(_ destination: URL, failure: String?) {
        defer { isInstalling = false }
        if let failure { lastInstallMessage = failure; return }
        // Claude Desktop registers for .mcpb. Without it, the file is revealed so
        // it can be dropped onto Claude Desktop by hand.
        guard let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            lastInstallMessage = "Claude Desktop was not found. The extension is in the Griasa folder; "
                + "install Claude Desktop, then open that file."
            return
        }
        NSWorkspace.shared.open([destination], withApplicationAt: claude,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastInstallMessage = "Claude Desktop could not open the extension: \(error.localizedDescription)"
            }
        }
    }

    private static func bundleTools() -> [(name: String, description: String)] {
        MCPTools.listings.map { (name: $0["name"] as? String ?? "",
                                 description: $0["description"] as? String ?? "") }
    }

    /// What the app answers now; the bridge serves it while the app is shut.
    private static func bundleSnapshot() -> [String: Any] {
        ["tools": MCPTools.listings,
         "instructions": MCPEndpoint.instructions,
         "versions": MCPEndpoint.legacyVersions]
    }

    /// `Griasa --build-mcpb <path>`: the same extension the Settings button
    /// builds, written for release.sh to attach to the GitHub release, which is
    /// where the MCP Registry points installers.
    static func writeBundle(to destination: URL) throws {
        _ = NSApplication.shared  // iconPNG reads NSApp
        try MCPBundle.build(into: destination, appVersion: appVersion, tools: bundleTools(),
                            iconPNG: iconPNG(), staticState: bundleSnapshot())
    }

    /// `Griasa --write-plugin-server <dir>`: the bridge and the tool snapshot the
    /// agent plugin in `plugins/griasa/server/` ships — the same two files the
    /// .mcpb carries. release.sh rewrites them and refuses to ship if they changed
    /// without a commit, so the plugin never lags the app.
    static func writePluginServer(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(MCPBundle.bridgeSource.utf8).write(to: directory.appendingPathComponent("index.js"))
        let state = try JSONSerialization.data(withJSONObject: bundleSnapshot(),
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try state.write(to: directory.appendingPathComponent("static.json"))
    }

    private static func iconPNG() -> Data? {
        let image = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 512, height: 512)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        lastError = nil
        ensureReadToken()
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
                        // The read side's file (url + token) is only for a client
                        // that may read; ingest alone has nothing to put in it.
                        if self.readSideOn { self.writeConfiguration() }
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

    /// Whether assistants may read: the person's switch, or the organisation's
    /// value when it is forced (UserDefaults returns the managed value).
    private var readSideOn: Bool { UserDefaults.standard.bool(forKey: "mcpEnabled") }

    /// The read token and mcp.json exist only while the read side is on. With
    /// only the add side on, no token for reading is created or written. Safe to
    /// call again after the switch changes while the listener runs.
    private func ensureReadToken() {
        guard readSideOn, token.isEmpty else { return }
        token = Self.loadOrCreateToken(at: configURL)
        if isRunning { writeConfiguration() }
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
                    switch HTTPRequest.parse(buffer, limit: { self.bodyLimit(for: $0) }) {
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

    /// `/conversations` takes a bigger body than `/mcp`, but only while its
    /// switch is on; otherwise it is held to the same limit as everything else.
    private func bodyLimit(for path: String) -> Int {
        path == IngestHTTP.path && AssistantWrites.isOpenNow ? IngestHTTP.maxBody : HTTPRequest.maxBody
    }

    private func answer(_ request: HTTPRequest.Parsed, on connection: NWConnection) {
        if request.path == IngestHTTP.path {
            answerIngest(request, on: connection)
            return
        }
        // The server may be up only for the ingest route; reading stays off
        // unless the person turned it on.
        guard readSideOn else {
            send(status: 404, reason: "not found", on: connection)
            return
        }
        ensureReadToken()
        let gate = MCPGate(token: token, port: port)
        if case .refuse(let status, let reason) = gate.verdict(for: request) {
            send(status: status, reason: reason, on: connection)
            return
        }
        // A search with the meaning model on needs the query's vector, and the
        // tools are synchronous: fetch it first, then answer.
        if let query = SemanticSearch.shared.pendingQuery(in: request.body) {
            Task { @MainActor in
                await SemanticSearch.shared.prepare(query)
                self.respond(request, on: connection)
            }
            return
        }
        respond(request, on: connection)
    }

    private func respond(_ request: HTTPRequest.Parsed, on connection: NWConnection) {
        let environment = MCPEndpoint.Environment(
            serverVersion: Self.appVersion,
            tools: MCPTools.liveListings,
            invoke: { MCPTools.invoke($0, $1) })
        let reply = MCPEndpoint.handle(body: request.body, headers: request.headers,
                                       environment: environment)
        if let body = reply.body {
            send(body: body, status: reply.status, on: connection)
        } else {
            send(status: reply.status, reason: "", on: connection)
        }
    }

    /// `POST /conversations`: the batch goes to the review list and nothing else
    /// happens. Logs carry counts, never what was in the chat.
    private func answerIngest(_ request: HTTPRequest.Parsed, on connection: NWConnection) {
        let now = Date()
        // The token is read (or made) only for a door that is open; a closed one
        // answers as if nothing were here and touches no secret.
        let switchOn = AssistantWrites.isOpenNow
        let verdict = IngestHTTP.admit(
            method: request.method, path: request.path, headers: request.headers,
            bodySize: request.body.count, token: switchOn ? ingestToken() : "",
            recent: ingestRecent, now: now, switchOn: switchOn)
        guard verdict == .accept else {
            send(status: verdict.status, reason: verdict.reason, on: connection)
            return
        }
        ingestRecent = ingestRecent.filter { now.timeIntervalSince($0) < IngestHTTP.rateWindow } + [now]

        switch IngestHTTP.decode(request.body) {
        case .failure(let problem):
            send(status: 400, reason: problem.message, on: connection)
        case .success(let batches):
            guard let store = MCPTools.conversationStore() else {
                send(status: 503, reason: "conversations are not available", on: connection)
                return
            }
            switch AssistantWrites.queue(batches, entrance: "http", store: store, now: now) {
            case .success(let ids):
                NSLog("Griasa: %d conversation batch(es) waiting for review (http)", ids.count)
                let body = (try? JSONSerialization.data(withJSONObject: [
                    "queued": true, "review_ids": ids.map { Int($0) }])) ?? Data("{}".utf8)
                send(body: body, status: 202, on: connection)
                NotificationCenter.default.post(name: .conversationReviewChanged, object: nil)
            case .failure(let why):
                send(status: why == .full ? 409 : (why == .storage ? 500 : 400),
                     reason: why.message, on: connection)
            }
        }
    }

    // MARK: - Ingest token

    private var ingestTokenCache: String?
    private var ingestRecent: [Date] = []

    /// The endpoint's own bearer token, made on first use. Kept in the keychain
    /// and read back from memory afterwards; never written to mcp.json.
    func ingestToken() -> String {
        if let ingestTokenCache { return ingestTokenCache }
        var token = Secrets.value(IngestHTTP.tokenName)
        if token.isEmpty {
            token = Self.newToken()
            Secrets.set(IngestHTTP.tokenName, token)
        }
        ingestTokenCache = token
        return token
    }

    func rotateIngestToken() {
        let token = Self.newToken()
        Secrets.set(IngestHTTP.tokenName, token)
        ingestTokenCache = token
    }

    var ingestEndpoint: String { "http://127.0.0.1:\(port)\(IngestHTTP.path)" }

    /// Runs while the read side or the add side is switched on, and stops when
    /// neither is. Called when either switch changes and at launch.
    func reconcile() {
        let wanted = readSideOn || AssistantWrites.isOpenNow
        wanted ? start() : stop()
        if wanted { ensureReadToken() }
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    // MARK: - Writing

    private func send(body: Data, status: Int = 200, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(Self.phrase(for: status))\r\n"
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
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
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
