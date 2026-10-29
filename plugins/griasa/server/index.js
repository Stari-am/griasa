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

const NOT_RUNNING = "Griasa is not running, or 'AI assistants (MCP)' is off in its Settings.";
const REFUSED = "Griasa rejected the extension's token — restart Griasa, then turn the Griasa extension off and on in Claude Desktop.";
const TOO_SLOW = 'Griasa took too long to answer.';
const REQUEST_TIMEOUT_MS = 60000;
// No keep-alive: nothing may hold the process open once stdin has closed.
const agent = new http.Agent({ keepAlive: false });

// The app's own tool list, instructions and protocol versions, captured when the
// extension was built. Served when the app cannot be reached, so Claude Desktop
// still learns the tools if it started before Griasa did.
let fallback = { tools: [], instructions: '', versions: ['2025-11-25', '2025-06-18'] };
try {
  fallback = Object.assign(fallback, JSON.parse(fs.readFileSync(path.join(__dirname, 'static.json'), 'utf8')));
} catch (_) { /* a bundle without it still forwards */ }

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

// Resolves { status, body }; rejects with the network error (.code is
// ECONNREFUSED when the app is not running, ETIMEDOUT when it did not answer).
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
      agent,
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

// The answer when the app cannot give one. What can be known without it is
// answered from the captured state, so a client that started first still sees
// the tools; a tool call gets a tool result the model reads and relays, and
// anything else a protocol error.
function unreachable(message, text) {
  if (message.method === 'tools/call') {
    return {
      jsonrpc: '2.0', id: message.id,
      result: { content: [{ type: 'text', text }], isError: true },
    };
  }
  if (message.method === 'initialize') {
    const asked = message.params && message.params.protocolVersion;
    // Never a version the app does not speak: the newest it does, when the
    // client asked for something else.
    const version = fallback.versions.includes(asked) ? asked : fallback.versions[0];
    return {
      jsonrpc: '2.0', id: message.id,
      result: {
        protocolVersion: version,
        capabilities: { tools: {} },
        serverInfo: { name: 'griasa', version: 'bridge' },
        instructions: fallback.instructions,
      },
    };
  }
  if (message.method === 'tools/list' && fallback.tools.length > 0) {
    return { jsonrpc: '2.0', id: message.id, result: { tools: fallback.tools } };
  }
  return failure(message.id, -32603, text);
}

function describe(error) {
  return error && error.code === 'ETIMEDOUT' ? TOO_SLOW : NOT_RUNNING;
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
    if (isRequest) write(unreachable(message, describe(error)));
    return;
  }
  if (!isRequest) return;
  if (reply.status === 401 || reply.status === 403) {
    // A tool call still gets a result the model can relay.
    write(message.method === 'tools/call' ? unreachable(message, REFUSED)
                                          : failure(message.id, -32603, REFUSED));
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
// No process.exit: once stdin has closed and the answers still in flight are
// written, nothing keeps the event loop alive, and the process ends after
// stdout has drained. Exiting by hand truncated large replies on a pipe.