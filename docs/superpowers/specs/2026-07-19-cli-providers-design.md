# CLI subscription providers (Claude Code / Codex)

Date: 2026-07-19 · Status: approved (chat), implementing

## Problem

API credits and chat subscriptions are separate wallets. Users with a Claude
Pro/Max or ChatGPT Plus subscription hit "credit balance is too low" on the
API while paying for AI they can't point Griasa at. Driving the desktop apps
via UI scripting is fragile, focus-stealing, and against their ToS — but both
vendors ship official CLIs that answer headless prompts using the
subscription login.

## Design

Two new `LLMProvider` cases, same tier/router architecture as every other
provider — no call-site changes:

- `claudeCLI` — "Claude Code (subscription)". Invokes
  `claude -p --system-prompt <system> --model <model> --max-turns 1
  --output-format text --tools ""`, user message via stdin (transcripts can
  exceed ARG_MAX). Models are CLI aliases: fast `haiku`, smart `sonnet`
  (editable; `opus` for Max plans).
- `codexCLI` — "Codex CLI (ChatGPT subscription)". Invokes
  `codex exec --skip-git-repo-check --output-last-message <tmpfile>`,
  prompt via stdin, reads the final message from the tmpfile (stdout is
  progress noise). Empty model default = CLI's own default; `-m` only when
  set.

### Binary discovery

`CLIRunner.locate(_:)` checks an explicit UserDefaults override
(`claudeCLIPath` / `codexCLIPath`) first, then common install dirs
(`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/bin`,
`~/.bun/bin`, npm/volta shims). GUI apps don't inherit shell PATH, so no
`which`. Resolved path rides in `LLMConfig.baseURL`; missing binary →
`isConfigured == false`, so feature gates and hidden-if-empty UI behave as
everywhere else.

### Process execution

`CLIRunner.complete` runs the process off the main actor: stdin written on a
utility queue (child reads all input before answering — no deadlock), stdout
and stderr drained concurrently, kill on timeout. Spawned env = inherited env
with `ANTHROPIC_API_KEY` removed (the whole point is subscription auth via
the CLI's own Keychain item) and the binary's dir appended to PATH. cwd =
temp dir so the CLI never picks up a project's CLAUDE.md.

### Errors

Non-zero exit → error with stderr tail. "Not logged in" and usage-limit
wording map to `AIProviderError` (401/429) with a CLI-specific
`adviceOverride` ("run `claude` in Terminal and log in"), so the existing
`AIAccountAlert` fires with correct advice instead of API-key advice.

### Fallback semantics

CLI providers are cloud (text goes to the vendor via subscription): they are
valid `cloudFallback` candidates after the API-key providers, and the consent
dialog wording ("text will leave this Mac") stays true.

### Settings UI

Provider picker gains both entries. Selecting one shows: detection status
line (✓ found at path / "Not installed" + install hint), optional path
override field, the usual fast/smart model fields, Test button (works
through the normal router). "Load model list" hidden (no endpoint to query).

## Honest constraints (documented in Settings caption + README)

- Latency: ~5–10 s per call (process spawn + subscription session) — fine for
  smart-tier work (meeting notes, dossiers, PRD), noticeably slower than an
  API key for typing-path features (;tldr HUD covers the wait; dictation
  cleanup falls back to local rules on timeout).
- Subscriptions have their own usage limits; the CLI reports them and Griasa
  surfaces the alert.
- macOS-local dependency: no CLI installed → option shows "Not installed".
