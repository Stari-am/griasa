# Griasa Projects — design

Date: 2026-07-12. Approved by user ("do").

## Goal

Categorize all Griasa history (dictations, meeting transcripts, capture actions) into
user-defined projects, mirror each project's content as Markdown files on disk, and let
the user ask Claude questions answered with a project's content plus attached source
folders as context.

## Decisions (user-selected)

- **Categorization:** automatic by Claude (Haiku) with manual override; built-in Inbox
  for unclassified entries; one-time "Categorize existing history" pass.
- **Disk layout:** folder per project, one Markdown file per entry with YAML frontmatter.
- **Context use:** a dedicated "Ask Project" action (menu + hotkey ⌃⌥⌘P), not silent
  context injection into existing presets.

## Components

### ProjectStore (Projects.swift)

`Project { id, name, emoji, description, sourceFolders: [String], createdAt }`.
Persisted as JSON at `~/Library/Application Support/Griasa/projects.json`.
Inbox is a virtual project (fixed UUID zero) — always present, not stored, not deletable.
`@MainActor ObservableObject`, `@Published projects`. Rename → `ProjectFiles.renameFolder`;
delete → entries and MD files move to Inbox (content is never destroyed).

### ProjectFiles (ProjectFiles.swift)

Mirrors entries to `~/Documents/Griasa/Projects/<Project name>/`:
`YYYY-MM-dd-HHmm-<kind>-<slug>.md` with frontmatter (date, kind, title, source file path
for meetings) + entry text. Meetings whose transcript already exists on disk get a stub
with a link instead of duplicated content. File name is derived deterministically from
the entry id + date so reassignment can find and move the old file.

### ProjectAI (ProjectAI.swift)

- `classify(text, projects) -> UUID?` — Haiku picks a project by name from the list
  (name + description given); returns nil / Inbox when unsure or on failure. Uses first
  ~1500 chars of the entry. Never blocks or fails the save.
- `buildContext(project) -> String` — project MD entries newest-first, then text-like
  files from `sourceFolders` (.md .txt .swift .ts .js .py .json .yaml .toml .html .css
  and similar; skip files > 256 KB, skip hidden/.git/node_modules), total capped at
  150,000 characters with a truncation note.
- `ask(question, project) -> String?` — claude-opus-4-8 with the built context.

### HistoryStore changes

`HistoryEntry.projectID: UUID?` (old JSON decodes as nil → Inbox). `add()` saves
immediately, then a detached task classifies and re-saves + writes the MD file.
`reassign(entry, to:)` moves the MD file. `categorizeAll()` classifies untagged entries
in sequence (rate-friendly), reporting progress.

### Ask Project window (AskProjectWindow.swift)

Small titled window: project picker, question TextField (⏎ submits), answer area with
Copy / Insert, progress spinner. Opened from the menu or hotkey. Single Q→A (no chat
history) in v1.

### Hotkey + menu + settings

`CaptureAction` gains `.askProject` (⌃⌥⌘P, key `captureAskProjectHotkey`) — reuses the
existing global-hotkey plumbing; `CaptureController.run` routes it to the window.
MenuView shows "🗂 Ask Project…" in the capture section. New **Projects** settings tab:
project list (name, emoji, description, source folders via NSOpenPanel), Ask Project
hotkey field, "Categorize existing history" button.

## Error handling

- No API key → classification silently skipped (Inbox); Ask Project shows the standard
  "set a key" message.
- Classifier returns unknown name → Inbox.
- MD write failures are logged, never fatal; JSON stays the source of truth.
- Deleting a project never deletes files — they move to Inbox's folder.

## Non-goals

No embeddings/RAG, no cloud sync, no multi-turn chat in Ask Project, no automatic
re-classification of already-tagged entries.
