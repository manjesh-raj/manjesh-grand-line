# Reading list (F4)

The `.readingList` destination, in the Stores space. Built by
`fm/grandline-feature-f4-reading-list`, the third of full review #3 §8's
twenty-four recommendations the captain picked to build, after F1 (Notebook,
PR #426) and F2+F3 (universal capture and clipboard history, PR #427).

The report's own entry:

> **F4 - Reading list / link inbox.** Paste a URL anywhere → a card with
> title/favicon/summary (local `LinkPresentation`), tags, "read", optional AI
> one-paragraph summary via `ClaudeOneShot`. Fit: Docs' `WKWebView` reader is
> there; adds a Stores card. Scope: M.

The captain reviewed a mockup of the page before it existed, in the published
"Grand Line Futures" artifact (F4's section, green hue). The shipped page is
that mockup's arrangement, with the departures stated below.

---

## What shipped

A new destination, lazily mounted through `DestinationRegistry` like every
other Stores page, with:

- **A sidebar** (`HelmPageSidebar`, `.panel` surface, `.badge` counts): an
  Inbox section (Everything / Unread / Read / Added today) over a Tags section
  with one row and one identity dot per tag, counts on every row.
- **A segmented strip** over the grid - All / Unread / Summarised - plus the
  mockup's own hint line, "Drop a URL anywhere in the window to add it."
- **A responsive card grid** (`HelmResponsiveGrid`, `equalHeights: true`), one
  `ReadingListCardView` per saved link.
- **A dashed drop-zone card** under the grid: "⌘V here, or drop a link from any
  browser."
- **A reader**: the saved page in a `WKWebView` inside a card, with
  back/reload/open-externally and a close that returns to the grid.

### The card, and the mockup's own judgment call

The mockup's closing note is the design: *"optional is shown as state, not as a
setting: one card carries a summary, one carries a Summarise button, one was
read and never needed either. That is the whole feature in one row."*
`ReadingListCardView.render` is that sentence - it branches on
`ReadingLink.summaryKind` and on `isRead`, and draws exactly those three
shapes. A summarised card also gains a 4pt accent rule along its top edge, so
the state is readable from across the grid rather than only on inspection.

The monogram tile is the mockup's too: a rounded square with the host's first
letter, coloured by `ReadingListHostHue` - a stable FNV-1a over the host, never
`String.hashValue`, which Swift seeds per process and would repaint the grid on
every launch. A real favicon replaces the letter when `LinkPresentation`
returned one.

### Where the data lives

`GrandLineDocs/reading-list/links.yaml`, one batched file, inside the same
local clone of `manjesh-config` `ShiftGitSync` already manages -
`ReadingListGitSync` mirrors `StickyBoardGitSync` exactly, sharing that class's
`workingTree` and serial `sharedQueue` so no two stores race on
`.git/index.lock`. Favicons are **not** in the YAML: they are one PNG per
**host** under `reading-list/icons/`, so twenty saved kubernetes.io articles
cost one small file rather than twenty base64 blobs in a file whose diffs
someone has to read.

`FM_READING_LIST_DIR` is the narrow override; `FM_SHIFT_DIR` is honoured as a
second fallback, for the reason `StickyBoardStore.init` spells out - every
existing self-test harness already sets it, so this store stays off the
captain's real clone with no per-harness edit. `main.swift`'s `#if FM_SELFTESTS`
block sets both.

---

## What was reused rather than rebuilt

This was the firstmate spec's explicit instruction, and all five held:

| Reused | Instead of |
|---|---|
| `LinkPresentation` (`LPMetadataProvider`), locally | any metadata service |
| `ClaudeOneShot` (GL-26) through `ReadingListAI` | a second `claude -p` runner |
| Docs' `WKWebView`-in-a-card shape and delegate | a second web-view integration |
| `StickyBoardStore`'s storage shape and git sync | a new persistence model |
| `CaptureRouter`'s ⌥Space panel | a second capture surface |
| `HelmPageSidebar` / `HelmResponsiveGrid` / `HelmCard.applyCardSurface` / `HelmSegmentedTabs` / `HelmPageToolbar` / `HelmEmptyState` / `HelmChipInput` / `HelmButton` | a per-page reimplementation of each |

### "Paste a URL anywhere", made literally true

Before F4 the ⌥Space panel's Return was hard-coded to `.task`, so a pasted URL
became a task *titled with a URL* - which is exactly the thing this feature
exists to stop being the only option. Three changes, all small:

- `CaptureDestination.link` is **appended** (⌘6). Appended rather than
  inserted, because `chordDigit` is derived from the case order and inserting
  would silently renumber four chords the captain already knows.
- `CaptureRouter.defaultDestination(for:)` returns `.link` when the capture is
  *nothing but* a URL, and `.task` otherwise. The panel re-evaluates it on
  every keystroke and moves the visibly-default tile, so the captain can see
  where Return will file before pressing it. Prose that merely *contains* a
  link still defaults to `.task`.
- The crew classifier's prompt gained a sixth bullet and its count went from
  "five" to "six", or the crew could never pick the new destination.

Plus a drop target on the destination's whole root view (`public.url` and a
plain string, which is what a browser puts on the dragging pasteboard for a
dragged tab - never `.fileURL`, which is what every other drop zone in this app
accepts), a ⌘V button in the page toolbar and the drill header, a `New Link`
File-menu verb through `ContextualNewAction`, and a ⌘K provider.

### Why the AI summary is opt-in per card

The report says "optional"; the spec asked for the reasoning to be stated. It
is a button on the card, one turn per press, result stored so it is never
fetched twice - because a paste is not a request (⌥Space and a drop are one
gesture each), because dropping a window's worth of tabs would fire twenty
unbounded turns (GL-35), and because summarised/not-summarised is only a useful
axis - it is one of the three tabs - if it records a decision rather than how
long a queue was.

The model is given the title, the host and the page's own description, and
never the body: `LinkPresentation` returns metadata, and nothing in this app
fetches a page's prose. The prompt says so explicitly ("You have not read the
page... do not invent"), which is load-bearing rather than polite.

---

## GL-14, three times

The rule this feature touches most.

1. **Metadata state is three-valued and stored.** `.pending` / `.resolved` /
   `.failed(String)`. A link with no fetched title shows its *path* and says
   "Reading the page's title and summary…"; one whose fetch failed shows the
   path and the failure with a retry; only a resolved one shows a title. A
   stale title recorded by an earlier build is not shown while the state says
   pending - asserted directly, because that is the shape the bug would take.
2. **Three empty states, not one.** Nothing saved, nothing matching this
   filter, and a file that could not be read are three different situations.
3. **The drill subtitle and the canvas card** distinguish "not loaded yet" from
   "nothing saved", and neither renders as `0 saved`.

GL-01 is the other invariant this store leans on, in both halves: an
unparseable `links.yaml` is backed up once and then never written until a
successful reload clears the flag, and a *record* this build cannot decode is
carried through verbatim (the full-app audit's finding 4.2) so an older build's
write cannot destroy a newer build's link.

---

## Departures from the reviewed mockup

Both are GL-14 again, and both are stated in `ReadingListCardView`'s header.

1. **No "6 min read".** Nothing in this feature knows how long an article is.
   That slot carries the date instead - "saved 18 Sep", "read 14 Sep" - which
   the mockup's other two cards already showed in their body copy.
2. **No "highlighted 3 passages".** Highlights are not in F4's scope and the
   reader stores none, so the card does not claim any.

One addition the mockup does not draw: a **read** card shows no "No summary
yet." line and no Summarise button. Caught in the render probe below - on a
card that has been dealt with, that line reads as an outstanding job which is
not outstanding.

---

## Verification

Two suites, split by AGENTS.md's own classification rule.

- **`FM_RUN_READING_LIST_TESTS`** (pure logic, CI's **blocking** lane): URL
  detection and normalisation, tag folding and counting, the filter and
  ordering rules, the three-valued state, the AI prompt and reply parse, the
  store's disk round trip, its GL-01 refusal, its forward-compatible decode,
  its `FM_SHIFT_DIR` honouring, the icon cache's path-escape refusal, the
  capture router's new default, and the destination's wiring into all five
  tables.
- **`FM_RUN_READING_LIST_VIEW_TESTS`** (window-backed, `NEEDS_SESSION`): the
  real controller in a real `NSWindow` - the mockup's three card states, the
  three metadata states, the read toggle, the sidebar tracking the store, the
  tabs driving the grid, the empty states, the drop target's real accept/refuse
  decision, the reader, contrast in three themes, one painted pixel read back
  out of a render, and a window resize proving gotcha (13) does not bite.

**Confirmed to catch real regressions, not merely to pass.** Six injections,
each made by copying the file aside and editing it, never `git stash`:

| Injection | Failed by name |
|---|---|
| drop the tracking-parameter strip in `normalise` | 5 cases, including "the same article from two campaigns must be one card" |
| show a title whatever the metadata state says | "a title is only shown while the state says it was fetched" |
| let a read card offer Summarise again | "the read card carries neither, which is the mockup's third state" (+1) |
| paint the summary well magenta | *nothing* - the render check compares paint against the **resolved** colour, so it proves the pixel matches the decision, not that the decision is right. That is what the contrast assertions are for, and it is why both exist |
| `summaryWell.alphaValue = 0` (right decision, no pixel) | "the summary well's painted pixel is 0.1497 away from the colour `applyTheme` resolved for it" |
| paint the well's kicker in the raw hue | "the summary well's kicker measures 3.85:1 / 2.79:1 against the well's own fill" |

**Render-probed in both registers.** A temporary `FM_RUN_READING_LIST_PROBE`
suite rendered the mounted page at 1400x860 into the session scratchpad under
Dusk and Daylight and the PNGs were read back - the app's own substitute for a
screenshot, per AGENTS.md's "Verifying native UI bugs" convention, since this
agent's shell has neither Screen Recording nor Accessibility permission. The
probe saved and restored `fm.themeID`, and was **reverted before the commit**.
It is what found the "No summary yet." nit above. Two traps of
`bitmapImageRepForCachingDisplay` are respected in the permanent suite: the rep
is measured in **pixels** (scaled by `rep.pixelsWide / bounds.width`), and the
expected colour is converted into **`rep.colorSpace`** rather than the sample
into sRGB.

**Not verified:** the live `LPMetadataProvider` path against a real site, and
the live `claude -p` summary. Both are behind seams the suites drive with
canned answers, deliberately - a suite that fetched a real page would be
asserting the weather. The network halves are the captain's own check.
