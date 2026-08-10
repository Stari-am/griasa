# Launch-readiness features — design

Date: 2026-07-18. Status: approved (brainstorm in chat — pre-sale must-haves).

## Goal

Close the gaps that make a paid launch risky: no update channel, no
permission onboarding, no support/feedback path, and nothing that shows the
user the value they got (the number that justifies the price). Scope is the
agreed must-have list; Sparkle proper is deferred (below).

## Components

### 1. Support links (`Support.swift`)

One place for outbound identity, all `TODO`-marked until publication:

- `SupportLinks.donateURL` — Ko-fi/GitHub Sponsors page (placeholder now).
- `SupportLinks.supportEmail` — feedback mailto target.
- `SupportLinks.updateRepo` — GitHub `owner/name` for release checks;
  empty string = update checking disabled (pre-publication state).
- `SupportLinks.sendFeedback()` — opens a mail draft with app version +
  macOS version pre-filled in the body (mailto can't attach files; version
  info in the body is the 90% win).
- `AppInfo.version` — reads `CFBundleShortVersionString`.

Donate/feedback buttons appear in the menu-bar panel footer (icon buttons,
with `MenuBarPanel.dismiss()` first, per convention) and in Settings →
System → Support.

### 2. Time-saved usage stats (`UsageStats.swift`)

`@MainActor ObservableObject` singleton; `@Published` counters persisted in
UserDefaults (`statsWordsDictated`, `statsDictationCount`). `@AppStorage`
doesn't publish from an ObservableObject, so plain `@Published` + explicit
UserDefaults writes.

- `recordDictation(text)` called from `AppState.endDictation` after the
  polished transcript is produced (counts whitespace-separated words).
- Time saved = words × (1/40 − 1/150) minutes — 40 wpm typing vs 150 wpm
  speaking, the standard dictation-market claim.
- `summary` line ("12,340 words dictated · ~4 h 5 min saved vs typing")
  shown as a caption in the menu panel and in Settings.

Meetings are not counted — the counter is about typing replaced, not audio
processed.

### 3. Onboarding welcome tab (`OnboardingView.swift`)

New `HubTab.welcome` (per the hub rule — no new windows). Opens
automatically once on first launch (`welcomeShown` UserDefaults flag) and on
demand from Settings → System → "Open Welcome Guide".

Content: quick-start ("hold Right ⌥ and speak"), then a live permission
checklist (microphone, screen recording, accessibility) — each row shows
granted/missing status refreshed every second, a "Open Settings…" button
deep-linking to the exact System Settings privacy pane
(`x-apple.systempreferences:com.apple.preference.security?Privacy_…`), and a
one-line note on what still works if declined (house convention). Footer:
"Done" closes the tab.

### 4. Update checker (`UpdateChecker.swift`)

Lightweight GitHub Releases check — not Sparkle:

- `GET api.github.com/repos/{updateRepo}/releases/latest`, compare
  `tag_name` (leading `v` stripped) against `AppInfo.version` with numeric
  string comparison.
- Auto-check at launch, at most once per 24 h (`lastUpdateCheck`).
- Newer version → NSAlert: Download (opens release page) / Later / Skip This
  Version (`skippedUpdateVersion`, respected only for auto-checks).
- Manual "Check for Updates…" button in Settings → System; user-initiated
  checks also report "up to date" and errors.
- Entirely inert while `updateRepo` is empty; Settings shows a caption
  explaining that instead of the button.

**Why not Sparkle now:** Sparkle needs an embedded framework (SwiftPM is
broken here — manual framework vendoring into build.sh), EdDSA appcast
signing, and a hosted appcast URL. None of that exists before the GitHub
repo + Developer ID signing. The GitHub check delivers the user-visible 90%
(you're told about updates, one click to the download) and Sparkle can
replace it in the Developer ID release.

## Out of scope (deferred)

Sparkle auto-install updates, launch-at-login toggle, text snippets,
transcript export formats — post-launch or separate specs.
