# Managing Griasa with MDM

For IT and security teams rolling Griasa out to a company. Nothing here applies to anybody else: without a profile, Griasa behaves exactly as it always has.

## How it works

macOS does the enforcement. A configuration profile whose payload type is Griasa's bundle identifier, `am.stari.griasa`, installs *managed preferences*, which macOS returns ahead of anything the user saved. Griasa reads its settings the ordinary way, so a managed value is simply what it uses. In Settings, each managed setting is disabled and marked "set by your organization", so nobody is left moving a control that does nothing.

## Settings a profile can set

| Key | Type | Effect |
|---|---|---|
| `allowCloudAI` | Boolean | `false` closes every path that sends text off the Mac: Anthropic, OpenAI, Gemini and the Claude Code / Codex subscriptions. Cloud providers disappear from Settings, a cloud provider saved earlier is replaced by the on-device one, and nobody is offered a one-off cloud fallback. Absent means allowed. **Write it as a real boolean** (`<false/>`): a value Griasa cannot read as yes — such as `<string>false</string>` — counts as no, so a typo fails closed rather than open. |
| `allowAnthropic`, `allowClaudeCode`, `allowOpenAI`, `allowCodex`, `allowGemini` | Boolean | One switch per way text can leave the Mac, for allowing one vendor and not another. `false` closes that provider only; absent leaves it allowed. A vendor's API and its subscription CLI are separate switches — Claude Code and Codex run on the person's own Claude or ChatGPT subscription, under consumer terms rather than a company agreement — so `allowClaudeCode` false with `allowAnthropic` absent allows only the company's API account. `allowCloudAI` false overrides all of them. Same parsing rule: anything not readable as yes is no. |
| `llmProvider` | String | The AI provider. `custom` is the on-device, OpenAI-compatible one. |
| `customBaseURL` | String | Address of the OpenAI-compatible endpoint. `http://localhost:11434/v1` is Ollama on each Mac; a model server the organization runs works the same way. |
| `customFastModel`, `customSmartModel` | String | Model names on that endpoint. |
| `localModelID` | String | Pin the on-device model to one catalog entry instead of the size Griasa picks for the Mac's memory and free disk. One of `qwen3.5-4b-q4` (8 GB Macs), `qwen3.5-9b-q4` (16 GB), `gemma4-12b-q8` (32 GB), `qwen3.6-35b-a3b-q4` (56 GB), `qwen3.6-35b-a3b-q8` (96 GB). A value not in the list is ignored. A pinned model skips the memory check, so pin only on Macs with the memory shown; a model too big for the Mac swaps and runs many times slower. Ignored too when `customBaseURL`, `customFastModel` or `customSmartModel` is set: a server or models the person or the organization named are never replaced. |
| `localModelAutoDownload` | Boolean | `true` sets the on-device model up without asking: no consent card, the download (or the pull into a running Ollama) starts as soon as Griasa finds nothing suitable on the Mac. Absent means Griasa asks once. A Mac that already has a suitable model in Ollama or LM Studio downloads nothing either way, and with `customBaseURL` set there is nothing to download. |
| `localEnginePreferred` | String | Which runtime to prefer when more than one could answer: `ollama`, `lmStudio` or `griasa` (Griasa's own engine, which listens on `127.0.0.1:8177` only). A preference is only followed when that runtime already has the model; otherwise Griasa falls back to the usual order (Ollama, LM Studio, its own engine). Empty or absent lets Griasa decide. |
| `recordingNotice` | Boolean | When a recording starts, show a sentence to paste into the call's chat telling the other participants they are being recorded. Off unless set. macOS gives the other side of a call no recording indicator, so this is the place to make asking routine. Read in the safe direction: anything written that is not a clear *no* counts as on. |
| `recordingNoticeText` | String | The sentence. The default says the call is recorded and offers a way to object. |
| `audioRetentionDays` | Integer | Delete the audio of transcribed recordings after this many days (0 keeps it). Transcripts and notes are kept; a recording without a finished transcript is never touched. |
| `conversationsEnabled` | Boolean | `false` turns Conversations (chat history the person brings in, such as a Telegram export) off for everybody on the Mac. Absent means on. Same parsing rule: anything not readable as yes is no. |
| `conversationIngestEnabled` | Boolean | `false` turns off the *Let assistants add to Griasa* switch: the two MCP write tools and the local `/conversations` endpoint. Forcing `mcpEnabled` off closes this door as well (the add side runs on the same local listener), and no assistant token is created or written when only the add side is on. Absent means the person's own switch decides; `true` does not turn anything on, it only leaves the choice with the person. Anything not readable as yes is no. |
| `conversationRetentionDays` | Integer | Delete stored chat messages after this many days. Also removes waiting review batches older than the limit, and chats imported or accepted later are cut at it. Only a positive whole number counts; a string, zero or a negative value is ignored, and messages are kept (there is no personal retention setting). |
| `semanticSearchEnabled` | Boolean | `false` turns off *Search by meaning*: the 634 MB search model cannot be downloaded or run (it would listen on `127.0.0.1:8176` only), and an index already built (`search.sqlite`) is deleted at the next launch. Search then matches words, as before. Absent leaves it to the person, who still has to download the model. Anything not readable as yes is no. |
| `mcpEnabled` | Boolean | The local MCP endpoint that lets assistants on the Mac read meeting history. `false` also closes the *Let assistants add to Griasa* door, whatever `conversationIngestEnabled` says. What an assistant reads goes wherever that assistant sends its context. |

Any other Griasa preference can be managed the same way and macOS will enforce it; the ones above are the ones Settings displays as locked.

**API keys are not managed through a profile.** A profile is plain text in `/Library/Managed Preferences`, which is what keys were moved out of. With `allowCloudAI` set to `false` there is nothing for a key to unlock anyway.

## Deploying

Two ready profiles:

- [`Griasa-on-device-only.mobileconfig`](Griasa-on-device-only.mobileconfig) — on-device AI only, Ollama on each Mac, MCP off.
- [`Griasa-claude-not-chatgpt.mobileconfig`](Griasa-claude-not-chatgpt.mobileconfig) — Claude allowed, OpenAI (API and Codex) and Gemini closed.

For the first, edit `customBaseURL` if the organization runs its own model server, then either

- upload it through the MDM as a custom profile, or
- recreate the keys in the MDM's custom-settings screen (Jamf "Application & Custom Settings", Kandji "Custom Profile", Intune "Preference file") with the preference domain `am.stari.griasa`.

Profiles from an MDM install silently. Double-clicking the file on a test Mac also works: macOS asks for approval in System Settings → General → Device Management.

## Checking it on a Mac

```sh
defaults read "/Library/Managed Preferences/am.stari.griasa"
```

Then open Griasa → Settings → AI & Actions. The provider picker offers only what the profile allows, with the note *Your organization allows only on-device AI* or *Some providers are turned off by your organization*. A provider saved before the profile arrived and now closed falls back to the on-device one — never to a different vendor.

## What a profile does not cover

Data at rest — transcripts, history, people — is plain files in the user's Library, protected by FileVault and the user account, as with any app outside the sandbox. Whether a recording needs consent depends on where everybody on the call is — `recordingNotice` makes asking routine, but deciding what is required is a matter for policy and legal, not configuration.
