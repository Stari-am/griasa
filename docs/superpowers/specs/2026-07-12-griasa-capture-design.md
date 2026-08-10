# Griasa Capture — Design

Date: 2026-07-12
Status: Approved (pending spec review)

## Summary

Add a system-wide "capture" layer to Griasa that works in any app (Telegram,
Slack, browser, Mail, etc.) and feeds four everyday AI actions. All four reuse
Griasa's existing infrastructure: the `KeyCombo` hotkey monitor, `PopupController`
result window, the Claude Messages client, and `PromptPreset` presets. Screen
capture uses the OS and Apple Vision (offline, no API); reminders use EventKit.

## Goals

- Select text **or** drag a screen rectangle, then ask Claude to create a real
  reminder in Apple Reminders.
- OCR any screen rectangle to text (offline).
- Run an existing prompt preset against the current clipboard contents.
- Draft a context-aware reply by reading the frontmost chat window via OCR.

## Non-goals (v1 / YAGNI)

- Custom drag-to-select overlay (use the OS `screencapture -i` crosshair).
- Accessibility-tree reading of app content (unreliable in Electron apps).
- Per-app Telegram/Slack integrations.
- Editable tone/instruction field on Draft Reply (popup regenerate is enough).

## Architecture

One shared capture foundation feeds four action handlers. Each capture unit has
a single purpose and a narrow interface; the action handlers compose them.

### Shared foundation (new files)

- **`RegionCapture.swift`** — wraps the system interactive selector
  (`screencapture -i -x <tmp.png>`). `capture() async -> NSImage?`, returning
  `nil` when the user presses Esc (non-zero exit / missing file). No custom UI.
- **`OCR.swift`** — Apple Vision `VNRecognizeTextRequest`, recognition
  languages `["ru-RU", "en-US"]`, `.accurate`, `usesLanguageCorrection = true`.
  `recognize(_ image: NSImage) -> String` joining observations top-to-bottom.
  Fully offline; no network.
- **`WindowCapture.swift`** — screenshot of the frontmost window's bounds.
  Uses `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` to find the frontmost
  on-screen window owned by the active (non-Griasa) app, then
  `CGWindowListCreateImage` for that window's bounds. `captureFrontWindow() -> NSImage?`.
  No user interaction.
- **`Reminders.swift`** — EventKit wrapper. `requestAccess() async -> Bool`,
  `create(title:notes:due:) async throws`. Creates an `EKReminder` in the
  default reminders list with an optional `dueDateComponents` alarm.

### Action handlers

Each action is exposed as (a) a menu item in the new Capture section and
(b) a configurable global hotkey with a sensible default. Clipboard-AI is a
menu submenu (no default hotkey) because it fans out over the user's presets.

| Action | Default hotkey | Flow |
|---|---|---|
| Remind me | ⌃⌥⌘R | Grab selected text if present (existing `SelectionGrabber`), else `RegionCapture` → `OCR`. Send text to Claude (Haiku) → `{title, notes, dueDateISO?}`. Create `EKReminder`. `PopupController.showMessage` confirms ("Reminder set: … · tomorrow 3pm"). |
| OCR region | ⌃⌥⌘O | `RegionCapture` → `OCR`. Put text on `NSPasteboard` and show it in the popup (Copy / Insert). No Claude. |
| Draft reply | ⌃⌥⌘Y | `WindowCapture` → `OCR` → Claude (Haiku) drafts a reply in the thread's language and tone → popup (Copy / Replace Selection). |
| Clipboard-AI | menu submenu | "Run on clipboard ▸ [presets]" — read `NSPasteboard` string, run the chosen `PromptPreset` through the existing Claude path → popup. |

### Claude prompts

- **Remind:** system prompt instructs Claude to extract a concise reminder
  title, optional notes, and a due date. Output strict JSON:
  `{"title": string, "notes": string?, "dueDateISO": string?}` where
  `dueDateISO` is a local ISO-8601 datetime or null if no time is implied.
  Today's date is injected so relative phrases ("tomorrow 3pm") resolve.
- **Draft reply:** system prompt says: given an OCR'd chat transcript (order may
  be imperfect), draft a single natural reply as the user, matching the
  conversation's language (RU/EN) and register; return only the reply text.

## Data flow

```
hotkey / menu ─▶ action handler
                   ├─ capture: SelectionGrabber | RegionCapture+OCR | WindowCapture+OCR | Pasteboard
                   ├─ transform: Claude (Haiku) | none (OCR region)
                   └─ present: PopupController (showLoading → showResult / showMessage)
                                 └─ Remind also: Reminders.create(...)
```

## Wiring into existing code

- **`SelectionActions.swift`** — the existing NSEvent `ActionHotkeys` monitor
  gains four built-in `KeyCombo` bindings alongside the preset hotkeys, using
  the same early-out and `KeyCombo.matches` logic.
- **`PopupController.swift`** — reused as-is. `showMessage` used for the Remind
  confirmation; Draft Reply sets `canReplace = true`.
- **`MenuView.swift`** — new "Capture" section: Remind me, OCR region,
  Draft reply, and a "Run on clipboard ▸" submenu built from `PresetStore.shared.presets`.
- **`SettingsView.swift`** — the four built-in hotkeys become editable
  `HotkeyField`s in a new "Capture" group, persisted via `@AppStorage`
  (`captureRemindHotkey`, `captureOCRHotkey`, `captureReplyHotkey`).
- **Claude client** — reuse the existing Messages API path; Remind and Reply
  use `claude-haiku-4-5-20251001`.
- **`Support/Info.plist`** — add `NSRemindersUsageDescription`. Screen Recording
  (already granted) covers region and window capture.

## Error handling

- `RegionCapture` returns nil on Esc → action aborts silently (no popup).
- OCR empty result → popup message "No text found in the selection."
- `WindowCapture` nil (no eligible window) → popup message asking the user to
  focus the chat window.
- Reminders access denied → popup message pointing to System Settings →
  Reminders; the parsed reminder text is still shown so nothing is lost.
- Claude/network error → existing popup error path.
- Clipboard empty → popup message "Clipboard is empty."

## Testing

- `RegionCapture`: manual — crosshair appears, Esc yields nil, a drag yields a
  non-empty image.
- `OCR`: unit-style check against a bundled fixture PNG with known RU+EN text;
  assert both scripts recognized.
- `Reminders`: create a reminder with and without a due date; verify it appears
  in Reminders.app and (with due date) fires a notification.
- `WindowCapture`: focus Telegram/Slack, trigger Draft Reply, confirm OCR text
  contains recent messages.
- End-to-end: each hotkey from a third-party app (TextEdit, Telegram, Chrome)
  produces the expected popup without stealing/deleting the selection
  (reuse `waitForModifiersRelease`).

## Permissions

- **Reminders** (EventKit): one-time prompt on first Remind; usage string added.
- **Screen Recording**: already granted; reused for region/window capture.
- No new Accessibility scope beyond what selection grab already uses.
