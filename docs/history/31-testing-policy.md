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
- The pull request's own CI run is the proof of the times: CI_AFTER
