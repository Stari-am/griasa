# Managing Griasa with MDM

For IT and security teams rolling Griasa out to a company. Nothing here applies to anybody else: without a profile, Griasa behaves exactly as it always has.

## How it works

macOS does the enforcement. A configuration profile whose payload type is Griasa's bundle identifier, `am.stari.griasa`, installs *managed preferences*, which macOS returns ahead of anything the user saved. Griasa reads its settings the ordinary way, so a managed value is simply what it uses. In Settings, each managed setting is disabled and marked "set by your organization", so nobody is left moving a control that does nothing.

## Settings a profile can set

| Key | Type | Effect |
|---|---|---|
| `allowCloudAI` | Boolean | `false` closes every path that sends text off the Mac: Anthropic, OpenAI, Gemini and the Claude Code / Codex subscriptions. Cloud providers disappear from Settings, a cloud provider saved earlier is replaced by the on-device one, and nobody is offered a one-off cloud fallback. Absent means allowed. **Write it as a real boolean** (`<false/>`): a value Griasa cannot read as yes — such as `<string>false</string>` — counts as no, so a typo fails closed rather than open. |
| `llmProvider` | String | The AI provider. `custom` is the on-device, OpenAI-compatible one. |
| `customBaseURL` | String | Address of the OpenAI-compatible endpoint. `http://localhost:11434/v1` is Ollama on each Mac; a model server the organization runs works the same way. |
| `customFastModel`, `customSmartModel` | String | Model names on that endpoint. |
| `mcpEnabled` | Boolean | The local MCP endpoint that lets assistants on the Mac read meeting history. What an assistant reads goes wherever that assistant sends its context. |

Any other Griasa preference can be managed the same way and macOS will enforce it; the ones above are the ones Settings displays as locked.

**API keys are not managed through a profile.** A profile is plain text in `/Library/Managed Preferences`, which is what keys were moved out of. With `allowCloudAI` set to `false` there is nothing for a key to unlock anyway.

## Deploying

[`Griasa-on-device-only.mobileconfig`](Griasa-on-device-only.mobileconfig) is a ready profile: on-device AI only, Ollama on each Mac, MCP off. Edit `customBaseURL` if the organization runs its own model server, then either

- upload it through the MDM as a custom profile, or
- recreate the keys in the MDM's custom-settings screen (Jamf "Application & Custom Settings", Kandji "Custom Profile", Intune "Preference file") with the preference domain `am.stari.griasa`.

Profiles from an MDM install silently. Double-clicking the file on a test Mac also works: macOS asks for approval in System Settings → General → Device Management.

## Checking it on a Mac

```sh
defaults read "/Library/Managed Preferences/am.stari.griasa"
```

Then open Griasa → Settings → AI & Actions: the provider picker offers only the on-device provider and carries the note *Your organization allows only on-device AI.*

## What a profile does not cover

Data at rest — transcripts, history, people — is plain files in the user's Library, protected by FileVault and the user account, as with any app outside the sandbox. Recording consent is a matter of policy rather than configuration.
