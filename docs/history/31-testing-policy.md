# The self-test classification rule

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

## Window-backed or pure logic: where the rule came from

**`fm/grand-line-e2e-unit-test-rule`, the captain's own ask: "too many testing cases are there currently in E2E testing and every new feature is just adding new test cases to it. So add a rule to create unit test cases for such cases and we need only the required test cases in E2E testing."** The rule is written in the README's "Window-backed or pure logic?" section and enforced by `E2ETestingPolicySelfTest`; what follows is only what a future session needs that neither of those states.

**The enforcement is `E2ETestingPolicySelfTest`, and the reverse direction is what this task added.** That suite already asserted "a suite that builds a window is declared in `NEEDS_SESSION`" - one direction, which catches a suite losing its windowed-CI coverage. Nothing asked the opposite, so a windowless suite could sit in that list forever. `checkSessionOnlySuitesReallyNeedASession` is that second direction, and both are **confirmed to catch a real regression rather than merely to pass** (re-adding the three reclassified flags fails by name, all three; removing a marker fails by name).

- **The parser had to learn to tolerate a trailing comment** (`needsSessionFlags` returns flag -> trailing text now, not a `Set`) - a `hasSuffix("\"")` test silently drops any entry carrying a marker, which would have made the guard skip the very entries it exists to reason about.

**The audit's honest result: the suite was already very nearly correctly classified, and the bloat the captain felt is not misfiled tests.** Measured at the time - 156 suites, 81 `NEEDS_SESSION` entries (52%), and **only 5** of those 81 built no window. Two of the five genuinely need a session (real `NSPanel`s; they carry the marker now). **Three were genuinely misclassified and moved back onto blocking CI**: `FM_RUN_VAULT_DATA_TESTS` (string safety, command-string builders, `av doctor --json` parsing, a recipe diff - imports only `Foundation`, and the runner's stated reason for listing it, "reads and writes the machine's real Keychain (and can prompt)", was simply **false**: it touches no Keychain, no `SecItem` and no subprocess it asserts on), `FM_RUN_TERMINAL_WRAP_REDRAW_TESTS` (pure invalidation-rect geometry, no AppKit at all) and `FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS` (offscreen `NSImage` downscale/PNG round trip). Each keeps every assertion it had; only where it runs changed. So the growth is real growth in what the app does, not a reclassification backlog - **the rule's value is forward-looking**, stopping the next feature from defaulting to a session-backed test by copying its neighbour.

- **The one empirical unknown, stated rather than assumed**: `FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS` uses `NSImage.lockFocus()`, and no suite already on the blocking job does. It is an offscreen bitmap context and should need no window server; if a hosted runner disagrees, it belongs in `CI_UNSUPPORTED` with that measured reason, per that list's own rule ("every entry here is a measured result, not a guess") - not back in `NEEDS_SESSION`, which would be the wrong reason.
- **Deliberately not touched**: test style, naming, file organisation, and the ~10 suites whose *cases* mix pure-logic and window-backed assertions inside one correctly-listed file. Splitting those is a per-suite judgement with real regression risk and buys CI coverage only for the cases actually extracted; it is follow-up work, not part of establishing the rule.

## CI in half the time, with every suite kept (`fm/grandline-ci-speedup-1792665154`)

The captain's ask: "check if all the suites in CI are actually needed. I think its now taking around 30 mins if this keeps going on its very difficult to deploy small changes. Lets remove unwanted ones."
Measured rather than guessed, over the last 20 completed CI runs on `main` and on pull requests (2026-10-21 to 22), from the jobs API and the runner's own per-suite lines in the job logs.

### Where the 30 minutes went

- A whole run took a median of 32 minutes (24 to 39).
- The `swift build` job took a median 10.2 minutes: 3.4 for the debug build and 6.5 for the release build.
- Both test jobs waited for the whole build job, release build included, although they only use the debug binary, which was ready at about minute 4.
- The window-backed job then took a median 21.8 minutes. The headless job took 5.4, beside it.
- So the critical path was 10.2 plus 21.8 minutes, and the release build and the window-backed lane were most of it.

### What the suites cost and what they caught

- 256 suites ran in CI: 120 window-backed (21.3 minutes of medians) and 136 headless (4.7 minutes).
- Four window-backed suites take 9.5 of those minutes: `APP_SHELL_BODY_WIDTH` (245s), `PAGE_LOAD_OFF_MAIN` (135s), `SETTINGS_THEME_LAYOUT_PARITY` (102s) and `DESTINATION_MOUNTING` (84s).
- Five suites failed in the 20 runs. Every one was on a feature branch, every one was a real defect in that branch, and every one was fixed before merge: a sticky note's stored position, a Reduce Motion collapse that did not land at once, a vault subtitle reading "Locked", four pages growing a 1177pt window, and Daylight building 22 Settings cards instead of 21.

### Classification

- **REMOVE: none.** Each of the brief's four grounds came up empty.
  - Nothing tests a feature that no longer exists. Every suite compiles against live code, and the suites about removed features guard removals the captain asked to keep (`TODAY_CALENDAR_REMOVAL`).
  - Nothing duplicates another suite. Comparing every suite's assertion messages pairwise, the largest overlap between two suites is a shared helper string. The git-backed stores share a pattern and test different stores.
  - No suite only pins a string or a count without protecting something. The size and count guards there are (the AGENTS.md budget, the inventory) are deliberate.
  - The expensive suites that never failed in these runs guard captain-reported bugs: the black gap beside the body (`APP_SHELL_BODY_WIDTH`) and pages reading their store on the main thread (`PAGE_LOAD_OFF_MAIN`). The other two are named must-keep, and `SETTINGS_THEME_LAYOUT_PARITY` caught a real regression in these runs.
- **MERGE: none**, for the same reason as duplicates.
- **SPEED UP:** the window-backed lane and the build, structurally, below. No suite and no assertion changed.

This matches the earlier audit above: the time is structure, not misfiled or unneeded tests.

### What changed

- **The release build is its own job** (`build-release`) beside the tests. The tests wait only for `build-debug`. The `swift build` check is now a small aggregate job that passes only when both builds did, so it still means what it meant.
- **The window-backed lane runs as three shards** (`test-windowed-shard`, a matrix). `run-all-tests.sh --shard=K/N` splits the selection longest suite first onto the least-loaded shard, using `SHARD_WEIGHTS` (the measured medians of the suites over ten seconds). That gives about 7 minutes a shard.
- **`self-test suites (window-backed)` is an aggregate job.** It passes only when every shard passed and when the shards' recorded lists, put together, equal the whole window-backed selection with no suite twice. A matrix edit or a change to the split cannot drop a suite out of CI quietly.
- The six check names CI always reported still report, with the same meaning. The new jobs add their own names beside them.
- `E2ETestingPolicySelfTest` checks the runner still parses `--shard=`, as it already did for `--ci` and `--session-only`.

### Verification

- The split, under macOS's bash 3.2: the three shards of the window-backed selection hold 40, 42 and 42 suites, 124 in all, each exactly once. On the measured medians they come to 6.9, 7.3 and 7.4 minutes.
- Removing the `--shard=*)` case from the script fails `E2ETestingPolicySelfTest` by name ("the runner script no longer parses --shard=*").
- A real sharded run of four suites ran two in each shard and reported its shard in the summary.
- The pull request's own CI run, [39912125893](https://github.com/manjesh-raj/manjesh-grand-line/actions/runs/39912125893), took 15.2 minutes end to end against the 32-minute median, all eleven checks green.
  The debug build was ready at 3.5 minutes, the release build finished at 6.8 beside the tests, and the shards ran 6.3, 8.2 and 8.4 minutes.
  It shared the account's five macOS slots with another pull request's run, so one shard waited 3.3 minutes for a slot and the `swift build` aggregate 2.6.
- The first run on `main` after the merge, [39913816152](https://github.com/manjesh-raj/manjesh-grand-line/actions/runs/39913816152), had the runners to itself and took 12.8 minutes, all eleven checks green.
  The debug build was ready at 3.9 minutes, the release build finished at 7.9, the headless lane at 9.3, and the shards ran 6.9, 6.5 and 8.5 minutes, the last of them finishing at 12.5.
- In both runs the aggregate printed "124 window-backed suites, each in exactly one shard": the same 120 suites ran and passed as before, and the 4 runner-unsupported ones were skipped as before.

## Review #2's process findings (`fm/grandline-review2-process-1792983685`)

Section 3.4 of the second full review listed eight process findings, R2-PROC-01 to R2-PROC-08.
This entry records the ones that changed the test harness and CI.

### R2-PROC-01: infrastructure failures read as their own kind of red

`main` went red on two pushes in a row.
One of them (run 39914224694) was shard 2 failing to download the debug binary, with no suite run at all, and the check list could not tell that apart from a suite failure.

- Both test jobs now download the binary twice: one `continue-on-error` attempt, a 30-second pause, then a second attempt.
  `download-artifact`'s own five retries are seconds apart, which a storage blip outlasts.
- A new `CI infrastructure` check reads the attempt's jobs from the API.
  It goes red only when a test job failed in a step other than its "Run the ..." step, or the debug build failed in its artifact upload.
  A suite failure leaves it green, because the test checks already report that.
- `.github/workflows/ci-rerun.yml` re-runs a failed `main` run once, and only when `CI infrastructure` failed.
  A suite failure is never re-run automatically, so a retry can never turn a real failure green.
- `fail-fast: false` was already set on the shard matrix.
  The six existing check names report with the same meaning.

### R2-PROC-02: isolation by construction

`ProcessMode` is the one answer to "is this a self-test or tour process".
`main.swift`'s redirect block, `ExternalToolGuard` (so `Subprocess` and `NetworkGate` too) and `AppPaths.dataRoot()` read it.
An isolated process never resolves the real data root, even when nothing set `FM_SCRATCH_ROOT`.
The runner starts every suite with an empty `FM_SCRATCH_ROOT` of its own and removes it afterwards, which replaced CI's shared `ci-stores` folder.
`git fetch`, `pull`, `push`, `ls-remote` and `clone` are refused in a test process unless every remote they can reach is a local path, so the git-sync suites' local bare repositories keep working.
`ProcessModeSelfTest` and a new case in `ExternalToolGuardSelfTest` hold both halves, and each was confirmed to fail with its half reverted.

One limit: a `git` command run inside a `/bin/sh -c` string is not visible to the guard, which sees only the program and its arguments.

### R2-PROC-06 and TEST-09: a flake detector and check counts

- `--rerun-failed` re-runs each failed suite once after the rest.
  The verdict does not change: the suite stays in `failed:` and the run exits 1.
  The summary then names a suite that failed and then passed as likely flaky, and one that failed twice as failed twice.
- `--history=<file>` appends the run to a JSON history through `Scripts/suite_history.py`.
  It keeps the newest 50 runs.
  Each run records every suite's result, time and check count, plus the run's suite count and lane time, so the window-backed lane's growth (R2-PROC-05) is a number per run rather than a recollection.
  The script prints the lane's summary, which CI writes into the job summary.
  That summary lists this run's flaky suites, every suite whose recorded results disagree, and the suite count and lane time of the last ten runs.
- CI passes both flags to the headless job and to every shard.
  It keeps the history between runs with `actions/cache` (a pull request also sees `main`'s) and uploads it as the `suite-history-*` artifacts.
  None of those steps can fail a job.
- TEST-09: `SelfTestAssertions` counts every check recorded through it and prints the count as the process exits, and the runner puts it on the PASS line (`PASS  FM_RUN_X  1.6s  (30 checks)`).
  A suite that keeps its own failure list without recording through the shared helpers shows no count rather than a wrong one (`E2ETestingPolicySelfTest` is one).
  Moving those onto the shared helpers is a mechanical change across many files and was left out of this one.

### R2-PROC-08: stale scratch folders are swept

PR #520 found 3,169 `selftest-process-<pid>` folders in the temporary directory and emptied only a process's own, because a sweep by dead pid alone could race a new process given that pid.
`SelfTestScratchRoot.sweepStale` adds the condition that closes the race: a folder goes only when its pid is not in use and it has not changed for an hour.
A process that took the pid over writes into the folder at once, so its folder is recent and stays.
`main.swift`'s redirect block runs the sweep over the temporary directory on every self-test or tour start.
A run through the runner leaves nothing to sweep, because the runner removes each suite's root.

Measured on the development machine: the first suite run with the sweep removed 4,145 such folders.
Seven of the 11 left name pids that are running, so they stay.
The other four name pids that root processes now hold, which `kill(pid, 0)` reports as `EPERM`, so the sweep counts them as in use and leaves them.
That is the conservative answer, and they go once those pids are free.

### R2-PROC-05: still open

The window-backed lane is 124 suites and growing.
The fix the review names is review #1's TEST-01 and ARCH-07, moving models out of controllers so the next suite can be headless, and that is an architecture change of its own.
What this branch adds is the measurement: every recorded run now carries the lane's suite count and time.

## Full review #4's process findings (`fm/grandline-review4-process-1793190000`)

### R4-PROC-01: the Home rows flake, and the re-run workflow that looked like it re-ran a test failure

`MainSplitShellSelfTest` flaked 5 of the last 20 `main` runs.
Three were the toolbar-save check #549 already fixed.
One was "overview at 998pt: the sidebar is collapsed", covered below.
The fifth, on #551's push, was `checkHomeRowsFillBesideTheSidebar`: "row 1 (3 cards) ends at 1217.0pt of 952.0pt".
The row had the sidebar-open width and its cards the sidebar-away width.
Opening the sidebar narrows Home's clip view without resizing the window, and Home reflows on the next main-queue turn after that.
The case asserted after `settle`'s one 50 ms turn, which on a loaded runner sometimes did not include the reflow.

How that was established rather than guessed:
- A replay of the case 20 times on CI, alone, passed every time (and 20 more on the runner's re-run), so it needs the load of the cases before it.
- Asserting with no run-loop turn at all fails every sidebar-open step locally, with exactly CI's shape.
- With the new wait (`settleHomeGrid`, which waits for `HomeCanvasController.gridIsCurrentForTests`), that injected variant passes.

The re-run workflow had not re-run a test failure: the run for #551 has one attempt, and the workflow's log says it declined.
It looked as if it had, because its single job started for every failed `main` run and finished green.
It is two jobs now, and the `rerun` job only starts when `CI infrastructure` failed.
The 998pt flake recurred on this PR's own first CI run, so it was traced too.
`checkNoPageGrowsTheWindow` resizes to the narrowest width that keeps the sidebar, which includes a legacy scroller's track while the system draws them.
A traced replay on CI measured 1013pt for Overview, and both failures had measured 998pt: the same sum without the track.
CI's runner changes `NSScroller.preferredScrollerStyle` after launch, the shell re-fits on that notification, and the sidebar correctly stepped aside at a width that no longer had room.
The check now re-measures after the resize until the floor holds.
A simulated flip (the floor raised by a track and the notification posted during the resize) fails the old check with the same message and passes the new one.

A third check in the suite failed once on this PR's second run: "setPosition left the sidebar at 264.0pt holding at 499.5, want 224.0" (the divider placement the review named as the likely suspect).
It is **not** root-caused.
A traced replay on CI repeated the same sequence 25 times (1100, then 1512, then Console, then `setPosition` to 224) and did not reproduce it.
It logged the sidebar's pin range, both holding priorities, the pane widths around the placement, and every horizontal constraint at 490 or above on a miss.
That hook (a static `debugPlacementTrace` closure called from `placingDividerDidChange`) is the place to start if it recurs.

The flake rate per suite is recorded in `native/MANUAL-CHECKS.md` section 21.

### R4-PROC-03: web bundle inputs are checked in CI

Each `build-*-web.sh` now records a SHA-256 of every input (`src/` and the script) in `BUILD-INFO.txt`, through `Scripts/check-web-bundles.sh --record`.
The same script without arguments recomputes them, needs no node or network, and runs in `run-all-tests.sh`'s exhaustive and `--ci` selections.
The Excalidraw bundle was rebuilt from its lockfile, which closed `MANUAL-CHECKS.md`'s section 15a.
The rebuild is 8,451,183 bytes, the size that section measured in September.

### R4-PROC-04: a ThreadSanitizer lane, the macOS floor, and the lane ceiling

- TEST-07: `.github/workflows/sanitizers.yml` builds with `--sanitize=thread` and runs the headless selection, nightly, on demand, and on a pull request that changes the lane.
  Its first local run took 13 minutes and found two real races in the same shape: `DocsRunbookGitSync` and `StickyBoardGitSync` wrote `status` on the git queue while main read it.
  Notebook, Reading List and Code Preview had the identical unlocked code.
  All five now share `GitSyncStatusCell`.
  `ShiftGitSync`, `CredentialVaultGitSync` and `DotfilesAutoSync` already had locks of their own and guard more state under them, so they were left alone.
- TEST-10: GitHub retired its macOS 13 image, so nothing can run on the floor.
  `Scripts/check-deployment-target.sh` proves in the release job that the binary's `minos`, `Package.swift` and `LSMinimumSystemVersion` agree.
  The run-on-13 half is a manual check (section 20).
- R2-PROC-05: still not fixed at the root, for the reason above.
  `E2ETestingPolicySelfTest.checkTheWindowBackedLaneDoesNotGrowUnasked` now fails when `NEEDS_SESSION` passes 135 entries, so a new window-backed suite raises the ceiling in its own PR and says why.
  It also fails when the count drops below the ceiling, so room a suite leaves is not spent again unasked.

### R4-PROC-05

#552 had already added the state assertions after the hide-and-show round trip in `ShiftCalendarViewSelfTest`, so nothing was added.

## Full review #5's test-lane finding (R5-PROC-03)

### The window-backed audit, re-run

`NEEDS_SESSION` held 136 entries, not the 174 the review counted.
All 136 were mapped to their files and scanned for window, geometry and pixel calls, and about 35 were read in full.
The bar was strict: a suite stays if any one check reads a frame after layout, samples pixels, needs a key window or first responder, uses a tracking area, a popover, a panel or a sheet, posts an `NSEvent`, or depends on window-server visibility.

Five suites moved to the headless lane in this round.
Each mounted a real `ConsoleController` in an off-screen window and asserted only model, control or string state:

- `FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS`
- `FM_RUN_TAB_FORWARD_DRAGS_TOGGLE_TESTS`
- `FM_RUN_HERDR_RESTART_BUTTON_TESTS`
- `FM_RUN_SRE_LEAD_PER_TAB_TESTS`
- `FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS`

Each one now hosts the controller's view in a plain 900x600 `NSView`.
The ceiling in `E2ETestingPolicySelfTest` drops from 136 to 131.
To check that a moved suite still bites without a window, `quotaUsageButton.isHidden = !available` was inverted, and `FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS` failed three cases by name.

These are candidates for the next round, each with its caveat:

- `FM_RUN_COMMAND_LIBRARY_AI_TESTS`: its window hosts an empty view that nothing reads.
- `FM_RUN_VAULT_LOADING_STATE_TESTS`: strings, badges and visibility only.
- `FM_RUN_INCIDENT_RESUME_TESTS`: it already calls `viewDidAppear()` by hand.
- `FM_RUN_CONSOLE_TAB_LIFECYCLE_TESTS`: model state only, but it has 17 `orderOut` defers to remove.
- `FM_RUN_KEYED_LISTS_VIEW_TESTS`: the Reading List's column count reads the laid-out width, so give the view an explicit frame first.
- `FM_RUN_REVIEW_LOADING_STATE_TESTS`: one check is a render time budget, which may time differently without a window.
- `FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS`: no check reads a frame, but its header argues the real window matters for constraint activation, so read that first.

`ReviewTourLabSelfTest` needs its window: it checks the resized frame and sweeps rendered pixels.
Its `checkTheGrammar` half is pure, and could be split into a headless suite of its own.
The `*ViewSelfTest` suites the review named all read frames or pixels, apart from the ones listed above.

### The debug-binary handoff and the re-run workflow

- Both test jobs' "Make it executable" step now does two more things.
  It raises a warning annotation when the first download attempt failed and the second supplied the binary.
  It also fails by name if the artifact did not contain `.build/debug/GrandLine`, rather than leaving `--no-build` to fail with a runner error.
  Nothing rebuilds in its place, as before.
- `ci-rerun.yml` no longer listens on `workflow_run`.
  A `workflow_run` trigger cannot filter on the run's conclusion, so it started, and showed up skipped, for every completed `main` run.
  `CI infrastructure` now dispatches it with the run id, and only for a first-attempt push to `main` whose verdict was infrastructure.
  It waits for the CI run to complete, re-reads the verdict and re-runs the failed jobs once.

### Splitting the target (not done)

The review's recommended end state is several SwiftPM targets:

- `HelmKit` for the design system, so the widget extension could share it instead of the hand-duplicated `WidgetPalette`.
- `GrandLineCore` for stores and subprocesses.
- One target per feature family.

It was not attempted here.
The brief made it a final separate PR, only once the earlier work was merged and the split built green.
The first thing such a split meets is GL-27: the suites reach `internal` members throughout, and `FM_SELFTESTS` is a compilation condition on one target.
So a split needs either `package` access (Swift 5.9+) on what the suites touch, or per-target suite files.

## The sidebar shell's suite, split in two (2026-11-19)

`FM_RUN_MAIN_SPLIT_SHELL_TESTS` ran 1,573 checks in 297.6s on CI's window-backed shard 2, against the runner's 300s per-suite bound (`SUITE_TIMEOUT`).
Earlier runs had recorded it as a timeout, or as flaky for the same reason, and it grows whenever a page is added.
Splitting it was chosen over raising the bound, which would have taken the backstop away from every other suite.

- `FM_RUN_MAIN_SPLIT_SHELL_NAVIGATION_TESTS` (`MainSplitShellNavigationSelfTest`) is how the captain gets around.
  It covers the routes, the window keeping its size, the sidebar, the tabs, the toolbar, Back and Forward, the calendar button, Console and Home's cards.
- `FM_RUN_MAIN_SPLIT_SHELL_PANES_TESTS` (`MainSplitShellPanesSelfTest`) is the frame around the page.
  It covers the inspector, the page's first content, the lock, the content reaching the foot, the focus chip, the sidebar's width, toasts, the account menu, and Notebook's and Tasks' fit.
- `MainSplitShellHarness` holds the one setup both use, so each half mounts its own shell from the same state.

The seam follows the old file's own numbered areas, and the balance is by CI time rather than by count.
A CI replay that timed every check put the old suite at 275.6s, with the navigation half at about 137s (1,102 checks) and the panes half at about 132s (468 checks).
`checkNoPageGrowsTheWindow` alone is 64s of the navigation half.
The halves together run the same 33 checks, each once, with every check's body unchanged.

Two things came with it:

- `windowBackedSuiteCeiling` went from 135 to 136, for a split rather than a new suite.
- `SHARD_WEIGHTS` was refreshed from the medians of 10 green CI runs.
  It had the suite at 48s against a measured median of 254s, and `FM_RUN_REVIEW2_UX_TESTS` at 36s against 122s.
  Against those medians, main's table put the three shards at about 682s, 817s and 846s of suite time.
  The refreshed table puts them at about 781s, 788s and 780s.

One local trap, measured while timing the checks: a single check took 904s in one local run and 3.3s in the next, on a machine with a load average of 21.
A local per-check time from a loaded or sleeping machine is not a measurement, so the split used CI's.

## The recurring CI failures (full review 2026-11-25, T-01 and T-02)

### T-01: the nightly ThreadSanitizer run

The nightly run failed every night from 2026-11-19 on, on four reports, and nothing said so.

- `DocsRunbookStore.debugInitCount` and `SRELead.claudePathOverrideForTests` are behind locks (GL-28).
- `DevOpsHubModelSelfTest.fetch` hands URLSession's answer across under a lock.
- SwiftTerm's `LocalProcess` writes `running` and `childfd` from its PTY read queue while the main thread reads them.
  That is vendored code with no seam, so it is two narrow suppressions (`race:LocalProcess.childStopped`, `race:LocalProcess.childProcessRead`) with their reason in `tsan-suppressions.txt`, not an eleventh patch.
  A local TSan build ran the three failing suites clean, including the second `childfd` report that only appeared once the first was suppressed.
  The race itself fires rarely, so the patterns were also proved against a small TSan program with a deliberate race in methods of the same names: two warnings and exit 134 without the file, none with it.
- A scheduled run now keeps its state on one GitHub issue, "Nightly ThreadSanitizer run is failing", opened or commented on by a failing run and closed by the next green one.
  The review suggested the app's weekly "Manual checks due" schedule instead, but that runs weekly and would need a GitHub token in the app.

### T-02: window-backed flakes on main

Main went red on three of eight merges for suites each pull request had passed.

- The three checks wait on what they assert instead of a fixed pump: the Daylight cards' render (the 2s bound is now 15s, and a timeout says so), the Connect button's window, and the settled window width with the band moved in.
  The last one's message used to blame the width when the band was the missing half.
- `run-all-tests.sh --accept-flaky`, passed by CI's windowed job on a push to main only: a suite that failed and then passed on its re-run is a warning annotation and a job summary line, and stays `flaky` in the history.
  A suite that fails twice still fails, and a pull request's run never accepts a flake.
- `native/CI-FLAKES.md` is the tracked list, with the three fixed here.
