# Project agent memory

This file is the project's committed home for **standing rules** - the
invariants, conventions and sharp edges that apply to almost any change in this
repository. `CLAUDE.md` imports it, so every line here is paid for by every
agent session: keep it to what a session needs *before* it reads any code.

**The per-feature history lives in [`docs/history/`](docs/history/), and is not
imported.** Read the one file for the area you are touching. That is where "what
shipped, what was tried, what replaced it" is recorded - including every
measurement, every reverted approach and every captain decision behind the rules
below. Nothing was deleted in that split; it was relocated.

When you add something here, ask which of the two it is. A rule that will still
be true after the next three features is a standing rule. An account of what one
branch did is history.

**About 180 source comments point at this file by section name** ("AGENTS.md's
`Shift` section", "AGENTS.md gotcha (12)", "AGENTS.md's 'Verifying native UI
bugs' convention"). The gotcha numbers and the convention names still resolve
here unchanged; a pointer at a *feature* section now resolves one hop further
on, through the [feature index](#feature-index) at the bottom. They were left
as they are rather than rewritten across 180 files.

---

## Contents

- [Working in this repository](#working-in-this-repository) - worktrees, the shared stash, the shared working tree
- [Build, run, test](#build-run-test) - the two CI lanes, and the vendored patches a sync must re-apply
- [Verification conventions](#verification-conventions) - how a change is proved here
- [Writing a self-test](#writing-a-self-test)
- [The AppKit gotcha catalogue](#the-appkit-gotcha-catalogue) - 17 measured traps
- [GL invariants](#gl-invariants) - GL-01 .. GL-38, one line each
- [The component index](#the-component-index) - one button, one card, one row
- [Stores, subprocesses and secrets](#stores-subprocesses-and-secrets)
- [Feature index](#feature-index) - which history file to read
- [Maintaining this file](#maintaining-this-file)

---

## Working in this repository

### Never launch a built copy from a worktree

Every build of this app - a `swift run` binary, `.build/debug/FirstmateCockpit`,
and the packaged `dist/Manjesh Grand Line.app` - shares one bundle identity
(`com.firstmate.cockpit.native`). There is no OS-level process isolation between
them, so a copy launched from a worktree contends with the captain's own running
instance over the same JSON stores and the same git working tree.

Verify with `swift build` plus the self-test suites. If you genuinely need a
composited window, `native/Scripts/build-probe-app.sh` builds a
separately-identified copy (its own bundle id, its own instance lock, its own
scratch stores) that is safe to launch alongside the real app. Never
`swift run`, and never open the assembled `.app`.

### Never `git stash` in a task worktree

**Every task worktree shares one `.git` directory, and therefore one stash stack.** `git stash` /
`git stash pop` are repository-global, not worktree-local: a `pop` here can apply - and then
**drop** - a *sibling crewmate's* in-flight WIP, while your own stash silently stays behind on the
stack. This is not theoretical; it happened during
`fm/grandline-text-selection-contrast-audit`, which stashed to take a clean baseline measurement
and got back a different branch's half-finished feature
(`fm/grandline-topnav-clicked-state-visibility-fix`) in its own working tree - and independently,
while verifying the other side of the same collision, `fm/grandline-topnav-clicked-state-
visibility-fix` found its own stash entry had picked up a garbled, cross-contaminated message from
that same concurrently-running sibling task.

Recovery, if it happens again: the dropped stash commit is still in the object database, so
`git fsck --unreachable` plus `git log -1 --format=%s <commit>` finds both stashes by their
`WIP on <branch>` message, `git stash store -m "..." <their-commit>` puts the other crewmate's
entry back on the stack, and `git checkout <your-commit> -- .` restores yours. A worktree pool's
other slots (`git worktree list`) may also still hold an unaffected copy of whatever a naive full
revert would otherwise destroy - diff and manually reconcile file-by-file (`git apply`/
`git checkout <ref> -- <path>` on individually-confirmed-safe paths) rather than blindly resolving
via a second `stash pop`/`stash drop`, since a second blind pop can just as easily grab the wrong
entry again.

**To take a clean baseline instead**, use a mechanism that touches no shared ref:
`git checkout HEAD -- .` (your own changes are recoverable from `git diff > file.patch` taken
first, or from a commit on your branch). Never reach for `git stash`.

### Never `pkill -f` a build or test command

`pgrep`/`pkill -f` match **every process on the machine**, and several task
worktrees run concurrently out of one treehouse pool - so
`pkill -f "run-all-tests.sh"` kills whichever lanes happen to be testing, not
just yours. That is not hypothetical: `fm/grandline-sudo-touchid-disable`
killed worktree 3's suite run that way while trying to clear its own.

Identify before you kill: `lsof -p <pid> | awk '$4=="cwd"{print $NF}'` gives the
worktree a process is actually running in. Kill by pid, and only after
confirming that pid's cwd is your own worktree.

The same sharing is why this file's own rule against running two
`./Scripts/run-all-tests.sh` passes concurrently is not just about *your* two
passes: a sibling lane's pass counts, and `pgrep -fl "run-all-tests"` is the
cheap way to find out before starting one.


### The working tree itself is shared, not just the stash

Two agents given the **same** treehouse slot share one working tree, so an
uncommitted file one of them leaves behind is in the other's build. Reproduced
live during full review #3: a temporary `SelfTests/Review3RenderProbe.swift`
left in the tree by one agent made the other's `swift build` fail with two
compile errors against current APIs, and made `E2ETestingPolicySelfTest` fail
the full suite by name. Neither agent had changed anything the other could see
in `git log`.

**Pre-flight before any build or test run: `git status --porcelain` must be
empty** (or contain only your own work, and you must know which lines are
yours). A build that fails on a file you did not write is this, not your change.

    git status --porcelain            # must be empty, or all yours
    git worktree list                 # who else is in this pool
    pgrep -fl run-all-tests           # is a sibling lane mid-run?

The same sharing is why the theme-leak note below matters across lanes, and why
`run-all-tests.sh` must not be run twice concurrently. Allocating one slot per
agent is a firstmate dispatch concern and not something this repository can
enforce; the pre-flight is.

**A third instance of the same class: bash re-reads a script from disk as it
executes.** Editing `Scripts/run-all-tests.sh` while a run is in flight corrupts
that run part-way through - measured, a full run died at the Python-suite
section with a syntax error at a line number that did not exist when it started.
Finish the run, or copy the script aside first.

### The self-test suite is not hermetic

**The self-test suite is not hermetic, and an interrupted run poisons every
later run on any tree - this cost real time before it was root-caused, so read
it before chasing a "flaky" suite.** `run-all-tests.sh` runs each suite as a
separate process against the **real** `FirstmateCockpit` `UserDefaults` domain
(the unbundled binary has no bundle id, so that is its domain).
`AppShellBodyWidthSelfTest.withScratchEnv` carefully isolated every FM_* *file*
override but not `UserDefaults`, and mounting a real `AppShellController`
writes there - measured, it left `fm.themeID = dusk` behind. Every suite that
ran afterwards then measured theme-derived geometry under an ambient theme
nobody selected, so `FM_RUN_CONTRAST_TESTS` and
`FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` failed **intermittently on a clean tree**
- reproduced at `main` with a freshly-cleared domain (1 failure), while each
suite passed standalone. Worse, the leak is *persistent*: a run killed before
the restore leaves the domain dirty and every subsequent run of every suite
fails until it is cleared by hand. `withScratchEnv` now saves and restores
`ThemeManager.shared.theme` and `AppSettings.shared.fontSize` (fixed at the
*test*, not the write site - persisting the selection is correct behaviour for
the app).

**Two more suites merged onto `main` the same day reintroduced it immediately**
- `TopNavPillPressedStateSelfTest` (leaked `dusk`) and
`UpdatesRefreshButtonThemeSelfTest` (`catppuccin-latte`), both calling
`setTheme` with no save/restore at all - which is why this is now a **guard**
rather than a convention: `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`
fails the run if any file in `SelfTests/` calls `ThemeManager.shared.setTheme`
without also capturing `ThemeManager.shared.theme` (a necessary condition - you
cannot restore what you never read - which caught all four real instances and
cannot false-positive on a suite that does save). Confirmed to catch the
regression by name. Full suite 3/3 clean afterwards with no leak, where the
same tree had been intermittently red.

**If a suite starts failing for no reason, check `defaults read
FirstmateCockpit` before suspecting the code.**

**A second, newly-discovered way to poison it: never run two
`./Scripts/run-all-tests.sh` passes concurrently.** Each pass saves and
restores `fm.themeID` around the suites that change it, so two overlapping
passes interleave those save/restores and one restores the *other's* value -
`fm/grandline-audit-energy-fixes` hit exactly this (a full run overlapping a
second one left `fm.themeID = dusk` against a real `helm-dark`, and
`FM_RUN_CONTRAST_TESTS` failed on a tree whose own standalone run passed). The
save/restore is per-pass and cannot defend against a sibling pass; run them one
at a time.

**The same applies to a temporary *probe*, which the source guard cannot see**:
`fm/grand-line-shell-selection-investigate-fix` hit this a fifth time - a
reverted probe that swept themes through the real
`ThemeManager.shared.setTheme` without restoring left `fm.themeID` behind, and
the very next full run failed exactly `FM_RUN_CONTRAST_TESTS` and
`FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` while both passed standalone. Restoring
the key made the identical tree green (86 passed, 0 failed). Save and restore
the theme in any probe that changes it, and re-run the suite from a known-clean
`fm.themeID` before believing a red result.

**And the inverse direction exists too, which every note above would lead you
to rule out: `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` passes inside
`run-all-tests.sh` and fails when invoked standalone**, with "the terminal
never laid out ((0.0, 0.0, 0.0, 0.0)) - the frame check would be vacuous" -
i.e. its own vacuity guard, not a colour assertion. Reproduced by
`fm/grandline-sudo-touchid-disable` under both `dusk` and `helm-dark`, so it is
not the ambient-theme mechanism, and **confirmed pre-existing** by checking the
four files that branch changed back out to `HEAD~1`, rebuilding and reproducing
it identically. Whatever the runner supplies that a bare `env FM_RUN_...=1
.build/debug/FirstmateCockpit` does not was not chased further. The practical
rule: for a **window-backed** suite, the runner is the authority - a standalone
red is not by itself evidence you broke something, and the cheap disambiguation
is to revert your own changed files to `HEAD~1`, rebuild, and see whether it
still fails.

#### An interrupted run cannot be fixed by a `defer`

**A `defer`-based restore does not run when the process dies by signal** (P4 of
full review #3). A SIGSEGV in a probe left `fm.themeID` on `catppuccin-latte`
with no `defer` ever firing, and the runner's own SIGKILL at `FM_SUITE_TIMEOUT`
does the same. Reproduced deliberately: a real suite process killed 0.4s in left
the domain on `helm-dark` against a real `dusk`.

A signal handler cannot close this - `UserDefaults` and Foundation are not
async-signal-safe, and SIGKILL cannot be handled at all. `SelfTestDefaultsGuard`
(in `SelfTests/`, armed once per process from `main.swift`'s own
`#if FM_SELFTESTS` block, beside the store redirects) does it with a **sidecar
file** instead: it records the domain's starting values before the first suite
runs, `atexit` removes that file on any ordinary exit, and a file still present
at the start of the *next* run is proof the previous one was interrupted - so
that run restores from it and says so out loud.

The honest limit: the dirt is cleaned up one run late. What the guard buys is
that it can never outlive one further run, and that the run which cleans it up
announces it, rather than the captain finding it by hand - which is how it was
found the first two times.

If a suite ever starts failing for no reason, check the domain by hand first:

    defaults read FirstmateCockpit fm.themeID     # the self-test domain
    defaults read com.firstmate.cockpit.native    # the real app's domain

They are different domains. The unbundled binary has no bundle identifier, so
its `UserDefaults` land in `FirstmateCockpit`; reading the wrong one is how one
investigation came to test a theme the captain was not using.

---

## Build, run, test

`native/` is the only app in this repo. Command Line Tools are enough - this
uses `swift build` / `swift run`, never Xcode or `xcodebuild`.

    cd native
    swift build                         # first build ~90s (vendored SwiftTerm)
    ./Scripts/run-all-tests.sh          # build, then every suite, with timings
    ./Scripts/run-all-tests.sh --list   # what would run
    ./Scripts/run-all-tests.sh --ci     # the headless-safe half (what CI blocks on)
    ./Scripts/run-all-tests.sh --session-only   # the exact complement

`native/README.md` is the front door for anything more (packaging, the local
signing identity, the probe app, the destination map). The repo-root `README.md`
carries the complete `FM_*` environment-variable index.

**Pre-flight for a full run**, in this order: `git status --porcelain` empty,
no sibling `run-all-tests.sh` running, and `fm.themeID` at a known value
(`dusk` is the documented one). All three are described above.

### Toolchain

Local development is on **Swift 6.x**; CI pins `macos-15` and asserts the same
major in every job that builds (`EXPECTED_SWIFT_MAJOR` in
`.github/workflows/ci.yml`). This matters because the `build` job fails on
**any** warning in `Sources/FirstmateCockpit`, and the compilers genuinely
disagree in both directions - a 6.x-only `#ImplicitStrongCapture` set that 5.10
does not emit, and a 5.10-only redundant-downcast warning that 6.x does not. A
warning-clean build says nothing about the other compiler. Bump the image label,
the assertion and `native/README.md`'s Requirements together.

### Vendored dependencies carry patches, and a sync must re-apply them

Everything under `native/Vendor/` is committed source, not a remote package -
there are no remote SPM dependencies and no `Package.resolved`. `SwiftTerm`
carries **five local patches**, each because the thing it fixes has no
`public`/`open` seam upstream, so a re-sync is a five-patch re-apply and the
realistic failure is a hunk lost in a merge rather than a deliberate removal.
Every one of those then fails *silently*, in a way this project has already
paid for once each.

- The pin, the per-patch verdict against the current upstream, the re-apply
  table and the four-command upstream check live in
  `native/Vendor/SwiftTerm/README.md`. **Read it before touching or bumping
  that tree**, and record the result of a check even when the answer is "stay
  pinned".
- The standing decision is **stay pinned and re-check on a schedule** (183
  days, tracked in `native/MANUAL-CHECKS.md`). A newer tag on its own is not a
  reason to bump; an upstream security fix, or a patch's root cause being fixed
  or gaining a hook upstream, is.
- `FM_RUN_VENDORED_PATCHES_TESTS` asserts all five patches are still present, so
  a sync that drops one fails by name. It matches its markers with comments
  stripped, because a merge that drops the code under a doc comment leaves the
  comment - and the comment names the symbol.

### The two CI lanes

Both are blocking. `test` runs the headless-safe suites; `test-windowed` runs
the ones that mount a real `NSWindow`. The split lives in `NEEDS_SESSION` in
`Scripts/run-all-tests.sh` and nowhere else, and `E2ETestingPolicySelfTest`
enforces **both** directions of it. A suite that a runner genuinely cannot
support belongs in `CI_UNSUPPORTED`, with the measurement that put it there.

---

## Verification conventions

These are the house rules for proving a change. Nearly every entry in
`docs/history/` closes with the same shape, and a PR that does not is unusual
enough to explain itself.

- **A test must be confirmed to catch a real regression, not merely to pass.**
  Revert the fix, watch the named case fail, restore it. Say which injection
  failed which case.
- **Inject by copying the file aside and editing it - never `git stash`, and
  never `git checkout -- <file>` on a branch with no commits yet** (that
  discards the whole task's work on that file, not just the experiment).
  Restore several edits to one file in **reverse** order, then re-read it.
- **A check that cannot fail is worse than no check.** Assert the fixture's own
  discriminating power first - that the numbers really differ, that the element
  really is off-screen, that the string really was present - so a drifted
  fixture fails loudly instead of passing vacuously.
- **Assert what is painted, not what was computed.** A model-level assertion is
  blind to a signal that never reaches the view; re-deriving an expected value
  from the function under test asserts nothing at all.
- **No key equivalent may be declared twice in `NSApp.mainMenu`.** AppKit
  resolves a chord to the first *enabled* match in menu order and this app
  implements no `validateMenuItem`, so a duplicate silently makes one of the
  two items permanently dead - it shipped once as H3 (two ⌘N items) and was
  found by a captain. `NavigationCoherenceSelfTest` now fails the run on any
  duplicate, so a new menu item with a taken chord fails by name.
- **A behavioural check and a source guard catch different things**, and several
  fixes here need both: the behaviour can be right while the call site that
  reaches it is deleted, and a source guard can pass while the mechanism is
  broken. When only one is possible, say which.
- **State what was not verified.** "Verified by `swift build` only", "not
  reproducible in this sandbox", "the live half is the captain's own check" are
  all acceptable; implying a check that did not happen is not.

### Verifying native UI bugs without a real screenshot

- **Verifying native UI bugs without a real screenshot.** This machine has a
  real console session, but the agent's shell process (`claude` under WezTerm)
  has neither Screen Recording nor Accessibility permission granted, and there
  is no way to grant either non-interactively (`screencapture`/`osascript
  "System Events"` both fail, TCC.db is SIP-protected even to root, no
  passwordless sudo). The effective substitute that actually caught real bugs
  (fixes4): add temporary, env-var-gated debug code straight into the
  controller under test - print live `NSView.frame` geometry after a real
  layout pass, or a `Thread.callStackSymbols` dump inside a suspect delegate
  callback - `swift build && FM_DEBUG_X=1 .build/debug/FirstmateCockpit`, read
  the printed numbers/stack, then revert the instrumentation before committing.
  This is real evidence from AppKit's actual layout/event engine, not a
  screenshot, but it is not guesswork either - say so explicitly in any PR that
  relies on it instead of claiming a visual check that didn't happen. **One
  hard-won rule for any probe that pixel-samples a render**
  (`fm/grandline-design-system-phase2`): compare the sampled pixel against the
  expected colour **in `rep.colorSpace`**, never via
  `colorAt(...).usingColorSpace(.sRGB)`. `bitmapImageRepForCachingDisplay`
  returns a rep in the *display's* profile ("Color LCD" on this machine) when
  the view is inside a real `NSWindow`, and Generic RGB when it is not - and
  the sRGB conversion is only correct in the second case. In a window it
  reported `0.286/0.484/0.575` for a pixel genuinely holding the theme accent's
  `0.157/0.412/0.514`, which reads exactly like a real colour bug; converting
  the *expected* colour into `rep.colorSpace` first matched to 0.002. A probe
  that samples a view rendered standalone (no window) will pass with the sRGB
  conversion and then mislead the moment someone renders the same view inside a
  window, so use the rep's own space unconditionally.

**Two probe rules that cost real time here.**

- `cacheDisplay` / `bitmapImageRepForCachingDisplay` is this repo's screenshot
  substitute, and it does **not** capture `WKWebView` content, draws an
  `alphaValue = 0` view *visibly*, and renders a `TerminalView` as blank in a
  window that was never ordered front. Use `WKWebView.takeSnapshot` for a web
  island, read the alpha rather than looking for a hidden view, and order the
  probe window in.
- A probe that changes the theme must save and restore `fm.themeID`; see the
  hermeticity note above. A probe that renders to a file should write to the
  session scratchpad and be read back with `Read`, which is a plain file read
  rather than a screen capture.

---

## Writing a self-test

A suite is **window-backed or pure logic**, and the choice is not a style
preference: it decides whether the suite guards the **blocking** CI job or only
ever runs locally. Getting it wrong costs real coverage silently, because a
misclassified suite still passes.

- **The classification decides whether a suite guards the blocking CI job at
  all, which is why getting it wrong is silent.** `NEEDS_SESSION` in
  `Scripts/run-all-tests.sh` is the operative list: `--ci` skips it,
  `--session-only` runs exactly it (CI's *non-blocking* windowed job). So a
  pure-logic suite parked there still runs locally, still passes, still looks
  healthy - and never once guards a merge. Nothing about that is visible in a
  diff, a review or the suite's own output, which is precisely why it
  accumulated.
- **The test is what the suite *asserts*, never what it imports.** Real
  hover/press/focus-ring behaviour, real rendered geometry or pixels, a real
  `NSPanel`/`NSPopover`/sheet/`NSStatusItem`/drag session, real window-server
  visibility - those need a session. A pure function, a parser, a state
  machine, a source guard, a real-file or subprocess round trip does not.
  **Needing `AppKit` is not the test**: offscreen `NSImage` work (`lockFocus`
  into an image's own bitmap cache) and pure geometry maths need no window
  server, and two of the three suites this audit reclassified declared "pure
  logic, no window/view hierarchy" in their own headers while sitting in
  `NEEDS_SESSION`.
- **When one feature needs both halves, split the file** rather than dragging the cheap half out of CI - `FM_RUN_WHITEBOARD_TESTS`/`..._VIEW_TESTS` and `FM_RUN_CREDENTIAL_VAULT_TESTS`/`..._VIEW_TESTS` are the model, and several suite headers already state that reasoning.

The one thing that makes a suite window-backed *operationally* is being listed
in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`, and
`E2ETestingPolicySelfTest` enforces **both** directions: a suite that builds a
window and is not listed fails, and a suite that is listed and builds no window
fails unless its entry carries a trailing marker.

- **`# session-not-window: <why>` is the one escape hatch**, a trailing marker
  on the entry's own line in the array. Per-entry with a stated reason,
  deliberately not a blanket allowlist - the same shape as
  `OffScreenProbe-exempt:` in the same file, and for the same reason: the
  legitimate cases are a couple of suites whose *controller* builds a real
  `NSPanel` (`UnifiedSearchLayoutSelfTest`, `AuditSecurityLockSelfTest`), not a
  standing licence for a file. **`mountsAWindow`'s marker
  (`OffScreenProbe.window(` / `NSWindow(contentRect`) cannot see a window a
  controller builds internally**, which is exactly what the escape hatch is
  for; widening that marker to guess at panels would misfile suites in the
  other direction.



### Conventions every suite here follows

- Live in `SelfTests/`, wrapped in `#if FM_SELFTESTS` (GL-27). A suite is
  compiled into debug builds only, so **always test against
  `.build/debug/FirstmateCockpit`** - a release binary runs zero suites and
  exits 0, which looks exactly like a clean run.
- Get an `NSWindow` from `OffScreenProbe.window(...)`, never by hand; see that
  file's header for the measurements (a hand-rolled one is *not* off-screen,
  whatever origin it is given, and these were caught live on the captain's
  display).
- Use the shared assertion helpers in `SelfTestAssertions.swift` rather than a
  local `check`/`fail` pair. The free `check(_:_:_:)`/`fail(_:_:)` match the
  signatures the hand-rolled copies used, so a suite needs no adapter at all
  unless its helper is nested inside a case function and captures that
  function's own accumulator - which is the one thing a free function cannot
  do, and the reason an adapter is allowed. What is banned is a *copy*, and
  `E2ETestingPolicySelfTest.checkSuitesUseTheSharedAssertions` enforces it: a
  `check`/`fail` helper in that directory whose body does not reach
  `SelfTestAssertions` fails the run. A helper that genuinely owns a
  comparison (a tolerance, a numeric expectation) is fine - only its
  *reporting* has to go through the shared prefixes.
- Never touch real captain data. Point every store at a scratch path; the
  `#if FM_SELFTESTS` block in `main.swift` is the backstop that covers a store
  reachable from a bare production constructor, and a new such store needs an
  entry there **before** its first suite.
- A suite that greps the app's own sources must resolve its root through
  `SelfTestSources.appSourceDirectory()`, and must skip loudly when it cannot
  find its sentinel - every such guard silently passes otherwise.
- **`NSApp` is nil in a headless suite**, and it is an implicitly-unwrapped
  `NSApplication!` - so reading `NSApp.mainMenu` (or anything else on it)
  *crashes* rather than failing, which reads as a broken suite rather than a
  broken assertion. Nothing calls `NSApplication.shared` in a `FM_RUN_*` block.
  Where a suite needs something the app normally installs on `NSApp`, give the
  producer a "build it but do not install it" seam and assert the product -
  `AppDelegate.buildMenu(installing:)` is the worked example, and it is what
  lets the menu bar's own shape be asserted from CI's *blocking* lane.
- **`autoreleasepool` is mandatory** around any repeated AppKit
  construct/teardown loop in a headless suite: nothing turns the run loop, so
  removed views are never drained and a perfectly healthy view reads as a leak.
  A one-shot baseline capture needs it too.
- **`HelmContrast.ratio(a, b) < 1.01` is not a colour-equality check** - it
  compares relative *luminance*, so two different hues of similar brightness
  pass it. Compare `HelmContrast.components` element-wise.
- A GitHub runner has **Reduce Motion ON** and always-visible scrollbars. Pin
  `HelmMotion.reducedOverrideForTests` rather than inheriting the host's
  setting, and do not assert a pixel width that a scroller track can move.

---

## The AppKit gotcha catalogue

Seventeen traps, every one measured on this app rather than read about. Each was
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

---

## GL invariants

`GL-01` .. `GL-38` are the findings of the production-readiness review, and
they are cited by number throughout the sources and the history files. One line
each; the full reasoning, measurement and the fix that established it are in
[`docs/history/26-production-readiness.md`](docs/history/26-production-readiness.md).

| # | The rule |
|---|---|
| GL-01 | "File missing" and "file present but unreadable" are different states. Back an undecodable file up before the next write, and never let a failed read look like an empty store. A new `Codable` field needs `decodeIfPresent` with a default, or it makes every existing file undecodable. |
| GL-02 | One subprocess runner (`Subprocess.swift`). Drain stdout and stderr **concurrently** - draining one then the other still deadlocks on a child that fills the other - and bound every run. |
| GL-03 | A latch guarding a background pass needs a wall-clock watchdog *and* a pass id, or one hung child silences the signal for the session. |
| GL-04 | Reach a subprocess through `Subprocess.runAsync` rather than blocking a caller that is on the main thread or on someone else's callback. |
| GL-05 | One instance, three layers: `LSMultipleInstancesProhibited`, an `NSRunningApplication` check (whose pid must be verified alive - it reports dead pids for ~15 minutes), and an advisory `flock`. `SingleInstanceGuard.acquire()` runs after every `FM_RUN_*` block, never before. |
| GL-06 | One confirmation prompt for an irreversible delete: `DestructiveConfirm`. |
| GL-07 | CI runs on every push and PR, and fails on any warning in this app's own sources. |
| GL-08 | `--` goes before the destination in every `ssh` argv, and a leading `-` is rejected at save, at import and at quick-connect. A tampered `.glbackup` is the delivery vector. |
| GL-09 | Anything that runs while the main window is not frontmost **and** shows or writes the captain's data consults `AppLockGate`. Add an `AppLockedSurface` case; never reuse a related one - a test asserting the neighbour passes with your gate deleted. |
| GL-10 | No silent `try?` on a persistence write. `try` at the write, `report` at the store, through `PersistenceFailureReporter`. |
| GL-11 | Log before degrading. `os.Logger` through `AppLog`, one subsystem, categories per area, nothing leaving the machine. |
| GL-12 | Nothing synchronous and slow on the main thread before the window exists - a launch-path subprocess is a pre-window beachball. |
| GL-13 | Background work stops when nobody can see it: a poller gated on visibility, on `AppActivityState`, or both. `beginActivity` opts out of App Nap without `.idleSystemSleepDisabled`. |
| GL-14 | **Unknown is never rendered as zero.** A failed fetch and an empty result are different states and must read differently. This is the most-cited rule in the file. |
| GL-15 | A secret travels in a subprocess's environment, never in argv - `ps` shows argv. `Subprocess.gitAuthEnvironment` is the one copy of the git token injection. |
| GL-16 | Accessibility: a clickable row is a `HoverHighlightView` (which supplies the role, the label, the focus ring and the keyboard press), every focusable view draws a real `.exterior` ring, and every looping animation is gated on Reduce Motion through `HelmMotion`. |
| GL-17 | The App menu carries the standard system-visibility trio (Hide / Hide Others / Show All) and Services. |
| GL-18 | The version comes from `git describe`, never a constant. A release is cut by tagging. |
| GL-19 | `run-all-tests.sh` discovers its suite list from `main.swift`, so a new suite joins automatically and the script cannot drift. |
| GL-20 | A global resize handler does a cheap staleness check first and only then pays for a layout pass - not a debounce, which breaks the synchronous guarantee the repair exists for. |
| GL-21 | "The directory could not be enumerated" is not "the directory is empty". A seeder that conflates them overwrites real data. |
| GL-22 | `ConfigRepoPrivacy` asserts the config repo is private before any push. `.unknown` never blocks; only a confirmed public repo refuses. |
| GL-23 | A store that **caches** gets one shared instance. Two caching copies of one file diverge in-session and race each other's writes. (A store that re-reads disk per call may be constructed freely.) |
| GL-24 | A theme observer **repaints - it never fetches.** |
| GL-25 | A Keychain read that can prompt for Touch ID runs off the main thread, and a cancel aborts the operation rather than silently falling through to a weaker credential. |
| GL-26 | One `claude -p` runner: `ClaudeOneShot`. Every caller is bounded, parses one envelope, and calls back on main exactly once. |
| GL-27 | The suites are compiled into **debug builds only**. `SelfTests/` + `#if FM_SELFTESTS`, and every `debug*` accessor in a production file needs the same guard. |
| GL-28 | State written on a background queue and read on main lives behind a lock - including an enum with a `String` payload, where the failure is a torn read rather than a stale one. |
| GL-29 | The high-risk subsystems have named suites of their own, each confirmed to catch a regression. |
| GL-30 | Modal for a blocked decision, toast for a transient confirmation, Notification Center for anything still true after the toast fades. Writes go through `AtomicWrite`. |
| GL-31 | First run is threaded: a machine with no resolvable firstmate home lands on Setup rather than on an empty dashboard. |
| GL-32 | Chrome text scale: every size goes through `HelmType.scaled`, floored at `minimumUIPointSize` (11), and a fixed table `rowHeight` must follow it via `HelmType.scaledRowHeight` and be re-read in `applyTheme`. |
| GL-33 | An undo restores the value the caller already had in hand. One toast slot; a newer pill supersedes the older by committing it. Where a real restore is impossible, offer no Undo rather than a pretend one. |
| GL-34 | A bridge that polls a terminal reads the **viewport**, not the whole buffer, with a full scan only every N ticks. |
| GL-35 | Nothing unbounded: caps on histories and logs, pruning for scratch clones, memoisation for a read that is O(files) per row. |
| GL-36 | A controller that has outgrown its seams is split along its own `// MARK:` boundaries. Swift's `private` is file-scoped, so treat such a family as private to itself. |
| GL-37 | Destinations mount **lazily** through `DestinationRegistry`'s one table. A mounted slot is only ever hidden, never torn down. Adding a destination is one enum case plus one `register(...)` line. |
| GL-38 | The merge action passes the task id. The argv shape is asserted, because nothing else can see it.

---

## The component index

This app applied "one component, not N copies" relentlessly. Reach for the
existing one; a hand-rolled second copy is the single most common finding in
this repository's own audits. Every entry's history is in
[`docs/history/04-design-system.md`](docs/history/04-design-system.md) unless
noted.

| Reach for | Instead of |
|---|---|
| `HelmButton` (`.primary` / `.secondary` / `.quiet` / `.destructive`) | any stock `NSButton` bezel - a source guard fails the build on one. A page must not set `font`, `attributedTitle`, `contentTintColor` or `isBordered` on one; `restyle()` owns all four. |
| `HelmPopUpButton` | a stock `NSPopUpButton` |
| `HelmCard` + `HelmCard.applyCardSurface` | a hand-rolled rounded background view |
| `HelmAccentRow` | a hand-rolled alert/record row (accent bar, badge, kicker, body, chip) |
| `ToolRowLayout` | a hand-rolled dense checklist row (fixed columns, actions, chevron, expandable log) |
| `HelmStatTile`, `HelmEmptyState`, `HelmSegmentedTabs`, `HelmPlateCard`, `HelmModuleCard` | four, two, three and two prior copies respectively |
| `HelmField` / `HelmTextField` / `HelmTextView` / `HelmSearchField` / `HelmChipInput` / `HelmDateField` / `HelmToggle` | a raw `NSTextField()`, `NSSearchField()`, `NSDatePicker` or `NSSwitch` - source-guarded |
| `HelmFormSheet` | a hand-built editor sheet |
| `HelmConfirm` | an `NSAlert`, **except** where a command or binary is about to execute outside this app's control (the risk gates, the herdr restart, `beginSheetModal`) |
| `Feedback.report(_:kind:persistence:in:)` | deciding at the call site whether something is a toast or a bell entry. State whether it is **still true after a toast would have faded** (GL-30's own dividing line) and let it route; pair a `.lasting` report with `Feedback.clear(id:)` on the path that resolves it. A blocked *decision* is still `HelmConfirm`/`DestructiveConfirm` - it needs an answer, so it needs a return path |
| `HelmPageSidebar`, `HelmPageToolbar`, `HelmResponsiveGrid`, `HelmDrillHeader`, `HelmRefreshPill`, `HelmBarPanel`, `HelmSkeletonRow` | a per-page reimplementation of each |
| `HelmCountBadge` | a bare number in a card header's action slot |
| `HelmType` roles | a literal `systemFont(ofSize:)`; `HelmMetrics` for spacing and radii |
| `HelmMotion` | a direct `accessibilityDisplayShouldReduceMotion` read - source-guarded |
| `OffScreenProbe.window(...)` | `NSWindow(contentRect:)` in a suite - source-guarded |
| `SelfTestAssertions` | a local `check`/`fail` pair in a suite - source-guarded |

### Colour and theming rules

- **A `HelmTint` hue is safe as a fill or a bar, and is NOT automatically safe
  as text.** Route any tinted label through `HelmContrast.tintedSurface` /
  `legibleTintedText` / `legibleOn`. `FM_RUN_CONTRAST_TESTS` sweeps every theme
  x every tint and fails the build below the floor.
- **Every theme-aware view follows `ThemeManager.swift`'s own checklist**, and
  its item 2 is the one most often missed: force `view.appearance` to the
  theme's light/dark mode. Without it the layer-backed fills track the theme
  while everything resolving a *system semantic* colour - scroller chrome, the
  shared field editor, an `NSMenu`, a focus ring - follows the OS instead. That
  is the "half-themed" defect, and it shipped four separate times.
- **`ThemeManager.observe`'s closure fires synchronously at registration**, so
  it runs before the rest of `loadView` has built anything. A repaint function
  with an early-return cache guard must not consume that cache on the premature
  call; a component that themes itself must do so *after* it builds its chrome.
- **A theme observer repaints; it never fetches** (GL-24), and it must not
  rebuild a page that is not on screen.
- `HelmDomainHue.identityHex` is for identity (it resolves to `.neutral` off the
  Daylight family); `fallbackTint` resolves a *semantic* slot and will paint an
  alert bar on a benign row.
- A Daylight-family restyle branches on `theme.isDaylight` and leaves the other
  twelve palettes byte-identical. Branch **colour and geometry recipes** that
  way - never *structure*: a page whose column count depends on the theme is a
  bug, and shipped as one.

---

## Stores, subprocesses and secrets

- **Every store honours an `FM_*` override** for where it reads and writes; the
  repo-root README has the complete index. A store nested under Shift's data
  root must honour `FM_SHIFT_DIR` as a fallback, not only its own narrow
  variable - and it needs an entry in `main.swift`'s `#if FM_SELFTESTS` redirect
  block, which is the backstop for a store reachable from a bare constructor.
- **A new field on a `Codable` store type needs a hand-written
  `init(from:)` with `decodeIfPresent` and a default** (GL-01). A Swift-side
  default does *not* make a declared key optional to the synthesised decoder,
  and getting this wrong made every existing `hosts.json` undecodable once.
- **Git-backed stores share one working tree and one serial queue**
  (`ShiftGitSync.sharedQueue`). Two queues against one tree race on
  `.git/index.lock`. A terminate-time flush dispatches **onto** that queue with
  a short bound and cancels the pending debounce inside the queue block.
- **Secrets never reach disk or argv.** Private key material and vault
  passphrases live in the Keychain (`ThisDeviceOnly`, never iCloud-synced);
  credential material on a pasteboard goes through
  `CredentialVaultClipboard.writeConcealed`; files that carry connection or
  credential material are written through `AtomicWrite(... sensitive:)`.
- **One subprocess runner and one AI runner**: `Subprocess` (GL-02/03/04/15) and
  `ClaudeOneShot` (GL-26). Do not add a third invocation shape. Interactive and
  PTY work is the terminal's, not theirs.
- **Every `claude -p` run is fail-closed on the built-in tool set.**
  `--allowedTools` is *additive to* `~/.claude/settings.json`'s
  `permissions.allow`, and `--strict-mcp-config` scopes only MCP servers - so
  without `--tools`, the captain's ambient allow rules (which have included
  `Bash(python3 -)`) reach every persona, including the read-only crew, through
  ordinary store text a runbook or task title carries. `ClaudeOneShot` emits
  `--tools` on every run from a parameter defaulting to **none**; a caller that
  needs a built-in names it. Measured: `--tools` gates below permission
  checking and holds even under `--permission-mode bypassPermissions`, which is
  why no runner passes that flag any more.
  `ClaudeOneShotToolPolicySelfTest` guards the argv and the call sites.
- **A store whose file is git-synced must reconcile before it writes.** A pull
  can change the file underneath an in-memory copy, and a whole-file rewrite
  from that copy silently discards whatever arrived. `CredentialVaultStore`
  keeps a decrypted `baseline` - what it believes is also on disk - and
  three-way merges against it in `persist()`, refusing outright when the file
  was re-keyed elsewhere. Audit-only events (a reveal, a copy, a lock) are
  batched and never `markDirty()`: publishing them produces a commit log of
  when each secret was looked at.
- **An AI-authored command is never executed on its stored risk level.**
  `CommandRiskConfirmation.confirmAIAuthored` is unconditional, and a model
  rewriting a template re-derives the level through `heuristicRisk` with
  `raised(to:)`.

---

## Feature index

One file per area, in `docs/history/`. None of them is imported into a session;
open the one you are about to touch. They are chronological, so a later entry
can correct an earlier one - and several do.

| Read | When you are touching |
|---|---|
| [`01-foundations.md`](docs/history/01-foundations.md) | The runtime, `swift build`, the vendored SwiftTerm and its five local patches |
| [`02-console-and-terminal.md`](docs/history/02-console-and-terminal.md) | Console tabs, `CockpitTerminalView`, scrollback, text selection and drag routing, split panes, configurable shortcuts, the Claude-usage popover |
| [`03-navigation-and-chrome.md`](docs/history/03-navigation-and-chrome.md) | The icon rail (removed), the Daylight bar, the menu bar, window chrome fusion, the session switcher, Recents, the canvas |
| [`04-design-system.md`](docs/history/04-design-system.md) | `Helm*` components, the seven-phase UI audit rollout, contrast enforcement, themes, toasts, the later UI-modernization slices |
| [`05-daylight-migration.md`](docs/history/05-daylight-migration.md) | The Daylight/Dusk token layer and its six migration phases |
| [`06-hosts-and-ssh.md`](docs/history/06-hosts-and-ssh.md) | Saved hosts, the SSH keychain, jump hosts and port forwarding, the Hosts page |
| [`07-fleet-and-notifications.md`](docs/history/07-fleet-and-notifications.md) | Overview, the fleet dashboard, the captain's log, the Notification Center, actionable notifications, the morning briefing, replying to the crew |
| [`08-tasks-and-shift.md`](docs/history/08-tasks-and-shift.md) | Tasks (Shift): the data layer, projects, weekly review, the command library, the Kanban board |
| [`09-setup-updates-bootstrap.md`](docs/history/09-setup-updates-bootstrap.md) | Updates, Bootstrap, Automation, GitHub Sync, Schedules, Settings, packaging, backup/restore |
| [`10-docs-and-search.md`](docs/history/10-docs-and-search.md) | The DevOps Playbook viewer, runbooks, postmortems, the unified `⌘K` palette |
| [`11-sre-lead-and-composer.md`](docs/history/11-sre-lead-and-composer.md) | SRE Lead, the shared-terminal bridge, the command composer |
| [`12-tools.md`](docs/history/12-tools.md) | The Tools page and its nine utilities |
| [`13-block-view.md`](docs/history/13-block-view.md) | Block view (OSC 133), still at stage 0 |
| [`14-poneglyph-and-vault.md`](docs/history/14-poneglyph-and-vault.md) | Poneglyph (the credential vault) and Vault (Automic Vault's hardening panel) |
| [`15-app-lock.md`](docs/history/15-app-lock.md) | The app lock, the idle/session timers, the lock screen |
| [`16-dictation.md`](docs/history/16-dictation.md) | Dictation, the hotkey, the HUD, local Whisper |
| [`17-kubernetes.md`](docs/history/17-kubernetes.md) | The context badge, the cluster browser, multi-pod Log Tail |
| [`18-log-analyzer.md`](docs/history/18-log-analyzer.md) | The Log Analyzer |
| [`19-incident-mode.md`](docs/history/19-incident-mode.md) | Incident mode (F8) |
| [`20-whiteboard.md`](docs/history/20-whiteboard.md) | The embedded Excalidraw whiteboard and its DSL |
| [`21-sticky-board.md`](docs/history/21-sticky-board.md) | The Sticky Board |
| [`22-code-preview.md`](docs/history/22-code-preview.md) | The embedded Monaco code preview |
| [`23-straw-hat-pirates.md`](docs/history/23-straw-hat-pirates.md) | The AI crew: the roster, the reply envelope, proposals, MCP tools |
| [`24-window-and-layout.md`](docs/history/24-window-and-layout.md) | The body-width tie and the `contentView` drift - the two repairs behind the "black region" |
| [`25-removed-features.md`](docs/history/25-removed-features.md) | VPN control and local video generation: built, then removed |
| [`26-production-readiness.md`](docs/history/26-production-readiness.md) | The four-phase production-readiness review - where GL-01..GL-38 come from |
| [`27-full-app-audit-1.md`](docs/history/27-full-app-audit-1.md) | The first full-app audit (sections 2-7) and the AppKit-expert audit |
| [`28-full-app-audit-2.md`](docs/history/28-full-app-audit-2.md) | The second full-app audit |
| [`29-end-to-end-review-1.md`](docs/history/29-end-to-end-review-1.md) | End-to-end review #1 (HIGH / MEDIUM / LOW) |
| [`30-full-review-3.md`](docs/history/30-full-review-3.md) | Full review #3 - the eighteen defect findings |
| [`31-testing-policy.md`](docs/history/31-testing-policy.md) | Where the window-backed / pure-logic rule came from, and the audit behind it |
| [`32-notebook.md`](docs/history/32-notebook.md) | The Notebook: the page tree, the reused Monaco editor, the markdown preview, wiki-links and backlinks |

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

**There are now two homes, and the bar above is the test for which one.** This
file grew to 1.69MB / ~422K tokens before P1 of full review #3 split it, and it
got there one reasonable-looking append at a time - three whole sections were
added *after* the paragraph above told everyone not to. So:

- Did your task establish something that will still be true after the next
  three features - a trap, an invariant, a convention, a component nobody
  should hand-roll again? That belongs **here**, rewritten into the section it
  fits, not appended as a new one.
- Is it an account of what your branch did, why, what it measured, what it
  tried first and what it deliberately left out? That belongs in the matching
  `docs/history/` file, and a pointer here only if the pointer itself is a
  standing rule.

When in doubt, write it in `docs/history/` - it is read by whoever touches that
area, and it costs no session that does not.

