# Griasa for AI assistants

Gives an assistant — Claude, Codex, ChatGPT desktop, Cursor, Gemini CLI and other
MCP clients — read access to [Griasa](https://github.com/Stari-am/griasa), the
meeting app on your Mac: the promises made in your meetings, the people and
projects they involve, meeting summaries, and transcripts when asked for.

It contains the Griasa skill (`skills/griasa/SKILL.md`, when to use which tool)
and a small Node bridge (`server/`) that connects the assistant to Griasa's local
MCP server.

**What data is sent where.** The bridge talks only to Griasa on `127.0.0.1`, using
the token Griasa keeps in its own folder; nothing in this plugin contacts the
internet. What the assistant reads through it — promises, summaries, a transcript
if it asks for one — goes to that assistant's model provider like anything else in
the conversation. Griasa's tools only read, unless you switch on "Let assistants
add to Griasa", which lets them propose chats and closures for you to accept.
Privacy policy: https://stari-am.github.io/griasa/privacy.html

**Needs:** Griasa running on the same Mac with *Settings → System → AI assistants
(MCP)* on, and Node.js (Claude Desktop ships its own).

In Claude Code:

```
/plugin install griasa --marketplace Stari-am/griasa
```

Installation for every other assistant is in the main
[README](https://github.com/Stari-am/griasa#let-an-assistant-read-your-meetings-mcp).

License: GPL-3.0.
