# Full review #3

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

## Full review #3: eighteen rendered and code-traced defects

**`fm/grandline-audit3-bug-fixes` closed every finding in §1 and §1b of `data/grandline-full-review-3/report.md` (B1-B18), firstmate-side.** Four were traced in code, fourteen were caught in real renders, and two the review flagged as "suspicious" were reproduced live before anything was written. What is worth carrying forward:

- **`.byTruncatingTail` IS the single-line mode, and `maximumNumberOfLines` cannot override it (B7).** A wrapping `NSTextField` with that break mode lays the whole string out on one line and ellipsises it, so a label configured for four lines renders one - measured, a 97-character note using 15pt of a 101pt body. The wrap width was *also* wrong (read from a descendant's `bounds` during the card's own `layout()`, i.e. before that descendant had one), and fixing only that moved `preferredMaxLayoutWidth` to 268 while the render stayed one line. **Both halves are needed, and only one of them is visible from a constraint.**
  - **Nothing derived from `maximumNumberOfLines`, `fittingSize` or the body's height can see it** - which is why `DaylightDrillPageSlice6SelfTest`'s own check had passed for the whole life of the bug. `HelmModuleCard.Anatomy.noteRenderedLineCounts` lays each label's real attributed string out in a container of its real width and counts line fragments; a container mirroring the label's own `lineBreakMode` answers 1 for a truncating label however many lines its maximum allows. **Read the rendered line count.**
- **`NSView.performKeyEquivalent(with:)` skips a hidden subview (B15).** `HelmConfirm`'s zero-sized Escape button was `isHidden`, so Escape reached nothing at all on every `confirmIsDefault: false` dialog - i.e. the ~10 destructive ones that button exists to protect. `alphaValue = 0` is still invisible and stays in the walk. **`keyEquivalent` and `performClick` are both blind to this** (the property is still set; the click calls the action directly), which is exactly why the existing suite stayed green - a real `NSEvent` through the real dispatch is the only instrument that can see it.
- **A window-*height* floor is the same class as gotcha (13) and had no guard (B5).** The Hosts side column's three cards were pinned with required heights all the way up, and this window is driven by `contentViewController` (gotcha (3)), so the column's own content pushed the whole window taller - measured, a window asked for 750pt of content came back 906. A scroll view is the one shape that lets content exceed the space it is given; its height tie sits at `HelmDaylightPriority.contentTie` so it prefers to be exactly as tall as its cards and can never floor the window. `AppShellBodyWidthSelfTest` measured width only and now sweeps **height** across every destination too.
- **A vertical `NSStackView` at `.gravityAreas` has no rule for who absorbs leftover height, and `alignment = .top` on the horizontal row does not prevent the stretch (B9).** That row *also* installs a `bottom == bottom` alignment constraint, so the shorter column was stretched to the taller one's height and the slack landed on one card - the one-row Connection card resolving to **504pt against its own 133pt** of content. Measured: `setHuggingPriority(.required, for: .vertical)` on the column changed nothing (gotcha (12) - a `HelmCard` has no intrinsic content size). The fix is a plain `NSView` with explicit constraints: both columns pinned to the row's top, both `bottom <=`, equal widths, and a **priority-1** `height == 0` shrink-wrap.
- **A row needs a flexible member, and `.required` hugging on a view with no intrinsic size is not one (B10).** The Dictation "Model ready" chip rendered **1208pt** wide. Putting the hugging on the pill (a container) rather than its label is gotcha (12); moving it to the label then collapsed the whole page to 391pt, because `modelStatusLabel` is hidden in `.ready` and the pill was the row's only remaining flexible member. A real `NSView()` spacer is what gives the row something to stretch. **A/B the fix in isolation** - the second failure looked exactly like the first.
- **A colon means two different things and only its surroundings tell them apart (B18).** `splitLabel` took the first colon anywhere, so `svc:v2 --> db` became a head of `svc` and a label of `v2 --> db`. "The first colon after the **last** arrow" is wrong in the other direction - the last arrow in `A --> B: maps a->b` is inside the label - and "after the *first* arrow" breaks `app --> image:tag`. The rule that satisfies all four is **an arrow before it, and whitespace (or end of statement) after it**: a name's colon never has either.
- **Two "suspicious" findings both reproduced, and one of them needed the app lock turned off to reproduce at all.** B13 (closing the *primary* pane of a split tab terminated the tab's own session, leaving `TabModel.terminal` - a `let` ~50 consumers read - pointing at a detached dead view) and B15 above. `AppLockGate.shared` starts **locked** in a self-test process, and `splitFocusedPane` refuses while it is: a probe reporting "panes after split: 1" is that gate, not a broken split.
- **A split-pane test cannot assert on child processes.** A headless harness never calls `viewDidAppear`, so `hasAppeared` gates `startSplitPane` and no pane's shell is ever started - a liveness check passes whatever the code does. `TerminalPane.isClosing` is the direct observable that `teardownAll` reached every pane (B14: `closeTab` was its only caller, so quitting or deleting a host left every split pane's `zsh -l` running).
- **B1 is honest about what it cannot prove, and the shape generalises.** The repair's third reference (is the *showing page* narrower than the body it is pinned to?) is real - review #3's sweep caught ten destinations rendering into 973.5pt inside a 1512pt window, 973.5 being a page shown ten destinations earlier - but **a frame set directly on a constraint-managed view leaves Auto Layout holding the correct solution**, so a forced pass repairs it whether or not the comparison ran. Measured: with the comparison deleted, every behavioural assertion still passed. The case therefore asserts the comparison's own answer plus a **source guard** on the call site, and says so - the same limitation `bodyWidthTieIsActiveForTests` was written for.
- **Three of this batch's own new checks were vacuous on their first injection and were strengthened rather than accepted** (B1, B16, B17): each re-implemented a predicate the fix had changed *at a call site*, so reverting the call site left them green. Where driving the real path needs a mounted shell plus a real host page (B16) or an encrypted vault plus a stale login-Keychain key (B17), a source guard on the call site is the honest instrument.
- **Scripted revert-and-restore: back a file up OUTSIDE `Sources/`, and restore several edits to one file in REVERSE order.** A `.pristine` sitting in the source directory fails the build with SwiftPM's unhandled-file error, and restoring two backups of the same file forwards writes the *intermediate* state last - which silently left one half of a fix reverted in the working tree and was only caught because the next sweep reported the anchor missing. **Never `git stash` for any of this** (see this file's own warning about the shared stash stack), and re-read the file after a multi-edit injection rather than trusting the restore.

## Full review #3: PF1, PF2, S1, S2 and S3

**`fm/grandline-audit3-perf-security-fixes` closed the two performance findings in §3 and the three security findings in §4.** Five commits, one per finding, each with regression coverage confirmed by injection. The standing rules this produced are in the root `AGENTS.md` (gotcha (15), and two bullets in "Stores, subprocesses and secrets"); what follows is the branch's own account.

- **S1's premise was verified before anything was written, and the exploit ran.** A real `claude -p` against the captain's real `~/.claude/settings.json`, given only `--allowedTools mcp__luffy-stores__shift_read` - today's Straw Hat shape - executed `echo '...' | python3 -` and **wrote the marker file**, with `permission_denials: []`. The prompt asking for it was ordinary conversation text, which is exactly what a runbook body is. Three further measurements decided the fix: `--tools ""` denies it; `--tools "Task,TodoWrite"` denies it **even with `--permission-mode bypassPermissions` also passed**, so `--tools` gates below permission checking; and `--tools ""` does not strip MCP tools, which is what makes it usable here at all. A positive allowlist rather than `--disallowedTools`, because a denylist goes stale the moment the CLI gains a built-in nobody here has heard of.
  - **`StrawHatTools.swift`'s existing measurement was right and incomplete.** It had proved that `--allowedTools` alone both permits a listed MCP tool and denies an unlisted one - true, and it says nothing about `Bash`, which was never an MCP tool and was granted by the ambient file. A negative result about one mechanism is not a negative result about the surface.
- **S2's merge needs a third copy of the data, and that is the whole design.** `credentials` is what the captain sees and `file` is the sealed snapshot it came from; neither can answer "of the differences between memory and disk, which are *mine*?". A decrypted `baseline` - the set as of the last time memory and disk agreed - makes the answer a three-way merge. Without it the only available behaviours are "always overwrite" (the bug) and "always reload" (which throws away the captain's own edit instead).
  - A re-key landing from another Mac is **refused**, not merged: this machine's key opens nothing in that file, so every item would fail to authenticate and writing anyway would replace a vault we cannot read with one the other Mac cannot. `finishPasswordChange` opts out of the whole reconciliation (`persist(adoptingOnDiskChanges: false)`) because a re-key deliberately replaces the header the reconciliation measures against - it would look exactly like the case it exists to refuse.
  - **Reveal and copy were the worst of both problems at once**: the two most frequent actions in the feature, each a full-file overwrite from memory *and* a git commit, so the git host's commit timestamps recorded when the captain looked at which secret. They batch now, and `persistAuditOnly` no longer marks the sync dirty at all.
- **S3 reaches a different answer from end-to-end review #1's L4, deliberately.** L4 declined a sidecar file for the vault's `failedAttempts`/`throttledUntil` on the grounds that it would add GL-01 handling, an override and a redirect entry *without making the thing a control*. Neither half holds for session-restore state: it is the same data class as `snippets.json` (captain-authored strings that in practice name what a tab is connected to) getting the same 0600 treatment, and the cost is one small store beside four siblings of identical shape. The reasoning is on `SessionRestoreStore` itself so nobody "completes" L4 by accident in either direction. The migration removes the legacy `UserDefaults` key only **after** the file write succeeds.
- **PF1's two named suspects were both exonerated by measurement, and the real cause was a third thing.** See gotcha (15) for the mechanism and the numbers. The method is worth repeating: a standalone stock-AppKit probe modelling this app's *shape* (N destination containers pinned into one body view) isolated the variable in a way that instrumenting the real app could not, because it could be run at 1, 3, 7, 14 and 27 destinations and with each candidate invalidation source switched on separately. `reassertBodyContainerWidthTie` was ruled out by a cheaper instrument still: its reactivation path logs, and `log show` had **zero** entries in six hours of the captain's instance.
  - The before/after in the real app was measured through `Scripts/build-probe-app.sh`'s separately-identified bundle with identical temporary instrumentation on both sides, then the instrumentation was reverted. **GL-37's other half - unmounting cold destinations - was deliberately not attempted**, and the scaling curve is the argument: the cost is about what is in the *constraint graph*, not about what is mounted, so detaching gets essentially all of the saving for none of the risk of reasoning about ~27 controllers' live sessions and in-flight fetches.
- **PF2 got three things wrong before it got them right, all caught by rendering it off-screen rather than by reasoning.** The card's body tie had to stay `<=` (an `==` hug leaves a row no slack to stretch a short card into); the card's own height preference had to be **priority 1**, not `.defaultLow`, because at 250 it already outranked some bodies' vertical resistances and clipped a three-row peek list into a 68pt area it needed 86pt for, *with nothing logged* - nothing was unsatisfiable, the hug simply won; and the row's equal-height tie had to be a required `>=` plus a 499 `==` rather than a required `==`, because a required tie outranks every clipping resistance inside a card and the solver squashes the tallest card to match the shortest.
  - **`NSStackView.alignment = .height` is not a reliable way to equalise a row.** Measured, it left content-sized `HelmModuleCard`s at `[124, 143, 124]`. Explicit constraints are what holds - and they must be activated **after** the views are in their stack, or activating a constraint between views with no common ancestor raises and aborts the process.
  - **Two of PF2's injections did not reproduce a failure, and that is recorded rather than papered over.** With the hug at priority 1, removing the row tie and raising it back to required both leave the fixtures uniform anyway, because a row already equalises cards that express no strong height preference. The tie is kept as an explicit guarantee rather than as the mechanism, on the strength of a real render showing the property does *not* hold once a card has a stronger preference.
  - **The one behavioural contract that genuinely changed**: `DaylightDrillPageSlice6SelfTest` used to assert every plate reserves room for `maximumNumberOfLines` full lines, which was the only way a long description could be safe while the height was fixed. It now measures the lines the longest real description actually renders against the area it actually gets. It also has to lay out **twice** - `applyNoteWrapWidth` assigns `preferredMaxLayoutWidth` from the card's own `layout()`, which invalidates the label's intrinsic size and schedules another pass, so the first pass settles on a one-line label. The app gets the second pass for free; before PF2 it did not matter, because the height was fixed either way.

---

**`fm/grandline-audit3-ui-fixes` closed §5's UI findings (UI1-UI13).** Twelve
changes and one deliberate non-change, each grounded in an off-screen render of
the real page before and after rather than in a source-level guess - the same
`Review3RenderProbe` the review itself used, re-pointed at the twelve pages §5
names, in both theme families and at 1512 and 1100. The standing rules this
produced are in the root `AGENTS.md` (gotcha (16), and `HelmCountBadge` in the
component index); what follows is the branch's own account.

- **UI1 settled the "sidebar *and* tab strip" question the other way, and that
  reverses a recorded captain decision.** `HostsSidebar.swift`'s header said the
  tab strip stays because the captain's own target screenshot showed both, with
  the two wired as one mechanism so they could never disagree. UI1's finding is
  that being one mechanism does not stop them being the same three words twice,
  one row apart - so the strip is gone and the column is the page's whole
  navigation. The column is the half that survived because it is strictly
  richer (a glyph per scope, a TOOLS section, the keychain footer). The header
  comment was rewritten rather than left to be discovered as stale.
  - **The count went from four statements to one**, and picking which one
    survives was the real decision: the Workspace panel, because its own
    subtitle is "At-a-glance inventory", it is visible at the same time as all
    three of the others, and it is the only one that also reports live
    sessions. The sidebar badges, the card header's `Hosts (3)` and the drill
    subtitle's counts all went. The drill subtitle keeps its *empty* case ("No
    saved hosts yet"), which is a state to act on rather than a count.
  - **Removing the strip exposed a latent layout bug 44pt away** - see gotcha
    (16). `HostsSideStack`'s scroll view was escaping its own container by
    220pt; it had been falling off the bottom, and moving the column's top up
    put it over the app's top bar instead. Caught in the after-render, not in
    review, and root-caused by printing the container's and the scroll view's
    frames at capture time rather than at build time (they differ - `savePNG`
    forces a layout pass of its own).
- **UI2 fixed the disabled state for every palette, not for latte.** The
  finding names latte's washed lavender pill, but the mechanism is
  palette-independent: `restyleBody` resolved the *enabled* palette for a
  disabled control and dropped `alphaValue` to 0.42, so a `.primary` rendered
  as a pale wash of its own accent - which reads as a fault, not as "switched
  off". macOS itself greys a disabled push button rather than fading a blue
  one. `disabledPalette` is now a separate recipe (neutral surface, muted
  label, no gradient, no whole-control dim), and `.quiet` keeps its own shape
  because a filled grey pill on a switched-off toolbar glyph would be *more*
  chrome than when it works.
- **UI8's root cause was measured before anything was chosen, and the first
  fix was not enough.** Outline against the card it sits on:
  `catppuccin-latte` 2.30, `helm-dark` 1.55, `dusk` 1.37, `daylight` 1.33 - so
  the same component reads as a button on Settings in latte and as a label on a
  Schedules row in dusk. The fill was never going to carry it (`HelmField.fill`
  measures 1.01-1.14 against a card by design). A first pass floored the
  outline at 1.8, re-rendered, and the button still read as a dark capsule
  beside the filled status pill next to it; 2.3 - latte's own measured number -
  is what makes it read as a control, and leaves latte untouched to the
  hundredth.
- **UI9 needed new state, not new words.** `LocalProcess` exposes only
  `running` after the fact, so "exited" was the only honest thing the Console
  canvas card could say - and GL-14 forbids softening it into a claim the app
  has not earned. `TabModel.ExitOutcome` is recorded in `processTerminated`
  (and reset in `restartTabBookkeeping`, the one place every restart path goes
  through), which is what lets the card distinguish `closed` from `exit 130`
  from `ended` from `idle`.
- **UI10 and UI4 are the same fix in two places**: D3's skeleton is this app's
  loading language, and both pages predate it. The five Engineering cards' own
  `checking:` sentences did differ - they truncate to the same first word at a
  canvas column's width, which is what made them read as one wall - so they
  moved to the card's tooltip rather than being deleted. The *stale* state
  (a pass finished and produced nothing) deliberately stays a sentence: a
  shimmer there would promise an answer that is not coming.
- **UI13 is the one finding with no code change.**
  `HelmSegmentedTabs.applyDaylightTheme` already carries the rationale in its
  own doc comment (§7's resolution, so a drill page's tab strip and the
  floating bar's space strip read as the same control one level apart), and
  `HelmContrastSelfTest.checkSegmentedTabsRecipe` already asserts both recipes.
  `Audit3UIFixesSelfTest` guards the *rationale* instead, so a future reader
  who meets the divergence cannot delete the reason without failing a named
  check.
- **Two of the fifteen injections initially produced no failure, and both were
  the same mistake.** `checkSecondaryButtonOutlineClearsTheFloor` read
  `HelmButton.secondaryBorderMinRatio` as its expectation, so dropping the real
  constant to 1.0 moved the check with it; and
  `checkWarmingCanvasCardShowsASkeletonNotASentence` built its own
  `.skeleton()` content rather than calling the canvas's own function, so
  putting the old chip and sentence back in `fillPendingSetupSignal` was
  invisible to it. The floor is a literal in the test now, and the canvas's
  warming/stale branch was lifted into a static the suite actually drives. Both
  re-injected and confirmed failing afterwards.
