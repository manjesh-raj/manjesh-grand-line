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
