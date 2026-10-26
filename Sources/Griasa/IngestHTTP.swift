import Foundation

/// The rules for `POST /conversations` on the local server, as pure functions.
///
/// Foundation only, like the rest of what decides who gets in. The route is a
/// second, narrower door next to `/mcp`: its own bearer token (kept in the
/// keychain, not in mcp.json), its own body limit, a rate limit, and it exists
/// only while the person's "Let assistants add to Griasa" switch is on. What it
/// accepts goes to the review list, never straight into the stores.
enum IngestHTTP {
    static let path = "/conversations"
    /// Larger than the MCP route's limit: a chat export is the point.
    static let maxBody = 2 * 1_048_576
    static let rateLimit = 30
    static let rateWindow: TimeInterval = 60
    static let tokenName = "conversationIngestToken"

    enum Admission: Equatable {
        case accept, notFound, unauthorized, forbiddenOrigin, tooLarge, rateLimited, methodNotAllowed

        var status: Int {
            switch self {
            case .accept: return 202
            case .notFound: return 404
            case .unauthorized: return 401
            case .forbiddenOrigin: return 403
            case .tooLarge: return 413
            case .rateLimited: return 429
            case .methodNotAllowed: return 405
            }
        }

        var reason: String {
            switch self {
            case .accept: return ""
            case .notFound: return "not found"
            case .unauthorized: return "a valid bearer token is required"
            case .forbiddenOrigin: return "requests from other origins are refused"
            case .tooLarge: return "body larger than \(IngestHTTP.maxBody) bytes"
            case .rateLimited: return "at most \(IngestHTTP.rateLimit) requests a minute"
            case .methodNotAllowed: return "only POST is served"
            }
        }
    }

    /// Whether one request may be served. Ordered so the cheapest and least
    /// revealing answers come first: a switch that is off, or a path that is not
    /// this route, looks like nothing is here at all.
    ///
    /// `recent` holds the times of requests already served; the rate limit counts
    /// only those inside the last minute, and only requests that got past the
    /// token should be added to it, so a stranger cannot use up the limit.
    static func admit(method: String, path: String, headers: [String: String], bodySize: Int,
                      token: String, recent: [Date], now: Date,
                      switchOn: Bool = true) -> Admission {
        guard switchOn, path == Self.path else { return .notFound }
        guard method == "POST" else { return .methodNotAllowed }
        if let origin = headers["origin"], !origin.isEmpty, !isLocalOrigin(origin) {
            return .forbiddenOrigin
        }
        // A browser page reaching this server through a name it controls
        // (DNS rebinding) sends that name as Host.
        if let host = headers["host"], !isLoopbackHost(host) { return .forbiddenOrigin }
        guard !token.isEmpty, let auth = headers["authorization"], auth.hasPrefix("Bearer "),
              MCPGate.constantTimeEqual(String(auth.dropFirst("Bearer ".count)), token) else {
            return .unauthorized
        }
        guard bodySize <= maxBody else { return .tooLarge }
        let inWindow = recent.filter { now.timeIntervalSince($0) < rateWindow && $0 <= now }
        guard inWindow.count < rateLimit else { return .rateLimited }
        return .accept
    }

    /// `http://127.0.0.1`, `http://localhost` or `http://[::1]`, with or without
    /// a port, and nothing longer: `http://127.0.0.1.evil.example` is not local.
    static func isLocalOrigin(_ origin: String) -> Bool {
        let lower = origin.lowercased()
        guard lower.hasPrefix("http://") else { return false }
        return isLoopbackHost(String(lower.dropFirst("http://".count)))
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber)) else { return false }
            host = String(host[...close])
        } else if let colon = host.firstIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return false }
            host = String(host[..<colon])
        }
        return ["127.0.0.1", "localhost", "[::1]"].contains(host)
    }

    // MARK: - Body

    /// One batch as a JSON object, or several as an array.
    static func decode(_ body: Data) -> Result<[IngestBatch], QueueProblem> {
        do {
            if let first = body.first(where: { !" \n\r\t".utf8.contains($0) }), first == UInt8(ascii: "[") {
                return .success(try JSONDecoder().decode([IngestBatch].self, from: body))
            }
            return .success([try JSONDecoder().decode(IngestBatch.self, from: body)])
        } catch {
            return .failure(QueueProblem(message: "The body is not shaped as described: \(AssistantWrites.shapeProblem(error))"))
        }
    }

    struct QueueProblem: Error, Equatable { var message: String }
}
