# Multi-provider LLM support — design

Date: 2026-07-17. Status: approved (brainstorm in chat).

## Goal

Let Griasa run without an Anthropic key: OpenAI key, or fully local models
(Ollama / LM Studio / any OpenAI-compatible endpoint). One universal
integration, not per-service adapters.

## Provider model

`LLMProvider`: `anthropic` (default, unchanged behavior) / `openAI` / `gemini`
(added 2026-07-17, same day) / `custom` (OpenAI-compatible base URL). All
non-Anthropic traffic speaks the OpenAI chat-completions API — covers Gemini's
compat endpoint (`https://generativelanguage.googleapis.com/v1beta/openai`),
Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`),
OpenRouter, Groq, DeepSeek, etc.

## Model tiers

Hardcoded model strings are removed from call sites. `AIFormatter.complete`
takes `tier: .fast | .smart`; the provider config maps tiers to models:

| Provider  | fast default        | smart default       |
|-----------|---------------------|---------------------|
| Anthropic | `claude-haiku-4-5`  | `claude-opus-4-8`   |
| OpenAI    | `gpt-5.6-luna`      | `gpt-5.6-terra`     |
| Gemini    | `gemini-3.1-flash-lite` | `gemini-3.5-flash` |
| Custom    | `qwen3:8b`          | `qwen3:30b`         |

(Models verified current as of 2026-07-17: GPT-5.6 family GA 2026-07-09;
Gemini 3.5 Flash GA and 3.1 Flash-Lite stable as of 2026-07; Qwen3 is the
local-model default generation.)

Tier usage stays as today: fast = dictation cleanup, project classification,
reminder parsing, draft reply; smart = presets, live summary, Ask Project,
meeting notes.

## Config & resolution

Settings stored in UserDefaults (`llmProvider`, `openAIKey`, `geminiKey`,
`customBaseURL`, `customAPIKey`, `<provider>FastModel`/`<provider>SmartModel`,
`customContextLimit`). `LLMConfig.current()` snapshots them (thread-safe,
callable from detached tasks). Key env fallbacks: `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GEMINI_API_KEY`. Custom provider works keyless (Ollama).

`AIFormatter.isConfigured` replaces the `key.isEmpty` gates: anthropic/openAI/
gemini → key present; custom → base URL present. All "Set an Anthropic API key…"
messages become provider-neutral ("Configure an AI provider…").

## API differences

- Anthropic branch: existing Messages API code, unchanged.
- OpenAI branch: `POST {base}/chat/completions`, system as first message,
  `max_completion_tokens` for provider `.openAI` (required by GPT-5.x),
  `max_tokens` for `.gemini` and `.custom` (compat-layer/Ollama compatibility).
  `Authorization: Bearer` only when a key is set. Gemini rides this branch with
  a fixed base URL; its `/models` list returns `models/…`-prefixed ids, which
  `listModels` strips.

## Context limits

Meeting transcripts truncate at the provider's limit: 400k chars for
Anthropic/OpenAI (1M-token windows), `customContextLimit` (default 24_000)
for custom — local models rarely have >32k ctx. Truncation note stays in the
output MD. `num_ctx` is not set via the API (Ollama's /v1 endpoint ignores
options); users tune it in Ollama itself.

## Failure / fallback policy (user decision: "ask each time")

When the selected provider fails or is unreachable and a cloud key is
configured, explicit actions (presets, summaries, Ask Project, "From the
text", Draft reply) show a dialog: send this request via the cloud provider,
cancel, or "use cloud until restart". Two exceptions never ask:
- dictation cleanup silently falls back to the local rule-based cleanup;
- background history classification silently files to Inbox.

## Settings UI (AI & Actions tab)

Provider picker; per-provider fields (Anthropic key / OpenAI key / base URL +
optional key); fast & smart model fields with defaults as placeholders; for
custom, a "Load models" button fetching `{base}/models` (works on Ollama and
LM Studio) into a picker; a "Test" button that pings the fast model and shows
latency; context-limit field for custom. Hints list the common base URLs.

## Out of scope (YAGNI)

Streaming, per-feature provider routing, embeddings, auto-installing Ollama
(link only). Whisper transcription is unaffected — it's already local.
