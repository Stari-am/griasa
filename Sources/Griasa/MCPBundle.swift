import Foundation

/// The Claude Desktop extension (.mcpb) that lets Claude Desktop reach Griasa.
///
/// Claude Desktop installs local servers as extensions: a zip holding a
/// manifest.json and a program it launches and talks to over stdio. Griasa's
/// server is HTTP and lives inside the running app, so the extension is a small
/// Node script (Node ships inside Claude Desktop, so nothing is installed and no
/// binary is shipped) that forwards each message to the app.
///
/// Foundation only, so the manifest and the bundle layout are checked rather than
/// trusted. The script reads the port and token from mcp.json at run time, which
/// means the bundle contains no secret and survives a token change.
enum MCPBundle {
    static let extensionName = "griasa"
    static let fileName = "Griasa.mcpb"

    /// MCPB manifest 0.3. `version` must look like semver; a development build's
    /// "dev" does not, so it becomes 0.0.0 rather than an extension Claude
    /// Desktop refuses.
    static func manifest(appVersion: String, tools: [(name: String, description: String)]) -> [String: Any] {
        [
            "manifest_version": "0.3",
            "name": extensionName,
            "display_name": "Griasa",
            "version": semver(appVersion),
            "description": "Ask Claude about your Griasa meetings: open promises, people, and what the next meeting is about.",
            "long_description": "Connects Claude Desktop to Griasa on this Mac. Claude can read your open "
                + "promises, colleagues, meeting summaries and the next meeting's brief; transcripts are "
                + "returned only when asked for. Read-only, and everything stays on this Mac until Claude "
                + "reads it. Griasa must be running with \"AI assistants (MCP)\" switched on in "
                + "Settings \u{2192} System.",
            "author": ["name": "Stari", "url": "https://github.com/Stari-am/griasa"],
            "homepage": "https://github.com/Stari-am/griasa",
            "icon": "icon.png",
            "server": [
                "type": "node",
                "entry_point": "server/index.js",
                "mcp_config": [
                    "command": "node",
                    "args": ["${__dirname}/server/index.js"],
                ],
            ],
            "tools": tools.map { ["name": $0.name, "description": $0.description] },
            "tools_generated": false,
            "compatibility": [
                "platforms": ["darwin"],
                "runtimes": ["node": ">=16.0.0"],
            ],
        ]
    }

    static func semver(_ version: String) -> String {
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        let parts = core.split(separator: ".")
        guard (1...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return "0.0.0" }
        return (parts.map(String.init) + ["0", "0"]).prefix(3).joined(separator: ".")
    }

    enum BuildError: Error, LocalizedError {
        case zipFailed(String)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let reason): return "Could not create the extension: \(reason)"
            }
        }
    }

    /// Lays the extension out in a scratch directory and zips it to `destination`.
    /// `ditto -c -k` is used without --keepParent so manifest.json sits at the
    /// root of the archive, which is where MCPB looks for it.
    static func build(into destination: URL, appVersion: String,
                      tools: [(name: String, description: String)], iconPNG: Data?) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("griasa-mcpb-\(UUID().uuidString)",
                                                                   isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("server"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest(appVersion: appVersion, tools: tools),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
        try Data(bridgeSource.utf8).write(to: staging.appendingPathComponent("server/index.js"))
        if let iconPNG { try iconPNG.write(to: staging.appendingPathComponent("icon.png")) }

        try? fm.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", staging.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BuildError.zipFailed(text.isEmpty ? "ditto exited with \(process.terminationStatus)" : text)
        }
    }

    // MARK: - The bridge

    /// stdio on one side, Griasa's HTTP endpoint on the other. Node built-ins
    /// only. Kept as one self-contained file so the extension has nothing to
    /// install.
    static let bridgeSource = #"""
    #!/usr/bin/env node
    'use strict';
    // Griasa <-> Claude Desktop. Claude Desktop speaks MCP over stdio to a process
    // it launches; Griasa serves MCP over HTTP from inside the running app. This
    // forwards each line it is given to the app and writes the answer back.
    //
    // The port and token are read from Griasa's own mcp.json on every message, so
    // switching the token or the port in Griasa never needs a reinstall. Node
    // built-ins only; nothing here is installed from anywhere.

    const fs = require('fs');
    const http = require('http');
    const os = require('os');
    const path = require('path');
    const readline = require('readline');

    const NOT_RUNNING = 'Griasa is not running — open it from the menu bar.';
    const NOT_ENABLED = 'Griasa is running but is not letting assistants in — switch on ' +
      'Settings → System → AI assistants (MCP) in Griasa.';
    const REQUEST_TIMEOUT_MS = 60000;

    function storeDir() {
      const override = process.env.GRIASA_STORE || '';
      if (override) {
        return path.resolve(override.startsWith('~') ? path.join(os.homedir(), override.slice(1)) : override);
      }
      return path.join(os.homedir(), 'Library', 'Application Support', 'Griasa');
    }

    // { url, token } from mcp.json, or null when Griasa has never run here. Only
    // loopback addresses are accepted, so an edited file cannot send the token
    // somewhere else.
    function readConfig() {
      try {
        const saved = JSON.parse(fs.readFileSync(path.join(storeDir(), 'mcp.json'), 'utf8'));
        const url = new URL(saved.url);
        const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
        if (url.protocol !== 'http:' || !loopback || typeof saved.token !== 'string') return null;
        return { url, token: saved.token };
      } catch (_) {
        return null;
      }
    }

    function write(message) {
      process.stdout.write(JSON.stringify(message) + '\n');
    }

    function failure(id, code, message) {
      return { jsonrpc: '2.0', id: id === undefined ? null : id, error: { code, message } };
    }

    // Header mirrors of body fields, as Streamable HTTP 2026-07-28 requires. A
    // legacy client sends no _meta, so its version is the one the app agreed to in
    // initialize (remembered below).
    let negotiated = null;

    function headersFor(message, token) {
      const params = (message && message.params) || {};
      const meta = params._meta || {};
      const version = meta['io.modelcontextprotocol/protocolVersion'] || negotiated;
      const headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Authorization': 'Bearer ' + token,
      };
      if (version) headers['MCP-Protocol-Version'] = version;
      if (typeof message.method === 'string') {
        headers['Mcp-Method'] = message.method;
        if (message.method === 'tools/call' && typeof params.name === 'string') {
          const plain = /^[\x21-\x7e]+$/.test(params.name) && !/^=\?base64\?.*\?=$/.test(params.name);
          headers['Mcp-Name'] = plain ? params.name
            : '=?base64?' + Buffer.from(params.name, 'utf8').toString('base64') + '?=';
        }
      }
      return headers;
    }

    // Resolves { status, body }; rejects when the app cannot be reached
    // (ECONNREFUSED when it is not running).
    function post(config, message) {
      return new Promise((resolve, reject) => {
        const payload = Buffer.from(JSON.stringify(message), 'utf8');
        const headers = headersFor(message, config.token);
        headers['Content-Length'] = payload.length;
        const req = http.request({
          host: config.url.hostname.replace(/^\[|\]$/g, ''),
          port: config.url.port || 80,
          path: config.url.pathname || '/mcp',
          method: 'POST',
          headers,
          timeout: REQUEST_TIMEOUT_MS,
        }, (res) => {
          const chunks = [];
          res.on('data', (c) => chunks.push(c));
          res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
          res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(Object.assign(new Error('timed out'), { code: 'ETIMEDOUT' })));
        req.on('error', reject);
        req.end(payload);
      });
    }

    // What to tell the model when the app cannot be reached. A tool call gets a
    // tool result, which the model reads and relays; anything else gets a
    // protocol error.
    function unreachable(message, text) {
      if (message.method === 'tools/call') {
        return {
          jsonrpc: '2.0', id: message.id,
          result: { content: [{ type: 'text', text }], isError: true },
        };
      }
      // Answering initialize locally keeps the extension listed as connected while
      // the app is closed, instead of failing at startup; the first tool call then
      // explains what to do.
      if (message.method === 'initialize') {
        const asked = message.params && message.params.protocolVersion;
        return {
          jsonrpc: '2.0', id: message.id,
          result: {
            protocolVersion: typeof asked === 'string' ? asked : '2025-06-18',
            capabilities: { tools: {} },
            serverInfo: { name: 'griasa', version: 'bridge' },
            instructions: text,
          },
        };
      }
      return failure(message.id, -32603, text);
    }

    async function forward(message) {
      const isRequest = message.id !== undefined && message.id !== null && typeof message.method === 'string';
      let config = readConfig();
      if (!config) {
        if (isRequest) write(unreachable(message, NOT_RUNNING));
        return;
      }
      let reply;
      try {
        reply = await post(config, message);
        if (reply.status === 401) {
          // The token can change between reading the file and the app seeing the
          // request; read it again once before giving up.
          config = readConfig() || config;
          reply = await post(config, message);
        }
      } catch (error) {
        if (isRequest) write(unreachable(message, NOT_RUNNING));
        return;
      }
      if (!isRequest) return;
      if (reply.status === 401 || reply.status === 403) {
        write(failure(message.id, -32603, NOT_ENABLED));
        return;
      }
      let parsed = null;
      try { parsed = JSON.parse(reply.body); } catch (_) { /* not JSON */ }
      if (!parsed || typeof parsed !== 'object') {
        write(failure(message.id, -32603, 'Griasa answered HTTP ' + reply.status + ' without a JSON-RPC reply.'));
        return;
      }
      if (message.method === 'initialize' && parsed.result && typeof parsed.result.protocolVersion === 'string') {
        negotiated = parsed.result.protocolVersion;
      }
      write(parsed);
    }

    const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    const pending = new Set();
    input.on('line', (line) => {
      if (!line.trim()) return;
      let message;
      try {
        message = JSON.parse(line);
      } catch (_) {
        write(failure(null, -32700, 'Parse error'));
        return;
      }
      if (Array.isArray(message) || message === null || typeof message !== 'object') {
        write(failure(null, -32600, 'Invalid Request'));
        return;
      }
      const work = forward(message).catch((error) => {
        if (message.id !== undefined) write(failure(message.id, -32603, String((error && error.message) || error)));
      }).finally(() => pending.delete(work));
      pending.add(work);
    });
    // Close only after the answers still in flight have been written.
    input.on('close', () => Promise.allSettled([...pending]).then(() => process.exit(0)));
    """#
}
