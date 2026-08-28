import Foundation

// Checks for the MCP endpoint's framing and its front door.
//
// This is the only part of Griasa that faces anything other than the user, and
// the failure mode is not a wrong answer on screen — it is somebody else's
// process reading months of recorded conversations. So the rules here are checked
// rather than reviewed, and every one of them was shown to fail before being
// trusted.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runMCPChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

func request(_ text: String) -> Data { Data(text.utf8) }

let goodToken = "0123456789abcdef0123456789abcdef"
let gate = MCPGate(token: goodToken, port: 8179)

func parsed(_ raw: String) -> HTTPRequest.Parsed? {
    if case .complete(let value, _) = HTTPRequest.parse(request(raw)) { return value }
    return nil
}

func post(origin: String? = nil, host: String = "127.0.0.1:8179",
          auth: String? = "Bearer 0123456789abcdef0123456789abcdef",
          path: String = "/mcp", method: String = "POST", body: String = "{}") -> String {
    var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host)"]
    if let origin { lines.append("Origin: \(origin)") }
    if let auth { lines.append("Authorization: \(auth)") }
    lines.append("Content-Length: \(body.utf8.count)")
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
}

// ── Framing ──────────────────────────────────────────────────────────────────

do {
    // The expected length is taken from the string, never counted by hand. A
    // hand-written 45 for a 46-byte body is exactly the mistake this check is
    // meant to catch in the parser, and it caught it in the check instead.
    let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
    let raw = post(body: json)
    let outcome = HTTPRequest.parse(request(raw))
    if case .complete(let value, let consumed) = outcome {
        check(value.method == "POST" && value.path == "/mcp"
                && value.headers["host"] == "127.0.0.1:8179"
                && value.body == Data(json.utf8) && consumed == raw.utf8.count,
              rule: "a well-formed request parses to method, path, headers and an exact body",
              meaning: "an off-by-one on the body boundary either truncates the JSON or leaves "
                     + "bytes that get read as the start of the next request",
              saw: "method \(value.method), path \(value.path), body \(value.body.count) bytes, "
                 + "consumed \(consumed) of \(raw.utf8.count)")
    } else {
        check(false,
              rule: "a well-formed request parses to method, path, headers and an exact body",
              meaning: "nothing else can be checked if the parser cannot read a valid request",
              saw: "outcome was \(outcome)")
    }
}

// Header names are case-insensitive in HTTP. A client sending lower-case
// `authorization` must not be treated as anonymous.
do {
    let raw = "POST /mcp HTTP/1.1\r\nHOST: 127.0.0.1:8179\r\nAUTHORIZATION: Bearer \(goodToken)"
            + "\r\ncontent-length: 2\r\n\r\n{}"
    guard let value = parsed(raw) else {
        check(false, rule: "header names are matched without regard to case",
              meaning: "a client using different capitalisation would be refused as unauthorised",
              saw: "request did not parse")
        return failures
    }
    check(gate.verdict(for: value) == .allow,
          rule: "header names are matched without regard to case",
          meaning: "HTTP says names are case-insensitive; a gate that only reads one spelling "
                 + "rejects valid clients and, worse, could miss a header it means to police",
          saw: "verdict \(gate.verdict(for: value))")
}

do {
    let partial = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8179\r\nContent-Length: 40\r\n\r\n{}"
    check(HTTPRequest.parse(request(partial)) == .incomplete,
          rule: "a body shorter than Content-Length is incomplete, not an error",
          meaning: "TCP delivers whatever has arrived; treating a split request as malformed would "
                 + "break every client at random",
          saw: "\(HTTPRequest.parse(request(partial)))")
}

do {
    let chunked = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8179\r\nTransfer-Encoding: chunked\r\n\r\n"
    let outcome = HTTPRequest.parse(request(chunked))
    check(outcome == .refuse(status: 411, reason: "Transfer-Encoding is not supported; send Content-Length"),
          rule: "a chunked body is refused rather than half-understood",
          meaning: "an untested chunked decoder in the one component facing the network is a worse "
                 + "outcome than a clear refusal a client can report",
          saw: "\(outcome)")
}

do {
    let huge = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8179\r\nContent-Length: 99999999\r\n\r\n"
    if case .refuse(let status, _) = HTTPRequest.parse(request(huge)) {
        check(status == 413,
              rule: "an oversized declared body is refused before anything is allocated",
              meaning: "without a cap any local process can make the app allocate until it dies",
              saw: "status \(status)")
    } else {
        check(false, rule: "an oversized declared body is refused before anything is allocated",
              meaning: "without a cap any local process can make the app allocate until it dies",
              saw: "\(HTTPRequest.parse(request(huge)))")
    }
}

// ── The front door ───────────────────────────────────────────────────────────

do {
    guard let value = parsed(post()) else { return failures }
    check(gate.verdict(for: value) == .allow,
          rule: "a correct token over loopback is allowed",
          meaning: "the server has to actually serve its client",
          saw: "\(gate.verdict(for: value))")
}

// THE one. A page in a browser resolves its own domain to 127.0.0.1 and posts
// here; the browser attaches Origin and cannot be told not to.
do {
    guard let value = parsed(post(origin: "https://example.com")) else { return failures }
    if case .refuse(let status, _) = gate.verdict(for: value) {
        check(status == 403,
              rule: "a request carrying any Origin header is refused",
              meaning: "this is DNS rebinding: a web page talks to a localhost server with the "
                     + "page's privileges. Command-line MCP clients send no Origin, so refusing "
                     + "every one closes the door at no cost",
              saw: "status \(status)")
    } else {
        check(false, rule: "a request carrying any Origin header is refused",
              meaning: "DNS rebinding would give a web page access to every recorded conversation",
              saw: "\(gate.verdict(for: value))")
    }
}

do {
    guard let value = parsed(post(host: "evil.example.com")) else { return failures }
    if case .refuse(let status, _) = gate.verdict(for: value) {
        check(status == 403,
              rule: "a Host that is not this machine's loopback is refused",
              meaning: "the second half of the rebinding defence, and the half that still works "
                     + "when a token has leaked into a log or a screenshot",
              saw: "status \(status)")
    } else {
        check(false, rule: "a Host that is not this machine's loopback is refused",
              meaning: "the second half of the rebinding defence",
              saw: "\(gate.verdict(for: value))")
    }
}

do {
    for (label, auth) in [("no header", nil as String?),
                          ("wrong token", "Bearer 00000000000000000000000000000000"),
                          ("right token, wrong scheme", "Token \(goodToken)"),
                          ("token with a trailing character", "Bearer \(goodToken)x")] {
        guard let value = parsed(post(auth: auth)) else { continue }
        if case .refuse(let status, _) = gate.verdict(for: value) {
            check(status == 401,
                  rule: "only an exact bearer token is accepted (\(label))",
                  meaning: "the token is the real defence; a prefix or a different scheme slipping "
                         + "through would make the other checks the only thing standing there",
                  saw: "status \(status)")
        } else {
            check(false, rule: "only an exact bearer token is accepted (\(label))",
                  meaning: "the token is the real defence",
                  saw: "\(gate.verdict(for: value))")
        }
    }
}

do {
    guard let value = parsed(post(path: "/")) else { return failures }
    if case .refuse(let status, _) = gate.verdict(for: value) {
        check(status == 404, rule: "only the /mcp path is served",
              meaning: "a server that answers on every path invites being probed as a web server",
              saw: "status \(status)")
    } else {
        check(false, rule: "only the /mcp path is served",
              meaning: "a server that answers on every path invites being probed",
              saw: "\(gate.verdict(for: value))")
    }
}

do {
    guard let value = parsed(post(method: "GET", body: "")) else { return failures }
    if case .refuse(let status, _) = gate.verdict(for: value) {
        check(status == 405, rule: "only POST is served",
              meaning: "a GET that returned anything could be triggered by a plain link or an "
                     + "image tag, which needs no JavaScript at all",
              saw: "status \(status)")
    } else {
        check(false, rule: "only POST is served",
              meaning: "a GET that returns anything can be triggered by a plain link",
              saw: "\(gate.verdict(for: value))")
    }
}

// ── JSON-RPC ─────────────────────────────────────────────────────────────────

do {
    let body = #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"list_commitments"}}"#
    switch JSONRPC.decode(Data(body.utf8)) {
    case .success(let call):
        check(call.method == "tools/call" && call.id == .string("abc")
                && call.params["name"]?.stringValue == "list_commitments"
                && !call.isNotification,
              rule: "a tools/call request decodes with its id, method and params",
              meaning: "nothing works if the call cannot be read",
              saw: "method \(call.method), id \(String(describing: call.id))")
    case .failure(let error):
        check(false, rule: "a tools/call request decodes with its id, method and params",
              meaning: "nothing works if the call cannot be read", saw: "failed: \(error)")
    }
}

// An id that arrived as a string must come back as a string. Clients match
// replies to calls by identity, not by value.
do {
    for (label, body, expected) in [
        ("string id", #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#, JSONValue.string("abc")),
        ("number id", #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#, JSONValue.number(7)),
    ] {
        guard case .success(let call) = JSONRPC.decode(Data(body.utf8)) else { continue }
        check(call.id == expected,
              rule: "an id is echoed back in the type it arrived as (\(label))",
              meaning: "a client that sent a string and gets back a number cannot pair the reply "
                     + "with its call, and reports a timeout instead",
              saw: "decoded \(String(describing: call.id))")
    }
}

// A notification has no id, and replying to one is a protocol violation.
do {
    let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    guard case .success(let call) = JSONRPC.decode(Data(body.utf8)) else {
        check(false, rule: "a notification is recognised as needing no reply",
              meaning: "replying to a notification is reported as an error by some clients",
              saw: "did not decode")
        return failures
    }
    check(call.isNotification,
          rule: "a notification is recognised as needing no reply",
          meaning: "replying to one is a protocol violation, and some clients surface it as a "
                 + "failed session rather than ignoring it",
          saw: "isNotification = \(call.isNotification)")
}

do {
    if case .failure(let failure) = JSONRPC.decode(Data("not json at all".utf8)) {
        check(failure.code == .parseError,
              rule: "a body that is not JSON produces a parse error, not a crash",
              meaning: "the endpoint is reachable by any local process and will be sent rubbish",
              saw: "code \(failure.code)")
    } else {
        check(false, rule: "a body that is not JSON produces a parse error, not a crash",
              meaning: "the endpoint will be sent rubbish", saw: "decoded successfully")
    }
}

return failures
}
