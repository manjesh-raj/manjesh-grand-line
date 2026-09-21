# Notebook

> Feature history. **This file is not imported into an agent session.** Read it
> when you are about to touch this area; the standing rules that apply
> everywhere live in the repository root `AGENTS.md`.
>
> Chronological, in the order entries were written - a later entry can correct
> an earlier one.

## Notebook (F1) - `fm/grandline-feature-f1-notebook`

**F1 of `data/grandline-full-review-3/report.md` §8, and the captain's own
first pick out of that section's twenty-four future-feature recommendations:
"There are some really good features we should start implementing - let's
start with the Notebook (F1)."**

The report's entry, verbatim: *"A Markdown notebook: pages in a tree, a
Monaco-backed editor (Code Preview already vendors it), live preview,
wiki-links `[[page]]`, backlinks, a daily-note button, all in
`GrandLineDocs/notebook/` on the same git sync. Fit: Runbooks/Postmortems are
already Markdown files in that tree - a notebook is the general form of both.
Scope: M (1-2 weeks)."*

Seven files: `NotebookStore.swift` (the model, the git sync, the CRUD),
`NotebookLinks.swift` (the `[[wiki-link]]` scanner, the resolver, the backlink
index), `NotebookMarkdown.swift` (the markdown -> render-model parser),
`NotebookPreviewView.swift` (that model drawn as AppKit views),
`NotebookEditorTheme.swift` (the source pane's palette),
`NotebookController.swift` (the destination) and two suites.

### Built to a mockup the captain had already seen

This is the first feature in this repo built from a **pre-reviewed visual
spec**: the F1 panel of the `grandline-future-features-mockups-artifact` deck,
whose own report records that every colour in it was read out of
`HelmDaylight.swift` rather than chosen. The shipped page is that mockup's
arrangement - page tree left, source and preview as two equal cards, a narrow
right rail carrying Backlinks over a Page inspector - and the two departures
are deliberate and stated in `NotebookController`'s header:

- **A Source / Split / Preview switch the mockup does not show.** The mockup
  draws three columns plus the tree side by side. That is the right default
  and it is what `.split` renders, but gotcha (13)'s own measurement is that
  this window is routinely 1033-1410pt wide, and three columns plus a 208pt
  tree leaves each text column around 300pt - under the measure prose needs.
- **One status line instead of a per-card chip.** The mockup gives the source
  card a "Saved" chip and the preview card a "Live" chip. Both state the same
  fact, so they are one line in the page toolbar reading the same words the
  drill subtitle reads (`syncSummary`, one definition).

### Storage: `DocsRunbookStore`'s shape, a tree instead of a folder

`GrandLineDocs/notebook/`, plain `.md` files, in the **same** local clone of
`manjesh-config` that `ShiftGitSync` already manages. `NotebookGitSync` shares
`ShiftGitSync.shared`'s working tree and serial queue, and owns only a
debounced commit+push scoped to its own subtree - the fifth instance of that
shape (`ShiftGitSync`, `DocsRunbookGitSync`, `CredentialVaultSync`,
`CodePreviewGitSync`, this), and the duplication is the same deliberate call
`CodePreviewStore`'s header makes: the shape is shared, the surface is not.

What is genuinely new here is that it is a **tree**. A page's id is its path
relative to the root without `.md` (`migrations/raas-cutover`), which is what
makes the link graph worth building: an id that changed every time somebody
fixed a typo in a heading would break every `[[link]]` pointing at it.

Three store decisions worth not re-deriving:

- **No index file, no metadata sidecar** - `CodePreviewStore`'s reasoning
  applies word for word, and the cost it names (order is filename order) is
  the *wanted* behaviour for a tree.
- **The walk is bounded** (`maxDepth` 4, `maxPages` 2000) and the overflow is
  *reported* rather than silently dropped, because GL-35 caps and GL-14
  forbids a cap that looks like an empty result.
- **A page id is validated before it reaches the filesystem**
  (`isSafeIdentifier`). This is not a formality: a page id reaches
  `fileURL(for:)` from a `[[wiki-link]]` inside a markdown file, and a
  markdown file is something a `git pull` can deliver from another machine -
  so `[[../../.ssh/authorized_keys]]` is a path this app would otherwise
  resolve and write to. Same posture as GL-08's argv rule: the file the
  captain did not type is the delivery vector.

### The editor is `CodePreviewWebView`, unchanged

No second Monaco integration, no second bundle, no edit to
`native/Vendor/Monaco/` at all. The Code Preview bridge is content-agnostic -
"here is an id, a language and some text" - so a notebook page is a snippet
whose language is `markdown`, and it arrives with the offline CSP, the
`HelmTheme`-derived palette, the three-layer display gating and the
jettisoned-content-process recovery already built.

Two instances of that view coexist safely: each owns its own
`WKUserContentController`, so the handler name they share is registered once
per configuration, and `window.GrandLineCodePreview` is a per-page global.

### Wiki-link highlighting in the *source* pane, and what it cost

The brief asked for `[[wiki-links]]` styled distinctly in **both** edit and
preview modes. The preview is this app's own renderer and was free. The editor
is Monaco, whose language set is fixed at bundle-build time, and rebuilding
that bundle needs node, npm and network access - "the one and only time either
is needed", per `Scripts/build-monaco-web.sh`. So this feature does **not**
add a `notebook-markdown` Monarch language.

What it does instead: Monaco's existing markdown grammar already tokenizes
`[[Target]]`, and `NotebookEditorTheme` re-points the two slots a markdown
document actually uses -

- `string` (the link family) -> the theme's accent, which in every Daylight
  palette *is* `linkBlue`, i.e. literally the colour the mockup draws;
- `keyword` (which is how that grammar tags a `#` heading) -> the page's
  strongest ink, because `CodePreviewTheme` points `keyword` at magenta and a
  magenta `## Pre-flight` in a prose document reads as an error.

**Measured, not assumed.** `NotebookViewSelfTest.checkEditorHighlightsWikiLinks`
reads Monaco's own tokenizer output back through the bridge's `tokensAt` for
the line carrying a `[[wiki-link]]`. The answer on the pinned bundle
(monaco-editor 0.54.0) is `["", "strong.md", "", "string.link.md", ""]` -
Monaco matches theme rules by dotted prefix, so the `string` rule reaches
`string.link.md`. That case is what fails by name if a future bundle bump
moves the grammar under this file's feet.

The honest limit, stated rather than hidden: this is as specific as the
existing grammar allows, so a wiki-link and an ordinary markdown link take the
same colour in the source pane. They do not in the preview.

### The preview is AppKit, and why

The editor beside it is already a web view, so HTML was the obvious cheap
answer. Three measured reasons it was rejected, in order of weight: a second
web content process on one destination doubles the hidden-page floor Code
Preview's gating story exists to keep at zero; `cacheDisplay` does not capture
`WKWebView` content, so the app's own render-probe convention could not see
half of this page; and a themed HTML document has to restate every type ramp
and colour token in CSS and keep them in step by hand.

**`NotebookMarkdown` is a hand-written parser, and both of the obvious
alternatives were tried first.** `SRELeadMarkdown` parses a chat reply - no
headings, no links, no task items, no ordered lists - and widening it would
give the chat view four block cases it must render and never receives.
Foundation's `AttributedString(markdown:)`, which that parser delegates its
block structure to, fails here for two specific reasons: it rewrites
`[[wiki-links]]` (to CommonMark they are a nested link reference) so the one
syntax this feature is built around cannot be recovered afterwards, and
`presentationIntent` carries no GFM task-list state, so `- [x] Freeze deploys`
arrives as a list item whose text begins with "[x] " - exactly the thing the
preview must not show.

Three AppKit lessons from the preview, all measured on a real mounted page:

- **`NSTextView` has no useful intrinsic size**, so a stack view resolves it
  to zero and the pane renders blank. The height is derived from the layout
  manager, and the `ensureLayout(for:)` before `usedRect(for:)` is not
  optional.
- **A hand-built text system must retain its `NSTextStorage`.**
  `addLayoutManager` makes the *storage* retain the manager and the manager's
  back-reference is `unowned(unsafe)`, so a storage that is only a local
  leaves the layout manager pointing at freed memory. This crashed with
  `EXC_BAD_ACCESS` inside `objc_autoreleasePoolPop` on the suite's first
  mounted page.
- **`NSTextView` paints its own styling over every `.link` range**, and its
  default is the system blue plus an underline. That silently overrode the
  per-run colours this view computes: caught in a real off-screen render,
  where a resolved link and an unresolved one came out the *same* blue in both
  registers while the attributed string the view had installed correctly
  carried two different colours. `linkTextAttributes` is handed a dictionary
  with no `.foregroundColor` and no `.underlineStyle`; the suite asserts that
  override directly, because "the attributed string is right" is not the same
  claim as "the text is painted right".

### Resolution and the backlink index

A `[[target]]` is matched most-specific-first: exact id, id
case-insensitively, page title case-insensitively, then a slug match. Ties
break **toward the linking page's own folder** and then by shortest id - two
pages called "Notes" in two folders is a thing a notebook grows, and "the one
next to me" is the only answer that beats a coin flip. Where the tie survives
that, the resolution is still deterministic, because a link that resolved
differently on each render would be worse than one that resolved wrongly but
consistently.

An unresolved link is **not an error** - it is a page that does not exist yet,
which is how notebooks are written. The preview draws it distinctly (the
theme's warn hue, a dotted underline) and clicking it creates the page.

`NotebookBacklinkIndex` is built over the whole corpus, never per page - the
brief calls that out and the reason is not tidiness: a backlink is by
definition information that is *not* on the page you are looking at. One row
per source page rather than per occurrence, self-links excluded, order stable
across rebuilds, and every unresolved target reported rather than dropped.

### Daily notes, and the auto-title

"Today's note" opens `daily/<yyyy-MM-dd>` and creates it only if it does not
exist. ISO in the *filename* because it sorts and because it is the same day
key `ShiftStore`, `LogAnalyzerStore`, `MorningBriefingData` and
`StrawHatEnvelope` already use - a captain grepping the config repo for a date
finds the day's tasks and the day's note with one pattern. The *heading*
inside the file is the localised long form via
`setLocalizedDateFormatFromTemplate`, because that is what a human reads.

"New page" creates `untitled` in the folder you are in and focuses the editor -
no modal. The moment that page has a real `# Heading`, the file is renamed to
its slug and **every link pointing at the old placeholder is retargeted**.
`CodePreviewAutoTitle`'s idea, for the same stated reason: the slug lands in a
filename in a git repo, so "forgot to rename it" is permanent and visible to
everyone who clones. Only a placeholder is eligible; a name the captain chose
is never overwritten.

### Wiring

One `RailDestination` case plus one `register(...)` line, per GL-37 - and the
mechanical edits the compiler finds for you (`slot`, `drillSubtitle`,
`domainHue`, the `DaylightModule` table and `DaylightModuleSelfTest`'s locked
membership literal, `ContextualNewAction`). Stores space, blue hue (§2.2's
"reading material", and what the mockup draws), `isDailyUse == false`, lazily
mounted, its store shared with the canvas card (GL-23). ⌘N on the page makes a
page; ⌘K searches it through `UnifiedSearchNotebookProvider`, which is
`UnifiedSearchDocsProvider` with one store and one destination changed,
short-TTL corpus cache included.

### Verification

- `FM_RUN_NOTEBOOK_TESTS` - pure logic, CI's **blocking** lane: the scanner
  (including that links inside a fence or a code span are quoted text, with
  the fixture's own discriminating power asserted first), the resolver's
  tie-break in both directions, the index, `retarget`, the block and inline
  parsers, tags and task progress, the store's round trip, its refusal of
  nine escaping ids, the `FM_SHIFT_DIR` fallback, the daily-note naming, and
  the editor palette swept across all fourteen themes.
- `FM_RUN_NOTEBOOK_VIEW_TESTS` - window-backed, in `NEEDS_SESSION`: the tree
  and its selection, the preview's painted checkboxes and fonts, the two link
  colours read off the installed attributed string *plus* the
  `linkTextAttributes` override, the backlink panel in three states, the
  daily-note button, the auto-title and its retarget, the three view modes'
  rendered geometry, both theme registers (including the forced appearance -
  the "half-themed" defect that has shipped four times), and Monaco's own
  tokens.

**Three regressions confirmed caught by injection**, per the verification
convention: dropping `NotebookEditorTheme`'s `string` override fails
"a wiki-link must not be painted the same colour as body text" in all
fourteen themes; dropping the `.link` attribute from the preview fails "the
preview must carry both a resolved and an unresolved wiki-link"; and the
rail's collapse constraint was *found* by its own case (a hidden rail resolved
to 154.5pt at priority 499, because the cards inside outrank it - the
collapsed state needs a required `width == 0`, which is a maximum and
therefore can never be a floor on the window).

**Verified by off-screen render probe in both registers** (dusk and daylight,
1100x720), per AGENTS.md's "Verifying native UI bugs without a real
screenshot". The probe was temporary and reverted before commit. Its one
stated blind spot: `cacheDisplay` does not capture `WKWebView` content, so the
source card renders empty in the capture - that the editor is genuinely live
is proven instead by the tokenizer case above, which needs a loaded page and a
real model to answer at all.

### Deliberately not built

- **No `[[page#heading]]` anchors, no `![[transclusion]]`, no aliases file.**
  Each is a real feature in some other notebook app and each needs its own
  resolution rule, rendering and failure mode. The report asked for
  `[[page]]` and backlinks.
- **No tables, setext headings, reference links or raw HTML in the preview.**
  They render as the text they are, which is still readable.
- **No explicit rename or move UI.** `NotebookStore.renamePage` and
  `NotebookLinks.retarget` exist and are exercised by the auto-title path; a
  captain-facing rename is a small, clearly-scoped follow-up.
- **No tag browsing.** Tags are parsed and shown on the page inspector; the
  mockup's sidebar "Tags 9" row would need a tag index and a filter mode, and
  the sidebar this shipped with *is* the page tree the report asked for.
- **`NotebookBacklinkIndex.orphans` is derived and has no surface yet.** It is
  cheap, it is the right place for it, and the sidebar does not show it.
