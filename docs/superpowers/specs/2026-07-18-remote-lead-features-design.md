# Remote-lead features: Commitments, People, Meeting Prep, Doc Templates

Date: 2026-07-18. Approved by user (checklist-in-Griasa variant for commitments; auto+manual prep; AI-filled templates; person pages with dossier). Explicit requirement: **Apple-grade UX polish** — empty states that explain what will appear, graceful degradation instead of alerts, relative dates, subtle animations, nothing steals focus, sensible defaults everywhere. The user should feel the app thought about them in advance.

## UX polish rules (apply to all four features)

- Every list has a designed empty state: SF Symbol + one friendly sentence about what will appear here and what triggers it.
- Dates render relatively ("2 days ago") via `.formatted(.relative(presentation: .named))`.
- Check-offs, insertions, and removals animate (`withAnimation(.snappy)`).
- Missing prerequisite (no AI provider, no calendar access) → inline caption + a button that fixes it, never a modal.
- Background events (auto-brief) surface the hub panel **without stealing keyboard focus** — `HubController.open(tab, activate: false)` orders the panel front but does not `makeKey`/activate.
- One-click feedback: buttons that fire an action flash a ✓ state briefly (e.g. "→ Reminders").
- People get avatar circles: initials on a deterministic pastel color hashed from the name.

## 1. Commitments tracker — `Commitments.swift`, `CommitmentsView.swift`

**Model** `Commitment: Identifiable, Codable`: `id`, `text`, `owner` (display name; the user's own = `myName` or "You"), `isMine: Bool`, `dueHint: String?` (free-text like "by Friday"), `dueDate: Date?` (parsed when confident), `sourceTitle` (meeting title), `sourceEntryID: UUID?`, `date`, `done: Bool`, `doneAt: Date?`.

**Store** `CommitmentStore` (`@MainActor ObservableObject`, singleton): `commitments.json` next to history.json, HistoryStore pattern. API: `add`, `toggleDone` (sets/clears `doneAt`), `delete`, `open(for owner:)`, computed `openMine`, `openTheirs`, `openCount`.

**Extraction** `CommitmentExtractor.extract(markdown:participants:myName:sourceTitle:sourceEntryID:)`: called at the end of `runMeetingPipeline` after `HistoryStore.add`. Fast tier, `allowCloudFallback: false`, prompt returns strict JSON array `[{text, owner, mine, due}]` from the finished meeting notes (Action items + transcript). Dedup: skip items whose normalized text already exists open. Failure = silent no-op (never blocks the pipeline). New items appended with animation-ready `@Published`.

**UI** hub tab `.commitments` "✅ Commitments": two sections — **My promises**, **Waiting on others** (grouped with owner name + avatar). Row: checkbox (animated strikethrough → moves to collapsible **Done** section at bottom), text, caption "«Meeting title» · 2 days ago" (click opens transcript file), due chip when known, hover buttons: → Reminders (creates via `RemindersService` with dueDate/дефолт завтра 10:00; flashes ✓), delete. "+ Add" row for manual entries (owner picker: me / roster names). Menu bar: "Commitments" item with open-count badge, opens the tab.

## 2. Person pages — `People.swift` (store + views)

**HistoryEntry change**: optional `participants: [String]?` — set by the meeting pipeline (old JSON decodes unchanged). Meetings for a person = entries whose `participants` contains the name, plus legacy fallback: `.meeting` entries whose text contains the name.

**Model** `Person: Codable`: `id`, `name` (unique, matches roster spelling), `notes: String` (free-form, autosaved debounced 1s), `dossier: String?`, `dossierDate: Date?`. Store `PersonStore` → `people.json`. Pages exist lazily: the People list shows the union of roster names and stored people; opening a page creates the record on first edit.

**UI** hub tab `.people` "📇 People": NavigationSplitView-style two panes. Left: search field + person rows (avatar, name, "Last met 3 days ago" caption), + add. Right detail: header (big avatar, name, last-met), **Notes** editor (placeholder: "Birthday, strengths, 1:1 agreements…"), **Open commitments** (from CommitmentStore, checkable inline), **Meetings** list (title + relative date, click opens transcript), **AI dossier** GroupBox: button "Generate dossier" (smart tier over concatenated meeting texts mentioning the person, ~100k char cap, progress spinner inline) → rendered text + "Updated today" caption; regenerate replaces.

## 3. Meeting prep brief — `MeetingPrep.swift`

**Watcher** `MeetingPrepWatcher` (singleton, started from `bootstrap()`): 60s timer; only active when `prepBriefEnabled` (default **true**) and calendar access granted (never prompts on its own — first prompt happens via {slot} snippet or the manual menu action). Finds the next non-allDay event starting within `prepLeadMinutes` (default 5, Stepper 1–30 in Settings → Meetings) that has ≥1 attendee **or** a video-call URL (zoom/meet/webex/jitsi regex over location+notes+url). Shown event occurrences remembered (`eventIdentifier + occurrenceDate`) so each fires once.

**Brief assembly** — pure local data, zero AI latency:
- Header: event title, "Starts in 4 min" live countdown, time range.
- **Join & Record** button when a video URL exists (opens URL + `startRecording()`); otherwise **Start Recording**; plus "Open in Calendar".
- Attendees matched to roster/People by name token overlap: avatar rows with notes first line + open-commitments count; unmatched attendees show plain.
- **Last meeting with these people**: most recent History `.meeting` sharing ≥1 participant — title, date, its `## Summary` section extracted.
- **You promised them**: open commitments whose owner is me, surfaced when any attendee name appears in commitment text or the source meeting shared participants; plus **They promised you** for attendee-owned ones.

**UI** hub tab `.prep` "📋 Prep" opened with `activate: false` for auto-fires (manual "Prep next meeting" menu item activates normally; looks 12h ahead; shows a friendly "No meetings in the next 12 hours 🎉" state).

## 4. Doc templates — `DocTemplates.swift`

**Model** `DocTemplate: Codable`: `id`, `name`, `emoji`, `skeleton` (markdown with `<!-- guidance -->` comments per section). Store `TemplateStore` → UserDefaults key `docTemplates` (PresetStore pattern) with four defaults: 📘 PRD, 📗 RFC, 📄 One-pager, 🧯 Postmortem — full useful skeletons, editable/deletable/addable in Settings → AI & Actions → "Document templates" (DisclosureGroup editor like snippets).

**Flow** hub tab `.newDocument` "📄 New Document" (menu item "New Document…"): template picker (segmented cards with emoji), brief TextEditor (placeholder: "Describe the idea — or press your dictation key and just talk"), Generate (disabled until brief non-empty; needs `AIFormatter.isConfigured` else inline hint + "Open Settings"). Smart tier, system prompt = fill the skeleton sections from the brief, keep headings, honest "TBD" where the brief is silent, document language follows the brief language. Result replaces the compose UI: editable TextEditor + word count + buttons Copy (✓ flash), Save (→ `HistoryStore.add(kind: .document, title:)` → auto-filed to a project + MD mirror; ✓ flash), New draft (back to compose keeping brief).

**HistoryEntry.Kind**: new case `document` (label "Document", symbol "doc.text").

## Wiring summary

- `HubTab`: + `.commitments`, `.people`, `.prep`, `.newDocument` (requestClose → plain close).
- `HubController.open(_:activate:)` — activate defaults true; false path uses `orderFrontRegardless()` only.
- `AppState.runMeetingPipeline`: pass participants into `HistoryStore.add`, then fire CommitmentExtractor.
- `bootstrap()`: `MeetingPrepWatcher.shared.start()`.
- `MenuView`: new group under presets — Commitments (badge), People, Prep Next Meeting, New Document.
- Settings: Meetings tab + "Meeting prep" section; AI & Actions + "Document templates" section.
- Build order: Commitments → People → Prep → Templates → build/relaunch/docs.
