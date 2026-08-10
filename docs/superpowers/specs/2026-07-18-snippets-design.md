# Dynamic snippets — design

Date: 2026-07-18. Status: approved (brainstorm in chat; user picked the
recommended option on all three questions).

## Goal

Text snippets that go beyond static expansion: computed placeholders
resolved at insert time — dates, clipboard, the user's meeting-room link,
the next free calendar slot, and AI-generated fragments. Killer combo:
`;meet` → "Would Tue 21 Jul, 15:00 work? Here's my room: <link>".

## Model & store (`Snippets.swift`)

`Snippet { id, name, abbreviation, template, enabled }`, JSON in
UserDefaults (`snippets` key) — same pattern as `PromptPreset`/`PresetStore`.
Ships with defaults: propose-a-meeting (`;meet`), three-slot options
(`;slots`), signature (`;sig`), today's date (`;today`).

## Placeholder engine (`SnippetEngine.swift`)

`render(template) async throws -> String`. Placeholders (`{…}`):

| Placeholder | Resolution |
|---|---|
| `{date}`, `{date+Nd}` | locale-formatted date, optional +N days |
| `{time}`, `{time+Nh}` | locale-formatted time, optional +N hours |
| `{clipboard}` | current pasteboard string |
| `{meetlink}` | `meetLink` UserDefaults value; empty → throws with a "set it in Settings → Snippets" message |
| `{slot}` / `{slots:N}` | next free calendar slot(s), see below |
| `{ai: prompt}` | `AIFormatter.complete(tier: .fast, allowCloudFallback: false)` — a fragment, no commentary; failure throws |

`allowCloudFallback: false` everywhere: the consent dialog would steal
focus mid-typing. Unknown placeholders pass through literally (they might
be intentional braces).

## Free slots (`FreeSlotFinder.swift`)

EventKit read (`requestFullAccessToEvents`, lazy — first `{slot}` use
prompts; new `NSCalendarsFullAccessUsageDescription` in Info.plist with the
"what still works" convention). Settings (UserDefaults):
`snippetWorkStart`=10, `snippetWorkEnd`=18, `snippetMinSlotMinutes`=30,
`snippetWeekdaysOnly`=true. Algorithm: busy = non-all-day, non-free events
across all calendars for the next 7 days, merged; scan each day's work
window starting from now+1h rounded up to the next half hour; first gap ≥
min duration wins. `{slots:N}` returns at most one slot per day (three
options on one morning is a useless proposal). Format: abbreviated
weekday + day month + time, locale-aware ("вт 21 июл, 15:00").

## Typing expander (`SnippetExpander.swift`)

`NSEvent` global+local keyDown monitors (delivered on the main thread;
Accessibility permission already required for hotkeys). Rolling buffer of
recent typed characters (cap 64):

- Reset on: ⌘/⌃-chords, arrows, Return, Tab, Esc, mouse click (separate
  click monitor), app switch (`didActivateApplicationNotification`).
- Backspace pops one char.
- Buffer suffix matches an enabled snippet's abbreviation → expand:
  synthesize Backspace × abbreviation length, `await render`, insert via
  `TextInserter` (paste). On render failure: re-insert the abbreviation
  (user loses nothing) and surface the reason via `AppState.lastError`.
- **Suppressed** while `dictationStatus != .idle` (LiveTyper's synthetic
  keystrokes would feed the buffer) and while the expander itself is mid-
  expansion. Master toggle `snippetExpansionEnabled` (default on).

## UI

- Menu bar: "Insert snippet" submenu (next to "Run on clipboard") — click
  dismisses the panel, renders, pastes into the previously-frontmost app;
  failures use `PopupController.showMessage`.
- Settings: new **Snippets** tab — DisclosureGroup list editor (name,
  abbreviation, template TextEditor, enabled toggle, delete), master
  expansion toggle, "My meeting link" field, free-slot settings (work
  hours, min duration, weekdays only), placeholder cheat sheet caption.

## Out of scope (v2+)

Voice-triggered snippets during dictation, Zoom/Google OAuth meeting
creation, Jitsi generator, `{input:}` prompt dialogs, snippet sync.
