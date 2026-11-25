# CI flakes

A suite that fails and then passes on its re-run, without a change in between, is a flake.
This file is where each one is tracked until it is fixed.
It exists because the 2026-11-25 review (T-02) found `main` red on three of eight merges for suites each pull request had passed, and nothing kept count.

## How a flake shows up

- **On a pull request** a flake still fails the run.
  `run-all-tests.sh --rerun-failed` re-runs the suite once and names it "likely flaky", but the verdict stays red, so a flake is fixed before the merge that brings it.
- **On a push to `main`** the window-backed lane passes `--accept-flaky`.
  A suite that failed and then passed is a `Flaky suite` warning annotation and a line in the job summary, and the run stays green.
  A suite that fails twice still fails.
- **Both results are kept** either way.
  The suite history (`--history`, `Scripts/suite_history.py`) records the suite as `flaky`, and the lane's summary lists every suite whose recorded results disagree.

## What to do with one

1. Add a row below the first time a suite is seen flaking, with the run that showed it.
2. Find the fixed pump or sleep the check relied on, and wait on the condition it asserts instead (AGENTS.md, "Writing a self-test").
3. Move the row to "Fixed" with the pull request that fixed it.
   If the same suite flakes again later, it goes back up with the new run.

## Open

| Suite | Check | First seen | Owner |
| --- | --- | --- | --- |
| (none) | | | |

## Fixed

| Suite | Check | Seen on main | Cause | Fixed in |
| --- | --- | --- | --- | --- |
| `FM_RUN_DAYLIGHT_MODULE_TESTS` | "Bootstrap chip is nil after a clean pass" and four more | 2026-11-20 (run 44731186275), 2026-11-23 (run 45150476006) | `pumpMainQueue` waited on the cards' render, but for at most 2s | `fm/grandline-bug-fixes-b01-b05`: the bound is 15s, and a timeout says so |
| `FM_RUN_CONNECTIONS_CARDS_TESTS` | "H3: the Connect button is not on screen" | 2026-11-23 (run 45116596604) | one fixed `settle` after putting the hero column away | `fm/grandline-bug-fixes-b01-b05`: waits for the button to be on screen |
| `FM_RUN_PAGE_REDESIGNS_TESTS` | "with a project's view hidden the window stayed 1100.0pt wide" | 2026-11-23 (run 45150476006) | one fixed `settle` after a resize; the band moves in on a later layout turn, and the message blamed the width | `fm/grandline-bug-fixes-b01-b05`: waits for the settled state and names which half was missing |
