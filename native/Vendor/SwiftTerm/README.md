# Vendored SwiftTerm (patched)

This is a vendored, patched copy of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
`Sources/SwiftTerm`, pinned to upstream commit `dd2fb8ac5b861e7bf617c872895e338f38165648`
(tag `1.15.0`). It replaces the plain SPM remote dependency that `native/Package.swift`
used to declare.

## Why vendored instead of a remote SPM dependency

SGR-2 (dim/faint) terminal text was nearly invisible in light Helm themes: light gray
on near-white. The root cause is `NSColor.dimmedColor(towards:)` in
`Sources/SwiftTerm/Mac/MacExtensions.swift` (and the iOS twin in
`Sources/SwiftTerm/iOS/iOSExtensions.swift`), which blends the foreground 50% toward
the background in flat sRGB regardless of which side is dark. That fixed 50% blend
lands on a good contrast ratio when the background is dark (blending a light ink
toward near-black still leaves it far from the background) but collapses to well
under 2:1 when the background is light (blending a dark ink toward near-white pulls
it most of the way to invisible).

There is no public hook to override this: `dimmedColor`, `getAttributes`,
`buildAttributedString`, and `mapColor` are all `internal` methods inside
`extension TerminalView` (not `open`, not part of the module's public API), and
`TerminalView.draw(_:)` itself is `public` but not `open`, so it can't be overridden
from a subclass in another module either. Fixing this required patching the function
itself, so the dependency is vendored here rather than fetched from GitHub - this
keeps the patch entirely inside this repo (reviewable in a normal diff, no external
fork to maintain) instead of depending on a personal SwiftTerm fork.

## The patch

`dimmedColor(towards:)` (both the AppKit and UIKit variants) now targets a fixed
WCAG contrast ratio (4.5:1, matching this project's own `verify-contrast.mjs` bar)
against the background, found by bisecting the blend fraction along the straight
sRGB line from the foreground to the background, capped at the original 50% so dim
text never becomes *less* dimmed than before. On dark backgrounds the cap wins (the
old 50% blend already clears 4.5:1 by a wide margin, so behavior is unchanged). On
light backgrounds the bisection finds a smaller blend fraction that stays legible
instead of collapsing toward the background. See the doc comment on
`dimmedColor(towards:)` for the exact algorithm.

## Second patch: truecolor de-emphasised text (cockpit-native-fixes5)

The `dimmedColor` patch above only fires for the SGR-2 "faint" attribute. Some tools
render de-emphasised text a different way entirely: a literal 24-bit truecolor
foreground (`ESC[38;2;r;g;bm`) chosen with no idea what background it will ever
render against. Verified live against this exact codebase's own firstmate session
(`tmux capture-pane -e` on a running `claude` pane): Claude Code renders its own
de-emphasised status lines ("Searched for N files...", token/cost footers) as
`ESC[38;2;153;153;153m`, not SGR-2 dim. That gray measures ~6.7:1 against a
near-black dark-theme background (legible, the look the source app intended) but
only ~2.55:1 against a light theme's near-white background - `getAttributes`'s
`flags.contains(.dim)` branch never sees it, so the first patch has no effect on it.

`getAttributes` in `Apple/AppleTerminalView.swift` now also checks whether the raw
foreground (`attribute.fg`) is a `.trueColor` case; if so it calls
`NSColor.legibleColor(against:)` / `UIColor.legibleColor(against:)` (new methods,
`Mac/MacExtensions.swift` / `iOS/iOSExtensions.swift`), which remap the color only if
it doesn't already meet the background contrast floor. This intentionally applies to
*every* truecolor foreground, not just gray/muted-looking ones - there is no reliable
way to distinguish "this is ghost/status text" from "this is a genuine but
unfortunately-low-contrast color choice" from RGB bytes alone, and the remap is
self-gating (a no-op whenever contrast is already sufficient) and hue-preserving
(blends toward black or white, whichever the color is already closer to, so a
saturated color darkens/lightens rather than desaturating to gray). See
`Dimming.contrastFixBlendFraction`'s doc comment for the full algorithm, including
why the blend direction can't simply be inferred from which side of the background
the foreground currently sits on.

## Third patch: wrap redraw boundary (`fm/grandline-terminal-wrap-duplicate-char`)

A captain-reported bug: when a long line soft-wraps to a second visual row in a
Console tab, the wrapped continuation row can start with a stray extra character -
observed as a duplicate of the original line's own leading (colored) character, e.g.
a `git diff`-style `+` marker reappearing at the start of the wrapped row. Confirmed
by the reporting task to be width-dependent (present only when a wrap actually
occurs) and not specific to one Console tab (Shell and the Herdr mirror tab, which
share this same vendored `TerminalView`, both showed it).

**What this task's own investigation found, and what it didn't.** An extensive
battery of tests against `Terminal`/`Buffer` (live wrap during print, wrap that
triggers a `scroll()`, `reflowNarrower` at many widths and through repeated
narrower/wider round-trips, byte-by-byte feeding to rule out PTY chunking, and an
exact reconstruction of the reported line/column width) never produced a duplicated
character in the underlying buffer content - `getCharacter()` on every affected cell
was correct in every case tried. A real `TerminalView` instance's `buildAttributedString`
output and an actual rendered `CGImage` bitmap (via `cacheDisplay(in:to:)`) were also
checked and were clean. This rules out the `Buffer`/`Terminal` wrap and reflow logic
itself (`insertAsciiRun`, `insertCharacter`, `reflowNarrower`) as the source of
*content*-level duplication, and rules out a one-shot forced-fresh-redraw of the
final state as a way to see the bug.

**What `cacheDisplay(in:to:)` structurally cannot reveal** is a class of bug where the
underlying buffer content and a *fresh* full render are both correct, but a live
*incremental* (dirty-rect-only) redraw leaves stale pixels from a previous frame
sitting at a row's edge, because `cacheDisplay` always forces a full draw of the
requested rect - it never exercises AppKit's own "only redraw what was invalidated"
path where a staleness bug like this would actually live. Reading
`TerminalView.updateDisplay`'s invalidation-rect computation with that in mind found a
real, concrete asymmetry: when a redraw's dirty row range doesn't reach the last
visible row, the code already extends the invalidated rect down by one extra cell
("so the sub-cell remainder just below the band's bottom row - descenders / tall
unicode - is cleared too", per that code's own existing comment) - but there was no
symmetric extension *upward* for a range that doesn't start at the first visible row.
A wrap's continuation row is exactly this shape: freshly written into (via `_y += 1`
or a `scroll()`-supplied row), non-zero `rowStart` relative to the viewport, redrawn
without necessarily also touching the row above it. Without the upward extension, any
leftover pixels from whatever that row's `BufferLine` slot in the circular buffer
last displayed - plausible in a `git diff`-heavy session with many similarly-colored
`+` lines reusing scrollback slots as they scroll past - are never included in the
invalidated-and-cleared area when a later partial redraw only covers that one row.

The fix (`Apple/AppleTerminalView.swift`) extracts the whole invalidation-rect
computation out of `updateDisplay` into a pure, testable
`TerminalView.invalidationRegion(rowStart:rowEnd:terminalRows:frameWidth:frameHeight:cellHeight:)`,
and adds the missing symmetric case: when `rowStart > 0`, the region is extended
upward by one more cell, mirroring the existing downward extension exactly. The two
pre-existing behaviors (extend down when `rowEnd` isn't the last row; extend fully to
`y = 0` when it is) are unchanged - covered by
`native/Sources/GrandLine/TerminalWrapRedrawSelfTest.swift`
(`FM_RUN_TERMINAL_WRAP_REDRAW_TESTS=1`), which also covers the new upward extension
and the exact mid-screen wrap shape (`rowStart`/`rowEnd` both strictly interior) from
the captain's report.

**Be honest about what is and isn't proven here.** The self-test proves the geometry
fix is genuinely symmetric and doesn't regress the two behaviors that already existed.
It does not - and structurally cannot, being a pure function with no view/CGContext -
prove that this was *the* mechanism behind the captain's screenshot, since confirming
that would need a real on-screen window driving genuine incremental AppKit redraws
across multiple frames (this sandbox has no way to grant Screen Recording/Accessibility
permission, and `cacheDisplay` bypasses incremental drawing entirely - see this
project's own `AGENTS.md` "Verifying native UI bugs without a real screenshot"
convention for the general constraint). If the captain can still reproduce the
duplicated character after this fix ships, the next step should be a live, on-device
repro with real window resizes and real captured frames, not another headless attempt.

## Fourth patch: display gating (`displaySuspended` / `displayIntervalNanos`)

`Mac/MacTerminalView.swift` declares two new public properties on
`TerminalView` and `Apple/AppleTerminalView.swift`'s `queuePendingDisplay()`
honours them. Nothing else changed.

**Why it has to be a patch.** A terminal attached to a busy live session (this
app's Herdr tab attaches firstmate's own session, which prints almost
continuously) parses every byte on the main thread and repaints at 60 Hz for as
long as the app is open. Measured on the captain's real instance: **~6-16% CPU
and 2.9% GPU sustained while the app was merely backgrounded**, top CPU
consumer machine-wide, and a 5-second `sample` put nearly all of the main
thread's busy time in `CA::Transaction commit -> NSViewBackingLayer display ->
TerminalView.draw(_:)`. That is not a SwiftTerm bug - it repaints when its
buffer changes, which is correct - but there is no way to say "stop painting
for now" from outside the module: `updateDisplay`, `queuePendingDisplay` and
`draw(_:)` are none of them `open`, and `TerminalView` cannot be subclassed
into that behaviour.

**What the patch does.** `queuePendingDisplay()` gains one early return
(`displaySuspended` -> remember the wanted pass in `suspendedDisplayPending`
and schedule nothing) and reads its throttle delay from
`displayIntervalNanos` instead of a hardcoded `fps60`. Clearing
`displaySuspended` flushes the deferred pass. The iOS path keeps the literal
60 Hz value verbatim (`#if os(macOS)`), so only the platform this app ships on
is affected.

**What it deliberately does not touch: the terminal model.** Every byte still
reaches the buffer through the ordinary feed path, so scrollback stays exact
and a resumed view is correct immediately - it never needs a reconnect or a
redraw request from the child. Only the *scheduling of painting* moves.

The policy (when to suspend, when to throttle) lives entirely in the app, on
`CockpitTerminalView.refreshDisplayGating()` - see its own doc comment. If
SwiftTerm is ever re-synced from upstream, re-applying this patch is two
hunks: the property block after `pendingDisplay` in `MacTerminalView.swift`,
and the early return plus `fpsDelay` source in `queuePendingDisplay()`.

## Fifth patch: a pinned minimum column count (`fm/grandline-k8s-ui-revamp`)

**Files:** `Mac/MacTerminalView.swift` and `iOS/iOSTerminalView.swift` (the new
stored `minimumColumns` property plus `applyMinimumColumnsIfNeeded()`), and
`Apple/AppleTerminalView.swift` (two `max(minimumColumns, …)` clamps, in
`processSizeChange` and `resetFont`).

**The bug this fixes is in the app, not in SwiftTerm.** The `.kubernetes`
destination drives a dedicated "feed" terminal tab, injects a read-only
`kubectl` command into it, and parses the rows that come back
(`KubeResources.swift`). `Terminal.getBufferAsData()` emits **one newline per
buffer row** and ignores `BufferLine.isWrapped`, so a logical line the
emulator hard-wrapped arrives at the parser as two independent lines. A real
`kubectl get pods -o wide` line with a ~50-character deployment pod name and a
full EKS node name measures roughly 190-210 columns, comfortably wider than a
window-sized terminal - so the continuation was read as its own table row.
That produced genuinely corrupt data (a row whose `NAME` was `5`, and a fake
row reading `NODE` / `NOMINATED NODE` / `READINESS GATES` - the wrapped tail of
kubectl's own header). The fix has to eliminate the wrap, not detect it after
the fact.

**Why a patch was needed at all.** `AppleTerminalView.resize(cols:rows:)` is
already public, but it does not stick: `processSizeChange` re-derives
`terminal.cols` from the view's own pixel width on *every* `setFrameSize`, and
`MacTerminalView.setFrameSize` calls it unconditionally - so a programmatic
resize is undone by the next layout pass. There is no override point from
outside the module (`processSizeChange` is internal, and `TerminalView` offers
no size-policy hook), which is the same "no seam upstream" situation that
justified patches 1-4.

**Shape of the patch.** `minimumColumns` is a **floor**, defaulting to `0`. A
view that never sets it computes exactly the stock column count, so every
ordinary tab in this app is byte-for-byte unaffected. A view that does set it
renders more columns than its frame can show and simply clips on the right;
that is deliberate and is only ever opted into by the Kubernetes feed tab,
whose whole purpose is to be machine-read (see
`CockpitTerminalView.applyMachineReadableGeometry`). The floor is applied in
both places that derive a column count - the size-change path and the
font-change path - because a font change would otherwise silently undo it.

**Re-applying it after a SwiftTerm upgrade:** re-add the stored property to
both `TerminalView` classes and re-wrap the two `Int(... / cellDimension.width)`
column computations in `max(minimumColumns, …)`. `KubeBridgeSelfTest`'s
`parse_wideLineWrapsAndCorruptsAtANarrowTerminal` /
`parse_wideLineSurvivesAtTheFeedTabColumnFloor` pair proves the width matters;
`KubernetesDestinationSelfTest.test_feedTabIsWidenedForMachineReadableOutput`
proves the feed tab actually asks for it.

## Sixth patch: an unused `withUnsafeBytes` result (`fm/grandline-swiftterm-unsafebytes-warning-fix`)

**File:** `Apple/Metal/MetalTerminalRenderer.swift`, at both of its vertex-buffer
upload sites - `BufferPool.makeBuffer<T>(_:)` and the renderer's own
`makeStaticBuffer<T>(_:)`. Two lines changed, both of the same shape.

**What it fixes.** Building this app printed two warnings from the vendored
tree, which is the only reason the captain saw them at all:

```
MetalTerminalRenderer.swift:1744:22: warning: result of call to 'withUnsafeBytes' is unused [#no-usage]
MetalTerminalRenderer.swift:1950:18: warning: result of call to 'withUnsafeBytes' is unused [#no-usage]
```

Both sites read `vertices.withUnsafeBytes { raw in memcpy(...) }`. `memcpy`
returns its destination pointer, so a single-expression closure around it infers
that pointer as its own result type, and `withUnsafeBytes` dutifully hands the
value back. Nobody wants it, and the compiler says so. The fix is one `_ = ` per
site, plus a comment saying why.

**Why there is no upstream seam - and this one is genuinely simpler than
patches 1-5.** There is no missing `public`/`open` hook here and no behaviour to
override. This is a **diagnostics** gap in third-party source: nothing outside a
file can silence a warning emitted inside it, so the only place the fix can live
is the file. It is not a fix this app needs upstream to adopt in order to work -
it needs it only to keep its own build output clean (GL-07's standing bar: the
build fails on any warning in this app's own sources, and vendored noise is what
trains everyone to stop reading the rest).

**What it deliberately does not touch.** The `memcpy` itself, its arguments, the
buffer lifetime and the pointer's scope are all unchanged. `_ = ` discards a
value that was already being discarded; the generated code is the same.

**Re-applying it after a SwiftTerm upgrade:** prefix every
`vertices.withUnsafeBytes` call in `Apple/Metal/MetalTerminalRenderer.swift` with
`_ = `. `VendoredPatchesSelfTest` asserts *both* sites, by count rather than by
presence - a re-apply that fixes one and misses the other is exactly the failure
a `contains` check would wave through.

## Seventh patch: a per-row render cache for the CoreText path (`fm/grand-line-review-perf-pf1-pf16`)

**Files:** `Apple/AppleTerminalView.swift` (the cache types, `preparedLineRender`,
`invalidateLineRenderCache`, `pruneLineRenderCache`, the two `draw(_:)` call
sites and two one-line invalidations), and `Mac/MacTerminalView.swift` /
`iOS/iOSTerminalView.swift` (the stored `lineRenderCache` /
`lineRenderStyleEpoch` plus the two hit/miss counters).

**What it fixes.** PF1 of the 2026-09-25 full-application review, measured live
on the captain's running instance: a single Console tab cost roughly a tenth of
a CPU core continuously **while the app was backgrounded**. Two 5-second
`sample` runs put 232-256 of 4000 main-thread samples in `TerminalView.draw` ->
`buildAttributedString` / `getAttributes`.

Patch 4's display gating was already working - the tab was repainting at 2 fps
rather than 60 - so this is not a frame-rate problem. It is the cost of a frame.
`draw(_:)` called `buildAttributedString` for every visible row on every frame,
then built a `CTLine` and a run array for every segment of every row, and threw
all of it away at the end of the frame. On BigSur and later AppKit hands the
view a full-view dirty rect even when one line changed (the code's own comment
above `isBigSur` says so), so a TUI that updates one status line repaints its
whole screen from scratch, twice a second, forever.

**What the patch does.** `preparedLineRender(row:line:cols:)` caches the
`ViewLineInfo` *and* its prepared `CTLine`s per absolute row, and `draw(_:)`
reads both from it. An entry is reused only when every input that can change a
row's rendering still matches:

- the same `BufferLine` **instance** at that row, and the same
  `BufferLine.generation`. `generation` is upstream's own per-line mutation
  counter - the Metal renderer's `RowCacheEntry` already validates its row cache
  exactly this way - and the identity check is what stops row N's render being
  shown for a different line that later rotates into slot N through the
  `CircularList`;
- the same column count, selection range for that row, link-highlight ranges,
  link mode and ⌘-held state;
- the same glyph policy (`customBlockGlyphs`, `useBrightColors`) and the same
  selection colours;
- the same style epoch, which `invalidateLineRenderCache()` bumps from
  `resetCaches()` (font, palette) and `colorsChanged()` (theme).

Everything but the epoch is compared per lookup rather than pushed from a
setter, so the cache is self-validating: a future upstream property that changes
rendering can only ever cause a *stale* render if somebody also forgets to route
it through one of those two invalidation points, and the two that matter today
already are.

`pruneLineRenderCache` keeps the row-keyed dictionary bounded - absolute row
numbers climb with the scrollback, so entries for rows that left the viewport
would otherwise accumulate for the life of the tab.

**What it deliberately does not touch: the terminal model.** Nothing about
parsing, the buffer, scrollback or the invalidation geometry changes. Only the
reuse of already-computed draw state moves.

**Measured, before and after**, on a 1100x700 view with 45 rows of coloured TUI
output and a status line changing every frame, 60 frames (30 seconds at the 2 fps
background cadence), CPU seconds from `getrusage(RUSAGE_SELF)`:

| | CPU per frame | rows rebuilt per frame |
|---|---|---|
| Before (cache reuse disabled) | 8.88 / 8.88 / 8.95 ms | 47.5 |
| After | 4.26 / 4.46 / 3.17 ms | 2.5 |

About 55% of the terminal's per-frame main-thread cost, gone. What remains is
the background fills and the glyph drawing themselves, which a cache of
*attributed strings* cannot remove.

**Re-applying it after a SwiftTerm upgrade:** re-add the two stored properties
and the two counters to both `TerminalView` classes, re-add the cache types and
the three functions to `Apple/AppleTerminalView.swift`, call
`invalidateLineRenderCache()` at the top of `resetCaches()` and
`colorsChanged()`, and replace `draw(_:)`'s `buildAttributedString` call and its
`preparedSegments` computation with `preparedLineRender(...)`.
`VendoredPatchesSelfTest` names the patch if any of that is missing, and
`FM_RUN_TERMINAL_ROW_RENDER_CACHE_TESTS` is the behavioural half - it renders a
real terminal in a real window and asserts a repaint of an unchanged screen
rebuilds no rows at all, that a single new line rebuilds fewer rows than a first
render, and that a theme change and a selection both still invalidate.

## Updating this vendored copy, and the scheduled check

**Pinned:** upstream `1.15.0` (`dd2fb8ac5b861e7bf617c872895e338f38165648`).
**Last checked:** 2026-09-19, against upstream `v1.20.0`.
**Re-check:** every 183 days (six months), or sooner if upstream publishes a
security fix.

The seven patches above are the price of this pin, and the review that filed
this section (P9 of full review #3) is right that the cost of a sync is
re-applying every one of them. So the standing decision is **stay pinned and
re-check on a schedule**, not "bump when a newer tag exists" - and the check
exists to notice the one thing that would change that decision.

### What would change the decision

In priority order. Any one of these is a reason to act now rather than wait for
the next scheduled check:

1. **A security fix upstream.** Acts immediately, whatever the diff costs.
2. **A patch's root cause is fixed upstream**, or upstream adds a `public`/`open`
   hook for it. That patch is then deleted rather than re-applied, and if it is
   the last one, `Sources/SwiftTerm` goes back to being a plain remote SPM
   dependency in `native/Package.swift` and this directory is deleted.
3. **A bug this app is actually hitting** is fixed upstream.

A newer tag on its own is **not** a reason. Nothing in this app is waiting on
an upstream feature, and every release since the pin has to be re-diffed against
all seven patch sites by hand.

### The check itself

Four commands, no clone needed - it is a network + judgement check, which is
why it is in `native/MANUAL-CHECKS.md` rather than a suite:

```bash
# 1. What is the newest tag?
curl -sS "https://api.github.com/repos/migueldeicaza/SwiftTerm/tags?per_page=5" \
  | python3 -c "import json,sys; [print(t['name']) for t in json.load(sys.stdin)]"

# 2. How big is the gap, and did it touch our seven patch sites?
curl -sS "https://api.github.com/repos/migueldeicaza/SwiftTerm/compare/v1.15.0...v<new>" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['total_commits'], 'commits,', len(d['files']), 'files'); [print('%+6d/-%-5d %s' % (f['additions'], f['deletions'], f['filename'])) for f in d['files'] if any(w in f['filename'] for w in ('MacExtensions','iOSExtensions','AppleTerminalView','MacTerminalView','MetalTerminalRenderer'))]"

# 3. For each of the seven patches, read the upstream function and answer one
#    question: is the root cause fixed, or is there a hook now?
curl -sS "https://raw.githubusercontent.com/migueldeicaza/SwiftTerm/v<new>/Sources/SwiftTerm/Mac/MacExtensions.swift"

# 4. Record the result below - the date and the per-patch verdict - whether or
#    not anything changed. A check that leaves no record is a check nobody can
#    tell was skipped.
```

`VendoredPatchesSelfTest` is the automated half, and it deliberately covers the
*other* hazard: it asserts all seven patches are still present in this tree, so a
sync that silently drops one fails by name rather than being found in
production. It also reads the `Last checked` date above and prints a NOTE (never
a failure - a date cannot break somebody else's build) once it is older than the
re-check interval.

### 2026-09-19, against v1.20.0: stay pinned

*(This check predates the sixth patch, which was added on 2026-09-22 and has no
upstream question to answer - it is a warning-only edit, not an override of
upstream behaviour, and the same is true of the seventh, added on 2026-09-26:
`buildAttributedString` and `draw(_:)` are both still `internal`/non-`open` at
v1.20.0, so a per-row cache still has nowhere else to live. The five verdicts
below are left exactly as they were recorded.)*

Upstream is **three releases ahead** of the review that filed this (which said
1.19.0). The gap is **81 commits across 123 files**, and it is feature work
rather than fixes this app is missing: a whole BiDi engine
(`Apple/TerminalBidi.swift`, `Bidi.swift`, `ArabicShapingData.swift`,
`BidiMirroringData.swift`, +974 lines in one new file), Metal renderer recovery,
semantic prompts, terminfo work, and Kitty keyboard extensions. Both files
carrying four of the five patches are among the most-churned in that range:
`Apple/AppleTerminalView.swift` +813/-157 and `Mac/MacTerminalView.swift`
+647/-54.

All five patch sites were read at `v1.20.0`. **Every one is still needed, and
none has gained a hook:**

| Patch | Upstream at 1.20.0 | Verdict |
|---|---|---|
| 1. `dimmedColor` contrast floor | Still a flat 50% sRGB blend toward the background; still `internal` | Still needed |
| 2. Truecolor `legibleColor` | `getAttributes`' `.trueColor` branch is a colour *cache* only, no contrast correction | Still needed |
| 3. `invalidationRegion` upward extension | Upstream still extends **down** only (`rowEnd` mid-screen). The symmetric `rowStart > 0` case is absent | Still needed |
| 4. `displaySuspended` / `displayIntervalNanos` | `queuePendingDisplay` still hardcodes `fps60`. Upstream's `suspendDisplayUpdates()` looks like a hook and is not - it is `internal`, empty, and commented "Not used on Mac" | Still needed |
| 5. `minimumColumns` floor | `processSizeChange` and `resetFont` still derive the column count straight from the pixel width, unclamped | Still needed |

Bumping would therefore mean re-applying all five into two heavily-rewritten
files, and inheriting a BiDi engine and a Metal recovery path this app has never
exercised, in exchange for nothing it is waiting on. Not worth it now; the next
scheduled check is the place to ask again.

### Re-applying the patches, if a sync does happen

Replace `Sources/SwiftTerm` with the new tree, then re-apply all seven. Each
patch's own section above ends with the specific hunks; in summary:

| # | Files |
|---|---|
| 1 | `Dimming.swift` (new file, keep it), `Mac/MacExtensions.swift`, `iOS/iOSExtensions.swift` |
| 2 | `Mac/MacExtensions.swift`, `iOS/iOSExtensions.swift`, the `getAttributes` call site in `Apple/AppleTerminalView.swift` |
| 3 | `Apple/AppleTerminalView.swift` (`invalidationRegion` + its `updateDisplay` call site) |
| 4 | `Mac/MacTerminalView.swift` (the property block), `Apple/AppleTerminalView.swift` (`queuePendingDisplay`) |
| 5 | `Mac/MacTerminalView.swift`, `iOS/iOSTerminalView.swift` (the `minimumColumns` property), `Apple/AppleTerminalView.swift` (two `max(minimumColumns, …)` clamps) |
| 6 | `Apple/Metal/MetalTerminalRenderer.swift` (a `_ = ` on both `vertices.withUnsafeBytes` calls) |
| 7 | `Mac/MacTerminalView.swift`, `iOS/iOSTerminalView.swift` (the cache storage + counters), `Apple/AppleTerminalView.swift` (the cache types, `preparedLineRender`, the two `draw(_:)` call sites, the two invalidations) |

Then run `FM_RUN_VENDORED_PATCHES_TESTS=1` first - it names any patch that did
not come back - followed by the terminal suites that prove each one behaves:
`FM_RUN_CONTRAST_TESTS` (patches 1-2, via `checkVendoredTerminalPairsSelection`),
`FM_RUN_TERMINAL_WRAP_REDRAW_TESTS` (3),
`FM_RUN_TERMINAL_DISPLAY_GATING_TESTS` (4), and
`FM_RUN_KUBE_BRIDGE_TESTS` plus `FM_RUN_KUBERNETES_DESTINATION_TESTS` (5), and
`FM_RUN_TERMINAL_ROW_RENDER_CACHE_TESTS` (7).
Patch 6 has no behavioural suite because it has no behaviour - a warning-clean
`swift build` is the check, and `FM_RUN_VENDORED_PATCHES_TESTS` is what makes a
dropped re-apply fail by name rather than only in build output nobody reads.
