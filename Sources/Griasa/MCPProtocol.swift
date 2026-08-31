import Foundation

/// The parts of the MCP endpoint that are decisions rather than plumbing: where a
/// request ends, whether it is allowed in, and what it is asking for.
///
/// Foundation only, deliberately. Everything security-relevant about this server
/// lives in this file, and a rule that can only be exercised by opening a socket
/// and pointing a client at it is a rule that gets checked once, by hand, on the
/// day it is written.

// MARK: - HTTP framing

/// Enough of HTTP/1.1 to serve one JSON-RPC endpoint to one local client.
///
/// Hand-rolled because the alternative is a dependency, and this project compiles
/// with swiftc and has none. Kept deliberately narrow: a request that does not
/// look exactly like what an MCP client sends is refused rather than
/// interpreted. Guessing is how a parser becomes an attack surface.
enum HTTPRequest {
    struct Parsed: Equatable {
        var method: String
        var path: String
        /// Lower-cased names, because HTTP header names are case-insensitive and
        /// a client that sends `authorization` must not be treated as anonymous.
        var headers: [String: String]
        var body: Data
    }

    enum Outcome: Equatable {
        /// Headers are not all here yet, or the body is short of Content-Length.
        case incomplete
        case complete(Parsed, consumed: Int)
        /// Malformed, or asking for something this server will not do.
        case refuse(status: Int, reason: String)
    }

    /// The largest body accepted. A JSON-RPC call from an MCP client is a few
    /// kilobytes; a megabyte is generous. Without a cap, a local process can make
    /// the app allocate until it dies.
    static let maxBody = 1_048_576

    static func parse(_ buffer: Data) -> Outcome {
        guard let headerEnd = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            // An enormous header block with no terminator is the same denial of
            // service as an enormous body.
            return buffer.count > 64 * 1024
                ? .refuse(status: 431, reason: "header block too large")
                : .incomplete
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .refuse(status: 400, reason: "headers are not UTF-8")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .refuse(status: 400, reason: "no request line")
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .refuse(status: 400, reason: "malformed request line")
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .refuse(status: 400, reason: "malformed header line")
            }
            let name = line[line.startIndex..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Chunked bodies are refused rather than supported. Every MCP client
        // sends a small JSON body with a Content-Length, and a chunked decoder
        // written for a case that does not arrive is untested code in the one
        // place that faces the network.
        if let encoding = headers["transfer-encoding"], !encoding.isEmpty {
            return .refuse(status: 411, reason: "Transfer-Encoding is not supported; send Content-Length")
        }

        let bodyStart = headerEnd.upperBound
        let declared = headers["content-length"].flatMap(Int.init) ?? 0
        guard declared >= 0 else {
            return .refuse(status: 400, reason: "negative Content-Length")
        }
        guard declared <= maxBody else {
            return .refuse(status: 413, reason: "body larger than \(maxBody) bytes")
        }
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= declared else { return .incomplete }

        let bodyEnd = buffer.index(bodyStart, offsetBy: declared)
        let parsed = Parsed(method: method, path: path, headers: headers,
                            body: Data(buffer[bodyStart..<bodyEnd]))
        return .complete(parsed, consumed: buffer.distance(from: buffer.startIndex, to: bodyEnd))
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.range(of: needle)
    }
}

// MARK: - Who is allowed in

/// Whether a parsed request may be served at all.
///
/// Two independent defences, on purpose. The token is the real one. The header
/// checks exist because tokens end up in shell history, in logs and in
/// screenshots, and because localhost servers are routinely attacked through the
/// browser: a page resolves its own domain to 127.0.0.1 and then talks to this
/// server with the page's privileges, carrying whatever the user's cookies and
/// scripts allow. A browser cannot suppress `Origin`, so refusing every request
/// that carries one closes that door completely, and costs nothing — the clients
/// this serves are command-line processes that send no Origin at all.
struct MCPGate {
    let token: String
    let port: UInt16
    /// Set false to serve read tools only, which is the default: reads and writes
    /// are different levels of trust and must not share one switch.
    var writesAllowed: Bool = false

    enum Verdict: Equatable {
        case allow
        case refuse(status: Int, reason: String)
    }

    static let path = "/mcp"

    func verdict(for request: HTTPRequest.Parsed) -> Verdict {
        guard request.path == Self.path else {
            return .refuse(status: 404, reason: "not found")
        }
        guard request.method == "POST" else {
            return .refuse(status: 405, reason: "only POST is served")
        }
        if let origin = request.headers["origin"], !origin.isEmpty {
            return .refuse(status: 403, reason: "requests carrying an Origin header are refused")
        }
        guard let host = request.headers["host"], Self.isLoopback(host, port: port) else {
            return .refuse(status: 403, reason: "Host must be this machine's loopback address")
        }
        guard let auth = request.headers["authorization"],
              auth.hasPrefix("Bearer "),
              Self.constantTimeEqual(String(auth.dropFirst("Bearer ".count)), token) else {
            return .refuse(status: 401, reason: "a valid bearer token is required")
        }
        return .allow
    }

    static func isLoopback(_ host: String, port: UInt16) -> Bool {
        let expected: Set<String> = [
            "127.0.0.1:\(port)", "localhost:\(port)",
            "[::1]:\(port)", "127.0.0.1", "localhost", "[::1]",
        ]
        return expected.contains(host.lowercased())
    }

    /// Compared in constant time. Over loopback a timing attack is far-fetched,
    /// but the alternative costs one line and there is no argument for the
    /// version that leaks.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

// MARK: - JSON-RPC

/// The subset of JSON-RPC 2.0 that MCP uses, plus the MCP methods this server
/// answers. Requests carry an id and expect a reply; notifications have no id and
/// must not be replied to — answering one is a protocol violation that some
/// clients report as an error.
enum JSONRPC {
    struct Request {
        var id: JSONValue?
        var method: String
        var params: [String: JSONValue]

        var isNotification: Bool { id == nil }
    }

    /// Result's failure type has to conform to Error, so the code and its
    /// message travel as a value rather than a tuple.
    struct Failure: Error, Equatable {
        var code: ErrorCode
        var message: String
    }

    enum ErrorCode: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }

    static func decode(_ data: Data) -> Result<Request, Failure> {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return .failure(Failure(code: .parseError, message: "body is not a JSON object"))
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return .failure(Failure(code: .invalidRequest, message: "missing method"))
        }
        let params = (object["params"] as? [String: Any]).map(JSONValue.object) ?? .object([:])
        var paramDict: [String: JSONValue] = [:]
        if case .object(let raw) = params {
            for (key, item) in raw { paramDict[key] = JSONValue(item) }
        }
        return .success(Request(id: object["id"].flatMap { JSONValue($0) },
                                method: method, params: paramDict))
    }

    static func result(id: JSONValue?, _ payload: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id?.raw ?? NSNull(), "result": payload])
    }

    static func failure(id: JSONValue?, _ code: ErrorCode, _ message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id?.raw ?? NSNull(),
                "error": ["code": code.rawValue, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// A tiny stand-in for an arbitrary JSON value, so an id can be echoed back in
/// whatever type it arrived as. Clients use numbers and strings both, and
/// returning a number where a string was sent breaks the match on their side.
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: Any])
    case array([Any])
    case null

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        // NSNumber must be examined before Bool, and this order was got wrong
        // once. JSONSerialization returns every JSON number as an NSNumber, and
        // `NSNumber(1) as? Bool` succeeds through Objective-C bridging — so a
        // request carrying `"id": 1` came back with `"id": true`, which no client
        // can pair with its call. The unit test missed it because it used 7, and
        // `NSNumber(7) as? Bool` is nil: the hole was exactly the two values that
        // look like booleans. The type encoding is the only reliable answer.
        case let value as NSNumber:
            self = String(cString: value.objCType) == "c" ? .bool(value.boolValue)
                                                          : .number(value.doubleValue)
        case let value as Bool: self = .bool(value)
        case let value as [String: Any]: self = .object(value)
        case let value as [Any]: self = .array(value)
        default: self = .null
        }
    }

    var raw: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? Int(value) : value
        case .bool(let value): return value
        case .object(let value): return value
        case .array(let value): return value
        case .null: return NSNull()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}
