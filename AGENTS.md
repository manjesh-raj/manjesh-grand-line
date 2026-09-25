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
- [Build, run, test](#build-run-test) - the two CI lanes, the second (widget) binary, and the vendored patches a sync must re-apply
- [Verification conventions](#verification-conventions) - how a change is proved here, and how much of the suite a PR has to run locally
- [Writing a self-test](#writing-a-self-test)
- [The AppKit gotcha catalogue](#the-appkit-gotcha-catalogue) - 22 measured traps, one rule each
- [GL invariants](#gl-invariants) - GL-01 .. GL-38, one line each
- [The component index](#the-component-index) - one button, one card, one row
- [Stores, subprocesses and secrets](#stores-subprocesses-and-secrets)
- [Feature index](#feature-index) - which history file to read
- [Maintaining this file](#maintaining-this-file)

---

## Working in this repository

### Never launch a built copy from a worktree

Every build of this app - a `swift run` binary, `.build/debug/GrandLine`,
and the packaged `dist/Grand Line.app` - shares one bundle identity
(`com.manjesh.grandline.native`). There is no OS-level process isolation between
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
separate process against the **real** `GrandLine` `UserDefaults` domain
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
GrandLine` before suspecting the code.**

**A second, newly-discovered way to poison it: never run two
`./Scripts/run-all-tests.sh` passes concurrently.** Each pass saves and
restores `fm.themeID` around the suites that change it, so two overlapping
passes interleave those save/restores and one restores the *other's* value -
`fm/grandline-audit-energy-fixes` hit exactly this (a full run overlapping a
second one left `fm.themeID = dusk` against a real `helm-dark`, and
`FM_RUN_CONTRAST_TESTS` failed on a tree whose own standalone run passed). The
save/restore is per-pass and cannot defend against a sibling pass; run them one
at a time.

**And `fm.themeID` is not the only shared thing two concurrent passes fight
over - a *named* `NSPasteboard` is machine-global too.**
`WhiteboardCaptureViewSelfTest` writes to `NSPasteboard(name:
"fm.selftest.capture.lock")` to prove `copyImageTapped` does not reach a
pasteboard while the app is locked. That name is one board per machine, not per
process, so a sibling worktree's pass running the same suite is writing to the
identical board - and the check reads as a real app-lock leak rather than as
two suites sharing a board. Measured in
`fm/grandline-notification-ambient-expand-fix`: exactly that check failed in a
full run that overlapped a sibling pass throughout, and the same suite passed
4/4 standalone on the same tree moments later, with the branch's own diff
nowhere near the whiteboard, the pasteboard or `AppLockGate`. The rule above is
the fix (one pass at a time); the reason to know this one separately is that
the *symptom* names a security guarantee, which is the last thing anyone wants
to write off as flake. Check `pgrep -fl run-all-tests` before believing it.

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
.build/debug/GrandLine` does not was not chased further. The practical
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

    defaults read GrandLine fm.themeID     # the self-test domain
    defaults read com.manjesh.grandline.native    # the real app's domain

(Both were renamed by `fm/grandline-rename-firstmate-cockpit-to-grand-line`;
a machine that has not yet run the renamed build still has its values under
`FirstmateCockpit` and `com.firstmate.cockpit.native`.)

They are different domains. The unbundled binary has no bundle identifier, so
its `UserDefaults` land in `GrandLine`; reading the wrong one is how one
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

**Whether a given change owes a full local run at all** is
["How much of the suite to run before opening a PR"](#how-much-of-the-suite-to-run-before-opening-a-pr),
under Verification conventions. CI's own full run is unconditional either way.

### Toolchain

Local development is on **Swift 6.x**; CI pins `macos-15` and asserts the same
major in every job that builds (`EXPECTED_SWIFT_MAJOR` in
`.github/workflows/ci.yml`). This matters because the `build` job fails on
**any** warning in `Sources/GrandLine`, and the compilers genuinely
disagree in both directions - a 6.x-only `#ImplicitStrongCapture` set that 5.10
does not emit, and a 5.10-only redundant-downcast warning that 6.x does not. A
warning-clean build says nothing about the other compiler. Bump the image label,
the assertion and `native/README.md`'s Requirements together.

**And the divergence is not only about warnings - it reaches hard errors, so a
green local build is not evidence the `build` job will pass.** Measured
(`fm/grand-line-review-bugs-b1-b14`): `carried + legacyIdentifierPrefix +
bare.dropFirst(n)` - a three-term concatenation ending in a `Substring` -
compiled clean on a local 6.3.3 in **both** debug and release, and CI's pinned
image rejected it outright with *"cannot convert value of type
String.SubSequence to expected argument type String"*. Nothing local reproduces
it, which is the point: **convert a `Substring` explicitly** (`String(...)`)
rather than relying on either compiler's overload resolution, and treat a PR's
own CI run as the only authority on whether it builds. `swift build -c release`
is worth running before a push regardless - it is a second CI gate, it catches a
`debug*` accessor referenced outside `#if FM_SELFTESTS`, and it is not what
`./Scripts/run-all-tests.sh` builds.

### Vendored dependencies carry patches, and a sync must re-apply them

Everything under `native/Vendor/` is committed source, not a remote package -
there are no remote SPM dependencies and no `Package.resolved`. `SwiftTerm`
carries **six local patches** - five because the thing each fixes has no
`public`/`open` seam upstream, and a sixth because a warning emitted inside a
vendored file can only be silenced inside it. A re-sync is therefore a six-patch
re-apply, and the realistic failure is a hunk lost in a merge rather than a
deliberate removal. Every one of those then fails *silently*, in a way this
project has already paid for once each.

- The pin, the per-patch verdict against the current upstream, the re-apply
  table and the four-command upstream check live in
  `native/Vendor/SwiftTerm/README.md`. **Read it before touching or bumping
  that tree**, and record the result of a check even when the answer is "stay
  pinned".
- The standing decision is **stay pinned and re-check on a schedule** (183
  days, tracked in `native/MANUAL-CHECKS.md`). A newer tag on its own is not a
  reason to bump; an upstream security fix, or a patch's root cause being fixed
  or gaining a hook upstream, is.
- `FM_RUN_VENDORED_PATCHES_TESTS` asserts all six patches are still present, so
  a sync that drops one fails by name. It matches its markers with comments
  stripped, because a merge that drops the code under a doc comment leaves the
  comment - and the comment names the symbol.

### There is a second binary, and one file is compiled into both

`native/Widgets/GrandLineWidgets/` is a **WidgetKit extension** (F23), and it
is not a SwiftPM target: SwiftPM has no bundle product, so
`Scripts/build-widget-extension.sh` compiles it with `swiftc` and assembles the
`.appex` by hand - the same shape `build_native_app.sh` already uses for the
app. `swift build` does not build it and CI does not either; run
`Scripts/build-widget-extension.sh --check` after touching it.

Three rules follow, and they apply to anything shared with that process:

- **`Sources/GrandLine/WidgetSharedContract.swift` is the only file
  compiled into both binaries**, which is why it imports nothing but
  `Foundation`. Adding an `AppKit`/`Yaml` import to it breaks the extension's
  build, not the app's. The extension cannot link `GrandLine` - the app's
  model types reach AppKit within a line or two of anything useful.
- **A table the extension has to duplicate needs a source guard, not a
  comment.** `WidgetPalette.swift` restates `DaylightTokens`' hexes because it
  cannot import them, and
  `WidgetSnapshotSelfTest.checkThePaletteMatchesDaylight` fails the run if the
  two ever disagree. Same for the App Group id, which lives in the contract and
  in the entitlements file.
- **A loadable `.appex` needs `-application-extension -parse-as-library` plus
  `-Xlinker -e -Xlinker _NSExtensionMain`.** Without the last one the bundle is
  a signed binary with an `_main` no widget host ever calls, and nothing fails
  loudly.

The extension is **blocked on the Developer ID item**, and precisely: a widget
extension is always sandboxed, so reading the App Group container needs
`com.apple.security.application-groups` with a Team-ID-prefixed identifier and
a team-signed binary, and `codesign -dv` reports `TeamIdentifier=not set`. The
*app* half works today (an unsandboxed process may write under
`~/Library/Group Containers/` with no entitlement - measured). See
`native/Widgets/README.md` for the two edits that unblock it.

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
- **A `debug*` hook must enter where the real event enters, not one call
  inside it.** The commonest way a check quietly stops being able to fail here
  is a test-only hook that calls the private helper the wiring reaches, rather
  than the wiring: `NotificationRowView.debugSetHovering` called
  `setActionVisible` directly, so deleting the row's entire `onHoverChange`
  registration left the hover check green - it was asserting the helper, not
  the hook. It drives `HoverHighlightView.mouseEntered`/`mouseExited` now.
  The cheap test is the injection itself: delete the wiring, not the helper,
  and watch the case fail. Same shape as the `debugCommit…()` warning in gotcha
  (19). **The same file then shipped the same mistake again in the same year**:
  `NotificationRowView.debugClickDisclosure()` called `disclosureClicked()`
  rather than the button whose `action` reaches it, and stayed green while an
  ancestor recognizer swallowed every real click on that button (gotcha (20)).
  A hook named after a *click* that does not go through the control is the
  shape to distrust.
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

### How much of the suite to run before opening a PR

`./Scripts/run-all-tests.sh` is every suite in the app (`--list` for the count,
which is over two hundred) and takes 10-15 minutes, and CI then
runs the same suites again on the pushed branch. Paying that twice for a change
whose blast radius is one literal is redundant. So the **local** run before a PR
is scoped by blast radius, and CI's run is not.

- **A narrow, single-purpose, low-blast-radius change may run only the suites
  that cover what it touched.** A literal icon swap on one row, a single colour
  or string constant on one page, a doc-only edit. Run those suites by their own
  `FM_RUN_*` variable against `.build/debug/GrandLine`, and say in the PR
  which ones you ran and why that was the whole relevant set. The full-run
  pre-flight above still applies to whatever you do run: a dirty shared tree and
  a leaked `fm.themeID` break one suite exactly as happily as ninety.
- **Anything cross-cutting runs the full local suite first.** A shared `Helm*`
  or `Daylight*` component, a page's layout or Auto Layout constraints, a store,
  a theme token, `main.swift`, the runner itself, or any behaviour that more
  than one page reads. This is where the full run has already earned its time:
  Settings' category-navigation rebuild was a shared-structure change, and the
  full run is what failed `IntentsBackupSettingsViewSelfTest`,
  `CompactModeViewSelfTest` and `WindowChromeFusionSelfTest` - three suites
  measuring a card or a document height in a view tree that now holds one pane's
  cards instead of all of them
  ([`09-setup-updates-bootstrap.md`](docs/history/09-setup-updates-bootstrap.md)).
  Nobody would have picked those three as "the directly relevant suites" for a
  navigation change. The shared-worktree and theme-leak failures in "Working in
  this repository" are the same shape, and so is most of the gotcha catalogue: a
  change that looked narrower than it was.
- **When the judgment call is close, run the full suite.** The scope decision is
  yours, and fifteen minutes is cheaper than a captain-reported regression.
- **None of this changes CI.** Both lanes still run their full split on every
  push and every PR, unconditionally, for a one-line change and a rewrite alike
  (see "The two CI lanes"). Scoping the local run only decides which failures
  you find before the PR rather than after it; it never decides what gates the
  merge.

### Verifying native UI bugs without a real screenshot

**`screencapture` does NOT work from an agent shell on this machine.**
`screencapture -x` fails with "could not create image from display" - measured
by the 2026-09-25 full-app review and again, independently, by
`fm/grand-line-review-bugs-b1-b14`. A grant this file recorded after
`fm/grandline-settings-black-band-real-fix` has since lapsed (a shell that is
re-signed or relaunched under a different parent loses it), so **check before
relying on it rather than trusting either state written here**: one
`screencapture -x /tmp/x.png` says which machine you are on today. Where it
does work, `screencapture -x -o -l <windowID>` captures one window with alpha
preserved, and `CGWindowListCopyWindowInfo` names every window, its owner and
its layer.

Accessibility is *not* granted either, and the failure mode is worse than an
error: `System Events` answers a window query for another process with `0`
rather than refusing, so a count of zero is not evidence of no window
(measured, `fm/grand-line-review-bugs-b1-b14`). A real `performClick` is still
the substitute for a synthetic click, and `CGWarpMouseCursorPosition` moves the
pointer without it.

So env-gated instrumentation and off-screen renders are the working tools, not
the fallback - but **an off-screen render still cannot prove a pixel is or is
not app-painted**: it has no full-screen Space, no title bar and no menu bar
window, so it structurally cannot reproduce a defect in that region and a clean
diff there proves nothing;
[`24-window-and-layout.md`](docs/history/24-window-and-layout.md) records the
round that cost.

- **Verifying native UI bugs without a real screenshot.** This machine has a
  real console session, but the agent's shell process (`claude` under WezTerm)
  has neither Screen Recording nor Accessibility permission granted, and there
  is no way to grant either non-interactively (`screencapture`/`osascript
  "System Events"` both fail, TCC.db is SIP-protected even to root, no
  passwordless sudo). The effective substitute that actually caught real bugs
  (fixes4): add temporary, env-var-gated debug code straight into the
  controller under test - print live `NSView.frame` geometry after a real
  layout pass, or a `Thread.callStackSymbols` dump inside a suspect delegate
  callback - `swift build && FM_DEBUG_X=1 .build/debug/GrandLine`, read
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
  window, so use the rep's own space unconditionally. **The same rule governs a
  *ratio between two samples*, where the plausible-sounding exemption is
  wrong** - "both operands take the identical transform, so the ratio is
  safe" - and `HelmContrast.ratio`'s `NSColor` overload converts to sRGB
  internally, so taking it is the default rather than a choice. Measured
  (`fm/grandline-settings-sidebar-differentiation-fix`): against a separation
  the tokens put at exactly 1.0800 in every palette, that overload reported
  **1.0597 on Daylight and 1.1305 on Dusk** - the display profile deflating
  every light palette below the floor and inflating every dark one above it,
  which reads as a real colour bug in eight themes and as a comfortable margin
  in seven. Feed the **tuple** overload the rep's raw components instead (the
  same two then measure 1.0753 and 1.0801), leave ~0.01 for the bitmap's 8-bit
  quantisation, and assert the true-sRGB floor separately against the *tokens*,
  where no rep is involved. **And the converse half, which is what makes the
  rule easy to over-apply: convert the *expected* colour and leave the
  *sample* alone.** `NSBitmapImageRep.colorAt(x:y:)` hands back the rep's own
  raw components in an `NSColor` that is *tagged* `Generic RGB` whatever the
  rep's real space is - "Color LCD" for a view inside a real window - so
  `sampled.usingColorSpace(rep.colorSpace)` re-interprets numbers that were
  already right. Measured
  (`fm/grandline-settings-alignment-regression-fix`): one ground pixel read
  `(0.055, 0.063, 0.086)` raw and `(0.067, 0.078, 0.110)` converted, against
  an expected `(0.053, 0.062, 0.088)` - a clean pass turned into a 0.022 miss
  that reads exactly like the unpainted-layer defect the check existed to
  catch.

**A second rule for the same call, and it is the one that bites first:
`bitmapImageRepForCachingDisplay` hands back a rep measured in *pixels*, not
points.** On a retina machine that is a factor of two, so sampling a view's own
point coordinates lands in the top-left quadrant of whatever you rendered.
Measured (`fm/grandline-feature-f2-f3-capture-clipboard`): a check comparing two
tiles of a 600pt panel failed with `delta 0.0000` - two identical *background*
pixels - which reads exactly like a real colour bug. Scale by
`rep.pixelsWide / bounds.width` (and the same for height) before indexing, and
mirror the row for an unflipped view.

**`ImageRenderer` is the substitute when the thing being drawn is SwiftUI
rather than an `NSView`**, and it is a real rasterised render rather than a
preview. `cacheDisplay` has nothing to render for a widget, and the system's
widget host will not load this app's extension until the Developer ID work
lands - so `Scripts/render-widget-previews.sh` compiles the extension's real
view files, renders every state at both widget families' real point sizes, and
writes PNGs the agent reads back with `Read`. It found a real defect on its
first run (F23's medium Sticky widget repeating a kicker on all three notes and
wrapping it). One thing it needs: **`EnvironmentValues.widgetFamily` is
read-only**, so a view that reads it directly can only ever be drawn by a
widget host - keep the environment read in the entry view and pass the family
down as a parameter.

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
  `.build/debug/GrandLine`** - a release binary runs zero suites and
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
- **A live-updating view reads its numbers from one injectable clock on its
  controller, never `Date()` of its own.** Two surfaces rendering the same
  countdown from two `Date()` calls are reading two clocks, and a suite that
  drives a fabricated instant then measures the *real* elapsed time instead -
  which reads as a broken feature rather than as a broken test. Measured on
  F7: the chip and the ring popover each called `Date()`, and the windowed
  suite reported `0:00` on a session that had just started, failing eleven
  checks. `FocusTimerController.clock` plus derived `fraction` /
  `countdownText` accessors is the shape; the views ask the controller.
- **A `"YYYY-MM-DD"` fixture needs `Calendar.current`, not a pinned UTC one** -
  the one place where forcing a fixed time zone makes a suite *wrong* rather
  than hermetic. Task due dates, follow-up dates and sticky timestamps are
  persisted as bare day strings and read back by `ShiftDateFormatting.date(from:)`,
  whose formatter resolves them to **local** midnight, because "due today"
  means today where the captain is. Measured on F22: a UTC fixture calendar put
  every date 5.5 hours on the wrong side of `startOfDay` and reported a task
  due today as overdue - the suite was measuring two calendars rather than the
  feature. Pin the *day* instead, at local noon so no runner's time zone lands
  the fixture on a boundary, and pass the same calendar production passes.
- **`HelmContrast.ratio(a, b) < 1.01` is not a colour-equality check** - it
  compares relative *luminance*, so two different hues of similar brightness
  pass it. Compare `HelmContrast.components` element-wise.
- A GitHub runner has **Reduce Motion ON** and always-visible scrollbars. Pin
  `HelmMotion.reducedOverrideForTests` rather than inheriting the host's
  setting, and do not assert a pixel width that a scroller track can move.
- **A GitHub runner's backing scale factor is 1x, and every dev Mac here is
  2x** - so a frame that lands on a half point is exact locally and *rounds*
  in CI. Auto Layout aligns a frame to the backing store, so a centred view
  whose ideal origin is a half point shifts by up to half a device pixel, and
  the two margins either side of it then differ by a **whole** device pixel:
  0.5pt on a retina Mac, 1.0pt on a runner. A symmetry assertion therefore
  needs `1.0 / window.backingScaleFactor`, never a hard-coded `0.5` - which
  passes 4/4 locally and fails every case in CI, measured
  (`fm/grand-line-settings-page-centering-fix`: Settings' centred column, an
  exact `287.5 / 287.5` here against CI's `288.0 / 287.0`). It is not a bug
  in the layout and there is nothing to round in the app: the visible region
  beside a sidebar is simply an odd number of points wide at even window
  widths. **To reproduce a 1x rounding defect on a 2x machine, add a
  half-point window width** to the fixture (`1512.5`), which pushes the same
  ideal centre off the retina grid; a suite that only tests whole widths
  cannot see this class at all.

---

## The AppKit gotcha catalogue

Twenty-two traps, every one measured on this app rather than read about. Each
was found by instrumenting a real layout or event pass; several took a full task
to root-cause, and at least four have recurred in a new file after being fixed
in an old one. **Read the ones that match what you are about to touch** - a tab
chip, a scroll view, a form, a dense row, or any full-size destination or window
root.

Each entry below is the *rule*. The measurement that established it - the probe,
the numbers, the file it was found in, and in several cases the two or three
wrong fixes tried first - is in
[`47-appkit-gotchas.md`](docs/history/47-appkit-gotchas.md), which holds the
catalogue as it stood before P7 of the 2026-09-25 review split it, verbatim.
**Read that file's entry before changing anything a gotcha governs**; the rule
alone tells you what to do, not why the obvious alternative fails. The numbers
are unchanged, so a source comment citing "AGENTS.md gotcha (12)" still lands
here and then one hop further on.

### (10) `.gravityAreas` is the default distribution and honours no hugging priority

A horizontal `NSStackView` left at its default `.gravityAreas` distribution
ignores its arranged subviews' hugging and compression-resistance priorities
entirely - those only matter under `.fill`/`.fillProportionally`/`.fillEqually`.
Leftover width goes wherever Auto Layout's own tie-breaking puts it, which can
differ between rows and between runs with no code change.

Set `distribution = .fill` **and** give every non-flexible arranged subview
`.required` hugging and compression resistance, leaving only the one view meant
to flex (usually the title/detail text stack) at `.defaultLow`. This has shipped
four times: the Updates row's chevron, Bootstrap's step row, and twice more one
level further in, where the row's *trailing control stack* was itself left at
the default and its first member absorbed all the slack. `SettingsRow` applies
the fix centrally to any control column still at the default - copy that shape
for any component that accepts a caller-built control stack.

### (1) `selectText(nil)` alone starts an edit session - never pair it with `makeFirstResponder`

`selectText(nil)` already makes an editable field first responder and begins
editing. Calling `window.makeFirstResponder(field)` first makes AppKit think a
session is already open, so it ends that one - firing a spurious
`controlTextDidEndEditing` with the *pre-edit* text, which flips an "is
renaming" flag false before the captain types a character. The rename UI looks
fine and the real commit on Return is silently dropped. Never call both.

### (2) `NSGridView`: give the column that must stay narrow the explicit width

Constraining one column and leaving the other free does not make the constrained
one absorb extra width on resize - the **unconstrained** column takes all of it,
because nothing says where it stops. Give the column that must *stay* narrow
(labels) the explicit width, leave the column that must *fill* (fields) free,
and pin the grid's own width to its container so the fill column has a definite
total.

### (3) A standalone window with a required `==` width tie refuses to stay resized

A window with `contentViewController` assigned keeps re-deriving its frame from
its content's fitting size for as long as that content holds a **required
equality** chain with no independent lower bound - not just once at open. A
capped-and-centred form column tied with `stack.width == content.width - 48`
snapped the whole window back to the one width where that equality has zero
slack, within a layout pass, right after a real user resize.

Use inequalities: keep the `<=` cap, position with `leading >=` / `trailing <=`
/ `centerX ==`, never a required width tie. Any standalone window with
Auto-Layout-capped content needs the same shape.

### (4) A scroll view's document view pins to the **clip** view, never the scroll view

`scroll.contentView.widthAnchor`, not `scroll.widthAnchor`. With "Show scroll
bars: Always" a non-overlay scroller reserves a real ~15pt track that narrows
the clip view without narrowing `scroll`'s own frame, so the document view's
trailing edge renders underneath the track. Every scroll-backed page in this app
pins to the clip view now; a new one is the only way this returns.

### (5) Compression resistance in a row: only the text stack may be `.defaultLow`

With every subview at AppKit's default 750, a long title squeezes *everything*
roughly proportionally - including trailing pills and buttons, which are small
containers with edge-pinned labels, so squeezing one below its fitting width
reads as the badge "wrapping". Give the icon and every trailing control
`.required` hugging and compression resistance, and the title/subtitle stack
`.defaultLow`, so it is the one thing that truncates.

### (6) `dismiss(_:)` is a no-op for a window whose `contentViewController` was assigned

`NSViewController.dismiss(_:)` does nothing unless the controller was presented
via `presentAsSheet`/`presentAsModalWindow`/`presentAsPopover`. For a top-level
window whose `contentViewController` was assigned directly, close the window
(`view.window?.close()`). Verify such a button with `performClick(nil)` plus an
`isVisible` check - that runs the exact target/action path a real click does and
needs no Accessibility grant.

### (7) A second window over a full-screen Space tiles into it unless told otherwise

A second regular `NSWindow` opened while another window is full screen docks
into that Space as a full-width tile, which turns a centred form back into a
full-width layout in full-screen mode only. Set `collectionBehavior =
[.fullScreenAuxiliary, .moveToActiveSpace]` and `level = .floating` on any
utility window opened over a possibly-full-screen main window.

### (8) `.behindWindow` vibrancy composites against the desktop, not the window

`NSVisualEffectView` with `.behindWindow` blends against whatever is behind the
*window*, so as a full-size destination or standalone window root it renders an
incorrect tint. Forcing `.appearance` does not fix it; only removing the
material does. Such a root is a plain `NSView` with `wantsLayer` and a
`HelmTheme`-derived `layer.backgroundColor`. Reserve real sidebar material for
an actual split-view pane.

The one legitimate `.behindWindow` case here is the inverse: `DictationHUD`'s
borderless pill floating over *other apps*, where the desktop genuinely is what
is behind it. Two non-obvious requirements there -
`.followsWindowActiveState` leaves the material permanently inactive on a
`.nonactivatingPanel` (it never becomes key), and the material needs
`masksToBounds` or it draws square corners behind a rounded border.

### (9) A plain `NSView` document view is not flipped

y=0 is its *bottom*. With content pinned to the document's top anchor, a
document shorter than the viewport rests against the bottom of the clip view and
leaves a blank gap above the header - which is what an async load looks like for
its first few seconds. Use a `FlippedView` document view plus an explicit
`scrollToTop()` in `viewWillAppear`, and force `layoutSubtreeIfNeeded()`
immediately before that call and again at the end of any `render()` that grows
the document.

### (11) `translatesAutoresizingMaskIntoConstraints` must be cleared before the constraints go on

Left at its default `true`, AppKit *also* synthesises required constraints
pinning the view to whatever frame it had at that moment - `.zero` for a
freshly-`NSView()`-initialised one, i.e. required width and height of 0 - which
silently fight any explicit fill constraint. Nothing is logged: AppKit resolves
it by adjusting the **window's** frame instead, so the symptom is a whole app
window that refuses to grow, even while a different destination is showing.

A hidden view still participates fully (see (15)), so this bites for a
hidden-by-default subview too. Any `NSView()`/`NSTextField()` stored as a
`private let` and initialised inline is a live instance of this trap until the
line is there.

### (12) Content-priority APIs are no-ops on any view with no intrinsic size

`setContentHuggingPriority` / `setContentCompressionResistancePriority`
constrain a view against its *intrinsic content size*, and an `NSStackView` has
none - nor does a bare `NSView()` spacer. So (10)'s advice to set `.required`
hugging on the container does nothing, and a nested stack stays the parent's
preferred stretch target.

Rule of thumb: **content**-priority APIs for a leaf view (label, button, image),
**stack**-priority APIs (`NSStackView.setHuggingPriority(_:for:)`,
`setClippingResistancePriority(_:for:)`) for a stack, an explicit width
constraint for a fixed column, and a real low-priority `width == 0` for a spacer
that must stay collapsed.

When the view that must absorb the slack is itself a stack or a scroll view,
stop asking one stack to distribute it: pin the chrome above to the container's
top edge and the chrome below to its bottom edge as two groups, and let the
flexible middle be what is left. `CompactModePopoverController` is the worked
example.

### (13) Any content constraint above priority 500 can resize the whole window

A window holds its own size at `NSLayoutPriorityWindowSizeStayPut` (500), so any
content constraint above 500 can resize it. A required `<=` plus a >500
proportional or equality constraint on the same view **is** a window-size cap -
one shipped as a 1410pt ceiling on the whole app, with genuine full screen
rendering a black bar down each side, and no "unable to simultaneously satisfy"
warning. The band for anything that must beat the stack defaults but never touch
the window is **251-499**. `FM_RUN_CONTRAST_TESTS`'s `checkRowDoesNotResizeWindow`
guards it.

Three consequences:

- **Two constraints at 499 tie**, and Auto Layout breaks the tie itself.
  `HelmPageSidebar`'s own `width == 208` sits at 499, so a page whose content
  column is **capped** must pin that content to the page by a constant rather
  than chaining it to the sidebar's trailing edge - otherwise the slack lands in
  the column and the nav rows render wider than the component's own width.
- **A capped column is centred, never left-pinned**, and the centre to measure
  against is the *visible* one: the scroll area starts under the sidebar panel,
  so centring on the clip view lands the column half that overlap off.
  `SettingsController.visibleCentreNudge` derives the correction from the two
  constraints rather than writing a number.
- **A content hugging priority travels the same chain as a width *ceiling*.**
  Wherever a required equality ties a container to its content, one `.required`
  hug on a label inside says "never wider than my text" about the container too
  - a span-2 card asked for 526pt resolved to 227pt that way. A hug that only
  has to beat sibling columns belongs at `HelmDaylightPriority.columnHug` (251),
  not at 499.

### (14) A required `==` tie does not self-verify on every resize

A correctly-declared required equality can still leave a view at a stale, wider
frame after the window shrinks: the constrained view's `.frame` is simply not
re-derived from the live graph unless something forces a fresh
`layoutSubtreeIfNeeded()` after that specific resize. Captured live on the
captain's own instance - `bodyContainer` frozen 395pt wider than the window.

Name such a constraint as a stored property and re-assert it: reactivate it if
AppKit left it inactive and force a layout pass, once after activation and again
on every `NSWindow.didResizeNotification`.
`AppShellController.reassertBodyContainerWidthTie()` is the worked example, and
`ToolsController`'s grid and `SettingsController`'s theme grid learned the same
lesson independently. See also
[`24-window-and-layout.md`](docs/history/24-window-and-layout.md), which corrects
this entry's original claim that `contentView` is always in sync with the window.

### (15) A hidden view is still in the window's constraint graph, and a full-screen-capable window re-solves all of it

Every full-screen-capable window re-derives `minFullScreenContentSize` whenever
anything invalidates it, and that walks the **entire** required-constraint chain
in the window - every mounted destination, not just the visible one. **A single
label's text changing is enough to invalidate it**, and the cost is near-linear
in what is mounted: 27 destinations measured 43.4% of the main thread. An
explicit `contentMinSize` does not short-circuit it.

The fix is to deactivate a hidden page's pins to its container, so its subtree
has no required path to the window, and reactivate them before unhiding
(`AppShellController.setDestinationVisible`). Nothing is torn down, so GL-37 is
untouched. Any container keeping many pages mounted needs the same, and any
"idle CPU" investigation should `sample` for CoreAutoLayout before suspecting a
timer.

### (16) A container whose height nothing ties is free to let its own content escape it

A view pinned at the top and only *capped* at the bottom has no height of its
own, and Auto Layout will resolve that by breaking the required constraint meant
to hold its content inside it - a scroll view rendered 220pt taller than its
container and 120pt above the window's top edge, with nothing logged, because
nothing was unsatisfiable. A `top ==` / `bottom <=` pair plus a low-priority
content-height preference is not a height: make the child exactly fill its
container and let the page decide how tall the container gets.

The same shape one level out: taking a view *out* of a height tie also removes
the container's protection of it, so an exempt view needs both a reference the
other rows cannot inflate and a floor of its own `fittingSize.height` to replace
what the tie supplied (`HelmResponsiveGrid.spanningRows`).

### (17) An `NSTextView` is not a label, and it repaints your colours

Reach for one only when a page needs *inline* clickable text, which an
`NSTextField` cannot give (its `.link` goes straight to `NSWorkspace` with no
seam). Three things then apply:

- **Retain the `NSTextStorage`.** The storage retains the layout manager, and
  the manager's back-reference to its storage is `unowned(unsafe)` - a storage
  held only in a local leaves a dangling pointer, surfacing as `EXC_BAD_ACCESS`
  inside `objc_autoreleasePoolPop`.
- **It paints its own `linkTextAttributes` over every `.link` range**, default
  system blue plus underline, so per-run colours computed into the attributed
  string are silently overridden. Hand it a dictionary carrying neither
  `.foregroundColor` nor `.underlineStyle` and assert that override directly.
- **It has no useful intrinsic size**, so in an `NSStackView` it resolves to
  zero. Derive the height from the layout manager, calling `ensureLayout(for:)`
  before `usedRect(for:)`.

A footnote to (13) from the same work: a required `width == 0` is safe where a
required fixed width is not - zero is a maximum and can never be a floor. But
that only works where the collapsing view's own content can reach zero. Where it
cannot (a pane with a real 28pt header row), **collapse the pane's neighbour
instead**: give the view below two alternative `top ==` constraints, one to the
pane and one past it, exactly one active.

### (18) A `WKWebView` bridge entry point must never return a `Promise`

Swift hands `window.<Global>.<name>(callID, payload);` to `evaluateJavaScript`,
which cannot marshal a `Promise` and fails the call with "JavaScript execution
returned a result of an unsupported type". The bridge's error path then reports
the command as failed *before* the page's real reply arrives, naming neither the
command nor a promise. Keep the entry point a plain method that starts the async
worker and returns nothing, and put the body in a sibling `async function` that
replies through the same `reply(callID, …)`:

    exportImage(callID, payload) { exportImageAsync(callID, payload); },

### (19) An `NSTextField`'s target/action fires on Return and on nothing else

Focus loss - clicking away, tabbing on, clicking the button the field was filled
in for - sends no action at all. The text stays visibly in the field and nothing
is saved. **A field whose value is *persisted* needs a `delegate` as well**, so
`controlTextDidEndEditing` reaches the same commit; `SettingsController`'s
`configure(_:)` wires all three. A field whose action means *submit* is the
legitimate Return-only case and must not gain one.

Two things make it hard to catch: `sendsActionOnEndEditing` is the other
half-fix and is not what this app uses, and a suite that calls the commit method
directly passes with the wiring deleted. Only a window-backed check that drives
the real field editor and then reads the *store* can see it.

### (20) An ancestor's click recognizer swallows a nested control's click

AppKit defines no automatic exclusivity between a gesture recognizer on an
ancestor and a real control nested inside it, and the control loses. Nothing is
logged, and the button still hit-tests correctly and still reports the right
target/action - so reading the code says the wiring is fine. It shipped three
times here.

It is handled for you now: `HelmGestureArbitration.shouldRecognize(_:with:)`,
which `HoverHighlightView` applies to any recognizer handed to it that has no
delegate. A recognizer on a view that is not a `HoverHighlightView` is on its
own - set `delegate` and call the shared helper, do not write a third copy. Note
the rule declines for an *actionable* control, not for any `NSControl`, and that
AppKit does not hit-test a **disabled** control, so a visibly-there-but-inert
button has to swallow its own clicks by frame.

The testing trap is the real lesson: arbitration is a property of real event
dispatch through a real window, so a suite that calls the handler cannot see it,
and both prior tasks had green coverage of exactly the interaction that was
dead. `NotificationRowInteractionSelfTest` is the worked example of a check that
posts a real `NSEvent`.

### (21) `.deviceIndependentFlagsMask` is the wrong mask for a hotkey predicate

Mask with `KeyChord.relevantModifierMask` (⌘⌥⌃⇧). `.deviceIndependentFlagsMask`
is `0xFFFF0000` and carries Caps Lock, Fn, the numeric-pad and help flags too,
so an exact equality turns any ambient flag riding along into "not the chord".
Shipped twice; route the comparison through `KeyChord` rather than writing a
third predicate.

Two related rules:

- **A chord that is also an `NSMenuItem` key equivalent has two independent
  implementations**, and the menu masks the monitor's failure while the app is
  frontmost. Establish *which* path fired before concluding anything.
- **A global `NSEvent` monitor is armed from the trust the process held when it
  was registered**, and macOS does not arm it retroactively.
  `ShiftGlobalHotkey.reassertIfTrustChanged()` is the shape.

And two about TCC, which cost two separate investigations:

- **A privacy-pane toggle shown ON is not proof the live check reads true for
  the running process.** Confirmed twice by a read-only `lldb -p` attach against
  the captain's real instance: `AXIsProcessTrusted() == 0` while System Settings
  showed the row on. Read the live process; never conclude from the UI.
- **Gate a permission-requiring call on the API that governs *that call*.**
  `AXIsProcessTrusted()` answers "may this process drive other apps through the
  AX API"; `CGPreflightPostEventAccess()` answers "may it *post* events", and
  they are free to disagree. When the gate is closed, **ask rather than narrate**
  - `CGRequestPostEventAccess()` re-registers the currently running binary's
  signature with `tccd`, which is what a captain editing System Settings by hand
  cannot reliably do. Hop such a call to the main thread, and short-circuit it
  under `#if FM_SELFTESTS` with a reset hook.

### (22) A wrapping label's `preferredMaxLayoutWidth` must never come from its own resolved width

Deriving it from the label's own bounds - or from a stack whose size that label
decides - is circular, and whichever layout pass ran first with a small width
becomes permanent. Measured: a text column locked at **11pt**, one word per
line and words broken mid-word, from a 700pt intermediate width. Both the
correct and the broken derivation converge once a further pass runs, which is
why a theme change "fixes" it and why it only appears on a first visit.

The shape that works measures things this label does not decide: the **row's**
own resolved width, minus its rigid siblings' `fittingSize.width`, minus the
spacing, floored. `SettingsRow.relayoutDescription`,
`DictationController.availableDetailWidth` and `HelmToggleRow.layout()` are the
worked examples.

And the trap underneath it: **`NSTextField(labelWithString:)` builds a cell whose
`wraps` is false**, so `maximumNumberOfLines = 0` and a word-wrap line break
mode do nothing and the label truncates with no ellipsis however wide you make
it. `wrappingLabelWithString` is the constructor that sets the cell up.

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
| `HelmModuleCard.Body.usageReport` | a hand-rolled quota/budget readout on a canvas card. Rows whose bars must line up are an `NSGridView` with the bar column left unconstrained (gotcha (2)), never nested stacks, and every content priority inside sits in the 251-498 band (gotcha (13)) - [`07-fleet-and-notifications.md`](docs/history/07-fleet-and-notifications.md) has the 526pt-to-227pt measurement |
| `HelmStatTile`, `HelmEmptyState`, `HelmSegmentedTabs`, `HelmPlateCard`, `HelmModuleCard` | four, two, three and two prior copies respectively |
| `HelmRingGauge` (`configure(value:total:)` for a count, `configure(fraction:text:)` for anything else) | a hand-rolled arc. It is a fixed 66pt with a centre label, so a *chip-sized* ring is legitimately its own small view - F7's is - but a card-sized one is this |
| `HelmField` / `HelmTextField` / `HelmTextView` / `HelmSearchField` / `HelmChipInput` / `HelmDateField` / `HelmToggle` | a raw `NSTextField()`, `NSSearchField()`, `NSDatePicker` or `NSSwitch` - source-guarded |
| `HelmRevealableSecretField` | a hand-rolled masked field plus Show/Hide toggle. Wire **both** `editableFields` (gotcha (19)), and ask `owns(_:)` in a delegate - the sender is one of its two halves, never the control |
| `HelmFormSheet` | a hand-built editor sheet |
| `HelmConfirm` | an `NSAlert`, **except** where a command or binary is about to execute outside this app's control (the risk gates, the herdr restart, `beginSheetModal`) |
| `Feedback.report(_:kind:persistence:in:)` | deciding at the call site whether something is a toast or a bell entry. State whether it is **still true after a toast would have faded** (GL-30's own dividing line) and let it route; pair a `.lasting` report with `Feedback.clear(id:)` on the path that resolves it. A blocked *decision* is still `HelmConfirm`/`DestructiveConfirm` - it needs an answer, so it needs a return path |
| `HelmPageSidebar`, `HelmPageToolbar`, `HelmResponsiveGrid`, `HelmDrillHeader`, `HelmRefreshPill`, `HelmBarPanel`, `HelmSkeletonRow` | a per-page reimplementation of each |
| `HelmCountBadge` | a bare number in a card header's action slot |
| `HelmType` roles | a literal `systemFont(ofSize:)`; `HelmMetrics` for spacing and radii |
| `HelmMotion` | a direct `accessibilityDisplayShouldReduceMotion` read - source-guarded |
| `CSVParser` (in `CredentialVaultImport.swift`) | a split-on-comma reader. It handles quoted commas, escaped quotes and embedded newlines - and **`\r\n` is one `Character` in Swift**, so a hand-rolled parser matching `"\n"` alone reads a whole Windows-exported CSV as a single row |
| `TOTPTicker.shared.now` | a `Date()` of your own in anything that renders a 2FA code or its countdown. One clock, or two surfaces disagree about the same code |
| `CredentialVaultRecoveryKitView` as the shape for any future **print** view | a themed view sent to a printer. It draws explicit black on white and does not observe `ThemeManager` - a themed page prints a near-black rectangle under Dusk - and the same view renders the PDF, so paper and file cannot drift |
| a menu-bar surface's **existing** content controller, at an injected width with `showsOwnHeader: false` | a lookalike pane for the same thing. F22's compact popover hosts `PoneglyphMenuBarPopoverController` and `StrawHatMenuBarPopoverController` themselves as two of its four tabs, so the countdown rings, the copy flash and the crew's reply states have exactly one implementation. Both take `init(width:showsOwnHeader:)` defaulting to their standalone behaviour - a required fixed width inside a narrower popover is a constraint conflict, and gotcha (13)'s window-size cap |
| `GrandLineServices.shared` | a second `ShiftStore()`/`NotebookStore()`/`CredentialVaultStore()` built by a non-UI entry point. `AppShellController` registers the live instances there; an App Intent, the Backup card or anything else with no view controller reads them from it, and gets `nil` (not a fresh store) before the shell is up. It is a **registry, not a factory** - the vault is its one exception, and that file's header says why |
| `DaylightSpace.destination` | a space pill that navigates by naming its own case. A pill is a canvas *filter* by default and a page when that table says so; `filtersCanvas` is what a canvas-shaped loop (and a canvas-shaped test sweep) filters on, so adding a page-shaped tab is one property and no edit anywhere else. **A space's own page is top-level, not a drill page**: `AppShellController.show` asks `DaylightSpace.owning(destination:)` whether the bar keeps its wordmark and space pills, so such a page has no drill header and must not conform to `DaylightDrillActions`. Naming the canvas there instead shipped once, and hid the whole tab strip the moment the new tab's own pill was pressed |
| `SettingsRow` / `SettingsGroup` / `SettingsSection` / `SettingsHero` (`SettingsForm.swift`) | a hand-rolled Settings row, group card or page header. The Settings page is ~60 rows across eight pages, and the separator inset, the `.sub` indent, the dimmed-**and-inert** dependent state and the description re-wrap are exactly what drifts when each call site spells them out. A group is a real `HelmCard` with no header, so there is still one card surface |
| `HelmGestureArbitration.shouldRecognize(_:with:)` (and `HoverHighlightView`, which applies it for you) | a hand-rolled `gestureRecognizer(_:shouldAttemptToRecognizeWith:)` walk. Two copies of it existed and the third row that needed one shipped dead - gotcha (20) |
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
- **`HelmTint.neutral` is page ink, and washing it as a *tinted surface*
  produces a near-black chip.** `HelmContrast.tintedSurface` is correct for
  every real hue and wrong for this one, because `.neutral` resolves to
  `chromeInkHex` - so the wash lands a few percent off full ink rather than a
  few percent off the surface. It matters because `.neutral` is what
  `ShiftProjectPalette` gives a record with **no** project, which is most of
  them: the commonest chip on a surface is then also its heaviest. A no-identity
  chip wants `HelmField.fill` plus ink text, the same treatment the Kanban's
  cards already use. Caught in a real off-screen render
  ([`34-recurrence-and-calendar.md`](docs/history/34-recurrence-and-calendar.md)),
  not from the code.
- `HelmDomainHue.identityHex` is for identity (it resolves to `.neutral` off the
  Daylight family); `fallbackTint` resolves a *semantic* slot and will paint an
  alert bar on a benign row. **The one sanctioned use of `fallbackTint` is a
  destination's own colour *tile***, where `identityHex` alone would wash page
  ink into a near-black chip on 24 of the 26 palettes - `UnifiedSearch`'s
  palette row and `DaylightBarIconButton.tileHex(for:in:)` are the two, and
  they resolve identically. It is safe there and not on a bar because every
  member of those sets carries a tile, so no one hue is the coloured thing
  among neutral siblings.
- **A surface drawing *all seven* `HelmDomainHue`s at once must resolve them
  through `categoricalHex`, not `fallbackTint`.** The seven-hue to seven-
  `HelmTint` map is 1:1, but a *palette* is free to spend one colour on two
  slots - Ayu publishes one amber and uses it as both `accent` and its ANSI
  yellow, Tokyo Night's `accent` **is** its ANSI blue. Swept as a washed tile
  over all 26 palettes, the closest pair of domain hues measured **0.0000** on
  eight of them and under a 0.035 separation floor on fourteen; against the
  raw §2.2 values the worst pair is 0.0568. That shipped as the top bar's
  three-tan icon row (`docs/history/03-navigation-and-chrome.md`). The
  per-palette resolutions stay right for a surface drawing **one** hue among
  neutral siblings, which is why `UnifiedSearch`'s result tile still splits -
  `HelmDomainHue.identityHex`'s comment is the dividing line. And measure such
  a collision as a weighted-RGB **distance**, never `HelmContrast.ratio`:
  that helper compares relative luminance, so two different hues of equal
  brightness score identical - exactly the defect being looked for.
- **An identity colour derived from text must not come from
  `String.hashValue`.** Swift seeds it per *process*, so the same host, tag or
  project gets a different colour on every launch - and the defect is invisible
  within a single session, which is where it would be looked for. Use an
  explicit stable hash over the UTF-8 bytes; `ReadingListHostHue.hue(for:)` and
  `ReadingListTags.stableIndex(of:)` are the worked examples, and both are
  asserted for stability rather than only for range.
- **A page-scoped nav column takes `HelmTheme.sidePanelFill` / `sidePanelEdge`,
  never a blend of the card into the page ground.** `chromeBackgroundHex ==
  backgroundHex` in several palettes, so that blend *is* the ground in those
  and the column renders invisible - which is exactly the defect those two
  exist to fix. The fill steps the ground toward the register's own endpoint,
  bisected to the smallest step clearing `sidePanelSeparation` (1.08:1, which
  is Daylight's own card-over-paper). `SettingsController`'s band is the worked
  example, and note it is the *page's* view: `HelmPageSidebar.Surface.panel`
  paints the nav list as a card, which is a smaller region than the column.
- **A new palette is one surface step, and the step is the family's own
  canonical editor background.** `backgroundHex` is simultaneously the page
  ground *and* the terminal background, so a palette whose card differs from
  its page reopens the seam
  `fm/grand-line-legacy-terminal-canvas-chrome-match` closed - unless it
  carries a real `terminalCard`, which only the Daylight family does.
  `ThemeFamilySelfTest.checkPaletteShape` fails the run on one that does not,
  and also on a `pairId` that is one-way (`ThemeManager.toggle()` *silently*
  falls back to the plain Helm swap, so a broken pair drops the captain out of
  their family on a keystroke and nothing else notices).
  [`44-new-theme-families.md`](docs/history/44-new-theme-families.md).
- A Daylight-family restyle branches on `theme.isDaylight` and leaves the other
  twelve palettes byte-identical. Branch **colour and geometry recipes** that
  way - never *structure*: a page whose column count depends on the theme is a
  bug, and shipped as one.

---

## Stores, subprocesses and secrets

- **The app has exactly one name, one identifier prefix and one data folder,
  and all three have a single definition.** The display name is **"Grand
  Line"** (never "Manjesh Grand Line", never "Firstmate Cockpit"), the Swift
  module and the shipped executable are `GrandLine`, every identifier this app
  owns is `com.manjesh.grandline…`, and every file-backed store nests under
  `AppPaths.applicationSupportFolderName`. A hand-written copy of any of those
  is how half a rename gets left behind - `LegacyRenameMigrationSelfTest`
  fails the run on a source that spells a pre-rename name, and on a sixth
  Keychain service that does not join `LegacyNameMigration.keychainServices`.
  **Changing the bundle identifier again is not a find-and-replace**: it
  orphans the captain's Keychain items, their Application Support folder, their
  whole preference domain and every macOS privacy grant they have given the
  app. The first three can be migrated and `LegacyNameMigration` is the worked
  example; the fourth cannot be, ever, because granting it is a user consent
  action - say so in the PR rather than leaving the captain to find out.
  [`45-rename-to-grand-line.md`](docs/history/45-rename-to-grand-line.md) is
  what a future one has to read first.
- **A store's default path comes through `AppPaths.dataRoot()`, which is the
  one place `FM_SCRATCH_ROOT` is honoured.** That single variable moves every
  file-backed store at once, and it exists because the alternative - a list -
  drifted: `build-probe-app.sh` promised its `ENV_ARGS` were "every FM_*
  location override, in one place", and by the 2026-09-25 review seven stores
  had been added that it did not redirect, so a probe launch wrote the
  captain's real clipboard history, session-restore file, scratchpad and widget
  snapshot. A store that resolves `.applicationSupportDirectory` for itself is
  a store no probe and no suite can move; `FM_RUN_PROBE_SCRATCH_ROOT_TESTS`
  fails the run on one. A default that is **not** under Application Support
  (`~/.dotfiles`, a shared App Group container) cannot nest under the root and
  must ask `AppPaths.isScratchRedirected()` instead.
- **Every store also honours its own narrow `FM_*` override**, which wins over
  the root; the repo-root README has the complete index. A store nested under
  Shift's data root must honour `FM_SHIFT_DIR` as a fallback, not only its own
  narrow variable - and it needs an entry in `main.swift`'s `#if FM_SELFTESTS`
  redirect block, which is the backstop for a store reachable from a bare
  constructor.
- **A Keychain service name comes through `KeychainService.resolve`**, which
  applies `FM_KEYCHAIN_SERVICE_PREFIX` in a debug build and is the identity in
  a release one. The same rule as the paths above, for the state that outlives
  the run: before it existed, `BackupSelfTest` had written **91 real items**
  under the production `com.manjesh.grandline.sshkey` service on the captain's
  login Keychain, each holding a literal test passphrase, and nothing removed
  them. `KeychainServiceSweep` deletes this process's items at exit and
  anything an interrupted earlier run left. Two traps it encodes:
  **`SecItemDelete` removes one matching item per call** on the file-based
  login keychain (a single call leaked a second seeded account 33 times), and
  a suite that drives a key store's `load(create:)` far enough to *mint* will
  delete and replace the captain's real key - install the store's write seam.
- **A new field on a `Codable` store type needs a hand-written
  `init(from:)` with `decodeIfPresent` and a default** (GL-01). A Swift-side
  default does *not* make a declared key optional to the synthesised decoder,
  and getting this wrong made every existing `hosts.json` undecodable once.
- **A store that re-serialises from a decoded struct silently drops any key
  it does not know, and that is a GL-01 failure with no symptom.** GL-01's
  usual shape is a *read* that fails; this is a read that succeeds and a
  *write* that loses something. A whole-file rewrite built from decoded
  values can only write the fields this build has, so a record carrying one
  extra key from a newer build loses it on the very next edit - across a git
  sync whose entire purpose is two machines on two builds, with nothing
  failing and nothing to notice. Preserving a record that will not decode at
  all (`StickyBoardStore.unreadableRecords`) is a *different* mechanism and
  does not cover this. `StickyBoardStore`'s `knownKeys` + `passthrough` pair
  is the worked example: capture the unrecognised pairs per record on read,
  append them on write, and list every key this build writes in one place so
  a new field that is forgotten there fails a test rather than duplicating
  itself. Any hand-written whole-file serialiser wants the same shape.
- **Git-backed stores share one working tree and one serial queue**
  (`ShiftGitSync.sharedQueue`). Two queues against one tree race on
  `.git/index.lock`. A terminate-time flush dispatches **onto** that queue with
  a short bound and cancels the pending debounce inside the queue block.
- **An OAuth refresh token is a secret, and it lives in the Keychain with the
  metadata that describes it.** `GoogleAccount.swift` stores one generic
  password per account slot (`ThisDeviceOnly`, never iCloud-synced) holding the
  tokens *and* the email address and granted scopes - one item rather than two,
  because the address a card displays is a claim about which token is stored,
  and splitting them is how a card comes to name an account whose token was
  already deleted. Nothing about it is written to a JSON store or git-synced.
  There is no `FM_*` path to redirect, so `main.swift`'s `#if FM_SELFTESTS`
  block swaps the **store itself** for `InMemoryGoogleAccountStore` - a suite
  that reached the real one would create Keychain items holding fabricated
  tokens on the captain's own machine.
- **Secrets never reach disk or argv.** Private key material and vault
  passphrases live in the Keychain (`ThisDeviceOnly`, never iCloud-synced);
  credential material on a pasteboard goes through
  `CredentialVaultClipboard.writeConcealed`; files that carry connection or
  credential material are written through `AtomicWrite(... sensitive:)`.
- **One screen-capture path: `ScreenRegionCapture`, and it is `screencapture -i`
  rather than ScreenCaptureKit.** SCK has no region-drag input and needs a
  standing Screen Recording grant; the interactive tool needs neither, because
  the system's own agent does the capture on the captain's drag. An app carrying
  a credential vault should not acquire a "read every pixel" capability it can
  avoid, so a second capture path is a security decision and not a convenience -
  reach for this one. The capture goes to the **pasteboard** (`-c`), never a
  file, and is read back through `ShiftImageAttachmentWell.image(fromPasteboard:)`,
  which is this app's one "get an image off a pasteboard" function. Both halves
  consult `AppLockGate`: the system crosshair draws *over* this app's lock
  overlay.
- **`av list` is the one Automic Vault read that can raise an approval prompt,
  and nothing unattended may call it.** Measured against a real `av` by counting
  rows in Automic Vault's own authorization log: `av list` adds a row and
  blocked 45s on a visible approval dialog on its first call, while
  `av doctor --json`, `av hardeners --json` and `av --version` add none and
  answer in well under a second. So a timer, a retry loop or any other
  unattended caller takes `VaultSource.loadToolStatus()` (the `av doctor --json`
  half, which produces the vault-attention signal); `VaultSource.loadSnapshot()`
  is reached only from something the captain just did. Note this is not an
  `AppActivityState` question - the captain's report was a prompt appearing
  while the app was **frontmost**, where every backgrounded gate is open.
  `VaultData.swift`'s "approval-prompt split" block has the numbers,
  `BackgroundSignalsSelfTest` source-guards the poller, and the one sanctioned
  exception (`ScheduleRunner.vaultRecipeExport`, whose content *is* the secret
  names, and which only runs for a schedule the captain enabled) is documented
  at its own call site.

- **One calendar path, and it is read-only: `DailyReviewCalendar.swift`.** It
  is the only file in the app that imports `EventKit`, it never calls `save`,
  `remove`, `commit`, `saveCalendar` or `removeCalendar`, and it hands out
  strings (`DailyReviewEventRow`) rather than `EKEvent`s, so no caller can
  reach an event object through it. `FM_RUN_DAILY_REVIEW_TESTS` guards both
  halves - the forbidden calls, and the "exactly one importer" rule - because
  the behaviour cannot be asserted without writing to a real calendar to see
  whether it happened. Two consequences for any future calendar work: the
  permission request belongs to a real click and never to a page appearing
  (TCC prompts are not something a card may fire on its own), and **an
  unbundled build must refuse to ask** - `.build/debug/GrandLine` has no
  `Info.plist`, and TCC kills a process that requests access without a usage
  description, so `canPrompt` checks for the key first.

- **There are two calendar *sources* now, and the read-only guarantee is a
  different mechanism in each.** The local one is the file above, guarded by a
  source grep because EventKit hands out an object that *can* write. The remote
  one is a connected Google account (`GoogleCalendarSource.swift`), where the
  guarantee lives one layer lower: `calendar.readonly` is the only calendar
  scope this app ever requests, so the token physically cannot write - assert
  the **scope list**, not just the call sites. `DailyReviewCalendarSources` is
  the one place that decides which sources are on, both hosts of the daily
  review card read it, and `CompositeDailyReviewCalendar` merges them. Two
  rules that fall out of a *remote* source and cost real thought:
  `DailyReviewCalendarReading.events(on:)` is **synchronous and on the main
  thread**, so a network source must serve a cached snapshot and refresh in the
  background (GL-04/GL-12); and before that first refresh lands it must report
  a **stated gap, never an empty day** (GL-14) - "not read yet" and "nothing
  on" are different sentences. `docs/history/43-google-accounts.md`.

- **`SubprocessResult.stdout` is trimmed, so never parse a fixed-column tool
  output by offset.** `git status --short` is `XY <path>`, which invites a
  `dropFirst(3)` - and the first line of a status whose field is ` M` (an
  unstaged modification, the commonest case there is) arrives with its leading
  space already gone, so the drop eats the first character of the path.
  Measured: `GrandLineDocs/seed.txt` read back as `randLineDocs/seed.txt`, which
  then classified into the wrong half of a scope split that exists precisely to
  keep backup folders out of an automatic commit
  (`BootstrapController.statusLinePath` is the copy to reach for). The same trap
  waits for any other column-formatted tool this app shells out to; split on the
  field separator, not on a byte offset.
- **One subprocess runner and one AI runner**: `Subprocess` (GL-02/03/04/15) and
  `ClaudeOneShot` (GL-26). Do not add a third invocation shape. Interactive and
  PTY work is the terminal's, not theirs.
- **Arbitrary *captain-authored* code runs in exactly one place: `CodeRunner`,
  under `sandbox-exec`.** Code Preview's Run is the only surface in this app
  that executes a snippet, and it is confined (network denied, writes denied
  outside a fresh temp directory, the home directory unreadable, a fixed
  five-variable environment, a wall clock, a cancel handle) with the profile
  asserted as text by `FM_RUN_CODE_RUNNER_TESTS`. Two rules follow. A missing
  `sandbox-exec` **refuses** the run rather than downgrading it to an
  unconfined one; and nothing else in this app gains an "execute this text"
  path - a second one would be a second, unreviewed sandbox. What the sandbox
  does **not** do is in `docs/history/22-code-preview.md`, written out rather
  than implied, and any change to the profile belongs there too.
- **`resolvingSymlinksInPath` does not resolve a `/var/folders` temporary
  path**, and anything that matches paths by prefix has to care. `NSString`'s
  resolver is documented to *strip* a leading `/private`, so a temp directory
  comes back as `/var/folders/…` while the child process's real cwd is
  `/private/var/folders/…`. A `sandbox-exec` profile naming the first form
  matches nothing, and the symptom is a denial inside the one directory that
  was supposed to be writable - which reads as a broken sandbox rather than a
  broken path. `CodeSandbox.realPath` is `realpath(3)` and is the copy to
  reach for.
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
- **`CredentialVaultClipboard.isConcealed(_:)` is the app's one definition of
  "a secret is on the pasteboard", and anything that reads `NSPasteboard`
  content must ask it.** The markers (`org.nspasteboard.ConcealedType`,
  `...TransientType`, `com.apple.is-sensitive`) are written by
  `writeConcealed`; **any one of them alone is enough to refuse**, because the
  nspasteboard.org convention exists to be honoured for other apps' writes too
  and those carry one marker rather than this app's three. Four readers exist
  today - the clipboard history's capture loop, ⌥Space's pasteboard chip,
  the Reading List's paste/drop route (`ReadingListController.pasteTapped`,
  `ReadingListDropRootView.acceptableURL`) and F12's `{{clipboard}}` placeholder
  (`SnippetExpander.clipboardText`) - and a second hard-coded copy of
  the marker strings is the one way this rule
  could silently stop matching, with no test failing. Check it **before**
  reading the string, so "a vault secret never reaches this store" is a
  property of the control flow rather than of a filter somebody could reorder.

- **Anything that reaches the vault from outside the vault page goes through
  the vault's own unlock, and returns a confirmation rather than the secret.**
  F21's Copy Credential App Intent is the worked example and the reason this is
  a rule: an entry point that handed a credential back as a value - a shortcut
  variable, a tool result, an automation's output - turns one Touch ID prompt
  into permanent access to the whole vault for anything that can invoke it. The
  secret goes on the pasteboard through `CredentialVaultClipboard` (concealed,
  auto-clearing) and the caller is told *which* credential was copied, never
  what it is. Three gates in order, none substituting for another: `AppLockGate`,
  the vault's own lock (`unlockWithTouchID`, and a refusal - never a prompt of
  your own - when the captain has turned it off), then the credential's own
  `requiresTouchIDToReveal`. **Look the credential up only after the vault is
  unlocked**, or the difference between "not found" and "vault locked" makes a
  locked vault an oracle for which titles exist.
- **A `.glbackup` section for a file-backed store carries the files, not the
  decoded models.** Re-serialising a directory store through its models is the
  symptomless GL-01 failure this file already describes, one restore later: a
  whole-file rewrite can only write the fields this build knows. `BackupStores.swift`
  carries bytes, which also round-trips attachments, passthrough keys and order
  files without knowing they exist. Validate the relative path on **both** sides
  (`BackupArchivePath`) - a bundle is a file from another machine, so GL-08's
  lesson applies to its paths. The vault travels **sealed** (the already-encrypted
  file, copied - never decrypted, never re-wrapped), a restore **merges and
  never deletes**, and replacing an existing vault needs its own
  `DestructiveConfirm` separate from the import confirm.
- **A store whose file is git-synced must reconcile before it writes.** A pull
  can change the file underneath an in-memory copy, and a whole-file rewrite
  from that copy silently discards whatever arrived. `CredentialVaultStore`
  keeps a decrypted `baseline` - what it believes is also on disk - and
  three-way merges against it in `persist()`, refusing outright when the file
  was re-keyed elsewhere. Audit-only events (a reveal, a copy, a lock) are
  batched and never `markDirty()`: publishing them produces a commit log of
  when each secret was looked at.
- **The vault's recovery key is a second wrap of the same key, and three of
  its properties are load-bearing.** `CredentialVaultRecovery.swift`'s header
  is the authority; read it before touching that path. The short version: the
  password path is unchanged by enrolment, the recovery *code* is 160 random
  bits (which is the whole reason the second door is no easier than the first
  - shortening it turns this into a backdoor), and a master-password change
  **drops** the wrap because it holds the old key's bytes and the code was
  shown once and stored nowhere. A session opened by recovery may re-key
  without the old password; that is gated on `unlockedViaRecoveryKey` and
  nothing else, because without the gate every ordinary unlocked session
  could be taken over.
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
| [`01-foundations.md`](docs/history/01-foundations.md) | The runtime, `swift build`, the vendored SwiftTerm and its six local patches |
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
| [`20-whiteboard.md`](docs/history/20-whiteboard.md) | The embedded Excalidraw whiteboard, its DSL, and F15's screenshot capture / annotate / copy |
| [`21-sticky-board.md`](docs/history/21-sticky-board.md) | The Sticky Board |
| [`22-code-preview.md`](docs/history/22-code-preview.md) | The embedded Monaco code preview, and its sandboxed Run / Format |
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
| [`33-capture-and-clipboard.md`](docs/history/33-capture-and-clipboard.md) | Universal capture (the ⌥Space router) and the encrypted clipboard history behind ⌘⇧V |
| [`34-recurrence-and-calendar.md`](docs/history/34-recurrence-and-calendar.md) | Recurring tasks (`ShiftRecurrence`), the per-task reminder offset, and the Tasks page's calendar view |
| [`35-reading-list.md`](docs/history/35-reading-list.md) | The Reading List (F4): the link inbox, `LinkPresentation` metadata, tags, read state and the opt-in AI summary |
| [`36-focus-timer.md`](docs/history/36-focus-timer.md) | The focus timer (F7): the task-bound Pomodoro, the bar chip and its ring popover, and Weekly Review's "time on tasks" tile |
| [`37-scratchpad-calculator.md`](docs/history/37-scratchpad-calculator.md) | The Scratchpad calculator (F9): the Tools tab, the expression engine, the unit/currency tables and the date words |
| [`38-snippet-expander.md`](docs/history/38-snippet-expander.md) | The snippet expander (F12): the `;abbrev` trigger grammar, the generalised Snippets store, and system-wide expansion over Dictation's own paste path |
| [`39-daily-review.md`](docs/history/39-daily-review.md) | The daily review (F20): the general-user briefing, its stated-gap rule, the app's one read-only EventKit path, and the Overview page it moved onto |
| [`40-menu-bar-mode.md`](docs/history/40-menu-bar-mode.md) | Menu-bar (compact) mode (F22): the merged status item, the four-tab popover that hosts the vault's and the crew's own popover controllers, and the window/Dock/last-window lifecycle |
| [`41-app-intents-and-full-export.md`](docs/history/41-app-intents-and-full-export.md) | App Intents / Shortcuts (F21), the `.glbackup` bundle's five new sections (F24), and `GrandLineServices` |
| [`42-widgets.md`](docs/history/42-widgets.md) | The WidgetKit extension (F23): the Tasks-due and Sticky-note widgets, the published snapshot, the queued-tap channel, and the Developer ID dependency |
| [`43-google-accounts.md`](docs/history/43-google-accounts.md) | Gmail sign-in (two independent Google accounts), the OAuth/PKCE flow, and Google Calendar as a second read-only source for the daily review |
| [`44-new-theme-families.md`](docs/history/44-new-theme-families.md) | The six families that took the picker from 14 palettes to 26 (Nord, Dracula/Alucard, One, Ayu, Night Owl/Light Owl, Oxocarbon) |
| [`45-rename-to-grand-line.md`](docs/history/45-rename-to-grand-line.md) | The app's name, the bundle identifier, the Keychain service names, the Application Support folder |
| [`46-review-bugs-b1-b14.md`](docs/history/46-review-bugs-b1-b14.md) | `FM_SCRATCH_ROOT` and the probe's safety, the Keychain service prefix, the quit-time ggml abort, the traffic-light hit-test recursion, Shift git sync's three data-loss paths |
| [`47-appkit-gotchas.md`](docs/history/47-appkit-gotchas.md) | Any of the 22 gotchas above - the probe, the numbers and the wrong fixes tried first |

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

**There is a budget now, and it is a check rather than a request.**
`FM_RUN_AGENTS_BUDGET_TESTS` fails the run when this file passes 120,000 bytes.
The paragraph above had already been here for a long time when P7 of the
2026-09-25 review counted three whole sections appended after it and 139KB in
total, so the honest conclusion was that a convention this consistently ignored
is not one. When it fails, the answer is normally the two-homes question above
rather than a bigger number - P7's own fix kept the gotcha catalogue's 22 rules
and 22 headings here and moved its 50KB of measurement narrative to
[`47-appkit-gotchas.md`](docs/history/47-appkit-gotchas.md) verbatim. Raising it
is allowed; it is a decision about what every future session pays, so say in the
PR what was added and why it could not be history.

