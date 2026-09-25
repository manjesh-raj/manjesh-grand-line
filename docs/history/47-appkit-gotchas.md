# The AppKit gotcha catalogue - the full measurements

This is the AppKit gotcha catalogue as it stood before process issue P7 of the
2026-09-25 review, moved here **verbatim**. Nothing was deleted.

`AGENTS.md` keeps the catalogue's structure - the same section, the same
numbered `### (n)` headings, so the ~180 source comments that cite "AGENTS.md
gotcha (12)" still resolve - and now carries the *rule* for each trap rather
than the account of how it was found. The account is what you are reading. It
is worth reading when you are actually inside one of these: it names the file,
the probe, the numbers and, in several cases, the two or three wrong fixes that
were tried first.

P7's finding was that `AGENTS.md` had reached 139KB, about 35K tokens, imported
into every session, and that this catalogue alone was roughly 50KB of it -
which its own "Maintaining this file" section already says belongs here.

Twenty-two traps, every one measured on this app rather than read about. Each was
found by instrumenting a real layout or event pass; several took a full task to
root-cause, and at least four have recurred in a new file after being fixed in
an old one. **Read the ones that match what you are about to touch** - a tab
chip, a scroll view, a form, a dense row, or any full-size destination or window
root.

Relocated here verbatim from the single bullet they used to share; only the
formatting (one heading per trap, numbered as they always were) changed.

### (10) `.gravityAreas` is the default distribution and honours no hugging priority

A horizontal `NSStackView` left at its default `.gravityAreas` distribution
(never set explicitly) does not honor arranged-subviews'
hugging/compression-resistance priorities to absorb slack width at all - those
priorities only matter under `.fill`/`.fillProportionally`/`.fillEqually`.
Under `.gravityAreas`, all views added via the plain `views:` initializer or
`addArrangedSubview` land in the *center* gravity area and get laid out at
their natural size with no defined "who grows" rule, so leftover width is
resolved by Auto Layout's own tie-breaking - which can drift between runs/rows
depending on transient sibling content (a spinner swapped for a button, a
longer status string) even with no code change. This is what caused the Updates
page's per-row disclosure chevron (`UpdatesController.buildRow`'s `topRow`) to
sit flush against the trailing edge for some rows and stop short with a stray
gap for others, inconsistently, after expanding a row's log. There's a second,
compounding trap: even under `.fill`, an `NSStackView` container's *own*
horizontal hugging priority (not its children's) defaults lower than any
priority you set on its arranged-subview children - so a `trailingStack` of
`.required`-hugging buttons/pills can still itself get chosen to absorb the
row's slack instead of the intended flexible text label, unless you also set
`.required` hugging/compression-resistance on the container view itself. Fix
needs both: set `topRow.distribution = .fill` AND give every non-flexible
arranged subview (including any nested `NSStackView` container, not just its
children) `.required` hugging/compression resistance, leaving only the one view
meant to flex (the title/detail text stack) at `.defaultLow`. Confirmed live
via a temporary `FM_DEBUG_CHEVRON`-style env-gated probe (`performClick(nil)`
on the disclosure button + `ThemeManager.shared.setTheme` cycling, dumping
`NSView.frame` for the chevron/trailing-stack/text-stack after each) - reverted
before commit, per the "Verifying native UI bugs" convention below. Same root
cause hit a third time (cockpit-bootstrap-row-width-parity):
`BootstrapController.buildStepRow`'s `row` (a horizontal `[leftColumn,
bodyStack]` stack wrapping each stepper step's content box) also left
`.gravityAreas` distribution unset, so `bodyStack` - and therefore the
`stepContentBox` nested inside it - stayed shrunk to its content's natural
width even though the step's own outer card correctly filled the page (the
card's `background` *was* already width-tied to the page via an external
`widthAnchor.constraint(equalTo: stack.widthAnchor)`, so the empty gap looked
like a "card too narrow" bug but was actually this same nested-row distribution
gap one level in). Confirmed live via an `FM_DEBUG_BOOTSTRAP_WIDTH`-style probe
dumping `stepContentBox` frame widths before/after the fix (169-467pt narrow ->
1044pt full-width, tracking window resize correctly afterward) - fixed by
adding `row.distribution = .fill` plus `.required` hugging/compression
resistance on `leftColumn` and `.defaultLow` on `bodyStack`, the same shape as
the Updates-page fix above.

**And a fourth time, one level further in** (`fm/grandline-settings-page-
redesign`). Fixing the *row* is not enough when the row's trailing control is
itself a stack of two or three buttons: that inner stack is left at
`.gravityAreas` too, so the **first** member absorbs all its slack. Measured on
Settings' font-size presets, where "12" rendered about 300pt wide beside three
compact siblings, in a row whose own distribution was already correct.
`SettingsRow` now applies `.fill` plus `.required` content priorities to any
control column still at the default, centrally rather than at each call site -
which is the shape to copy for any component that accepts a caller-built
control stack.

### (1) `selectText(nil)` alone starts an edit session - never pair it with `makeFirstResponder`

`TabChipView.beginRename()` (fixes4) used to call
`window.makeFirstResponder(label)` *and then* `label.selectText(nil)` -
`selectText(nil)` alone already makes an editable field first responder and
starts editing, so the redundant prior `makeFirstResponder` call makes AppKit
think a session is already active and needs ending before `selectText` starts
its own. That fires a spurious `controlTextDidEndEditing` with the *pre-edit*
text right there, permanently flipping the "is renaming" flag false before the
user types a single character - the rename UI looks like it's working, but the
real commit on Return later hits a now-stale guard and is silently dropped.
Root-caused via `Thread.callStackSymbols` inside the delegate callback, not by
reading the code. Never call both; `selectText(nil)` is sufficient on its own.

### (2) `NSGridView`: give the column that must stay narrow the explicit width

`NSGridView` column widths: setting an explicit pixel width on one column (e.g.
the field column) while leaving the other unconstrained does NOT make the
constrained column absorb extra space on window resize - the *unconstrained*
column absorbs 100% of any extra width instead, since nothing else defines
where it should stop. That's what caused the "Add Host" form's labels to drift
into a growing empty gap as the window widened. Fix: give the column that
should *stay* narrow (labels) the explicit width, leave the column that should
*fill* (fields) unconstrained, and pin the `NSGridView`'s own width to its
container (`widthAnchor.constraint(equalTo: stack.widthAnchor)`) so the fill
column has a definite total to fill.

### (3) A standalone window with a required `==` width tie refuses to stay resized

A standalone `NSWindow` with `contentViewController` assigned (as opposed to
embedded in the shared app-shell body) keeps re-deriving its own frame from its
content's Auto Layout fitting size for as long as that content contains a
**required equality** chain with no independent lower bound
(cockpit-native-host-pages) - not just once at open. Confirmed live
(`FM_DEBUG_HOSTEDITOR`-style probe: `setFrame`/`display:true` right after, then
read `win.frame` again after a runloop tick): capping-and-centering the host
editor's form column with a required `stack.widthAnchor == content.widthAnchor
- 48` (paired with a `<=520` cap) made AppKit snap the *whole window* back to
568pt (the one width where that equality has zero slack) within one layout
pass, even right after an explicit user resize to 1000pt - the window was
effectively stuck. Swapping that one `==` for `>=`/`<=` inequalities (keep the
`<=520` cap, position with `leadingAnchor >=`/`trailingAnchor
<=`/`centerXAnchor ==` instead of a width tie) removed the trap entirely -
verified holding any width the user drags to. This is *why*
`HostEditorController`'s max-width-centered column uses inequalities, and it
generalizes: any future standalone window with Auto-Layout-capped content needs
the same inequality-not-equality shape, or it will silently refuse to stay
resized.

### (4) A scroll view's document view pins to the **clip** view, never the scroll view

An `NSScrollView`'s document view belongs width-pinned to
`scroll.contentView.widthAnchor` (the clip view), never `scroll.widthAnchor`
(the outer view) - caught in code review, not by inspection. With "Show scroll
bars: Always" (System Settings, the default with a mouse attached), a
non-overlay vertical scroller reserves a real ~15pt track that narrows the clip
view without narrowing `scroll`'s own frame; pinning to `scroll.widthAnchor`
lets the document view's trailing edge render underneath that track.
`HostEditorController`, `FleetController`, and `ReviewController` (the last two
fixed in cockpit-native-fixes5) all use `scroll.contentView.widthAnchor`;
`SettingsController`, `AutomationController` and `BootstrapController` all had
the wrong version until `fm/grandline-design-audit-phase0` fixed all three
(audit §5.6) - every scroll-backed page in this app now pins to the clip view,
so a new one is the only way this can come back.

### (5) Compression resistance in a row: only the text stack may be `.defaultLow`

In a horizontal `NSStackView` row (icon + title/subtitle text + a trailing
status pill and/or buttons), leaving every subview's compression resistance at
its AppKit default (750, all equal) means a long title squeezes *every* subview
roughly proportionally under narrow width, not just the title - and since the
trailing pill/buttons are themselves small containers with edge-pinned labels,
squeezing them below their fitting width can visually read as the badge
"wrapping" even though nothing is a wrapping label
(cockpit-native-settings-compact, `FleetController`'s PR/task rows). Fix: give
the icon and every trailing control `.required` compression resistance (and
hugging) so they never shrink, and give the title/subtitle text stack
`.defaultLow` compression resistance so it's the one thing that truncates
first. Generalizes to any row mixing fixed-size chrome with variable-length
text.

### (6) `dismiss(_:)` is a no-op for a window whose `contentViewController` was assigned

`NSViewController.dismiss(_:)` is a documented no-op unless the view controller
was presented via `presentAsSheet`/`presentAsModalWindow`/`presentAsPopover`
(or has a `presentingViewController`) - for a plain top-level window whose
`contentViewController` was just assigned directly (`HostEditorController`'s
Save/Cancel/Delete, presented by `AppDelegate.presentHostEditor`),
`dismiss(self)` silently does nothing. Fixed (cockpit-native-host-form-fixes)
by closing the window directly (`view.window?.close()`) instead; verified live
via `NSButton.performClick(nil)` on the located button plus a `win.isVisible`
before/after check (no Accessibility permission needed - `performClick` runs
the exact target/action path a real click does). Any future standalone-window
view controller needs the same direct-close pattern, not `dismiss(self)`.

### (7) A second window over a full-screen Space tiles into it unless told otherwise

A second regular `NSWindow` opened while another app window is full screen
docks into that same full-screen Space as a full-width tile by default (macOS's
standard behavior for a second standard window) - this is what turned
`HostEditorController`'s centered form back into a full-width layout, but only
in full-screen mode. Fixed by setting `win.collectionBehavior =
[.fullScreenAuxiliary, .moveToActiveSpace]` and `win.level = .floating` on the
host editor's cached window in `presentHostEditor`, so it floats over the
full-screen Space instead of tiling into it. Verified live via a temporary
env-var-gated probe (`window.toggleFullScreen(nil)` then dump `win.frame` vs
`screen.frame` - width stayed 640pt against a 1512pt screen, not stretched to
match). Any future utility window opened over a possibly-full-screen main
window needs the same `collectionBehavior`/`level` pair.

### (8) `.behindWindow` vibrancy composites against the desktop, not the window

`NSVisualEffectView` with `.sidebar` material and `.behindWindow` blending mode
- used for a real split-view sidebar, where it blends against the desktop
through the window's own edge - renders an incorrect tint when used as a
*full-size* destination or standalone window root, since `.behindWindow`
blending composites against whatever is behind the *window* (desktop/other
apps), not other content inside the same window
(cockpit-native-theme-audit-review; same root cause independently hit and fixed
for the Hosts sidebar in PR #18's Fix 6, then for the icon rail and the SSH
Keys / Snippets windows in this task - the latter two are now tabs of the Hosts
destination, see Phase 5 below). Forcing the view's own `.appearance` does not
fix it - only removing the vibrancy material does. Any full-size destination or
standalone window's root should be a plain `NSView` with `wantsLayer = true`
and a `HelmTheme`-derived `layer.backgroundColor`, exactly like
`HostsController`/`FleetController`/`ConsoleController` already do; reserve
real `NSVisualEffectView` sidebar material for an actual split-view pane with
narrower, non-full-window geometry.

**The one legitimate `.behindWindow` case in this app is the exact inverse:
a borderless, clear-backgrounded panel that floats over *other apps*.**
`DictationHUD`'s pill is `NSVisualEffectView` with `.hudWindow` /
`.behindWindow` / `.active`, pinned to `.vibrantDark`, because the desktop and
whatever app is over it genuinely *are* what is behind it - which is what
makes a macOS system HUD read as the system rather than as a floating card,
and what no flat fill can imitate. Two things that are not obvious:
`.followsWindowActiveState` leaves the material permanently inactive on a
`.nonactivatingPanel` (it never becomes key), and the material needs
`masksToBounds` or it draws square corners behind a rounded border. Measured
(review #3 §7): the flat `calibratedWhite: 0.08` fill it replaced sat at a
contrast ratio of **1.003** against Dusk's own page background - the app's
default theme - so the overlay was the same value as the app under it; the
material's own rendered base measures 3.52 against the same surface, before
any live translucency.

### (9) A plain `NSView` document view is not flipped

A plain `NSView()` used as an `NSScrollView`'s document view is **not flipped**
by default, so y=0 is its *bottom*, not its top - while
`FleetController`/`ReviewController` pin their `NSStackView` content to the
document's *top* anchor (so the header is the visually topmost, highest-y
arranged subview), a document shorter than the scroll's viewport (true before
their background `gh`/Bitbucket fetch populates the section stacks) rests
against the *bottom* of the clip view by default, leaving a blank gap the size
of the shortfall sitting above the header - this is the "empty black area above
the header for several seconds" bug (cockpit-native-loading-state). Confirmed
live with a temporary geometry probe: with a plain `NSView`, the header sat at
y=438 in a 668pt-tall viewport with 254pt of content (668-254=414, matching the
gap exactly); swapping in `SettingsController`'s existing `FlippedView`
(`override var isFlipped: Bool { true }`) pinned the header to y=24 and kept it
there from frame 0 through 3s of simulated load. `SettingsController` already
used this `FlippedView` + an explicit `scrollToTop()` in `viewWillAppear` (its
own earlier Fix 4) - `FleetController`/`ReviewController` were simply built
without carrying that pattern forward. Any new `NSScrollView`-backed
destination needs the same `FlippedView` document view + `scrollToTop()` pair,
or it will silently reproduce this bug the moment its content starts smaller
than the viewport (e.g. during an async data load, or a genuinely short list).
Follow-up (cockpit-native-fixes5): a captain report of the gap recurring
specifically on the *first-ever* Overview visit after a cold launch could not
be reproduced via extensive live instrumentation (geometry,
`needsLayout`/`needsDisplay` flags, and appearance-transition timing all
measured correct at every checked point, both on the first
`isHidden`-toggle-triggered `viewWillAppear` and after the async `render()`
grows the document height while already visible) - see that task's PR
description for the actual probe transcripts. `viewWillAppear` and the end of
`render()` in both controllers now force `view.layoutSubtreeIfNeeded()`
immediately before `scrollToTop()` regardless, closing the two theoretical gaps
the investigation could identify (a first-ever layout pass racing the automatic
appearance notification; the scroll position never being re-pinned after the
loading-skeleton's short content is replaced by full-height data) even though
neither could be proven to be the captain's exact cause.

### (11) `translatesAutoresizingMaskIntoConstraints` must be cleared before the constraints go on

A **second, distinct** flavor of gotcha (3)'s "window stuck at a fixed size"
trap - this one doesn't need an explicit absolute cap at all. Any plain
`NSView()` added as a subview and given manual constraints must have
`translatesAutoresizingMaskIntoConstraints = false` set on it *before* those
constraints are activated - if it's left at its default `true`, AppKit *also*
synthesizes required constraints pinning the view to whatever frame it happened
to have at that moment (for a freshly-`NSView()`-initialized view, `.zero` -
i.e. required width == 0 and height == 0), and those silently fight any
explicit "fill the parent" constraint the moment the parent tries to grow.
Confirmed live (`fm/grandline-window-size-lock-fix`, right after
`fm/grandline-docs-no-window-fix` (#156) fixed a real crash-on-launch bug in
the same file): `DocsController`'s Runbooks tab's `runbookEditorContainer` (a
bare `NSView()`, hidden by default since it's the "edit" state, not the "list"
state) never got this line - #156's fix simply exposed it for the first time,
since before that fix the app crashed at launch before ever laying out the Docs
page at all. The captain's whole app window (not just the Docs page) refused to
grow past a small fixed size and snapped back on every resize/maximize attempt,
**even while a totally different destination (Console) was showing** - because
every `RailDestination` is mounted as a permanent, `isHidden`-toggled child up
front (see "Navigation shell" above), and a hidden plain `NSView`'s constraints
still fully participate in the window's Auto Layout fitting-size computation,
contradicting the intuitive assumption that "hidden" means "excluded from
layout" (true for a hidden *arranged subview of an NSStackView*, false for an
ordinary hidden `NSView`). Root-caused by bisection (temporarily unmounting one
`RailDestination` at a time, then one container/constraint at a time within
`DocsController`, down to reproducing the exact lock with nothing but an empty,
hidden `NSView()` plus 4 fill constraints and no content at all) rather than by
reading the constraint list alone - `NSLayoutConstraint`'s own "Unable to
simultaneously satisfy constraints" console warning never fired for this, since
AppKit resolves the conflict by silently adjusting the *window's* frame instead
of logging a break. Fix: add the missing
`translatesAutoresizingMaskIntoConstraints = false` line. Generalizes: any
`NSView()`/`NSTextField()`/etc. stored as a `private let` and initialized
inline (no `.translatesAutoresizingMaskIntoConstraints = false` alongside the
property-building code that gives it manual constraints) is a live instance of
this trap waiting to happen, whether or not it's ever shown - grep any new
full-size destination or hidden-by-default subview for this before assuming its
constraints are "just fill, should be safe."

### (12) Content-priority APIs are no-ops on any view with no intrinsic size

**The correction to gotcha (10)'s second trap, measured rather than reasoned
(`fm/grandline-design-system-phase3`):**
`setContentHuggingPriority`/`setContentCompressionResistancePriority` are
**no-ops on an `NSStackView`** - both constrain a view against its *intrinsic
content size*, and a stack has none (`NSView.noIntrinsicMetric` on both axes;
its size comes from constraints to its arranged subviews). So gotcha (10)'s
advice to "also set `.required` hugging on the container view itself" does not
actually do anything, and a nested stack stays the parent's preferred stretch
target. Measured live inside `ToolRowLayout.build`: with `topRow.distribution =
.fill` and `.required` *content* hugging set on `trailingStack`, that trailing
stack still absorbed 919pt of a 1056pt row while the `textStack` it was
supposed to yield to sat at its natural 69pt - which is the actual mechanism
behind audit §5.4's ragged status column. The stack-level APIs are
`NSStackView.setHuggingPriority(_:for:)` and
`setClippingResistancePriority(_:for:)`; `ToolRowLayout.columnHugging` is the
one place this app applies them, and `HelmAccentRow` uses the same pair for its
own nested title row (where the wrong pair let a long title push the whole row
wider than its card instead of truncating - caught in a real off-screen render,
not by reading the code). Rule of thumb: **content**-priority APIs for a leaf
view (label, button, image), **stack**-priority APIs for an `NSStackView`, and
an explicit width constraint for anything that must be a fixed column. **The
no-op is not specific to `NSStackView` - it is true of *any* view with no
intrinsic content size, a bare `NSView()` spacer very much included**, and that
generalisation cost real time in `fm/grandline-visual-polish-round2`: the first
attempt at right-anchoring `ToolRowLayout`'s status column set `.defaultHigh`
*content* hugging on the row's spacer to hold it collapsed, and measured the
spacer absorbing 1024pt of a 1352pt row anyway while the text column sat at its
200pt floor - the exact pre-fix geometry. A spacer that must stay collapsed
needs a real low-priority `width == 0` constraint, not a hugging priority.

**The way out, when the view that must absorb the slack is a stack or a scroll
view** (both have no intrinsic size, so neither a content- nor a stack-priority
API decides anything): stop asking one stack to distribute it. Pin the chrome
above to the container's top edge and the chrome below to its bottom edge as
two separate groups, and let the flexible middle be what is left between them.
`CompactModePopoverController` is the worked example - it is what gives F22's
menu-bar popover one fixed size on all four tabs
([`40-menu-bar-mode.md`](docs/history/40-menu-bar-mode.md)) - and the same
shape is what any fixed-size card with a swappable middle wants.

### (13) Any content constraint above priority 500 can resize the whole window

**A window only holds its own size at `NSLayoutPriorityWindowSizeStayPut`
(500), so any content constraint above 500 can resize the whole window** - a
third distinct flavour of gotchas (3) and (11), and the one that needs no
explicit window-level cap at all. `ToolRowLayout`'s fixed-name-column
constraint (§5.4's fix) shipped at `.defaultHigh + 1` (751) paired with a
required `textStack.width <= nameColumnMaxWidth`; between them they capped the
**entire app window** at `520 / 0.42` plus the row/card/page insets = 1410pt
wide, on every page carrying those rows. Measured live on a 1512x982 screen
(`fm/grandline-design-fidelity-fixes`): the window refused to grow past 1410
however it was asked, `isZoomed` reported `true` at that size, and genuine
macOS full screen rendered 1410x949 **centred with a black bar down each side**
- which the captain reported as "the window doesn't cover the laptop screen."
None of `maxSize`, `contentMaxSize`, `resizeIncrements`, `aspectRatio` or a
window delegate was involved, and `NSLayoutConstraint`'s own "unable to
simultaneously satisfy" warning never fired - AppKit just quietly resized the
window instead. Root-caused by swapping the content view for a plain `NSView`
(cap vanished), then bisecting destinations, then the constraint itself.
Dropping the priority to 499 fixed it with no layout change at all.
Generalises: **a required `<=` plus a >500 proportional/equality constraint on
the same view is a window-size cap**, and the intended-per-row priority band
for anything that must beat the stack defaults but never touch the window is
251-499. `FM_RUN_CONTRAST_TESTS`'s `checkRowDoesNotResizeWindow` guards it.

**The cost of living in that band: two constraints at 499 *tie*, and Auto
Layout breaks the tie on its own.** `HelmPageSidebar` puts its own
`width == 208` at `contentTie` (499) precisely so it can never be a floor -
which means any other 499 constraint in the same row is its equal. Measured
(`fm/grandline-settings-page-sidebar-redesign`): Settings caps its detail
column, so a wide window leaves real slack beside it, and with the content's
scroll view pinned to `sidebar.trailingAnchor` (the shape `SchedulesController`
and `CredentialVaultController` both use, where the content genuinely wants
every point) that slack went into the **column** - the nav rows rendered 303pt
wide against the component's own 208, at a 1400pt window. Nothing failed; the
suites all passed at that width, and only an off-screen render showed it. So:
a page whose content column is **capped** must pin that content to the page by
a constant and let the column's 499 width stand uncontested, rather than
chaining the two together. A page whose content is uncapped may keep the chain.

**And a capped column is *centred*, never left-pinned - plus the centre it is
measured against is not the one you would reach for.** A required
`leading == content.leading + gutter` under a width cap is deliberate
left-alignment with a ceiling: once the cap binds, every extra point of window
becomes empty space on the right *only*. Gotcha (3) already prescribes the
shape (`leading >=` / `trailing <=` / `centerX ==`, cap untouched, and the grow
tie stated as a **width** rather than a trailing pin, which under a centring
tie would be a statement about position too). It still shipped on Settings and
the captain reported it three times before it was read as positioning rather
than sizing. The second half is the one no diff shows: **the scroll area starts
under the sidebar panel**, because `scroll.leading` is `sidebarColumn.trailing`
while `sidebarPanel.trailing` is that *plus* `pageGutter`, with `sidebarEdge`'s
1pt rule on top. Centring on the clip view therefore lands the column half that
overlap left of the centre anyone can see - measured 219pt of visible margin
against 244pt at a 1400pt window, which reads as "still not centred" and is
what a fourth report would have been about. `SettingsController.
visibleCentreNudge` is `(pageGutter + 1) / 2`, derived from those two
constraints rather than written as a number, and the page's toolbar carries it
too. [`09-setup-updates-bootstrap.md`](docs/history/09-setup-updates-bootstrap.md).

**A content *hugging* priority travels the same chain in the opposite
direction, and it is a width *ceiling* rather than a floor.** Everything above
is about a minimum reaching the window; a hug is a label saying "never wider
than my text", and wherever a required equality ties a container to its
content, that sentence is said about the container too. Measured
(`fm/grand-line-claude-usage-card-redesign`): `HelmModuleCard` ties its body
to `bodyContainer` and that to the card's own edges, all required, so one
`.required` hugging on a caption label inside a body row resolved a span-2
card **asked for 526pt to 227pt** - the bars collapsed onto their own minimum
and every caption truncated, which reads as a broken grid rather than as a
priority. Nothing was logged, because nothing was unsatisfiable.

**And the obvious correction is the trap's second half**: moving that hug to
`contentTie` took the card to 265pt, still wrong, because the width tying the
card to its column is *itself* at 499 - the tie above, in a new place. A hug
that only needs to break a tie between sibling columns belongs at
`HelmDaylightPriority.columnHug` (251): above every stack's own 250 default,
which is all it ever had to beat, and unable to tie with anything this
migration declares. **Reach for the 251-498 band for a hug, and 499 only for a
width that is genuinely competing with the window.**

### (14) A required `==` tie does not self-verify on every resize

**A correctly-declared required `==` width tie can still leave a view stuck at
a stale, wider frame after the window shrinks - a real, live-captured bug
(`fm/grandline-live-gap-rootcause-scout`), not a theoretical one.** A scout
task attached read-only (`lldb -p <pid>`) to the captain's own real, running
instance and captured `AppShellController.bodyContainer` (the view immediately
right of the icon rail, holding the top bar + every destination) frozen at
`{84, 0}, {1428, 949}` while the window's real, current frame was only `{1033,
949}` - `1428` being `1512 - 84`, i.e. the *screen's* width minus the rail, not
the window's. `bodyContainer.trailingAnchor == root.trailingAnchor` (`root`
being this window's own `contentView`, which the OS keeps in sync with the
window's content rect unconditionally - confirmed live, `contentView.frame`
matched the real window exactly; **that last clause is FALSE and
`fm/grand-line-window-glitch-fix` measured it so - see "`contentView` is NOT
kept in sync with the window" below, where the captain's window was 1512pt wide
while its `contentView` sat at 1064pt, which is exactly how the black region
came back after #412**) was already declared correctly, at the default required
priority - the declaration alone was not the gap.
`AppShellBodyWidthSelfTest.swift`'s own regression run (a real
`AppShellController` mounted in a real `NSWindow`, resized through
`setFrame(_:display:true)`) proved something subtler and more general: **a
required equality constraint does not self-verify on every resize** - after a
sequence of resizes (in particular a *shrink*), the constrained view's `.frame`
can simply not be re-derived from the live constraint graph unless something
forces a fresh `layoutSubtreeIfNeeded()` pass following that specific resize;
removing the fix reproduced the exact stale-width failure in that same test, on
a completely fresh view hierarchy with no other page ever visited, no
theoretical required-vs-required conflict needed. `main.swift`'s own launch
sequence is a second, compounding reason this specific view was vulnerable:
`window.setFrame(Self.defaultWindowFrame(), display: false)` (screen-sized,
matching the `1512` this bug's own numbers echo) followed by
`setFrameAutosaveName(...)` silently restoring the captain's own smaller saved
frame on top of it - both with `display: false`, deferring the very layout
flush that would otherwise catch this. **Fix**: `AppShellController` now names
`bodyContainer`'s leading/trailing constraints as stored properties and calls a
`reassertBodyContainerWidthTie()` method - once right after activating them
(closing the pre-visible launch-time race above) and again on every
`NSWindow.didResizeNotification` (registered globally, `object: nil`, matching
`ToolsController.containerWidthMayHaveChanged`'s own convention two paragraphs
below) - which reactivates either constraint if AppKit ever left it `isActive
== false` and forces `view.layoutSubtreeIfNeeded()` regardless.
`AppShellController` was, before this fix, the one major structural container
in this app with *no* resize-driven defensive re-derivation at all, unlike
`ToolsController`'s grid or `SettingsController`'s theme grid (both of which
learned this exact lesson - "don't fully trust Auto Layout's continuous updates
to never get stuck" - independently, per their own bullets).
`AppShellBodyWidthSelfTest.swift` (`FM_RUN_APP_SHELL_BODY_WIDTH_TESTS=1`) is
the permanent regression coverage, via
`AppShellController.bodyContainerFrameForTests`/`.debugBreakBodyWidthTieForTests()`
test-only hooks - **confirmed live to actually catch the regression, not just
to pass**: temporarily removing the fix's initial call and its resize observer
reproduced a stale, too-wide `bodyContainer` after a real resize sequence in 2
of the file's 3 cases, restoring the fix made all 3 pass again.
`data/grandline-live-gap-rootcause-scout/report.md` has the scout task's full
live-lldb evidence and reasoning; this fix could not itself force-reproduce the
captain's exact live conflict (no Screen Recording/Accessibility permission,
per the "Verifying native UI bugs" convention below, plus this bug's own root
cause turning out to be resize-sequence-dependent rather than a single
deterministic trigger) - the self-test instead proves the *mechanism* (a
required tie needs a live re-assert, not just a one-time declaration) rather
than the exact captain-witnessed sequence of events.

### (15) A hidden view is still in the window's constraint graph, and a full-screen-capable window re-solves all of it

**A hidden `NSView` participates in Auto Layout exactly as much as a visible
one** - gotcha (11) says so in the other direction, and this is what makes
GL-37's "mounted, only ever hidden" cost real CPU rather than only memory.
Every full-screen-capable window runs a `CFRunLoopObserver` that re-derives
`minFullScreenContentSize` whenever anything invalidates it, and that
derivation walks the **entire** required-constraint chain in the window - all
~27 mounted destinations, not just the one on screen.

Measured (full review #3's PF1; 5s `sample` at 1ms, main-thread samples inside
CoreAutoLayout) on the captain's own running instance: **1095 of 4072, 26.9%**,
under `_doUpdateTilingConstraintsImmediately -> minFullScreenContentSize ->
NSISEngine`. A standalone stock-AppKit probe pinned down what it is and is not:

- **Not stock idle work.** A settled graph costs **zero**, at 1 destination and
  at 27. The cost is the re-solve, not the observer.
- **Not layout forcing.** Forcing a real layout pass 20x/second measured 0%,
  and so did marking views `needsLayout`. The per-navigation `layout()` forces
  are exonerated.
- **It is invalidation of the window's derived minimum size**, and *a single
  label's text changing is enough to cause it* - a clock, a counter, a status
  string. Cost is near-linear in what is in the graph: 1/3/7/14/27 mounted
  destinations measured 0.4%/3.1%/8.3%/22.7%/43.4% of the main thread.
- An explicit `contentMinSize`/`minSize` does **not** short-circuit it.

**The fix, and the shape to reach for:** deactivate a hidden page's pins to its
container so its subtree has no required path to the window, and reactivate
them before unhiding (`AppShellController.setDestinationVisible`). Nothing is
torn down, so GL-37 is untouched. Same probe, 27 mounted, same invalidation:
1823 samples -> 55. In the real app, 637 -> 360 (17.3% -> 9.5% of the main
thread). Any future container that keeps many pages mounted needs the same
treatment, and any "idle CPU" investigation should `sample` for CoreAutoLayout
before suspecting a timer.

### (16) A container whose height nothing ties is free to let its own content escape it

**A view pinned at the top and only *capped* at the bottom has no height of its
own, and Auto Layout resolves that by picking - including by breaking the
required constraint that was supposed to hold its content inside it.**

`HostsSideStack` is the measured case (`fm/grandline-audit3-ui-fixes`). It wraps
one `NSScrollView`, pinned `scroll.top == top` with `scroll.bottom <= bottom`,
and gives that scroll view a *preferred* height at `contentTie` (499) so the
column ends above the page's gutter rather than stretching a card. Every one of
those is individually correct. Together they leave the container's own height
determined by nothing: the page pins its top and caps its bottom, and the only
opinion in the system is a 499-priority preference.

What that cost: rendered at 1512x950 with a host selected (which grows the
detail panel, and so the document), the column's frame was
`(1168, 244, 320, 606)` while the scroll view **inside it** sat at
`(1168, 314, 320, 756)` - 220pt taller than its container and 120pt above the
window's top edge, so the Workspace panel drew over the app's top bar. No
"unable to simultaneously satisfy" was logged, because nothing was
unsatisfiable: AppLayout simply broke the required `top ==` in favour of a
system it could solve.

It was latent for as long as the overflow happened to fall off the *bottom*, and
became visible the moment UI1 moved the column's top up ~44pt. **The direction
generalises**: a `top ==` / `bottom <=` pair plus a low-priority content-height
preference is not a height, and the fix is to make the child exactly fill its
container (`scroll.bottom == bottom`) and let the *page* decide how tall the
container gets. Any wrapper of this shape - `HelmPageSidebar` uses the same
mechanism - wants the same check.

**The same "nothing ties this height" shape, one level out: taking a view *out*
of a height tie also takes away the container's protection of it.** A row stack
resists clipping its content at 750 and hugs it at 250, and it is a card's own
`== row` tie at 499 that transfers that protection to the card - so a card body
whose vertical resistance is below 250 (`HelmModuleCard`'s `bodyHug` comment
records exactly one) is squashed the moment the tie is dropped, measured as an
86pt body rendered into a 68pt area. `HelmResponsiveGrid.spanningRows`'
`exemptsHeightTie` is the worked example, and it needs *two* things rather than
one: a reference the exempt view cannot inflate for everything still tied, and a
floor of the exempt view's own `fittingSize.height` to replace what the tie used
to supply. [`04-design-system.md`](docs/history/04-design-system.md).

### (17) An `NSTextView` is not a label, and it repaints your colours

**Two separate traps that arrive together the moment a page needs *inline*
clickable text**, which an `NSTextField` cannot give (its `.link` attribute is
handled by AppKit itself and goes straight to `NSWorkspace`, with no seam to
route a click back into the app). Both were measured building the Notebook's
preview pane (`fm/grandline-feature-f1-notebook`); `NotebookProseView` is the
worked example.

- **A hand-built text system must retain its `NSTextStorage`.**
  `NSTextView(frame:)` funnels into `init(frame:textContainer:)`, which a
  subclass has to override or AppKit traps with "Use of unimplemented
  initializer" on construction - so the storage/layout-manager/container trio
  gets built by hand. `NSTextStorage.addLayoutManager` makes the **storage**
  retain the manager, and the manager's back-reference to its storage is
  `unowned(unsafe)`: a storage that is only a local variable leaves the layout
  manager pointing at freed memory the moment the initialiser returns.
  Measured as `EXC_BAD_ACCESS` inside `objc_autoreleasePoolPop`, with a stack
  naming the pool rather than the text view. Hold it in a property.
- **`NSTextView` paints its own `linkTextAttributes` over every `.link`
  range**, and the default is the system blue plus an underline. So a view
  that computes a per-run colour - a resolved link in the accent, an
  unresolved one in the warn hue - installs a correct attributed string and
  then renders both in one colour. Caught only in a real off-screen render;
  every assertion against the attributed string passed throughout. Hand it a
  dictionary carrying neither `.foregroundColor` nor `.underlineStyle`
  (`[.cursor: NSCursor.pointingHand]` is the useful minimum), and assert that
  override directly - "the attributed string is right" is a different claim
  from "the text is painted right".

One more thing worth knowing before reaching for one: **an `NSTextView` has no
useful intrinsic size**, because it is built to live in a scroll view that
gives it one. In an `NSStackView` it resolves to zero and the pane renders
blank. Derive the height from the layout manager, and call
`ensureLayout(for:)` before `usedRect(for:)` - the rect is not valid until
layout for that container has actually run.

**A footnote to gotcha (13), from the same task:** a required `width == 0` is
safe where a required fixed width is not. (13) is about a *minimum* reaching
the window through a page; zero is a maximum and can never be a floor. That
matters because a fixed column collapsed only at `contentTie` (499) does not
actually collapse - the cards inside it outrank it, and a hidden 200pt rail
measured 154.5pt. Keep the visible width at 499 and give the collapsed state
its own required zero.

**And the case where even that is not available, measured in
`fm/grandline-feature-f11-code-preview-run-format`.** A required zero works
only where the collapsing view's own content can reach zero. Code Preview's
output pane cannot: its header is a real 28pt button row with required
constraints, so `height == 0` at `contentTie` lost to its own content and the
pane still resolved to **45pt** - the editor above it gave up 155pt where 200
was expected, and `isHidden` changed nothing (gotcha (15): a hidden view is
still in the graph). Raising that constraint over 500 is gotcha (13) again. So
**collapse the pane's neighbour instead of the pane**: the status bar below it
owns two alternative `top ==` constraints, one to the pane and one to the
editor card, exactly one active, swapped in `renderPane`. Nothing then derives
from a hidden pane's height at all, and the hidden state reproduces the page's
geometry from before the pane existed - which is the thing to assert.

### (18) A `WKWebView` bridge entry point must never return a `Promise`

**An `async` function is the natural way to write a bridge command that does
async work, and it silently breaks the call.** Every web-hosted page in this app
(the Whiteboard's Excalidraw, Code Preview's and the Notebook's Monaco) is driven
the same way: Swift builds `window.<Global>.<name>(callID, payload);` and hands it
to `evaluateJavaScript`, and the page answers later through a
`WKScriptMessageHandler`. That script is an **expression statement**, so its value
is the function's return value - and `evaluateJavaScript` cannot marshal a
`Promise`. It fails the call with *"JavaScript execution returned a result of an
unsupported type"*.

What makes it expensive is where the failure lands. The bridge's own error path
treats an `evaluateJavaScript` error as the call failing, so the caller is handed
a failure **before** the page's real reply arrives - a command that is working
perfectly reports an error that names neither the command nor a promise.
Measured on F15's `exportImage`, which was written `async` first and failed on
exactly that message while the export itself was fine.

The fix is one line of shape: keep the entry point a plain method that *starts*
the async worker and returns nothing, and put the real body in a sibling
`async function` that replies through the same `reply(callID, …)` every other
command uses.

    exportImage(callID, payload) { exportImageAsync(callID, payload); },


### (19) An `NSTextField`'s target/action fires on Return and on nothing else

**A field wired with `target`/`action` alone commits only for the captain who
happens to press Return.** Focus loss - clicking away, tabbing to the next
field, clicking the button the field was filled in for - sends no action at
all. The text stays visibly in the field, so the page looks like it worked and
nothing is saved.

That is the whole of the captain-reported Gmail bug
(`fm/grandline-gmail-oauth-field-not-saving`): `buildGmailSection` hand-wired
`gmailClientIDField`/`gmailClientSecretField` to `gmailClientChanged`, the
captain pasted an OAuth client ID and clicked Connect, and
`GoogleOAuthClientStore` was never written. Measured in a real window - the
pasted text reached `stringValue`, first responder moved on, the store stayed
`nil`.

**The rule: a field whose value is *persisted* needs a `delegate` as well**, so
`controlTextDidEndEditing` reaches the same commit. `SettingsController`'s
`configure(_:)` is this app's one place that wires all three
(`target`/`action`/`delegate`) and every settings field goes through it - the
two Gmail fields were the only ones wired by hand, which is exactly how the gap
opened. A field whose action means **submit** (`CompactModePopover`'s capture
line, `IncidentCardView`'s note, Kubernetes' namespace) is the legitimate
Return-only case and must *not* gain one: committing a half-typed line on blur
is its own bug.

Two things that make this hard to catch. `sendsActionOnEndEditing = true` is
the other half-fix and is **not** what this app uses - the delegate is, because
a controller already owns one. And a suite that reaches the commit method
directly (a `debugCommit…()` hook) passes with the wiring deleted: the only
assertion that sees this is a **window-backed** one that drives the real field
editor (`window.makeFirstResponder(field)`, `field.currentEditor()?.insertText`,
then move first responder away) and then reads the *store*.
`GmailSettingsViewSelfTest.checkPastingAndClickingAwayCommits` is the worked
example, and it asserts the Return path in the same case so a future fix cannot
trade one for the other.

### (20) An ancestor's click recognizer swallows a nested control's click

**AppKit defines no automatic exclusivity between a gesture recognizer on an
ancestor view and a real control nested inside it, and the control loses.** The
recognizer claims the click; the nested `NSButton`'s `action` never fires. There
is no warning, nothing is logged, and the button still hit-tests correctly and
still reports the right `target`/`action` - so reading the code, or probing
`hitTest`, says the wiring is fine.

Found three times here. `SessionStripView` first (full-app audit finding 4.7: a
session pill's ✕ switched to the very session it was ending), `HelmModuleCard`
next (a card's header action), and then the whole "Waiting for you" row
(`fm/grandline-notification-rows-not-interactive`: the disclosure chevron and
the hover-reveal action button were both dead in the real popover). The first
two each fixed it with their own hand-rolled delegate and neither shared it,
which is exactly why the third row to need it did not get one.

**It is handled for you now**: the walk is `HelmGestureArbitration.shouldRecognize(_:with:)`,
and `HoverHighlightView` makes itself the delegate of any recognizer handed to
it that has none - so all ~40 recognizer-driven rows are covered by
construction. Two things still to know:

- **A recognizer on a view that is not a `HoverHighlightView` is on its own.**
  Set `delegate` and call the shared helper; do not write a third copy.
- **The rule declines for an *actionable* control, not for any `NSControl`.** A
  row's own title is an `NSTextField`, which is an actionless `NSControl`, and
  declining for it would stop most of the row's surface from activating.
  `HelmModuleCard` carries one extra rule the shared walk cannot: AppKit does
  not hit-test a **disabled** control, so a visibly-there-but-inert button has
  to swallow its own clicks by frame.

**The reason this shipped three times is a testing trap, not a coding one**, and
it is the one to take away: gesture arbitration is a property of real event
dispatch through a real window. A suite that calls the handler, or that mounts
the view without ever dispatching an event, cannot see it - and both prior
tasks had green coverage of exactly the interaction that was dead. A control
nested in a recognizer-driven row wants a check that posts a real `NSEvent`;
`NotificationRowInteractionSelfTest` is the worked example, and its header
carries the two AppKit facts that make such a check hard to write (an
`NSButton`'s tracking loop dequeues its own mouse-up, so the events must be
`postEvent`ed and pumped rather than `sendEvent`ed; and a row's window
coordinates go stale the moment a reload or a resize follows the click).

### (21) `.deviceIndependentFlagsMask` is the wrong mask for a hotkey predicate

**A chord predicate must mask with `KeyChord.relevantModifierMask` (⌘⌥⌃⇧),
never with `.deviceIndependentFlagsMask`.** The latter is `0xFFFF0000` and
carries Caps Lock, Fn, the numeric-pad flag and the help flag as well - so an
exact equality against it turns any ambient flag riding along on the event into
"this is not the chord", silently. `KeyChord`'s own header already writes down
why those four are ambient *state* rather than a deliberate press.

Shipped twice, both found by `fm/grandline-capture-global-hotkey-configurable`:
`ShiftGlobalHotkey` (⌥Space, the captain's report) and `CompactModeHotkey`
(⌃⌥G), the second having been shaped on the first and copied the mask.
`DictationHotkey` never had it. **Three hand-written predicates for one
question is the real defect** - route the comparison through `KeyChord` and
there is one.

Two things that made it expensive to find, and both generalise:

- **A chord that is *also* an `NSMenuItem` key equivalent has two independent
  implementations, and the menu masks the monitor's failure.** ⌥Space is in the
  Shift menu as the no-Accessibility fallback, so a predicate defect that
  killed both monitors still opened the panel while this app was frontmost -
  which reads exactly like "the global half needs permission". Establish
  *which* path fired before concluding anything about the other.
- **A global `NSEvent` monitor is armed from the trust the process held when
  it was registered**, and macOS does not arm an already-registered one
  retroactively. Requesting Accessibility and calling `start()` in the same
  breath means a captain who grants it in the pane that prompt opens has a
  dead monitor until the next launch, with nothing saying so.
  `ShiftGlobalHotkey.reassertIfTrustChanged()` (called on app activation) is
  the shape; any new global monitor wants it.

And the diagnostic worth reusing: `AXIsProcessTrusted()` can be read out of the
captain's **own running instance** with a read-only `lldb -p` attach, which is
how the trust story was eliminated here rather than assumed. Swift expression
evaluation does not work against the packaged build (no debug info), but plain
ObjC/C calls do.

**A privacy-pane toggle shown ON is not proof `AXIsProcessTrusted()` (or any
other live TCC check) reads true for the process actually running** -
confirmed a second time, independently, on Dictation's silent-auto-paste
failure (`fm/grandline-dictation-autopaste-not-firing`): the exact same
read-only `lldb -p` attach above, run against the captain's real running
instance, read `AXIsProcessTrusted() == 0` while System Settings > Privacy &
Security > Accessibility showed a "Grand Line" row toggled on in the same
minute. The captain had already tried the obvious fix (toggle off, toggle on,
fully quit and relaunch) with no change - that is expected, not evidence
against this diagnosis, since a re-toggle is not guaranteed to force a fresh
`tccd` re-validation for every prior grant shape. The only reliable recovery is
removing the row entirely and re-adding it, a captain-only action (no
interactive TCC dialog, no password, and `TCC.db` is SIP-protected even to
root). Never conclude "Accessibility must be denied" - or accept a captain's
"it looks granted" - from the Settings UI alone; read the live process. See
[`16-dictation.md`](docs/history/16-dictation.md) for the full investigation.

**And the rule that came out of the *second* round on the same bug
(`fm/grand-line-dictation-autopaste-fix`): gate a permission-requiring call on
the API that governs *that call*, and when the gate is closed, ask - do not
narrate.** `AXIsProcessTrusted()` answers "may this process drive other apps
through the Accessibility *API*"; `CGPreflightPostEventAccess()` answers "may
this process *post* events", which is what `CGEvent.post` actually does. They
are separate entry points onto TCC and they are free to disagree.
`DictationEngine.pasteGateIsOpen(postEventAccess:axTrusted:)` takes either as
sufficient, which can only ever add an attempt that used to be refused. The
second half matters more: the first round's fix ended at a status string
telling the captain to remove and re-add the row in System Settings by hand,
the captain did exactly that twice, and the app still only copied.
`CGRequestPostEventAccess()` (and `AXIsProcessTrustedWithOptions([prompt:
true])` for the AX half) is the in-app version of that repair - it registers
the *currently running* binary's signature with `tccd` rather than relying on
whichever older one the existing row was recorded against. Two things any such
call needs: it presents a system alert, so hop it to the main thread while
keeping the once-per-launch decision synchronous and therefore assertable, and
it must be short-circuited under `#if FM_SELFTESTS` - a suite that raises a
real TCC dialog on the captain's machine is its own defect, and needs a
reset hook, because a process-global "already asked" latch otherwise lets the
first case to consume it leave every later case passing for the wrong reason.


### (22) A wrapping label's `preferredMaxLayoutWidth` must never come from its own resolved width

**Deriving it from the label's own bounds - or from the bounds of a stack whose
size that label decides - is circular, and whichever layout pass ran first with
a small width becomes permanent.** An `NSStackView` has no intrinsic size
(gotcha (12)), so its resolved width comes *from* the label's intrinsic width,
which comes from `preferredMaxLayoutWidth`. Feeding the result back in closes
the loop.

Measured twice in one branch (`fm/grand-line-review-bugs-b1-b14`). The
Dictation page's `viewDidLayout` read `stack.bounds.width`: settling the page
from an intermediate width to 1512 locked the text column at **11pt** (from a
700pt intermediate), 91pt (860) and 161pt (1000). An 11pt column is the
captain's own report - one word per line, words broken mid-word ("permis /
sion", "microp / hone") - with the Status card grown to 380pt around it. Both
the correct and the broken derivation converge once a further pass runs, which
is why a theme change "fixed" it and why it only ever appeared on a first
visit.

**The shape that works** is `SettingsRow.relayoutDescription`'s, and it is
non-circular because it measures things that are not decided by this label:
the **row's** own resolved width, minus its rigid siblings' `fittingSize.width`
(they are `.required` hugging, so that is what they will take), minus the
spacing, floored. `DictationController.availableDetailWidth` and
`HelmToggleRow.layout()` are the two worked examples.

**And the trap underneath it: `NSTextField(labelWithString:)` builds a cell
whose `wraps` is false**, so `maximumNumberOfLines = 0` and a word-wrap line
break mode do nothing at all - the label truncates with no ellipsis however
wide you make it. `wrappingLabelWithString` is the constructor that sets the
cell up; it also makes the field selectable, which a row title is not. Two
single-line labels in a 420pt-capped card truncated this way for as long as the
credential vault's setup screen has existed.

---

