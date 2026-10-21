# Test hermeticity - the `UserDefaults` leak and what it cost

Process issue P10 of the 2026-09-25 review: "UserDefaults non-hermeticity is
mitigated, not solved". This file is the account; the standing rule is in
`AGENTS.md` under "The self-test suite writes its own preference domain, not the
captain's".

The fix is `AppDefaults.store` - `UserDefaults.standard` in the app the captain
runs, a per-process `UserDefaults(suiteName:)` in any `FM_RUN_*` process, swept
at exit by `AppDefaultsSweep`. `SelfTestDefaultsGuard` was rewritten from a
repair into a check that the redirect holds, and
`Phase3PolishSelfTest.checkTheRealDomainIsNeverWritten` asserts it by doing the
thing that used to leak.

Two details from building it, both measured:

- **`removePersistentDomain(forName:)` does not delete the plist.** Six
  `fm-selftest-defaults.<pid>.plist` files were still in
  `~/Library/Preferences` after six runs that all called it: `cfprefsd` owns the
  file and flushes its own copy after `atexit` has run. Emptying the domain is
  still worth doing - it is what makes the next run see nothing - and the file
  is then removed directly, which is the part that works. Verified afterwards
  at zero leftover files across two runs, including the six already there.
- **`atexit` takes a C function pointer**, so its closure cannot capture
  context; the sweep is a static method called by name.

Everything below is the section as it stood in `AGENTS.md` before this change,
verbatim. It is the record of five separate incidents that each cost real time,
and it is worth reading if a suite ever starts failing for no reason - the
*shape* of the reasoning outlived the specific cause.

---

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


## External tools: the redirect block moved files, not programs (polish report B4)

The Grand Line vs Automic Vault polish report (2026-10-16) found its tour of the Vault page running the captain's real `av --version`, `av list` and `av doctor --json`.
Every redirect in this file moves state the process *owns* - stores, the preference domain, the Keychain prefix.
None of them reached the programs the app starts, so a test process ran the captain's real tools with the captain's real credentials.

### Measured, with stubs only

Recording stubs named `av`, `brew`, `gh`, `claude`, `herdr`, `no-mistakes` and `quota-axi`, first on `PATH`, logged argv and exited 1.
`Subprocess.resolveExecutable` looks at `PATH` before its Homebrew fallbacks, so a stub always wins, and nothing real ran.
A temporary launch log in `Subprocess` caught the absolute-path launches a stub cannot shadow.

- The Vault tour ran `av --version`, `av list`, `av doctor --json`, `brew tap automic-vault/isotopes` (which changes the captain's Homebrew state) and `brew info --cask`.
- **Every process that mounts the shell** - every tour and most window-backed suites - ran the real `fm-crew-state.sh` from the firstmate home.
  That script runs `herdr` and `no-mistakes` on its own account: `FM_RUN_HOME_FIT_TESTS` alone recorded 85 `herdr status`, 3 `herdr server --session default`, 3 `herdr pane get` and 1 `no-mistakes axi status`.
  A full local run of the suite was driving the real fleet tooling on the machine that ran it.
- The PR scan (`gh pr list`, as the captain) and `quota-axi` queue behind those script calls, so they had not started by the time the measured tour ended; given a few more seconds they would have.
- With its own guard removed, `VaultSource` went on to run `av inject +GRANDLINE_APP_PASSWORD -- /bin/sh -c ...` and `brew upgrade automic-vault/isotopes/automic-vault` from a test - against the stubs.

### The rule

Two layers, both armed only in a self-test or tour process (the same predicate as the redirect block) and only under `FM_SELFTESTS`.

- `VaultSource` refuses first, at every entry point that runs `av`, `brew` or `open`, so not even a stub `av` runs.
  Each answer is unknown, never empty (GL-14), and the Vault page says it did not look rather than blaming the approval helper.
- `Subprocess.run(executable:)` and `launchDetached` - which every other entry point funnels into - refuse the real copies of `ExternalToolGuard.protectedTools` and any script in the firstmate home.
  A refusal is a `launchFailure` plus one `ExternalToolGuard: refused ...` line on stderr.
  **A copy in a temp directory still runs**, because that is what a suite's own stub is; about twenty suites fake `claude`, `herdr` or `fm-send.sh` that way.

So a new suite that needs one of these tools writes a stub into a temp directory and points the code at it.
A new tool that reaches a real account, a shared service or the machine joins `protectedTools`, with its reason in the doc comment.

### Not covered

- Terminal tabs start their program through SwiftTerm's `startProcess`, a PTY fork that does not go through `Subprocess`.
  None of the measured launches came from there, but it is not guarded.
- `git` is not protected: suites drive it against scratch repositories, and the git-backed stores are already redirected.
- The Vault page's Recipe Backup card reads the recipe file in the captain's local `manjesh-config` clone (secret names, never values) - a file read, not a launch.

### Verified

`FM_RUN_EXTERNAL_TOOL_GUARD_TESTS` (pure logic) puts recording stubs first on `PATH`, checks they shadow the real tools before it calls anything, and asserts zero launches through six `VaultSource` entry points and the four `Subprocess` entry points, plus the backstop's rule and that the same stub runs with the guard off.
It never calls `ensureServiceRunning`: `/usr/bin/open` cannot be shadowed by a stub.
Confirmed by injection, stubs only: the `VaultSource` layer off fails with 11 recorded launches, the backstop off fails every backstop case by name.
With the guard in place the same tour and suites recorded zero stub launches, and the full suite passed with nothing relying on a real protected tool.


## The dotfiles reader ran a real `git fetch` from every tour (modular-shell stage 3)

The B4 section above says `git` needs no guard because the git-backed stores are already redirected.
One was not: the reader.
`DotfilesAutoSync`, the watcher that commits and pushes, has had `FM_DOTFILES_AUTOSYNC_PATH` since it shipped.
`DotfilesSource.resolvedDotfilesPath()`, which everything else reads the checkout through, resolved `~/.dotfiles` directly.
And that read is not passive: `DotfilesSource.repoState` runs `git -C <checkout> fetch origin <branch>`.

### How it was found

A review tour of the floating bar crashed with SIGSEGV after Bootstrap, Automation and GitHub Sync.
The crash was in `DotfilesDataTestSeam.invocations.append`, on a background queue under `AutomationController.refreshDotfiles`.
That is the defect `UpdatesDataTestSeam` already fixed for `FM_RUN_PANEL_AND_PAGE_MOTION_TESTS`: an unsynchronised `Array.append` from several threads.
Its sibling seam had been missed.
The stack also showed where the read was going: the crashing thread was inside `behindOrigin`, the function that runs the fetch, against the captain's real `manjesh-config` clone.
That clone's `FETCH_HEAD` was written three seconds before the crash.
Its mtime alone proves nothing, though, because the captain's own running instance fetches the same clone from its signals poller every few minutes.
The code path is the evidence: nothing between a tour and that `git fetch` checked where it was running.

### Who read it

Bootstrap's and Automation's dotfiles cards, the signals poller's setup-drift check, the schedule runner and the Vault recipe export.
So every tour, and every window-backed suite that mounted one of those pages, fetched the captain's clone over the network.
A fetch moves only `refs/remotes/origin/<branch>` and `FETCH_HEAD`, so the working tree and the local branches were never touched.
CI was never affected, because a runner has no `~/.dotfiles`.

### Why the standing rule did not catch it

AGENTS.md told a store whose default is outside Application Support to ask `AppPaths.isScratchRedirected()`.
That is true only under `FM_SCRATCH_ROOT`, which the probe sets and a suite or a tour does not: the redirect block sets each store's narrow override instead.
So asking it alone protects the probe and nothing else, and the rule now says so.

### The fix

- `DotfilesSource.dotfilesLocation(_:)` resolves `FM_DOTFILES_PATH`, then `FM_SCRATCH_ROOT`, then `~/.dotfiles`, the same order `DotfilesAutoSync` uses.
- `main.swift`'s redirect block points `FM_DOTFILES_PATH` at a scratch path that does not exist, so a test process reads "no dotfiles here" and runs no git at all.
- `DotfilesDataTestSeam` takes one lock, with `UpdatesDataTestSeam`'s shape: a locked `record(_:_:)` for the append, because a read-modify-write through an accessor still loses appends.

### Verified

- `FM_RUN_SETUP_DATA_LAYER_TESTS` gained two cases.
  `aSelfTestProcessNeverReadsTheCaptainsDotfiles` checks the resolver's order against fixed environments, so it is the same on every machine, and then this process's own answer.
  `dotfilesSeamRecordsEveryConcurrentRead` drives 1,600 reads from eight threads and counts the records.
- `FM_RUN_PROBE_SCRATCH_ROOT_TESTS` lists the reader with the other stores, so a resolver that skips `FM_SCRATCH_ROOT` fails by name.
- Confirmed by injection.
  With the redirect line disabled, the first case fails and names `/Users/<you>/.dotfiles`.
  With the seam's lock removed, the suite dies with SIGSEGV, the crash the tour hit, rather than failing by name.

### Not covered

Other `git -C` reads of a repository the captain owns, from a page a tour mounts, were not audited.
The ones measured here were the dotfiles clone's.
