# The production-readiness review (phases 1-4, GL-01..GL-38)

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

## Production-readiness phase 1 (`fm/grandline-review-phase1-stabilize`)

The stabilisation pass over the captain-approved production-readiness review (`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md` on the firstmate side, findings GL-01..GL-38). Phase 1 was the "stop irreversible loss" slice; phases 2-4 (the shared `Subprocess` runner, `os.Logger`/Health, throwing persistence, CI, the accessibility sweep, architectural splits) are deliberately still open. Read that report before picking up any GL-numbered work - what follows is only what future sessions need to *not re-derive*.

- **`StoreLoadFailure.swift` is the one place a store backs up a file it could not decode (GL-01), and the rule it encodes is the important part: "file missing" and "file present but unreadable" are different states, and a single `try?` collapses them into the first.** Missing legitimately means "start fresh"; unreadable means real data is there and the only safe response is to preserve it before the next atomic write destroys it. `HostStore` had this right; `SSHKeyStore`, `SnippetStore` and `DictationStore` did `(try? decode(...)) ?? []` and then persisted over the file on the very next mutation. All four now share `StoreLoadFailure.decodeJSON`, each exposes a `loadFailureBackupPath`/`loadFailureBackupPaths`, and `main.swift` toasts every one of them at launch (staged a few seconds apart) - backing the file up is the durability half, saying so is what makes it recoverable. The backup is a **copy**, not a move, on purpose: a transient failure (a partial write, a file being hand-edited at that instant) can still be read successfully on the next launch. **Any new JSON-backed store must go through this helper**, and the same reasoning applies to a new field on an existing store - see the `fm/cockpit-fix-host-decode-regression` gotcha above for the *other* half of the same lesson.
- **Shift's YAML half of GL-01 needed a different shape, because a parse failure there was propagating off-machine.** A single hand-edited syntax error made `readList` return `[]`, `reloadAll` kept that silently, the next `addTask` wrote a one-task file over every real task, and the debounced `ShiftGitSync` committed and pushed the wipe to GitHub - git history was the only recovery. `ShiftYaml.readListChecked`/`readMappingChecked` now return `.ok`/`.missing`/`.parseFailed` (the plain `readList`/`readMapping` are thin wrappers kept for read-only callers), and `ShiftStore` tracks `loadFailurePaths`: while a path is in that set, `writeListGuarded` refuses every write to it **and** `notify()` suppresses `markDirty()` entirely, so nothing local is overwritten and nothing is synced. A successful re-read clears it, so repairing the file and reloading resumes writes with no relaunch. Two subtleties worth keeping: a document that parses but has no top-level key for the list is `.ok([])` (that is exactly what `writeList` produces for an empty list - treating it as damage would make an empty Shift permanently read-only), and a file that parses to something that is *not* a mapping is `.parseFailed`, since `writeList` can never produce that.
- **`CommandLibraryStore.scanCommandsChecked()` exists because `scanCommands()` returned `[]` for both "empty library" and "could not enumerate the root" (GL-21), and `seedIfEmpty` then wrote 73 seed files over whatever was really there.** The seeder now requires `!enumerationFailed && commands.isEmpty`. Note the check is specifically about enumerating *the root*: a failed category directory or one unparseable command file is a partial read, and cannot make the library look empty on its own.
- **`SingleInstanceGuard.swift` (GL-05) is three layers, and each covers a case the others cannot.** `LSMultipleInstancesProhibited` in the bundle's Info.plist makes Launch Services activate the running copy on a normal double-click (so the Swift code never runs); the `NSRunningApplication` bundle-id check covers paths that bypass Launch Services (`open -n`, running the binary inside the bundle directly); and an advisory `flock` on `~/Library/Application Support/FirstmateCockpit/instance.lock` (override `FM_INSTANCE_LOCK_FILE`) covers an unbundled `swift run`/`.build/debug` binary, which has no bundle identifier at all - which is the case AGENTS.md's own worktree warning is about. The lock fd is deliberately leaked for the process's lifetime: the kernel drops it on any exit including a crash, so there is no stale-lock recovery path to get wrong. **It is called from `main.swift` immediately before `AppDelegate()` and after every `FM_RUN_*_TESTS` block** - that ordering is load-bearing in both directions: `AppDelegate()` is the line that constructs every store, and a headless self-test must never contend for the captain's real lock. A guard that cannot open its lock file at all fails *open* (logs and proceeds) - a guard that cannot run must not prevent the app from starting.
- **`SingleInstanceGuard`'s `NSRunningApplication` layer (the middle of the three above) can report a genuinely-dead pid as "running" for 15+ minutes, and this is what caused a real, captain-reported "I can't open the app after rebuilding" incident (`fm/fix-grand-line-failing-to-open-after-reb-5d`) - not PR #344's new credential vault, which was the initial suspect and was cleared by evidence.** The unified log (`log show --predicate 'process == "FirstmateCockpit"'`) proved the timeline directly: the real instance quit cleanly via a genuine `NSApplication.terminate:` (full AppKit termination sequence logged, ending "Termination complete. Exiting without sudden termination."), and `launchd` itself confirmed the reap a moment later ("removing child: pid/NNNNN", "termination reported by launchd (0, 0, 0)" - exit 0, no signal). Yet `otherRunningInstance()`'s `NSRunningApplication.runningApplications(withBundleIdentifier:)` call kept returning that exact dead pid as a live candidate on **every** subsequent launch attempt for over 15 minutes (7+ real relaunch attempts logged, each self-exiting silently with no crash, no dialog, no Dock bounce that stuck - exactly "the app won't open" from the outside). `lsappinfo`/`lsappinfo find` did **not** show it as running at the same moment - the staleness is specific to the `NSRunningApplication` API, not a kernel-level zombie. **Fix**: `otherRunningInstance()` now verifies a candidate's pid is actually alive (`kill(pid, 0)`, the standard POSIX no-signal liveness probe - `ESRCH` means genuinely gone, any other failure such as `EPERM` still means alive) before trusting it; a stale candidate is logged and discarded, which is what lets `acquire()` fall through to the `flock` layer (layer three, kernel-managed, never subject to this staleness since the lock releases atomically on process death however it dies) instead of trusting a lying API forever. Covered by `Phase1HardeningSelfTest.staleRunningApplicationPidIsNotTrusted()` against a real spawned-then-reaped `/usr/bin/true` child (never a made-up pid, so a coincidentally-reused number on the test machine can't pass this by accident) via the new test-only `SingleInstanceGuard.isProcessAliveForTests(_:)` seam - confirmed live to catch the exact regression by scripted revert. **A plausible but unproven contributing trigger, worth knowing before re-deriving it**: `build_native_app.sh`'s auto-install step does `rm -rf` then `ditto` on `/Applications/Manjesh Grand Line.app` while a prior instance may still be alive and holding that exact bundle path registered with Launch Services - this file's own README claims that swap is safe ("the running process keeps its own open file handles... so the swap only affects the next launch"), which is true for the process's *own* file access but says nothing about `NSRunningApplication`'s external bookkeeping, and is exactly the kind of disruption that could explain why this staleness episode happened on a rebuild specifically rather than an ordinary quit/relaunch. Not confirmed as the root mechanism (that would need instrumenting Launch Services itself), but the fix does not depend on knowing it - it makes the app resilient to the staleness regardless of what triggers it.
- **GL-02's pipe rule, for whichever site is touched next: drain both pipes concurrently and *then* wait, or use `FileHandle.nullDevice` for a stderr nobody reads.** `waitUntilExit()`-then-read deadlocks the moment the child writes more than one pipe buffer (~64KB) - `FleetDataSource.mergePR` had exactly that, which is why a chatty merge script left the Merge button disabled for the session. Reading stdout to EOF and *then* stderr is only half a fix: it still deadlocks on a child that fills stderr while stdout is open. `mergePR` and `SSHKeyGenerator.run` now use a `DispatchGroup` over a concurrent queue, and five `proc.standardError = Pipe()` sites in `FleetData.swift` that never read became `FileHandle.nullDevice`. **~12 helpers still carry the half-fixed stdout-then-stderr order** (`UpdatesData`, `GitHubSyncData`, `ShiftGitSync`, `VaultData`, `SRELeadRunner`, `DictationCleanup`, `SRELeadPostmortem`, `LogAnalyzerAI`, `DocsRunbookData`, `TmuxMirror`) - deliberately left for the phase-2 shared runner rather than hand-fixed twelve times, since that runner deletes all twelve copies.
- **`BackgroundSignalsPoller`'s `isChecking` latch has a wall-clock watchdog (GL-03), and it needs a pass id, not just a timestamp.** One hung child used to mean every future tick returned on `guard !isChecking` and four notification signals went dark for the session with no signal at all. A pass older than `passWatchdog` (5 min) is now superseded by a new one - but a superseded pass still finishes eventually and reaches the completion block, so only the pass whose `currentPassID` still matches may release the latch (otherwise it clears it out from under its replacement and a third pass starts alongside). It does **not** kill the wedged pass - there is no handle to its children until the phase-2 runner exists; a late writer is stale-but-valid because every publish is an idempotent `NotificationSources.set*` with a freshly-computed count.
- **`ConfigRepoPrivacy.swift` (GL-22) asserts `manjesh-config` is private before any push, and the one decision worth not re-litigating is that `.unknown` never blocks.** No `gh`, offline, rate-limited, a token without repo scope - all ordinary, all must still sync. Only a *confirmed* `"private": false` refuses. Confirmed-private is cached for the process lifetime (the alternative is a `gh api` round trip before every debounced Shift commit); confirmed-public is **not** cached, so fixing the visibility and carrying on needs no relaunch. Gated at all four real push sites (`ShiftGitSync.pushOnly`, `DocsRunbookGitSync.pushOnly`, `VaultRecipeGit.export`, `GitHubBackupSource.export`), each scoped to the real remote so a self-test pointed at a disposable bare repo via `FM_SHIFT_REMOTE_URL` never shells out to `gh`. `GitHubSyncData`'s push is untouched - that targets a fork, which is public by design.
- **GL-08: `--` goes before the destination in every ssh argv builder, and a leading `-` is rejected at save time, import time and quick-connect.** The attack is one field: an address of `-oProxyCommand=<cmd>` is read by ssh as an option and runs `<cmd>` locally on Connect, and the realistic delivery vector is a tampered `.glbackup` (which restores hosts verbatim, including a GitHub-fetched bundle). `Host.hasUnsafeLeadingDash`/`unsafeFieldNames` are the shared check; `BackupImport.diff` drops an offending host from `hostRows` entirely and reports it in `rejectedHostWarnings`, so `apply` (which works off `hostRows`) cannot write it even if the captain approves the import. Note `connectSSH` *prepends* `-i <path>`, so keeping `--` inside the builders - immediately before the destination - is what survives that.
- **GL-13: `ProcessInfo.beginActivity`'s options matter as much as holding the assertion.** `AppLock` held `[.userInitiated, .idleSystemSleepDisabled]` for the app's lifetime; the assertion is genuinely needed (App Nap stops a backgrounded app's timers - measured), but `.idleSystemSleepDisabled` told macOS the whole *machine* must not idle-sleep while the app was open, which nothing here needs: `tick()` compares wall-clock `Date()`, so a Mac that slept two hours locks correctly on wake. Now `[.background]`, which still opts out of App Nap suspension. Also removed: `ShiftGitSync.pullNow`'s unconditional `pushOnly()` on the nothing-to-pull path, i.e. a `git push` every 5 minutes with nothing to send - it now pushes only when local is genuinely ahead (`!headBehindOrEqual`).
- **GL-14: an empty PR list and a failed PR fetch must not render the same.** `OpenPRsSource.fetchDetailed()` returns a `FetchResult` (`prs`, `failedRepos`, `projectsUnreadable`, `isDegraded`, `failureSummary`), and `githubOpenPRs`/`bitbucketOpenPRs` now return `nil` for failure versus `[]` for "genuinely no open PRs". Review renders a distinct `wifi.exclamationmark` empty state per forge (its own cached `NSUserInterfaceItemIdentifier`, because `HelmEmptyState`'s glyph is fixed at `init` and only its words can be rewritten - one reused instance would show `checkmark.seal` above an "I couldn't reach GitHub" message) and shows `?` instead of a count; Overview's tile shows an em dash with a warn tint and its banner says "PR status unavailable" rather than "0 PRs ready". A directory that simply is not a git clone is still skipped silently - that is not a failure to reach a forge and must not trip the degraded state.
- **GL-16 (partial): looping decorative animations are gated on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, with a live `accessibilityDisplayOptionsDidChangeNotification` observer so toggling the setting takes effect immediately.** Done for the lock screen's boat bob + wave drift and the rail mark's bob. The lock screen's failure shake and success sail-away are deliberately **not** gated: they are brief and non-looping, and the success one carries the `CATransaction` completion block that actually lifts the overlay - changing it risks a state where the password is accepted and the app never unlocks. The rail's heavier unlocked symbol weight is also not gated: a static weight change is not motion, it is the state signal.
- **Version comes from `git describe` now (GL-18), not a constant.** `build_native_app.sh` splits it: `CFBundleShortVersionString` takes the leading dotted-number run (Launch Services requires a plain dotted number) while `CFBundleVersion` takes the full describe string including commits-ahead, SHA and `-dirty`. Falls back to `0.0.0` rather than failing the build when tags are missing. `v0.1.0` is the repo's first tag, placed at `186b879` - **cut a release by tagging**, not by editing a constant.
- **`./Scripts/run-all-tests.sh` runs every suite (GL-19), and it discovers its list from `main.swift` rather than hardcoding it**, so a new suite joins the run automatically and the script cannot drift. Per-suite output is captured and shown only on failure. Its `SKIP_FLAGS` list is for suites that need something the script genuinely cannot provide (currently only the real-Whisper-model one) with the reason inline - a suite added there because it is *flaky* is a bug to fix, not a suite to skip. The repo-root README now carries the testing convention, the worktree-launch warning, and a verified index of all 25 `FM_*` behaviour/location env vars.
- **Two permanent suites came out of this pass, both confirmed to catch a real regression rather than merely to pass** (reverting the `--`, the `SSHKeyStore` backup and the Shift write-refusal each reproduced a specific named failure): `FM_RUN_STORE_DURABILITY_TESTS` (GL-01/GL-21 - every case proves the *original bytes are still on disk* after a post-failure write, since "the store loaded zero items" was true before the fix too) and `FM_RUN_PHASE1_HARDENING_TESTS` (GL-05/GL-08). The single-instance case needs a genuinely separate process to prove anything - `flock` is per-open-file-description, so re-acquiring from the same process succeeds and proves nothing - so it spawns a small `python3` child that takes the same advisory lock, and then re-runs it after release so a probe failing for an unrelated reason cannot make the test pass vacuously.
- **Verified with `swift build` (clean, zero warnings) plus all 43 runnable suites passing, deliberately without ever launching the app** - see the worktree rule above, which this pass also wrote into the README's front door.

## Production-readiness phase 2 (`fm/grandline-review-phase2-harden`)

The "harden the machinery" slice of the captain-approved production-readiness review
(`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`, findings
GL-01..GL-38). Phase 1 was the stop-irreversible-loss pass; this one builds the shared
infrastructure everything else rides on. Phase 3 (the full accessibility sweep, the
high-risk subsystem suites, Touch ID off-main, release-binary test exclusion, first-run
thread) and Phase 4 (the architectural splits) are still open - read section 31 before
picking up a GL-numbered item.

- **`Subprocess.swift` is the app's one subprocess runner, and a hand-rolled `Process()`
  outside it is now a self-test failure (GL-02/03/04/15).** It replaced ~25 call sites in
  21 files, seven `resolveExecutable` copies, ten result structs and four identical
  git-auth blocks. The thing worth internalising is *why* the duplication mattered: the
  three deadlock shapes it hid were not hypothetical, and the middle one is the trap.
  About twelve helpers drained stdout to EOF and stderr only afterwards, each with a
  comment explaining the pipe deadlock they thought they had fixed - and all twelve still
  deadlocked, permanently, on any child that filled the 64KB *stderr* buffer while stdout
  was open (`npm -g`, `brew upgrade`, git advice output, a `gh`/`av` failure spew). Both
  streams are drained concurrently now, via `readabilityHandler` into a locked buffer.
  - **`readDataToEndOfFile()` on a background thread is not an acceptable drain**, which
    is why `StreamCollector` uses handlers. That call does not return until *every* writer
    closes the pipe, including a grandchild that inherited it (`brew` and `npm` both spawn
    such children) - so a timeout could kill the child and still leave a thread blocked on
    the pipe forever. A handler can be torn down; a blocked `read(2)` cannot.
  - **Every run is bounded**, with SIGTERM then SIGKILL after a short grace, and returns
    partial output with `timedOut == true` rather than parking its caller. This is what
    makes `BackgroundSignalsPoller`'s watchdog a backstop rather than the only defence.
    Long operations pass their own value (`brew`/`git clone` are minutes, legitimately);
    the point is that nothing is unbounded, not that everything is fast.
  - **`signal(SIGPIPE, SIG_IGN)` is installed once, lazily, from the first run** - and it
    is load-bearing, not hygiene. Any child that exits without reading all of its stdin
    leaves the writer holding a broken pipe, and SIGPIPE's default disposition kills the
    process. Found live: the self-test's own "child ignores a large stdin" case took the
    whole binary down with exit 141 before this line existed.
  - **Secrets travel in `extraEnv`, never argv** (`ps` shows argv), and
    `Subprocess.gitAuthEnvironment` is the single copy of the GitHub Basic-auth
    `http.extraheader` block. It returns nothing for a non-`https://` remote, which is what
    keeps every disposable-bare-repo self-test in this project working.
  - **`FM_RUN_SUBPROCESS_TESTS=1`** is the guard, and it does two things rather than one:
    it proves the runner survives an stderr flood, *and* `legacyDrainOrderStillDeadlocks`
    runs the pre-fix drain order against the identical child in-process and asserts it does
    **not** finish. A passing flood test proves nothing unless the flood can genuinely
    deadlock a reader. **Confirmed to catch a real regression**: injecting the pre-fix
    order into the shared runner did not merely fail the suite, it hung the whole binary
    (no output at all, killed at 40s) - exactly the shipped bug's own signature.
  - Deliberately out of scope: interactive/PTY work. Every terminal tab (including the
    one-shot Console command tabs) forks through `LocalProcessTerminalView` and has nothing
    to do with `Process`; a real `sudo` prompt still needs a real terminal, which is why
    Bootstrap and Settings route through a Console tab.
- **`ClaudeOneShot.swift` is the one `claude -p` runner (GL-26).** Five copies had drifted
  in ways that were bugs rather than decisions: four bounded the wait (20/20/45/120s) and
  `SRELeadRunner` did not bound it at all, so a wedged `claude` left an SRE Lead turn
  spinning forever; all five had GL-02's half-fixed drain order; and three treated an empty
  `result` as failure while two accepted it. Now one parse, one contract (main thread,
  exactly once), and `SubprocessCancellation` for the one caller that needs to kill a turn
  early. **Called-out behaviour change:** an SRE Lead turn is now bounded
  (`ClaudeOneShot.conversationTimeout`, 300s). The per-caller `claudePathOverrideForTests`
  seams are all preserved, which is what keeps the existing fake-`claude` suites working
  untouched. `LogAnalyzerAI.parseEnvelope` survives as a thin adapter because
  `LogAnalyzerSelfTest` drives it directly.
- **`AppLog.swift` is the one logging surface (GL-11).** `os.Logger`, one subsystem
  (`com.firstmate.cockpit.native`, a literal - `Bundle.main.bundleIdentifier` is `nil` for
  the plain `swift build` binary this project documents as the dev flow), categories from
  the review's own list. Two rules: every catch-and-degrade site logs the underlying error
  *before* degrading, and nothing leaves the machine. The "don't log a secret value" rule
  is unchanged and is not delegated to `os.Logger`'s interpolation privacy. The seven
  remaining `NSLog` sites are gone.
- **`ServiceHealth.swift` + the `.health` rail destination is F1** (moved off Settings by `fm/grandline-health-sidebar-move` - see that bullet below for the move itself). A registry, not a monitor: it polls
  nothing and never decides a service is unhealthy on its own - each service reports its
  own outcomes, so "healthy" stays defined by the thing that knows. `failureThreshold` (3)
  is what makes a Notification Center entry mean "still broken" rather than "the network
  blipped once". Reporters are background queues, observers are views, so the state is
  lock-guarded and observers always fire on main. Wired from `BackgroundSignalsPoller`
  (including its watchdog firing, which was previously invisible), `FleetNotifier`,
  `ShiftGitSync.setStatus`, and `ShiftNotificationScheduler`.
- **`PersistenceFailureReporter` + `AtomicWrite` are GL-10/GL-30.** ~25 `try?` writes across
  `ShiftStore`, `CommandLibraryStore`, `DocsRunbookData` (plus the four JSON stores' own
  persist paths) now report instead of swallowing. The convention: **`try` at the write,
  `report` at the store** - the store method has the "which record" context a throw
  propagated to a view would lose. It deliberately does *not* roll back the in-memory
  model: keeping the edit visible so the captain can retry beats discarding their work a
  second time. `Phase2HardeningSelfTest.noSilentPersistenceWrites` greps the three files
  the finding names, so a reintroduced `try?` fails the test run - and that guard is what
  told this task the work was not finished yet, twice.
- **`AppLockGate.swift` closes GL-09.** The lock overlay is a subview of the main window
  and `setContentMenusEnabled` disables menu *items*, so before this everything outside
  that window kept working while locked: the menu-bar status item kept showing the due
  count and opening a popover that discloses the next follow-up, its quick-add kept writing
  *and pushing* tasks, ⌥Space kept capturing, dictation kept recording/transcribing/pasting,
  and a `.floating` Host Editor stayed fully usable above the lock screen. The gate is one
  tiny piece of shared state anything may read, because those surfaces are two global
  `NSEvent` monitors, an `NSStatusItem` and a floating window - none of which has a path to
  the shell controller, and giving them one would point four dependencies the wrong way.
  **Rule for adding a surface:** if it runs while the main window is not frontmost *and*
  either shows or writes the captain's data, it consults `allows(_:)`; add a case rather
  than reusing a related one. Secondary windows register a provider closure rather than the
  gate sweeping `NSApp.windows` - that array contains AppKit's own `NSStatusBarWindow`, and
  ordering that out would break the status item rather than secure it. Dictation's `onUp` is
  deliberately *not* gated: a recording started before the lock still has to be stopped, or
  the microphone stays open.
- **GL-38 (resolved captain decision): the merge action passes the task id.**
  `bin/fm-pr-merge.sh` takes `<task-id> <pr-url>` and validates the id, and for its whole
  life `FleetDataSource.mergePR` passed only the URL - so the script's own argument guard
  rejected every invocation. The id was never missing: `MergedPR.taskID` carries it and the
  Review row's button identifier has held `"<taskID>\0<url>"` since it was written. Nothing
  asserted the argv shape, which is the actual lesson. `mergeArguments`/`canMerge` exist so
  the contract and the row's gating are one definition;
  `Phase2HardeningSelfTest.mergeCommandCarriesTheTaskID` pins it.
- **Touch ID cancel (resolved captain decision): cancelling aborts the connect.** It used
  to fall through and start `ssh` without `-i`, silently downgrading to agent auth - wrong
  twice over, because the captain who pressed Cancel did not ask for a connection by other
  means, and on a host that *does* accept agent auth the downgrade succeeds so the "no" has
  no visible effect at all. `KeychainKeyStore.classify` maps `.userCancel`/`.appCancel`/
  `.systemCancel` onto `KeychainError.userCancelled`; `connectSSH` catches that one case and
  returns. A genuine *error* (deleted key, Keychain fault) still falls through to agent auth
  - that is an accident, not a decision. Tested through `classify` directly, which is the
  only way to cover this without a real biometric prompt.
- **Launch path (GL-12/23/24).** Mirror-backend resolution is asynchronous
  (the since-deleted `FirstmateBackend.resolveMirrorTargetAsync` - E1 removed the resolution entirely, so this launch path now makes no subprocess call at all): it was three serial subprocess calls on
  the main thread from inside `ConsoleController.loadView`, i.e. inside the eager embed loop
  *before* `makeKeyAndOrderFront`, so up to ~9s landed as a pre-window beachball. The
  mirror tab is created immediately (tab order and ⌘1…⌘9 numbering unchanged), marked
  `isAwaitingMirrorResolution`, shows a "Resolving the fleet's backend…" line, and has its
  launch pair written exactly once before its process ever starts - which is why
  `TabModel.launch` became `var` and why that does **not** weaken
  `fm/grandline-mirror-resolve-race-fix`'s frozen-pair invariant (one call, both values,
  frozen before the first start, replayed on every reconnect). Settings' tmux session list
  loads off the main thread, and its theme observer no longer fetches at all: **a theme
  observer repaints, never fetches** (`repaintForTheme()` is the repaint-only half). One
  shared `CommandLibraryStore` replaces two caching instances that diverged in-session and
  raced each other's `recent.yaml` - the "independent store instances" convention was
  established for a store that re-reads disk per call and does not transfer to a caching,
  writing one.
- **GL-20 resize gating: the cheap check, not a debounce.** `reassertBodyContainerWidthTie`
  used to force a full-tree `layoutSubtreeIfNeeded()` on every resize *frame*, resolving
  every mounted destination plus every per-host console and defeating the child
  controllers' own visibility gates. A debounce was tried first and is **wrong here** - it
  broke `AppShellBodyWidthSelfTest`, because the whole point of #231's fix is that the
  frame is correct *synchronously* after a resize. The gate is a staleness comparison
  instead: `root` is the window's `contentView` (the OS keeps its frame in sync
  unconditionally), so `bodyContainer.frame.width` vs `root.bounds.width - rail width` costs
  two frame reads and no layout, and only a genuine disagreement (or a deactivated
  constraint) pays for the resolve. Log Analyzer's six tabs are lazily mounted (built on
  first selection, then kept - a tab's inputs must survive switching away), which needed the
  Compare and Evidence tabs' implicitly-unwrapped views guarded and re-rendered on mount.
  `HostsListSection.clipViewResized` is gated on visibility.
- **GL-28: the two remaining races.** `ShiftGitSync`'s `status`/`statusHandlers`/
  `pendingConflictSet` are written from its serial git queue and read from the main thread -
  a torn read of an enum with a `String` payload, not merely a stale value - now behind one
  lock, with no lock held across a handler call. `DictationAudioResampler`'s sample array is
  appended from `AVAudioEngine`'s real-time audio thread and read from main; a reallocating
  append concurrent with a read can hand out a freed buffer, so it is locked too (around the
  array only, never across the conversion).
- **GL-14, the rest: an offline failure must not read as a tool bug.** `QuotaSource` used to
  surface `quota-axi`'s raw stderr and `BackupGitHub` printed a literal "HTTP -1" (its
  sentinel for "there was no HTTP response at all"). Both now name the recognisable
  offline/auth shapes and fall back to the real output for anything unrecognised - inventing
  a friendly message for an unknown failure would hide the one thing worth reading.
- **CI is real (GL-07).** `.github/workflows/ci.yml` on every push and PR: `swift build`
  with a hard failure on any warning in `Sources/FirstmateCockpit` (the vendored C/C++ is
  not this project's to fix), plus `./Scripts/run-all-tests.sh --ci`. `--ci` skips the
  suites needing a real login session or the machine's Keychain, and that list lives in the
  script with a reason per entry so CI and a local run cannot disagree about what "the
  tests" are. CI points every `FM_*` data-location override at a scratch directory, so a run
  never attempts a real clone of the private config repo. The runner also lost its
  `mapfile` dependency (macOS ships bash 3.2).
- **Verified with `swift build` (clean, zero warnings in this app's sources) and all 46
  runnable suites passing, without ever launching the app** - see the README's
  worktree-launch rule, which this pass did not relax. Two suites are new
  (`FM_RUN_SUBPROCESS_TESTS`, `FM_RUN_CLAUDE_ONE_SHOT_TESTS`,
  `FM_RUN_PHASE2_HARDENING_TESTS`), and three existing ones were adjusted for real
  behaviour changes rather than worked around: `MirrorResolveRaceSelfTest` (since deleted by E1) then waited for the
  async resolution (the invariant is unchanged, only its timing), `QuotaDataSelfTest` gained
  the offline-mapping cases, and `SRELeadPerTabSelfTest.scrollbackSurvivesSRELeadToggle`
  now waits for the terminal's geometry to settle before taking its baseline - it was
  intermittently comparing SwiftTerm's 80x25 default against the first real layout (97x32),
  which is a test-timing fragility rather than a pane resizing anything.

## Production-readiness phase 3 (`fm/grandline-review-phase3-polish`)

The polish/accessibility slice of the captain-approved production-readiness
review (`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`,
GL-01..GL-38). Phase 1 stopped irreversible loss, Phase 2 built the shared
machinery; this one makes the app usable without a mouse, stops the shipped
binary carrying its own test suite, and closes the growth/first-run/undo gaps.
**Phase 4 is still open** - lazy destination mounting + the destination table
(GL-37), `ConsoleController` decomposition (GL-36), Developer ID + notarization
+ self-update (F3), and the P3 batch. Read section 31 before picking up a
GL-numbered item.

- **Accessibility is fixed in the shared components, on purpose, and pinned by
  `FM_RUN_ACCESSIBILITY_TESTS` (GL-16).** The review's finding was ~40
  `NSClickGestureRecognizer`-driven controls that VoiceOver saw as static text.
  All but four of them turned out to already host their recognizer on a
  `HoverHighlightView`, so that component is where the fix lives: it derives a
  label from its own descendant labels, answers `.button`, and
  `accessibilityPerformPress()` **replays its own recognizer's target/action**
  (with the *recognizer* as sender, because several handlers read `sender.view`
  to know which row was hit). That is what made this a one-place change rather
  than 40 call-site edits - so **do not hand-roll accessibility on a new
  clickable row; put the recognizer on a `HoverHighlightView`.** The four that
  were not: the top bar's search pill (now `PillButton: HoverHighlightView` -
  which is why `HoverHighlightView` is no longer `final`), Updates' Refresh
  pill, Shift's sync pill (both now clear-coloured `HoverHighlightView`s, which
  render identically to the plain `NSView` they replaced), and the notification
  panel's "Mark all read" label (now wrapped in one).
  - **A control that does nothing must stay silent.** `isActivatable` gates
    both the accessibility element and the key view loop, because this app is
    built almost entirely out of decorative containers and flooding VoiceOver
    with them is its own accessibility failure.
  - **`HelmSegmentedTabs`' pills announce as `.radioButton` with a live
    selected value** and handle left/right arrows via `HoverHighlightView`'s
    new `onKeyDown` seam. `HelmStatTile` is `.staticText` until `onClick` is
    set (a number is worth reading either way; a button is not). `HelmAccentRow`
    reads kicker/title/meta/chip and keeps its `trailingAccessory` reachable as
    its only child.
  - **`focusRingType = .exterior` + `drawFocusRingMask()`, never `.none`, on
    anything focusable** - and the mask has to be **inset** by
    `HelmFocusRing.inset` on a control that clips its own layer
    (`HelmButton`/`HelmPopUpButton` set `masksToBounds = true`, which would
    otherwise clip an exterior ring away entirely). The remaining
    `focusRingType = .none` sites are text fields, where the caret is the focus
    indicator.
  - **`HelmTableView` is the app's one table now**, and the subtlety worth
    knowing: all four `doubleAction` handlers read `clickedRow`, which AppKit
    leaves at `-1` for a keyboard activation - so it **overrides `clickedRow`
    to report the selected row for the duration of a Return/Space activation**
    rather than making four handlers input-device-aware.
  - **An icon-only `HelmButton` announces its tooltip, never the SF Symbol
    name.** Left alone, AppKit derives something like "refresh" from
    `arrow.clockwise` - confirmed by injecting the regression.
  - The dictation HUD's pulse was the one looping animation Phase 1's Reduce
    Motion pass missed; it is gated and observed now, like the lock screen's
    boat/wave and the rail mark's bob.
- **GL-32 shipped as the floor plus the hook, not the full text-scaling
  system.** `HelmType.minimumUIPointSize` is 11 and every accessor goes through
  `HelmType.scaled(_:)`, which multiplies by `ChromeTextScale.shared.scale` and
  clamps to that floor - so the kicker went 10 -> 11 and `HelmStatTile`'s
  caption 10.5 -> 11, and a new role added to `HelmType` cannot bypass the
  floor. `ChromeTextScale` (in `FontSizeManager.swift`, deliberately its
  sibling: that one is the *monospace/terminal* size) is persisted as
  `AppSettings.uiTextScale`, offered as Default/Large/Larger in Settings >
  Terminal, and a change is turned into an app-wide repaint by
  `ThemeManager.reapplyCurrentTheme()` - **a scale change rides the theme
  observer every page already has, rather than a second app-wide fan-out.**
  What that does *not* cover, and is GL-32's remaining "High" half: text whose
  font is set once in a page's own `loadView` and never re-derived keeps its
  size until relaunch, and fixed table `rowHeight`s do not grow with the scale.
- **GL-25: `SSHKeyMaterializer.materialize` runs off the main thread now**, and
  `KeychainKeyStore.authenticate` carries a `dispatchPrecondition(.notOnQueue(.main))`
  so that cannot silently regress - the biometric prompt blocks its caller, and
  on the main thread that froze every window and every other terminal tab for
  as long as the captain took to answer. `ConsoleController.connectSSH` split
  into the async unlock plus `startSSHProcess` (main-thread only, SwiftTerm's
  requirement), with `TabModel.awaitingKeyUnlock` refusing a second unlock for a
  tab that already has one in flight (⌘R during a prompt is the easy way there)
  and cleaning up the scratch key file if the tab closes mid-prompt.
- **GL-34: the SRE Lead bridge's per-tick cost is a viewport read, not a
  10,000-line buffer read.** The end marker is the last thing a completed
  command prints, so it is on screen when it arrives - `currentViewportLines()`
  (via `Terminal.getLine(row:)`, which is display-relative) is the cheap probe,
  and the full `getBufferAsData()` snapshot happens twice per request instead of
  five times a second. The one case the probe cannot see is the captain
  scrolling away while a command runs (scrolling is not keystroke activity, so
  it does not trip the input guard) - covered by a full scan every
  `fullScanEvery` ticks. The idle request scan dropped to 1Hz
  (`idlePollInterval`, injectable so a hand-driven self-test does not sleep).
  Both are pinned by real cases in `FM_RUN_SRE_LEAD_BRIDGE_TESTS`, and the cost
  one was confirmed to fail on the pre-fix behaviour.
- **GL-35's caps, and what each one actually was:** dictation history is capped
  at `DictationStore.historyLimit` (the file is rewritten whole on every
  dictation) and gained a per-entry delete; `ShiftStore.allCompletedTasks()` is
  memoised (`completedTasksCache`, invalidated by the three writes that can
  change it plus `reloadAll`) because the Projects grid called it *once per
  project card* and each call re-parsed every month file; `LogAnalyzerStore.history()`
  is memoised the same way, and `directory(forID:)` now falls back to a raw
  id-in-bytes scan so a corrupt `investigation.yaml` is deletable instead of
  invisible-and-undeletable; GitHub Sync's scratch clones are
  `--single-branch --no-tags` (**not** `--filter=blob:none` - a blobless clone
  would have to lazily re-fetch blobs for the commits `syncManual` pushes,
  turning a local fast-forward into an unpredictable network operation) and
  orphaned ones are pruned; the 547MB Whisper model has a confirmed delete
  action.
- **GL-33: `Toast.showUndo` is the app's one undo, one slot.** No
  `UndoManager` anywhere - the rule instead is that `onUndo` must restore *the
  value the caller already had in hand*, which is why it is wired to host,
  snippet, dictation-vocabulary, dictation-history and port-forward-rule
  deletes and deliberately **not** to an SSH key delete: the private bytes leave
  the Keychain, and an "Undo" producing a key entry with no key material would
  be a lie. A newer pill supersedes the older one by committing it (its handler
  simply never runs). `Toast.swift`'s header also carries **GL-30's written
  rule** - modal for a blocked decision, toast for a transient confirmation,
  Notification Center for anything still true after the toast fades; Phase 2
  already wired the persistence and service-health paths that way.
- **GL-31: first run is threaded.** `AppShellController` lands on `.bootstrap`
  instead of `.console` when `FirstmateHome.homeOk()` is false (the one
  condition - no saved hosts, no Shift data and no Vault password beyond the
  lock screen's own are all genuinely fine); Overview's raw "set FM_HOME" string
  became a real `HelmAccentRow` banner with an "Open Setup" action; and the lock
  screen's unconfigured state renders `VaultSource.appPasswordSetupCommand` as a
  copyable code row instead of prose containing a command to retype - that
  constant is the single source both it and `setup-guide.md` follow.
- **GL-29 added five suites, and each one was confirmed to catch a real
  regression rather than merely to pass:** `FM_RUN_DICTATION_ENGINE_TESTS`
  (the finish/race/timeout state machine - all three of its shipped bugs
  reproduce when the fixes are reverted, and `DictationEngine.pasteSinkForTests`
  is what stops a run typing fixtures into whatever app is frontmost),
  `FM_RUN_FLEET_DATA_TESTS`, `FM_RUN_CREDENTIAL_PATH_TESTS` (real `ssh-keygen`,
  never the login Keychain), `FM_RUN_BACKGROUND_SIGNALS_TESTS` and
  `FM_RUN_ACCESSIBILITY_TESTS`. Two things came out of writing them:
  - **A real bug the Fleet suite found on its first run:** `mergedPRs`' URL
    normaliser stripped the scheme with a case-sensitive `hasPrefix` *before*
    lowercasing, so an `HTTP://`-cased PR URL kept its scheme in the dedup key
    and the same PR rendered twice, only one of them mergeable.
  - **GL-03's latch decision is now `BackgroundSignalsPoller.admit`/`mayReleaseLatch`**,
    extracted precisely because the decision was three inline lines wrapped
    around sixty subprocesses - which is what made the original stuck-latch bug
    untestable.
- **GL-27: the suites live in `SelfTests/` and are compiled into debug builds
  only.** `Package.swift` defines `FM_SELFTESTS` `.when(configuration: .debug)`;
  every file in that directory is wrapped in `#if FM_SELFTESTS`, as is
  `main.swift`'s whole dispatch chain. Measured: the release binary went from
  carrying 3,872 self-test symbols and 52 `FM_RUN_*` strings to 1 (an empty
  object-file debug-map entry) and 0. Four things to know:
  - **A compilation condition, not a second SPM target**, deliberately: the
    suites reach `internal` members throughout (that is what lets them drive the
    *real* `ConsoleController`/`DictationEngine`/stores), and a second target
    would mean widening hundreds of declarations to `public`. `@testable import`
    needs a test target, which this no-Xcode project has no story for.
  - **A new suite goes in `SelfTests/` with the guard**, and
    `FM_RUN_PHASE3_POLISH_TESTS` fails if a file there is missing it -
    confirmed by removing one.
  - **A suite that greps the app's own sources must use
    `SelfTestSources.appSourceDirectory()`**, never `#filePath`'s own directory:
    that now resolves to `SelfTests/`, and every such guard *skips* when it
    cannot find its sentinel, so they would all have gone on printing OK while
    checking nothing. The helper verifies a sentinel app file is really there,
    and deliberately excludes `SelfTests/` itself (a guard scanning its own
    suites trips on the very tokens it exists to forbid).
  - **Always test against `.build/debug/FirstmateCockpit`.** A release binary
    runs zero suites and exits 0, which looks exactly like a clean run.
    `Scripts/run-all-tests.sh` builds debug and says so; CI now also builds
    `-c release` (a genuinely separate compilation that can break on its own)
    and asserts the shipped binary carries no `FM_RUN_*` strings.
- **Verified with `swift build` (clean, zero warnings in this app's sources),
  `swift build -c release`, and all 52 runnable suites passing - without ever
  launching the app**, per the README's worktree rule, which this phase did not
  relax.

## Production-readiness phase 4 (`fm/grandline-review-phase4-strategic`)

The strategic/architectural slice of the captain-approved production-readiness
review (`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`,
GL-01..GL-38), and the last of its four phases. Read section 31 before picking
up anything still open.

- **Destinations mount lazily now, and there is one table instead of six edit
  sites (GL-37) - `DestinationRegistry.swift`.** Adding a body destination used
  to mean editing six places in lockstep (the `RailDestination` case, a stored
  property, an `addChild` line, the `embed(...)` array, a `case` in `show(_:)`,
  and a line in `hideAllDestinations()`), each of which fails differently when
  missed. It is now the enum case plus one `register(...)` line.
  `DestinationSlotID` existed because the mapping was not one-to-one: the
  four Setup pages shared one `SetupContainerController`. It is one-to-one
  again since `fm/grandline-separate-setup-destinations`, and the type is
  deliberately kept - a body view and a place you can navigate to are
  different concepts, and having them separate is what let both that un-merge
  and Poneglyph's before it be a table edit rather than a refactor.
  - **`mountsEagerly` is not a performance dial - each of its three uses is a
    named invariant, and moving one out should have to argue with the
    self-test.** `.console` owns live PTYs. `.overview` and `.review` seed the
    rail's badges at launch through `refreshIfNeeded()`, and both render that
    count *through their own views* - their view properties are IUOs built in
    `loadView`, so their render path cannot run against an unloaded
    controller. Decoupling their fetch from their render is a real refactor of
    both pages and was deliberately left out of this change.
  - **Retention is deliberate.** A mounted slot stays mounted for the process's
    life; navigating away only hides it. Tearing one down would throw away
    in-progress page state and reintroduce the failure the permanent-mount
    model exists to avoid. Host pages already worked this way, so this makes
    the fixed destinations match a model this app already relies on.
  - **The one thing to know before adding a caller:** anything that reaches
    into a destination controller must go through `show(_:)` first, or only
    assign a closure. Assigning a closure to an unloaded controller is safe and
    is what all the launch-time wiring does; touching its views is not. The
    Hosts menu's "New Host…" was the single menu item still targeting a
    destination directly and now routes through `AppShellController` like every
    other one.
  - `FM_RUN_DESTINATION_MOUNTING_TESTS` covers the table and the mounting, and
    was confirmed to catch both regressions (eager mount at launch; re-mount on
    revisit). Note *which* case catches the second: only
    `mounterIsLazyAndBuildsEachSlotOnce`, because `NSViewController` caches its
    own `view`, so a duplicate mount hands back the same view and a
    view-identity check cannot see it. Count the mount calls.
- **`ConsoleController` is six files now (GL-36), split verbatim along its own
  `// MARK:` seams** - `+Tabs` / `+Sessions` / `+Toolbar` / `+SRELead` /
  `+LogCapture` / `+TestSupport`, with the core keeping state, `init` and
  `loadView`. The split was verified line-for-line against the pre-split file
  (every non-comment line accounted for; the only additions are the six file
  scaffolds), so behaviour is identical by construction rather than by
  inspection.
  - **The cost, so nobody re-derives it:** Swift's `private` is file-scoped, so
    members reached across those boundaries are internal now. Treat every
    member of the `ConsoleController*.swift` family as private to that family.
  - **Coordinator objects were considered and rejected**, not skipped: SRE
    Lead, the toolbar and the tabs all need the current tab, the terminal card
    and each other, so a coordinator would need all three handed to it and
    would buy nothing beyond the file boundary an extension already gives.
  - **A stored property cannot live in an extension** - `blockViewShowing` is
    the one member that had to stay in the core file for that reason, and it
    says so at its declaration.
  - **The `debug*` hooks were never behind `FM_SELFTESTS`.** Phase 3's GL-27
    work moved every self-test *file* behind that flag, but these sat in a
    production file and kept shipping. They are guarded now - measured, 0
    symbols in the release binary against 10 in debug.
- **F3, the in-app self-update channel, shipped here and was later removed
  entirely** (`fm/grandline-updates-remove-app-card`) - the captain asked for
  the Updates page's "App" card gone, and nothing else in the app called into
  its check/download/verify/swap/relaunch machinery, so `AppUpdateData.swift`,
  `AppUpdateInstaller.swift`, `UpdatesController+AppRow.swift` and their
  `FM_RUN_APP_UPDATE_TESTS` self-test were all deleted rather than left as an
  orphaned feature behind a removed card. `.github/workflows/release.yml`'s
  build/zip/publish-on-a-`v*`-tag machinery was left untouched - it still
  produces a real, versioned, downloadable release for manual install
  regardless of whether anything in-app consumes it - but its own header
  comment no longer promises a consuming in-app installer or names
  `AppUpdateInstaller.expectedTeamIdentifier`, since that symbol no longer
  exists. `Subprocess.launchDetached` (below) is the one piece of shared
  infrastructure this feature used and is deliberately the one thing kept -
  it lives in general-purpose `Subprocess.swift`, outside the three named
  files, and removing it was judged out of scope for a task scoped to the
  Updates-page card.
- **`Subprocess.launchDetached` is the one fire-and-forget spawn**, added
  rather than widening Phase 2's "no hand-rolled `Process`" allowlist.
  Originally added for, and for a while its only caller, was the self-update
  relaunch helper above (whose child waited for *this* process to exit and
  therefore could not be waited on) - that caller is gone now that F3 was
  removed, so this currently has no production caller, kept in place as
  general-purpose infra rather than deleted alongside its one-time consumer.
  Keep it narrow - no stdin, no capture, no timeout - and keep new process
  spawning on `Subprocess.run` unless a future caller genuinely needs a
  fire-and-forget detached spawn.
- **Three P3 items landed alongside:** `RailDestination` moved into its own
  file (its case order is still what orders the rail);
  `GIT_TERMINAL_PROMPT=0` is set for background children in `Subprocess`
  specifically, **not** in `childEnvironmentDict()`, which also builds the
  environment for the captain's own interactive terminal tabs where git
  prompting is correct; and six per-presentation sheets
  (`PortForwardingController`, `ShiftConflictController`,
  `ShiftSnoozeCustomController`, Vault's three) now store their
  `ThemeManager` token and unobserve in `deinit`.
- **Verified with `swift build` (zero warnings in this app's sources),
  `swift build -c release`, and all 54 runnable suites - without ever
  launching the app**, per the README's worktree rule, which this phase did
  not relax.
- **Still open after phase 4**, for whoever picks up next: Developer ID
  signing and notarization themselves (captain-only), the rest of the P3 batch
  (token-based store `observe()`, `@objc protocol` for the cross-controller tab
  selectors, cached static formatters, `AppSettings.init(defaults:)`, store
  activation split from construction, state restoration, localization, the
  whisper model SHA-256 pin, `Host.password`), and GL-32's remaining half -
  text whose font is set once in a page's `loadView` does not follow a
  `ChromeTextScale` change until relaunch, and fixed table `rowHeight`s do not
  grow with it.
