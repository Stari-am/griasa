# Project one-pager for GitHub Pages — design

**Date:** 2026-08-10
**Status:** approved

## Purpose

A single page that presents Griasa as evidence of engineering capability, not as a
product for sale. Two audiences read it: someone judging what the app does, and
someone judging who built it. The page has to serve both without blending them
into one paragraph of adjectives.

It is explicitly **not** a sales page. No price, no buy button, no competitor
comparison table. The existing sales page keeps that job at a separate URL.

## Decisions taken

| Question | Decision | Why |
|---|---|---|
| Relationship to the existing sales page | Both published: one-pager at `/`, sales page at `/buy/` | User's choice. Keeps PR and sales separate without discarding work already done. |
| Language | English | The README, the specs and the sales page are already English; the intended audience is international. One coherent shopfront. |
| Pages source | `main` branch, `/docs` folder | GitHub Pages serves only from the repository root or `/docs`. Root would make every source file a served URL. |
| Screenshots | None | The project has no real screenshots, and mocking them up would undercut a page whose whole argument is credibility. |

**Known trade-off, accepted:** publishing from `/docs` makes
`docs/superpowers/specs/*.md` reachable as URLs. Those files are already public in
the repository, so nothing is disclosed that was not already; they simply become
servable as text. The alternative — a `gh-pages` branch holding only the site —
was rejected because it permanently adds a copy-to-another-branch step to every
edit of the page.

## Structure

Three parts, in this order, on one vertical scroll.

### 1. What it does together

The argument is not the list; it is that dictation, meetings, commitments,
snippets and screen capture share one history and one project model. Each entry
is one line, no marketing adjectives.

### 2. What standard AI apps do not do

Five items, each stated as an explicit contrast rather than a feature name:

- Live typing **into any app** while you speak — not into the app's own text box
- `;ai … ;;` mid-sentence, in someone else's window
- Snippets that expand to **real** free calendar slots and **real** open commitments
- Promises extracted from a recorded meeting, with due dates, split into mine and theirs
- Your own AI, including a subscription you already pay for via the `claude` or
  `codex` CLI — no second subscription, no API key

### 3. Why this is harder than it looks

The section that carries the portfolio weight. Five concrete cases, each in the
shape *naive approach → what actually happens → what it took*:

1. **Live typing that never deletes what is already there.** A recogniser revises
   its hypothesis; a naive implementation retypes the line and eats the user's
   text. Fix: LocalAgreement-2 — commit only what two successive hypotheses agree
   on, append-only, and stall rather than fabricate.
2. **Ordering.** Dispatching each partial in its own `Task { @MainActor }` has no
   FIFO guarantee. Two transposed partials and the app's model of the text field
   describes a fiction, so every later edit is computed against it.
3. **Accessibility APIs lie.** Slack declares `AXSelectedText` settable and
   silently does nothing; Telegram declares it read-only and reports emoji as
   U+FFFC. Measured across three apps, which is why synthetic keystrokes are the
   primary path and AX the optimisation.
4. **Local speech models loop.** One spoken sentence came back seven times. Fix:
   an entropy threshold, a context cap, and a collapser that distinguishes human
   emphasis ("no no no") from a decoder loop.
5. **Notarisation is not a signature.** An unsigned disk image notarises fine,
   accepts a stapled ticket fine, and is then rejected by Gatekeeper — after both
   trips to Apple are already spent.

### Local operation — one line, in passing

Speech recognition runs on the Mac; only the optional text-cleanup step can reach
a model, and only if enabled. Deliberately understated: the user asked for this
mentioned in passing, not as the headline.

## Implementation

- `docs/index.html` — the one-pager. Single file, no dependencies.
- `docs/buy/index.html` — the existing `site/index.html`, moved. Its in-page
  anchors (`#buy`, `#opensource`) survive the move unchanged.
- Inline CSS, no external fonts or scripts (a page about not sending your data
  anywhere should not phone a CDN).
- Light and dark via `prefers-color-scheme`; readable on a phone; wide content
  scrolls inside its own container rather than the body.
- GitHub Pages enabled on `main` / `/docs` via the API.

## Out of scope

Price, buy buttons, comparison tables, screenshots, analytics, newsletter
capture, custom domain.

## Verification

- Page fetched over HTTPS from the published URL returns 200 and contains the
  three section headings.
- `/buy/` returns 200 and still renders the sales page.
- No external network requests in the served HTML (grep for `http` in `src`/`href`
  attributes pointing off-origin).
- Rendered at 375 px width without horizontal body scroll.

## Note on the moved sales page

Its dead placeholder links are wired up as part of this change: the Ko-fi page,
the GitHub repository, a `mailto:` for support, and a link back to the one-pager.
The Ko-fi buy button points at `ko-fi.com/griasa` until a shop item exists —
swapping that single `href` for the product URL is the whole remaining step.

The page also carries a commented-out `<img src="hero.png">`. It is inert: no
broken image renders, because the tag is inside an HTML comment. It stays
commented out until a real screenshot exists, on the same reasoning as the
one-pager — an invented screenshot would undercut the credibility both pages
depend on.
