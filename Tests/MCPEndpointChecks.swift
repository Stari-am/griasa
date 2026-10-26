import Foundation

// Checks for what the MCP endpoint answers: version negotiation across the two
// protocol eras, the mirrored-header rules of 2026-07-28, and the shape of the
// results. The socket and the stores are not involved — MCPEndpoint is a pure
// function of one request.

func runMCPEndpointChecks() -> Int {
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

let tool: [String: Any] = [
    "name": "list_people", "title": "People", "description": "d",
    "inputSchema": ["type": "object"],
    "annotations": ["readOnlyHint": true],
]
let environment = MCPEndpoint.Environment(
    serverVersion: "9.9.9",
    tools: [tool],
    invoke: { name, _ in
        switch name {
        case "list_people": return ["people": [["name": "Anna"]]]
        case "broken": return ["error": "name is required"]
        default: return nil
        }
    })

func json(_ data: Data?) -> [String: Any] {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}
func result(_ reply: MCPEndpoint.Reply) -> [String: Any] { json(reply.body)["result"] as? [String: Any] ?? [:] }
func error(_ reply: MCPEndpoint.Reply) -> [String: Any] { json(reply.body)["error"] as? [String: Any] ?? [:] }

func send(_ body: [String: Any], headers: [String: String] = [:]) -> MCPEndpoint.Reply {
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return MCPEndpoint.handle(body: data, headers: headers, environment: environment)
}

func meta(_ version: String) -> [String: Any] {
    ["io.modelcontextprotocol/protocolVersion": version,
     "io.modelcontextprotocol/clientInfo": ["name": "t", "version": "1"],
     "io.modelcontextprotocol/clientCapabilities": [String: Any]()]
}
func modern(_ method: String, id: Any = 1, params: [String: Any] = [:], version: String = "2026-07-28",
            headers extra: [String: String] = [:], dropHeader: String? = nil) -> MCPEndpoint.Reply {
    var p = params
    p["_meta"] = meta(version)
    var headers = ["mcp-protocol-version": version, "mcp-method": method]
    if method == "tools/call", let name = params["name"] as? String { headers["mcp-name"] = name }
    for (k, v) in extra { headers[k] = v }
    if let dropHeader { headers[dropHeader] = nil }
    return send(["jsonrpc": "2.0", "id": id, "method": method, "params": p], headers: headers)
}

// ── Legacy initialize ────────────────────────────────────────────────────────

for asked in ["2025-06-18", "2025-11-25", "2025-03-26", "2024-11-05"] {
    let reply = send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": ["protocolVersion": asked]])
    check(reply.status == 200 && result(reply)["protocolVersion"] as? String == asked,
          rule: "initialize with \(asked) is answered with \(asked)",
          meaning: "a client that was told another version may refuse to continue",
          saw: "status \(reply.status), \(result(reply)["protocolVersion"] ?? "none")")
}
do {
    // Versions this server does not speak: newer than any it knows, and older
    // than any it does. Each gets the newest legacy version, and the client
    // decides whether it can live with that.
    for asked in ["2030-01-01", "2023-01-01"] {
        let reply = send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": ["protocolVersion": asked]])
        check(result(reply)["protocolVersion"] as? String == "2025-11-25",
              rule: "initialize with an unknown version (\(asked)) is answered with the newest legacy version",
              meaning: "echoing a version this server does not implement is a promise it cannot keep",
              saw: "\(result(reply)["protocolVersion"] ?? "none")")
    }
    let reply = send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
    let info = result(reply)["serverInfo"] as? [String: Any]
    check(info?["version"] as? String == "9.9.9",
          rule: "initialize reports the app version",
          meaning: "clients show it, and it is what a bug report quotes",
          saw: "\(String(describing: info))")
}

// ── Legacy requests without a handshake ─────────────────────────────────────

do {
    let list = send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                    headers: ["mcp-protocol-version": "2025-06-18"])
    let tools = result(list)["tools"] as? [[String: Any]] ?? []
    check(list.status == 200 && tools.count == 1 && result(list)["resultType"] == nil,
          rule: "a legacy tools/list is stateless and carries no 2026-only fields",
          meaning: "no session exists to initialize, and extra fields are noise to an older client",
          saw: "status \(list.status), keys \(result(list).keys.sorted())")
    let ping = send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
    check(ping.status == 200 && json(ping.body)["result"] != nil,
          rule: "ping is still answered for legacy clients",
          meaning: "older clients use it as a liveness probe and drop the connection without an answer",
          saw: "status \(ping.status)")
    for older in ["2025-03-26", "2024-11-05"] {
        let accepted = send(["jsonrpc": "2.0", "id": 4, "method": "tools/list"],
                            headers: ["mcp-protocol-version": older])
        check(accepted.status == 200 && (result(accepted)["tools"] as? [Any])?.count == 1,
              rule: "a request carrying MCP-Protocol-Version \(older) is served",
              meaning: "clients still on that revision must not be turned away by the header check",
              saw: "status \(accepted.status), \(error(accepted))")
    }
    let unsupported = send(["jsonrpc": "2.0", "id": 4, "method": "tools/list"],
                           headers: ["mcp-protocol-version": "1900-01-01"])
    check(unsupported.status == 400 && error(unsupported)["code"] as? Int == -32022,
          rule: "a legacy request naming an unsupported protocol version header is a 400",
          meaning: "2025-06-18 says an invalid or unsupported MCP-Protocol-Version is Bad Request",
          saw: "status \(unsupported.status)")
}

// ── Modern: version handling ─────────────────────────────────────────────────

do {
    let ok = modern("tools/list")
    check(ok.status == 200 && result(ok)["resultType"] as? String == "complete"
            && result(ok)["ttlMs"] as? Int == MCPEndpoint.listTTLms
            && result(ok)["cacheScope"] as? String == "public",
          rule: "a 2026-07-28 tools/list is complete and carries caching hints",
          meaning: "the spec requires ttlMs and cacheScope on list results; without them clients re-list every turn",
          saw: "\(result(ok).keys.sorted())")
    let info = (result(ok)["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any]
    check(info?["name"] as? String == "griasa" && info?["version"] as? String == "9.9.9",
          rule: "modern results identify the server in _meta",
          meaning: "servers SHOULD say who answered in each result",
          saw: "\(String(describing: info))")

    let bad = modern("tools/list", version: "1900-01-01")
    let data = error(bad)["data"] as? [String: Any]
    check(bad.status == 400 && error(bad)["code"] as? Int == -32022
            && data?["supported"] as? [String] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            && data?["requested"] as? String == "1900-01-01",
          rule: "an unsupported version is UnsupportedProtocolVersionError listing what is supported",
          meaning: "the client picks a mutual version from that list and retries; without it, it gives up",
          saw: "status \(bad.status), \(error(bad))")

    let mismatch = modern("tools/list", headers: ["mcp-protocol-version": "2025-11-25"])
    check(mismatch.status == 400 && error(mismatch)["code"] as? Int == -32020,
          rule: "a header version that differs from the body's is HeaderMismatch",
          meaning: "a gateway routing on the header and a server acting on the body must not disagree",
          saw: "status \(mismatch.status), \(error(mismatch))")
    for dropped in ["mcp-protocol-version", "mcp-method"] {
        let missing = modern("tools/list", dropHeader: dropped)
        check(missing.status == 400 && error(missing)["code"] as? Int == -32020,
              rule: "a modern request without the \(dropped) header is HeaderMismatch",
              meaning: "the spec makes the mirrored headers required, not advisory",
              saw: "status \(missing.status)")
    }
    let wrongMethod = modern("tools/list", headers: ["mcp-method": "tools/call"])
    check(wrongMethod.status == 400 && error(wrongMethod)["code"] as? Int == -32020,
          rule: "an Mcp-Method that is not the body's method is HeaderMismatch",
          meaning: "the header is only trustworthy if it is checked against the body",
          saw: "status \(wrongMethod.status)")
}

// ── Modern: server/discover ─────────────────────────────────────────────────

do {
    let reply = modern("server/discover")
    let r = result(reply)
    check(reply.status == 200 && r["supportedVersions"] as? [String] == MCPEndpoint.supportedVersions
            && (r["capabilities"] as? [String: Any])?["tools"] != nil
            && r["resultType"] as? String == "complete" && r["cacheScope"] as? String == "public"
            && (r["ttlMs"] as? Int ?? -1) >= 0 && r["instructions"] is String,
          rule: "server/discover lists versions, capabilities and instructions, with caching hints",
          meaning: "servers MUST implement it; a client may call it before anything else",
          saw: "status \(reply.status), \(r.keys.sorted())")
    // Callable without a body version, as a probe: the headers alone are enough.
    let probe = send(["jsonrpc": "2.0", "id": 1, "method": "server/discover"],
                     headers: ["mcp-method": "server/discover"])
    check(probe.status == 200 && result(probe)["supportedVersions"] != nil,
          rule: "server/discover answers a bare probe",
          meaning: "a dual-era client uses it to find out which era the server speaks",
          saw: "status \(probe.status), \(error(probe))")
    let bad = modern("server/discover", version: "1900-01-01")
    check(bad.status == 400 && error(bad)["code"] as? Int == -32022,
          rule: "server/discover with an unsupported version names the supported ones",
          meaning: "same negotiation rule as every other request",
          saw: "status \(bad.status)")
}

// ── Modern: unknown methods ──────────────────────────────────────────────────

do {
    let unknown = modern("resources/list")
    check(unknown.status == 404 && error(unknown)["code"] as? Int == -32601,
          rule: "an unknown modern method is 404 with JSON-RPC -32601",
          meaning: "the JSON-RPC body is what tells a modern server's 404 from a missing endpoint",
          saw: "status \(unknown.status), \(error(unknown))")
    let ping = modern("ping")
    check(ping.status == 404 && error(ping)["code"] as? Int == -32601,
          rule: "ping does not exist in 2026-07-28",
          meaning: "the spec removed it; answering it would hide a client still on the old model",
          saw: "status \(ping.status)")
    let legacy = send(["jsonrpc": "2.0", "id": 9, "method": "resources/list"])
    check(legacy.status == 200 && error(legacy)["code"] as? Int == -32601,
          rule: "an unknown legacy method is a -32601 error with the id echoed",
          meaning: "older clients match the error to their request by id",
          saw: "status \(legacy.status), id \(String(describing: json(legacy.body)["id"]))")
}

// ── tools/call ──────────────────────────────────────────────────────────────

do {
    let reply = modern("tools/call", params: ["name": "list_people", "arguments": [String: Any]()])
    let r = result(reply)
    let content = (r["content"] as? [[String: Any]])?.first
    let structured = r["structuredContent"] as? [String: Any]
    let text = (content?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    check(reply.status == 200 && r["isError"] as? Bool == false && structured?["people"] != nil
            && text?["people"] != nil && r["resultType"] as? String == "complete",
          rule: "a tool result carries structuredContent and the same JSON as text",
          meaning: "the spec asks for the text block for clients that ignore structuredContent",
          saw: "\(r.keys.sorted())")

    let legacy = send(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                       "params": ["name": "list_people"]])
    check(legacy.status == 200 && result(legacy)["structuredContent"] != nil && result(legacy)["resultType"] == nil,
          rule: "a legacy tools/call works with no handshake",
          meaning: "the server is stateless, so there is no initialize it could be waiting for",
          saw: "status \(legacy.status), \(result(legacy).keys.sorted())")

    let failed = modern("tools/call", params: ["name": "broken"])
    check(result(failed)["isError"] as? Bool == true,
          rule: "a tool that reports an error produces isError, not a clean result",
          meaning: "the model reads isError to know the call failed and can correct it",
          saw: "\(result(failed))")

    let unknown = modern("tools/call", params: ["name": "no_such_tool"])
    check(error(unknown)["code"] as? Int == -32602,
          rule: "an unknown tool is invalid params (-32602)",
          meaning: "the spec classes it as a protocol error with that code, not method-not-found",
          saw: "\(error(unknown))")

    let wrongName = modern("tools/call", params: ["name": "list_people"], headers: ["mcp-name": "other"])
    check(wrongName.status == 400 && error(wrongName)["code"] as? Int == -32020,
          rule: "an Mcp-Name that is not params.name is HeaderMismatch",
          meaning: "gateways route on that header, so it has to be the tool actually called",
          saw: "status \(wrongName.status)")
    let encoded = "=?base64?" + Data("list_people".utf8).base64EncodedString() + "?="
    let ok = modern("tools/call", params: ["name": "list_people"], headers: ["mcp-name": encoded])
    check(ok.status == 200,
          rule: "a Base64-sentinel Mcp-Name is decoded before it is compared",
          meaning: "a name outside plain header text can only arrive that way",
          saw: "status \(ok.status)")
    let missing = modern("tools/call", params: ["name": "list_people"], dropHeader: "mcp-name")
    check(missing.status == 400,
          rule: "tools/call without Mcp-Name is rejected",
          meaning: "the spec lists it as required for tools/call",
          saw: "status \(missing.status)")
}

// ── Framing ──────────────────────────────────────────────────────────────────

do {
    let notification = send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    check(notification.status == 202 && notification.body == nil,
          rule: "a notification is a bare 202",
          meaning: "answering one is a protocol violation",
          saw: "status \(notification.status)")
    let garbage = MCPEndpoint.handle(body: Data("nope".utf8), headers: [:], environment: environment)
    check(garbage.status == 400 && error(garbage)["code"] as? Int == -32700,
          rule: "a body that is not JSON is a 400 parse error",
          meaning: "the endpoint is reachable by any local process",
          saw: "status \(garbage.status)")
    let id = send(["jsonrpc": "2.0", "id": "abc", "method": "ping"])
    check(json(id.body)["id"] as? String == "abc",
          rule: "a string id comes back as a string",
          meaning: "a client cannot pair a reply whose id changed type",
          saw: "\(String(describing: json(id.body)["id"]))")
    check(MCPEndpoint.decodeHeaderValue("plain") == "plain"
            && MCPEndpoint.decodeHeaderValue("=?base64?!!!?=") == nil,
          rule: "header decoding passes plain values and rejects broken Base64",
          meaning: "a name that cannot be decoded must not match anything",
          saw: "\(String(describing: MCPEndpoint.decodeHeaderValue("=?base64?!!!?=")))")
}

return failures
}

// MARK: - The Claude Desktop extension

func runMCPBundleChecks() -> Int {
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

check(MCPBundle.semver("1.0.18") == "1.0.18" && MCPBundle.semver("dev") == "0.0.0"
        && MCPBundle.semver("2.1") == "2.1.0" && MCPBundle.semver("1.2.3-beta.1") == "1.2.3",
      rule: "the extension version is always semver",
      meaning: "Claude Desktop rejects a manifest whose version is not",
      saw: "\(MCPBundle.semver("1.0.18")) \(MCPBundle.semver("dev")) \(MCPBundle.semver("2.1")) \(MCPBundle.semver("1.2.3-beta.1"))")

let manifest = MCPBundle.manifest(appVersion: "1.0.18", tools: [(name: "t", description: "d")])
let server = manifest["server"] as? [String: Any]
let config = server?["mcp_config"] as? [String: Any]
check(manifest["manifest_version"] as? String == "0.3" && manifest["name"] as? String == "griasa"
        && manifest["display_name"] as? String == "Griasa" && manifest["version"] as? String == "1.0.18"
        && (manifest["author"] as? [String: Any])?["name"] is String
        && server?["type"] as? String == "node" && server?["entry_point"] as? String == "server/index.js"
        && config?["command"] as? String == "node"
        && (config?["args"] as? [String])?.first == "${__dirname}/server/index.js",
      rule: "the manifest has the fields MCPB 0.3 requires and a node entry point",
      meaning: "a manifest Claude Desktop cannot read is an install that fails with no explanation",
      saw: "\(manifest.keys.sorted())")
check(manifest["tools_generated"] as? Bool == true,
      rule: "the manifest says the server can return tools it does not list",
      meaning: "the listed tools are a snapshot; after an app update the running server has more",
      saw: "\(String(describing: manifest["tools_generated"]))")
check((manifest["privacy_policies"] as? [String])?.allSatisfy { $0.hasPrefix("https://") } == true,
      rule: "the manifest links a privacy policy over https",
      meaning: "extension directories and the MCP Registry reject a local server without one",
      saw: "\(String(describing: manifest["privacy_policies"]))")
check(!MCPBundle.bridgeSource.contains("child_process") && MCPBundle.bridgeSource.contains("mcp.json"),
      rule: "the bridge reads the token from mcp.json and spawns nothing",
      meaning: "a token baked into the bundle would outlive a token change, and a bridge that runs "
             + "processes is more than a bridge",
      saw: "")

do {
    // The bridge is JavaScript inside a Swift string, so nothing else would
    // notice a syntax slip before a user's Claude Desktop did.
    let fm = FileManager.default
    let script = fm.temporaryDirectory.appendingPathComponent("griasa-bridge-check-\(UUID().uuidString).js")
    try? Data(MCPBundle.bridgeSource.utf8).write(to: script)
    defer { try? fm.removeItem(at: script) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--check", script.path]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()
    if (try? process.run()) != nil {
        process.waitUntilExit()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 127 || text.contains("No such file or directory") {
            print("  · node not found: bridge syntax check skipped")
        } else {
            check(process.terminationStatus == 0,
                  rule: "the bridge script passes node --check",
                  meaning: "a syntax error means Claude Desktop starts an extension that exits at once",
                  saw: text)
        }
    } else {
        print("  · node not found: bridge syntax check skipped")
    }
}

do {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("griasa-bundle-check-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let out = dir.appendingPathComponent("Griasa.mcpb")
    do {
        try MCPBundle.build(into: out, appVersion: "1.0.18",
                            tools: [(name: "list_people", description: "d")],
                            iconPNG: Data([0x89, 0x50, 0x4E, 0x47]),
                            staticState: ["tools": [["name": "list_people"]]])
        let unpacked = dir.appendingPathComponent("x")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", out.path, unpacked.path]
        try process.run()
        process.waitUntilExit()
        let names = ["manifest.json", "server/index.js", "server/static.json", "icon.png"]
        let present = names.allSatisfy { fm.fileExists(atPath: unpacked.appendingPathComponent($0).path) }
        check(present && !fm.fileExists(atPath: unpacked.appendingPathComponent("__MACOSX").path),
              rule: "the built bundle has manifest.json, the bridge and the icon at the archive root",
              meaning: "MCPB looks for manifest.json at the top of the zip",
              saw: "\((try? fm.contentsOfDirectory(atPath: unpacked.path)) ?? [])")
        let data = try Data(contentsOf: unpacked.appendingPathComponent("manifest.json"))
        let read = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check(read?["name"] as? String == "griasa",
              rule: "the manifest inside the bundle parses",
              meaning: "it is what Claude Desktop reads", saw: "\(String(describing: read))")
    } catch {
        check(false, rule: "the bundle builds", meaning: "the Settings button depends on it",
              saw: "\(error)")
    }
}

return failures
}
