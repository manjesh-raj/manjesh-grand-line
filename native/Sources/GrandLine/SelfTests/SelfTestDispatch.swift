// Grand Line - native macOS app.
//
// The self-test dispatch (R2-ARCH-02, review #1's T-16): every `FM_RUN_*_TESTS`
// flag the debug binary answers, and the redirect block that puts every store
// on scratch first. It used to be the larger half of `main.swift` - 2,300 lines
// and 274 flags between the app delegate and the launch - so every new suite
// edited the app's entry point. `main.swift` calls `SelfTestDispatch.run()`
// at the same point in the launch as before: after nothing, before the
// legacy-name migration, `SingleInstanceGuard.acquire()` and `AppDelegate()`.
//
// `Scripts/run-all-tests.sh` discovers the suite list by grepping this file
// for the flags (GL-19), so they stay spelt out here, in dispatch order. The
// body below is the old top-level code moved verbatim, one indent deeper.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum SelfTestDispatch {

    /// Run the suite or tour this process was started for, if any, and
    /// exit with its result. Returns only when no flag asked for one.
    static func run() {
        // MARK: - Self-test dispatch (GL-27: debug builds only)
        //
        // Every `FM_RUN_*_TESTS` block below is compiled out of the release binary,
        // along with the suites themselves (see any file in `SelfTests/`). The flags
        // stay greppable in this file either way, which is what
        // `Scripts/run-all-tests.sh` discovers the suite list from - and that script
        // builds and runs the debug binary, where they exist.
        //
        // This whole block sits before `SingleInstanceGuard.acquire()` and before
        // `AppDelegate()` is constructed: every branch `exit()`s, so a headless suite
        // never contends for the instance lock and never touches the real stores.
        // F6: redirect the captain's log to a scratch directory for the whole of a
        // self-test process, unless the caller already pointed it somewhere.
        //
        // Not a precaution - a real defect this caught. `FleetLogStore.shared` is
        // appended to by `ShiftGitSync.resolveConflicts` and `LogAnalyzerStore.save`,
        // which `ShiftConflictSelfTest` and `LogAnalyzerSelfTest` both drive against
        // their own scratch stores. Those suites correctly override every store they
        // know about (`FM_SHIFT_DIR`, `FM_LOG_ANALYZER_DIR`, ...), but the fleet log
        // is reached indirectly, through a singleton neither of them constructs - so
        // a plain `./Scripts/run-all-tests.sh` wrote three fabricated events into the
        // captain's real `events.jsonl`. Doing it here rather than in those two
        // suites covers every present and future suite that reaches an append path,
        // including a single suite run by hand, which is the case a per-suite fix
        // would keep missing. Same reasoning as `CommandLibraryStore` honouring
        // `FM_SHIFT_DIR` (see AGENTS.md's DevOps Commands section).
        //
        // Pr1 extends the same treatment to the schedule stores, for exactly the
        // reason the paragraph above gives. Several suites construct a bare
        // `ScheduleStore()` purely to satisfy an initializer's parameter list
        // (`AppShellBodyWidthSelfTest`, `AppShellDrillHeaderTitleSelfTest`,
        // `DaylightHardeningSelfTest`, `DaylightModuleSelfTest`,
        // `DestinationMountingSelfTest`) and their `withScratchEnv` blocks omit
        // `FM_SCHEDULES_FILE`, so each of those *reads* the captain's real
        // `schedules.json` during a plain test run - and `ScheduleRunHistoryStore.shared`
        // (PR #289) is a second indirectly-reachable singleton with no redirect at
        // all. No suite drives a schedule write today, which is the only reason
        // nothing has been corrupted yet; AGENTS.md's own post-incident rule says to
        // close that here rather than wait for the suite that does.
        // P11: `FM_REVIEW_TOUR` arms this block too. The tour lab mounts a real
        // `AppShellController` with real stores, exactly as a window-backed suite
        // does, so it needs every redirect below for the same reason - and it is not
        // an `FM_RUN_*` flag, deliberately (see `ReviewTourLab.variable`), so it has
        // to be named here rather than caught by the prefix.
        //
        // R2-PROC-02: the predicate is `ProcessMode`, the one `ExternalToolGuard`,
        // `NetworkGate` and `AppPaths.dataRoot()` read too.
        if ProcessMode.current.isIsolated {
            // `selftest-process-<pid>`, in the runner's per-suite `FM_SCRATCH_ROOT`
            // when it gave one and in the temporary directory otherwise.
            let scratchRoot = ProcessMode.isolatedScratchRoot()
            // Pids are reused, so a folder by this name can be an earlier process's.
            // See `SelfTestScratchRoot`.
            SelfTestScratchRoot.startEmpty(scratchRoot)
            // R2-PROC-08: and the folders earlier processes left in the temporary
            // directory are swept, once their process is gone and they are an hour
            // old. A run through `run-all-tests.sh` leaves none (the runner removes
            // each suite's root); a suite or tour started by hand still does.
            SelfTestScratchRoot.sweepStale(in: FileManager.default.temporaryDirectory)
            // R2-PROC-02: every store that resolves through `AppPaths.dataRoot()`
            // follows this one variable, so a store with no narrow entry below still
            // lands in scratch. `dataRoot()` answers the same folder on its own in an
            // isolated process; setting it here also moves the widget snapshot, which
            // cannot import `AppPaths` and reads the variable itself.
            if (ProcessInfo.processInfo.environment[AppPaths.scratchRootVariable] ?? "").isEmpty {
                setenv(AppPaths.scratchRootVariable, scratchRoot.path, 1)
            }
            // TEST-09 (review #1), with R2-PROC-06: every suite reports how many
            // checks it recorded, for the runner's PASS line.
            SelfTestAssertions.armCheckCount()
            // R2-SEC-01: no request leaves this process for anywhere but loopback.
            // `ExternalToolGuard` fences the programs a suite or tour may start; this
            // fences what `URLSession` does. See `NetworkGate`'s header.
            NetworkGate.arm()
            // P4 (full review #3): the sibling of every redirect below, for the one
            // piece of shared state that is NOT a file path.
            //
            // ~44 suites change `fm.themeID`/`fm.fontSize` in this process's shared
            // `UserDefaults` domain and restore them in a `defer` - which covers every
            // normal exit and none of the abnormal ones. A SIGSEGV in a probe left the
            // domain on `catppuccin-latte` and the next unrelated run failed the
            // documented pair of suites on a clean tree. A signal handler cannot fix
            // that (`UserDefaults` is not async-signal-safe, and SIGKILL is not
            // catchable at all), so this records the starting values to a sidecar
            // before the first suite runs and recovers from one left by an interrupted
            // run. See `SelfTestDefaultsGuard`'s own header.
            SelfTestDefaultsGuard.arm()

            // P10 (2026-09-25 review): the same treatment for `UserDefaults`, which is
            // the one piece of shared state the redirects above could not cover
            // because it is not a path.
            //
            // Everything AGENTS.md documents about `fm.themeID` leaking between suites
            // - the intermittent `FM_RUN_CONTRAST_TESTS` failure on a clean tree, two
            // concurrent passes restoring each other's values, `defaults read
            // GrandLine` as the documented recovery - is a consequence of this process
            // writing the real domain. It writes a per-process suite domain now, so
            // there is nothing to leak into and nothing for a sibling pass to fight
            // over.
            //
            // Set BEFORE anything reads `AppDefaults.store`, which is a `static let`
            // resolved once. The name carries `AppDefaultsSweep`'s marker plus this
            // process's pid, so an interrupted run's domain is identifiable by the
            // next one.
            setenv(AppDefaults.suiteVariable,
                   "\(AppDefaultsSweep.marker)\(ProcessInfo.processInfo.processIdentifier)",
                   0)
            AppDefaultsSweep.arm()

            // Review bug B5: the same treatment for the Keychain, which this block had
            // never covered. `security dump-keychain` found 91 real SSH-key items
            // under the production service - one pair per suite run over two days,
            // each holding `THIS-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE` - plus 33
            // orphaned rename-migration items. A file in a temp directory is gone with
            // the temp directory; a Keychain item is not.
            //
            // Set BEFORE anything reads `KeychainService.testPrefix`, which is a
            // `static let` resolved once. The value carries the marker
            // `KeychainServiceSweep` recognises plus this process's pid, so an
            // interrupted run's items are identifiable by the next one.
            setenv(KeychainService.prefixVariable,
                   "\(KeychainServiceSweep.marker)\(ProcessInfo.processInfo.processIdentifier).",
                   0)
            KeychainServiceSweep.arm()

            if (ProcessInfo.processInfo.environment["FM_FLEET_LOG_DIR"] ?? "").isEmpty {
                setenv("FM_FLEET_LOG_DIR", scratchRoot.appendingPathComponent("fleet-log", isDirectory: true).path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_SCHEDULES_FILE"] ?? "").isEmpty {
                setenv("FM_SCHEDULES_FILE", scratchRoot.appendingPathComponent("schedules.json").path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_SCHEDULE_HISTORY_DIR"] ?? "").isEmpty {
                setenv("FM_SCHEDULE_HISTORY_DIR", scratchRoot.appendingPathComponent("schedule-history", isDirectory: true).path, 1)
            }
            // `fm/grandline-sticky-board`: the same lesson, caught live during this
            // task's own verification rather than in a later follow-up. Any suite -
            // including this feature's own `StickyBoardViewSelfTest` - that
            // constructs a real `StickyBoardController()`/`StickyBoardStore()` via
            // their production `init()` (no explicit `FM_STICKY_BOARD_DIR`/
            // `FM_SHIFT_DIR` override of its own) would otherwise reach
            // `StickyBoardGitSync.shared`, which shares `ShiftGitSync.shared`'s real
            // production working tree - a real local clone of the captain's actual
            // `manjesh-config` on this machine. Running `FM_RUN_STICKY_BOARD_VIEW_TESTS`
            // once, unprotected, left a stray untracked `GrandLineDocs/sticky-board/`
            // folder sitting in that real clone (never committed or pushed, since the
            // 3s debounce never fires before a headless suite process exits - but a
            // real hazard regardless, and the exact class of bug this whole block
            // exists to close for every present and future suite at once).
            // F3: the clipboard history is a sealed file plus a Keychain item, and
            // both need redirecting for the same reason every store above does - a
            // suite must neither read nor overwrite the captain's real history, and
            // must certainly not create a real Keychain item on his machine.
            // `FM_CLIPBOARD_HISTORY_EPHEMERAL` is what `ClipboardHistoryKey.load`
            // honours to use a per-process random key instead of the Keychain.
            if (ProcessInfo.processInfo.environment["FM_CLIPBOARD_HISTORY_FILE"] ?? "").isEmpty {
                setenv("FM_CLIPBOARD_HISTORY_FILE", scratchRoot.appendingPathComponent("clipboard-history.sealed").path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_CLIPBOARD_HISTORY_EPHEMERAL"] ?? "").isEmpty {
                setenv("FM_CLIPBOARD_HISTORY_EPHEMERAL", "1", 1)
            }
            // `fm/grandline-bootstrap-dotfiles-autocommit`: the highest-stakes entry
            // in this block, because the store it redirects is not one this app
            // created. `DotfilesAutoSync.shared` resolves `~/.dotfiles` - the
            // captain's REAL `manjesh-config` checkout, the one home-manager symlinks
            // live into his home directory - and its whole job is to `git commit` and
            // `git push` it. A suite that reached the production singleton without
            // this line would commit and publish whatever state that checkout happened
            // to be in. The scratch path below holds no `.git`, so an instance pointed
            // at it reports `.noRepo` and does nothing at all.
            if (ProcessInfo.processInfo.environment["FM_DOTFILES_AUTOSYNC_PATH"] ?? "").isEmpty {
                setenv("FM_DOTFILES_AUTOSYNC_PATH", scratchRoot.appendingPathComponent("dotfiles-autosync", isDirectory: true).path, 1)
            }
            // The read half of the same checkout. Bootstrap, Automation, the schedule
            // runner and the signals poller read it through
            // `DotfilesSource.resolvedDotfilesPath()`, and that read is not passive:
            // `repoState` runs a real `git fetch origin`. Without this line every
            // suite and tour that mounted one of them fetched the captain's real clone
            // over the network - measured by that clone's `FETCH_HEAD` during
            // modular-shell stage 3. The path below does not exist, so they read "no
            // dotfiles here" and run no git at all.
            if (ProcessInfo.processInfo.environment[DotfilesSource.locationOverrideVariable] ?? "").isEmpty {
                setenv(DotfilesSource.locationOverrideVariable,
                       scratchRoot.appendingPathComponent("dotfiles", isDirectory: true).path, 1)
            }
            // SEC-01 (full review): `SSHKeyMaterializer` and `SRELead.setUp` make
            // their scratch directories under `AppPaths.privateScratchFolder()`, which
            // is the captain's real Application Support folder by default, and
            // `SRELeadPerTabSelfTest` drives the real `setUp`.
            if (ProcessInfo.processInfo.environment[AppPaths.privateScratchVariable] ?? "").isEmpty {
                setenv(AppPaths.privateScratchVariable,
                       scratchRoot.appendingPathComponent("private-scratch", isDirectory: true).path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_STICKY_BOARD_DIR"] ?? "").isEmpty {
                setenv("FM_STICKY_BOARD_DIR", scratchRoot.appendingPathComponent("sticky-board", isDirectory: true).path, 1)
            }
            // `fm/grandline-monaco-code-preview`: `CodePreviewStore()` is another store
            // reachable from a bare, no-argument production constructor, so it gets an
            // entry here for the reason the Sticky Board note above spells out - not
            // because a suite is known to reach it today. Every harness that mounts an
            // `AppShellController` (which builds one) already sets `FM_SHIFT_DIR`,
            // which this store honours, and both of its own suites use the explicit
            // `CodePreviewStore(root:)` seam. This closes the case those two do not:
            // a future suite constructing `CodePreviewController(store: CodePreviewStore())`
            // with no override of its own.
            if (ProcessInfo.processInfo.environment["FM_CODE_PREVIEW_DIR"] ?? "").isEmpty {
                setenv("FM_CODE_PREVIEW_DIR", scratchRoot.appendingPathComponent("code-snippets", isDirectory: true).path, 1)
            }
            // Review #3's UX12: `StrawHatTranscriptStore()` is a new store reachable
            // from a bare production constructor - `StrawHatController` builds one -
            // so it needs an entry here **before its first suite**, which is the rule
            // this block exists to enforce. Without it, any suite that mounts an
            // `AppShellController` (which mounts that controller) would write the
            // crew's conversations into `ShiftGitSync.shared`'s real working tree: a
            // live clone of the captain's own private `manjesh-config`.
            if (ProcessInfo.processInfo.environment["FM_STRAW_HAT_DIR"] ?? "").isEmpty {
                setenv("FM_STRAW_HAT_DIR", scratchRoot.appendingPathComponent("straw-hat", isDirectory: true).path, 1)
            }
            // The credential vault (`fm/implement-grand-line-secrets-vault-poneg-ad`),
            // for exactly the reason the Sticky Board note above spells out and with
            // more at stake than any other entry in this block: `CredentialVaultStore()`
            // is reachable from a bare, no-argument production constructor, and with no
            // override it resolves to `CredentialVaultGitSync.shared` - which shares
            // `ShiftGitSync.shared`'s real working tree, a live clone of the captain's
            // actual private `manjesh-config`. A suite that constructed one unprotected
            // would write an encrypted vault file into that clone and mark it dirty for
            // commit. The store honours `FM_SHIFT_DIR` as well (see its `init`), so
            // this is the belt to that brace, and the one that covers a suite setting
            // neither.
            if (ProcessInfo.processInfo.environment["FM_CREDENTIAL_VAULT_DIR"] ?? "").isEmpty {
                setenv("FM_CREDENTIAL_VAULT_DIR", scratchRoot.appendingPathComponent("grand-line-vault", isDirectory: true).path, 1)
            }
            // The SECOND full-app audit's §7.1: `DocsRunbookStore` is the one store in
            // the `GrandLineDocs/` family that honoured only its own narrow override
            // and NOT `FM_SHIFT_DIR`, so the entry below - which the block's own
            // comment (and AGENTS.md) claimed covered it - genuinely did not. Two
            // windowed suites reached the real clone machinery on every *local* run
            // because of it; CI was safe only because `ci.yml`'s env block happens to
            // set this variable directly. `DocsRunbookStore.init()` has the fallback
            // now, so this line is the belt to that brace: it also covers a suite that
            // sets neither, and it keeps the override explicit at the one place a
            // reader looks for the full list.
            if (ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"] ?? "").isEmpty {
                setenv("FM_DOCS_RUNBOOKS_DIR", scratchRoot.appendingPathComponent("runbooks", isDirectory: true).path, 1)
            }
            // The Playbook's own local copy. Not a git-sync store - `DocsStore` only
            // resolves a folder under Application Support and `DocsSyncSource` fetches
            // on demand - so the exposure is a stray directory (and, if a suite ever
            // drove a sync, a real network fetch) in the captain's real profile rather
            // than a write into their repo. Same shape, same cost, no reason to leave
            // it as the one member of the family without an entry.
            if (ProcessInfo.processInfo.environment["FM_DOCS_DIR"] ?? "").isEmpty {
                setenv("FM_DOCS_DIR", scratchRoot.appendingPathComponent("docs", isDirectory: true).path, 1)
            }
            // The second audit's §7.3, the long-standing gap this block's own rule
            // ("every store reachable from a bare production constructor") always
            // implied but never covered. ~10 windowed suites construct a bare
            // `SSHKeyStore()`/`SnippetStore()` purely to satisfy `ConsoleController`'s
            // parameter list (`ConsoleTabLifecycleSelfTest`, `SRELeadPerTabSelfTest`,
            // `TabKeyboardShortcutsSelfTest`, BlockViewRestart, ConsoleClaudeUsage,
            // IncidentResume, KubeContextBridge, KubernetesDestination,
            // NotificationCenterSRELead, TabForwardDragsToggle), so locally each of
            // them *reads* the captain's real `keys.json`/`snippets.json` at
            // construction. Read-only in practice today - GL-01's load-failure path
            // makes a backup copy rather than overwriting - but the whole point of
            // this block is that the *next* suite to reach one of these is the one
            // that writes. `FM_HOSTS_FILE` and `FM_DICTATION_DIR` are the same class
            // and get the same treatment rather than waiting for their own incident.
            if (ProcessInfo.processInfo.environment["FM_KEYS_FILE"] ?? "").isEmpty {
                setenv("FM_KEYS_FILE", scratchRoot.appendingPathComponent("keys.json").path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_SNIPPETS_FILE"] ?? "").isEmpty {
                setenv("FM_SNIPPETS_FILE", scratchRoot.appendingPathComponent("snippets.json").path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_HOSTS_FILE"] ?? "").isEmpty {
                setenv("FM_HOSTS_FILE", scratchRoot.appendingPathComponent("hosts.json").path, 1)
            }
            if (ProcessInfo.processInfo.environment["FM_DICTATION_DIR"] ?? "").isEmpty {
                setenv("FM_DICTATION_DIR", scratchRoot.appendingPathComponent("dictation", isDirectory: true).path, 1)
            }
            // Full review #3's S3 moved this out of `UserDefaults` into a real file,
            // which puts it squarely in the class above: reachable from a bare
            // `AppSettings.shared.sessionRestoreState` read, and now something a
            // suite can *write*.
            if (ProcessInfo.processInfo.environment["FM_SESSION_RESTORE_FILE"] ?? "").isEmpty {
                setenv("FM_SESSION_RESTORE_FILE", scratchRoot.appendingPathComponent("session-restore.json").path, 1)
            }
            // F1's notebook (`fm/grandline-feature-f1-notebook`), for exactly the
            // reason the Docs-runbooks entry above spells out: `NotebookStore()` is
            // reachable from a bare, no-argument production constructor, and with no
            // override it resolves to `NotebookGitSync.shared` - which shares
            // `ShiftGitSync.shared`'s real working tree, a live clone of the captain's
            // actual private `manjesh-config`. Any suite that mounts an
            // `AppShellController` constructs one. The store honours `FM_SHIFT_DIR`
            // too (see its `init`), so this is the belt to that brace.
            if (ProcessInfo.processInfo.environment["FM_NOTEBOOK_DIR"] ?? "").isEmpty {
                setenv("FM_NOTEBOOK_DIR", scratchRoot.appendingPathComponent("notebook", isDirectory: true).path, 1)
            }
            // F4's reading list (`fm/grandline-feature-f4-reading-list`), for exactly
            // the reason the entry above spells out: `ReadingListStore()` is reachable
            // from a bare, no-argument production constructor, and with no override it
            // resolves to `ReadingListGitSync.shared` - which shares
            // `ShiftGitSync.shared`'s real working tree, a live clone of the captain's
            // actual private `manjesh-config`. Any suite that mounts an
            // `AppShellController` constructs one. The store honours `FM_SHIFT_DIR`
            // too (see its `init`), so this is the belt to that brace.
            if (ProcessInfo.processInfo.environment["FM_READING_LIST_DIR"] ?? "").isEmpty {
                setenv("FM_READING_LIST_DIR", scratchRoot.appendingPathComponent("reading-list", isDirectory: true).path, 1)
            }
            // F9's scratchpad (`fm/grandline-feature-f9-scratchpad-calculator`).
            // `ScratchpadStore()` is reachable from a bare, no-argument production
            // constructor - every Scratchpad tab builds one - so a suite that opens
            // that tab would otherwise read and rewrite the captain's own pads.
            if (ProcessInfo.processInfo.environment["FM_SCRATCHPAD_FILE"] ?? "").isEmpty {
                setenv("FM_SCRATCHPAD_FILE", scratchRoot.appendingPathComponent("scratchpad.json").path, 1)
            }
            // P9's diagnostics log. `DiagnosticsLog.shared` is a singleton reached
            // from `PersistenceFailureReporter` and `StoreLoadFailure`, both of which
            // a dozen store suites drive deliberately - so without this every suite
            // run would append its own fault-injection failures to the captain's real
            // diagnostics file, which is precisely the file a real investigation would
            // then be reading.
            if (ProcessInfo.processInfo.environment["FM_DIAGNOSTICS_DIR"] ?? "").isEmpty {
                setenv("FM_DIAGNOSTICS_DIR", scratchRoot.appendingPathComponent("diagnostics", isDirectory: true).path, 1)
            }
            // F23's widget snapshot (`fm/grandline-feature-f23-widgets`). The one
            // store in this app whose default location is **outside** the captain's
            // profile in the usual sense - it is the App Group container the widget
            // extension reads - and `WidgetSnapshotPublisher` is reachable from
            // `AppDelegate` at launch, so any suite that builds one would otherwise
            // publish fabricated tasks into the real shared container and reload the
            // captain's real widgets with them.
            if (ProcessInfo.processInfo.environment["FM_WIDGET_DIR"] ?? "").isEmpty {
                setenv("FM_WIDGET_DIR", scratchRoot.appendingPathComponent("widgets", isDirectory: true).path, 1)
            }
            // The full-app audit's §7.2, and the entry that generalises every one
            // above: `FM_SHIFT_DIR` is the *root* override the whole
            // `GrandLineDocs/` family resolves through.
            //
            // `ShiftStore`, `IncidentStore`, `DocsRunbookStore` (only since the second
            // audit's §7.1 - it was the outlier that ignored this variable entirely),
            // `CommandLibraryStore`, `LogAnalyzerStore`, `StickyBoardStore` and
            // `CodePreviewStore` all have a
            // no-argument production `init()` that, with no override set, resolves to
            // `ShiftGitSync.shared`'s working tree - a real local clone of the
            // captain's actual private `manjesh-config` repo. Every suite that
            // constructs one today sets either its own narrow override or this one, so
            // nothing is reaching that clone right now; this closes the case where the
            // *next* one does not, which is precisely how the two incidents the
            // comments above recount both happened. A per-suite fix keeps missing it
            // because the store is usually reached indirectly - through a controller,
            // or a singleton nobody constructs on purpose.
            //
            // Setting it also switches `ShiftStore` to its non-git-backed mode
            // (`gitSync == nil`), so a suite that writes cannot queue a commit against
            // the real remote either. Deliberately last, so a suite that sets one of
            // the narrower overrides above still wins for its own store.
            if (ProcessInfo.processInfo.environment["FM_SHIFT_DIR"] ?? "").isEmpty {
                setenv("FM_SHIFT_DIR", scratchRoot.appendingPathComponent("tasks", isDirectory: true).path, 1)
            }
        }

        // `fm/cockpit-sre-lead-shared-terminal`: `swift build && FM_RUN_SRE_LEAD_BRIDGE_TESTS=1
        // .build/debug/GrandLine` runs `SRELeadBridge`'s self-tests and exits,
        // never opening a window - this project builds with Command Line Tools only
        // (no Xcode), which has no `XCTest.framework` and, in practice, no working
        // `swift test` story for a `swift-testing`-based test target either (see
        // `SRELeadBridgeSelfTest.swift`'s header for what was actually tried and why
        // it didn't work), so this is the plain, dependency-free stand-in - the same
        // "env-var-gated verification, run and read the result" convention this
        // codebase already uses for AppKit UI probes (see AGENTS.md's "Verifying
        // native UI bugs without a real screenshot"), just kept permanently instead
        // of reverted after one use.
        if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_BRIDGE_TESTS"] == "1" {
            exit(SRELeadBridgeSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-sre-lead-per-tab`: same convention, for the real
        // `ConsoleController` per-tab SRE Lead integration (independent phases, no
        // chat cross-talk, tab-switch rebinding, the 5-tab cap, per-tab teardown on
        // close) - see `SRELeadPerTabSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_PER_TAB_TESTS"] == "1" {
            exit(SRELeadPerTabSelfTest.run() ? 0 : 1)
        }

        // Straw Hat Pirates phase 1 (`fm/implement-straw-hat-pirates-phase1-luffy-fb98`):
        // the pure-logic half - the persona's own safety clauses, `--resume`
        // threading proven from the argv a fake `claude` recorded, the stale-session
        // recap recovery, and the `.strawHatChat` lock gate. Runs in CI; the
        // window-backed half is `FM_RUN_STRAW_HAT_VIEW_TESTS`.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_TESTS"] == "1" {
            exit(StrawHatSelfTest.run() ? 0 : 1)
        }

        // The same feature's rendering half: the real `FleetController` Crew tab,
        // the real `StrawHatChatView`, and a real turn round trip against a fake
        // `claude`. Mounts a real `NSWindow`, so it is in `run-all-tests.sh`'s
        // `NEEDS_SESSION` list - see `StrawHatViewSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_VIEW_TESTS"] == "1" {
            exit(StrawHatViewSelfTest.run() ? 0 : 1)
        }

        // Straw Hat Pirates phase 2.5
        // (`fm/implement-straw-hat-pirates-phase25-mcp-fb52`): the crew's read-only
        // MCP tools - the pinned `--allowedTools`, the MCP config's real contents,
        // M2.5b's health file bridge, and the cross-language case that runs the real
        // `luffy_stores_mcp.py` over stdio against real Swift-written stores. Builds
        // no window, so it runs in CI alongside `FM_RUN_STRAW_HAT_TESTS`. The Python
        // half is `native/Scripts/test_luffy_stores_mcp.py`.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_MCP_TESTS"] == "1" {
            exit(StrawHatMCPSelfTest.run() ? 0 : 1)
        }

        // Straw Hat Pirates phase 3 (M3.2): the two navigation handoffs' resolution,
        // against a real `AppShellController` - which host a hint resolves to,
        // whether a handoff ever *connects* one (it must not), and the Whiteboard's
        // own composer being opened prefilled. Mounts a real shell, so it is in
        // `run-all-tests.sh`'s `NEEDS_SESSION` list - see
        // `StrawHatHandoffSelfTest.swift`'s header for why the shell-level half is
        // its own suite rather than more cases in the view one.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_HANDOFF_TESTS"] == "1" {
            exit(StrawHatHandoffSelfTest.run() ? 0 : 1)
        }

        // `fm/straw-hat-menubar-quick-chat-popover`: the crew's menu-bar quick-chat
        // popover and the static crew roster reference sheet - two more real,
        // window-mounted views, so this joins `run-all-tests.sh`'s `NEEDS_SESSION`
        // list beside its Straw Hat Pirates siblings. See
        // `StrawHatMenuBarSelfTest.swift`'s header for why it never drives the
        // popover's real click-to-open path.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_MENUBAR_TESTS"] == "1" {
            exit(StrawHatMenuBarSelfTest.run() ? 0 : 1)
        }

        // `fm/cockpit-sre-lead-reply-formatting`: same convention, for
        // `SRELeadMarkdown.parse`'s block/callout parsing - see
        // `SRELeadMarkdownSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_MARKDOWN_TESTS"] == "1" {
            exit(SRELeadMarkdownSelfTest.run() ? 0 : 1)
        }

        // fm/cockpit-local-state-portable: same convention, for the export/import/
        // diff/apply path - see `BackupSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_BACKUP_TESTS"] == "1" {
            exit(BackupSelfTest.run() ? 0 : 1)
        }

        // fm/cockpit-tools-page-diff: same convention, for `DiffEngine`'s line/word
        // LCS diffing - see `DiffEngineSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_DIFF_ENGINE_TESTS"] == "1" {
            exit(DiffEngineSelfTest.run() ? 0 : 1)
        }

        // cockpit-tools-page-specialist: same convention, for the cron next-run
        // explainer, the resource-unit converter, and the certificate inspector -
        // see each self-test file's own header.
        if ProcessInfo.processInfo.environment["FM_RUN_CRON_EXPLAINER_TESTS"] == "1" {
            exit(CronExplainerSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_RESOURCE_UNITS_TESTS"] == "1" {
            exit(ResourceUnitsSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_WRAP_REDRAW_TESTS"] == "1" {
            exit(TerminalWrapRedrawSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_VENDORED_PATCHES_TESTS"] == "1" {
            exit(VendoredPatchesSelfTest.run() ? 0 : 1)
        }
        // The rename to "Grand Line": the Keychain copy, the Application Support
        // folder move, and the standing guard that no source has drifted back to a
        // pre-rename name. Pure logic - a file-system round trip, a scratch-service
        // Keychain round trip and a source grep - so it guards CI's blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_LEGACY_RENAME_MIGRATION_TESTS"] == "1" {
            exit(LegacyRenameMigrationSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CERT_INSPECTOR_TESTS"] == "1" {
            exit(CertInspectorSelfTest.run() ? 0 : 1)
        }

        // Review bug B4: FM_SCRATCH_ROOT is the one variable that moves every
        // file-backed store, and this is the guard that stops a new store resolving
        // Application Support for itself and dropping back off it. Pure logic plus a
        // source grep, so it guards CI's blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_PROBE_SCRATCH_ROOT_TESTS"] == "1" {
            exit(ProbeScratchRootSelfTest.run() ? 0 : 1)
        }

        // Review process issue P7: AGENTS.md is imported into every agent session, so
        // its size is a cost every session pays. Pure logic plus one file read, so it
        // guards CI's blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_AGENTS_BUDGET_TESTS"] == "1" {
            exit(AgentsFileBudgetSelfTest.run() ? 0 : 1)
        }

        // The UI/UX revamp's source guards (UI-40): pure source reads, CI's blocking
        // lane. See `HelmKitSourceGuardSelfTest`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_HELM_KIT_GUARD_TESTS"] == "1" {
            exit(HelmKitSourceGuardSelfTest.run() ? 0 : 1)
        }

        // The UI/UX revamp's component kit (UI-39): what each piece paints. Pure
        // logic; its window-backed geometry half is FM_RUN_HELM_KIT_VIEW_TESTS.
        if ProcessInfo.processInfo.environment["FM_RUN_HELM_KIT_TESTS"] == "1" {
            exit(HelmKitSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_HELM_KIT_VIEW_TESTS"] == "1" {
            exit(HelmKitViewSelfTest.run() ? 0 : 1)
        }

        // The UI/UX revamp's Tasks chrome: sync wording, offline detection, sort.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_TASKS_CHROME_TESTS"] == "1" {
            exit(ShiftTasksChromeSelfTest.run() ? 0 : 1)
        }

        // Review process issue P9: the on-disk diagnostics sink and the crash-report
        // check. Pure logic plus real file round trips, so it guards CI's blocking
        // lane.
        if ProcessInfo.processInfo.environment["FM_RUN_DIAGNOSTICS_LOG_TESTS"] == "1" {
            exit(DiagnosticsLogSelfTest.run() ? 0 : 1)
        }

        // Review process issue P11: the tour lab's own coverage. Window-backed.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_TOUR_LAB_TESTS"] == "1" {
            exit(ReviewTourLabSelfTest.run() ? 0 : 1)
        }

        // Review process issue P11: the file-driven probe driver. Not a suite - it
        // takes a tour file's path, not `=1` - and deliberately not named `FM_RUN_*`,
        // which `run-all-tests.sh` discovers suites by.
        if let tour = ProcessInfo.processInfo.environment[ReviewTourLab.variable], !tour.isEmpty {
            exit(ReviewTourLab.runTourFile(at: tour) ? 0 : 1)
        }

        // Review bug B5: every Keychain service name carries a per-process prefix in a
        // self-test process, and the items are swept at exit. Pure logic plus a
        // Keychain round trip under this process's own prefixed service, so it guards
        // CI's blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_KEYCHAIN_SERVICE_ISOLATION_TESTS"] == "1" {
            exit(KeychainServiceIsolationSelfTest.run() ? 0 : 1)
        }

        // Review bug B10: the Dictation status card's wrapping column. Window-backed -
        // it measures real resolved geometry from a real layout pass.
        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_STATUS_CARD_LAYOUT_TESTS"] == "1" {
            exit(DictationStatusCardLayoutSelfTest.run() ? 0 : 1)
        }

        // fm/cockpit-tools-yaml-order-perf-fix: same convention, for YamlBeautify's
        // key-order fidelity - see YamlBeautifySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_YAML_BEAUTIFY_TESTS"] == "1" {
            exit(YamlBeautifySelfTest.run() ? 0 : 1)
        }

        // cockpit-shift-foundation: same convention, for ShiftStore's completion/
        // reopen file-move logic and YAML scalar fidelity - see
        // ShiftStoreSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_STORE_TESTS"] == "1" {
            exit(ShiftStoreSelfTest.run() ? 0 : 1)
        }

        // fm/grandline-tasks-kanban-devops-split: the Kanban board's pure logic - the
        // column/status table (including a cancelled task having no column at all)
        // and the process-stable per-project colour hash. The board's *view* half
        // needs a real window and lives in ShiftBoardViewSelfTest.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_BOARD_TESTS"] == "1" {
            exit(ShiftBoardSelfTest.run() ? 0 : 1)
        }

        // F23 of full review #3 §8 (`fm/grandline-feature-f23-widgets`): the widget
        // pipeline's pure logic - the snapshot's projection from real store types,
        // its round trip through the shared container, the digest both widgets draw
        // from, GL-14's unavailable/locked states, and the reverse channel a tapped
        // widget button writes into. No window and no WidgetKit, so this guards CI's
        // *blocking* lane; the extension's own rendering half cannot be asserted from
        // here at all (see `native/Widgets/README.md`).
        if ProcessInfo.processInfo.environment["FM_RUN_WIDGET_SNAPSHOT_TESTS"] == "1" {
            exit(WidgetSnapshotSelfTest.run() ? 0 : 1)
        }

        // The same board's view half: a real ShiftController mounted in a real
        // window, a real press-and-drag on a card, and a real drop onto a column.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_BOARD_VIEW_TESTS"] == "1" {
            exit(ShiftBoardViewSelfTest.run() ? 0 : 1)
        }

        // F5 (full review #3 §8): the RRULE-lite recurrence rule - parsing, the
        // occurrence generator, the "completing an instance writes the next one"
        // advance, and the per-task reminder offset's own comparison. Pure logic, so
        // it runs in CI's blocking lane; the calendar's render is its window-backed
        // sibling below.
        // B22: the app's one definition of "overdue" (the task list and the notifier
        // used to disagree about a date-only task all day long), and the withdrawal of
        // a banner whose task is gone. Pure logic - no window, no notification centre.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_DUE_TESTS"] == "1" {
            exit(ShiftDueSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_RECURRENCE_TESTS"] == "1" {
            exit(ShiftRecurrenceSelfTest.run() ? 0 : 1)
        }

        // The same feature's view half: the real Tasks page in a real window, the
        // Calendar pill genuinely clicked, and the month grid's own laid-out cells.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_CALENDAR_VIEW_TESTS"] == "1" {
            exit(ShiftCalendarViewSelfTest.run() ? 0 : 1)
        }

        // F7 (full review #3 §8): the focus timer's state machine, its two duration
        // formats, the activity-log write and the per-day aggregation Weekly
        // Review's tile reads. Pure logic, so it runs in CI's blocking lane; the
        // chip, the ring and the chart are its window-backed sibling below.
        if ProcessInfo.processInfo.environment["FM_RUN_FOCUS_TIMER_TESTS"] == "1" {
            exit(FocusTimerSelfTest.run() ? 0 : 1)
        }

        // The same feature's render: the real bar with the real chip on it, the
        // popover's ring, and Weekly Review's seven-day chart.
        if ProcessInfo.processInfo.environment["FM_RUN_FOCUS_TIMER_VIEW_TESTS"] == "1" {
            exit(FocusTimerViewSelfTest.run() ? 0 : 1)
        }

        // fm/grand-line-tasks-page-redesign: the Tasks page's own nav column, the
        // slice it filters by, its stat tiles, its one page-level primary action, and
        // a board column sized so a card is never sliced.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_TASKS_PAGE_TESTS"] == "1" {
            exit(ShiftTasksPageSelfTest.run() ? 0 : 1)
        }

        // fm/grandline-devops-command-library: same convention, for the DevOps
        // Command Library's parameter detection/substitution/search/favorites - see
        // CommandLibraryStoreSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_COMMAND_LIBRARY_TESTS"] == "1" {
            exit(CommandLibraryStoreSelfTest.run() ? 0 : 1)
        }

        // cockpit-shift-create-edit: same convention, for `ShiftDateParser`'s
        // natural-language date/time detection - see `ShiftDateParserSelfTest.swift`'s
        // header.
        // Review #3's UX1-UX4: the all-destinations map's completeness, the
        // quick-access row's cap/order/persistence, the menu bar's shape (Go, Window
        // and Help present; Keys and Snippets folded under Hosts) and the contextual
        // ⌘N routing table - see `NavigationCoherenceSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_NAVIGATION_COHERENCE_TESTS"] == "1" {
            exit(NavigationCoherenceSelfTest.run() ? 0 : 1)
        }

        // Review #3's UX14: GL-30's routing rule, and that `Feedback.report`'s real
        // side effects agree with it - see `FeedbackRoutingSelfTest.swift`.
        if ProcessInfo.processInfo.environment["FM_RUN_FEEDBACK_ROUTING_TESTS"] == "1" {
            exit(FeedbackRoutingSelfTest.run() ? 0 : 1)
        }

        // Review #3's UX12: the crew's conversations surviving a quit, and nothing
        // reaching that file unredacted - see `StrawHatTranscriptSelfTest.swift`.
        if ProcessInfo.processInfo.environment["FM_RUN_STRAW_HAT_TRANSCRIPT_TESTS"] == "1" {
            exit(StrawHatTranscriptSelfTest.run() ? 0 : 1)
        }

        // Review #3's UX7: the "Push to → Tomorrow / Next week" date arithmetic -
        // see `ShiftDuePushSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_DUE_PUSH_TESTS"] == "1" {
            exit(ShiftDuePushSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_DATE_PARSER_TESTS"] == "1" {
            exit(ShiftDateParserSelfTest.run() ? 0 : 1)
        }

        // cockpit-shift-git-sync: same convention, for `ShiftGitSync`'s clone/commit/
        // push/pull/debounce/status logic against a real disposable local bare repo -
        // see ShiftGitSyncSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_GIT_SYNC_TESTS"] == "1" {
            exit(ShiftGitSyncSelfTest.run() ? 0 : 1)
        }

        // fm/grandline-bootstrap-dotfiles-autocommit: same convention, for
        // `DotfilesAutoSync`'s detect/debounce/fast-forward/commit/push logic, its
        // refusal to push over a genuinely diverged remote, and its `home/`-only
        // scope - all against a real disposable local repository pair. See
        // DotfilesAutoSyncSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DOTFILES_AUTO_SYNC_TESTS"] == "1" {
            exit(DotfilesAutoSyncSelfTest.run() ? 0 : 1)
        }

        // cockpit-shift-power-features: same convention, for `ShiftStore.weeklySummary`'s
        // completed/pushed-back/upcoming counting - see
        // ShiftWeeklySummarySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_WEEKLY_SUMMARY_TESTS"] == "1" {
            exit(ShiftWeeklySummarySelfTest.run() ? 0 : 1)
        }

        // cockpit-shift-conflict-handling: same convention, for the record-level
        // 3-way merge and conflict-resolution flow layered on top of
        // `ShiftGitSync.pullNow`'s `.diverged` case - see
        // ShiftConflictSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_CONFLICT_TESTS"] == "1" {
            exit(ShiftConflictSelfTest.run() ? 0 : 1)
        }

        // grandline-shift-task-image-attachments: same convention, for the image
        // downscale/PNG-encode logic every attach path (file picker, drag-drop,
        // clipboard paste) funnels through - see
        // ShiftImageAttachmentWellSelfTest.swift's header. The store-level round
        // trip (hasAttachment persistence, file write/read/remove) is covered by
        // ShiftStoreSelfTest.swift; the real-remote push is covered by
        // ShiftGitSyncSelfTest.swift - both extended in place rather than
        // duplicated here.
        if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS"] == "1" {
            exit(ShiftImageAttachmentWellSelfTest.run() ? 0 : 1)
        }

        // `fm/cockpit-block-view-stage0`: same convention, for the OSC 133 parser,
        // the real-view-hierarchy render path, the reconnect-bookkeeping
        // unification, and volume - see each file's own header for what class of
        // prior production break it targets and why the other three couldn't have
        // caught it.
        if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_TESTS"] == "1" {
            exit(TerminalBlockTrackerSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS"] == "1" {
            exit(BlockViewHierarchySelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_RESTART_TESTS"] == "1" {
            exit(BlockViewRestartIntegrationSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_VOLUME_TESTS"] == "1" {
            exit(BlockViewVolumeSelfTest.run() ? 0 : 1)
        }

        // `fm/cockpit-fix-host-decode-regression`: same convention, for `Host`'s
        // custom decode fallback (a new `CodingKeys` entry with a Swift-side default,
        // like `blockViewOptIn`, must not break decoding of pre-existing `hosts.json`
        // files) - see HostStoreSelfTest.swift's header.
        // `fm/grandline-review-phase1-stabilize` (GL-01/GL-21): store durability -
        // a decode failure must preserve the file, and a failed directory read must
        // not look like an empty library. Runs entirely against scratch paths via the
        // stores' own `FM_*` overrides.
        if ProcessInfo.processInfo.environment["FM_RUN_STORE_DURABILITY_TESTS"] == "1" {
            exit(StoreDurabilitySelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-review-phase2-harden` (GL-02/GL-15): the shared subprocess
        // runner, including the stderr-flood child the review asked for by name plus
        // an in-process reproduction of the pre-fix drain order still deadlocking on
        // that same child - see SubprocessSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SUBPROCESS_TESTS"] == "1" {
            exit(SubprocessSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-review-phase2-harden` (GL-26): the one `claude -p` runner the
        // five drifted copies collapsed into - see ClaudeOneShotSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_CLAUDE_ONE_SHOT_TESTS"] == "1" {
            exit(ClaudeOneShotSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-audit3-perf-security-fixes` (full review #3, S2): the
        // unlocked vault reconciles with a file a git pull changed underneath it, and
        // reveal/copy no longer rewrite-and-commit the whole file - see
        // CredentialVaultConcurrentWriteSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_VAULT_CONCURRENT_WRITE_TESTS"] == "1" {
            exit(CredentialVaultConcurrentWriteSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-audit3-perf-security-fixes` (full review #3, S1): every
        // `claude -p` run is fail-closed on the built-in tool set via `--tools`, so
        // the captain's global `permissions.allow` cannot widen a read-only persona -
        // see ClaudeOneShotToolPolicySelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_CLAUDE_TOOL_POLICY_TESTS"] == "1" {
            exit(ClaudeOneShotToolPolicySelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-review-phase2-harden` (GL-10/GL-11/GL-30): throwing
        // persistence writes funnelled through PersistenceFailureReporter, and the
        // ServiceHealth registry behind the Health card - see Phase2HardeningSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_PHASE2_HARDENING_TESTS"] == "1" {
            exit(Phase2HardeningSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-review-phase1-stabilize` (GL-05/GL-08): the single-instance
        // lock and the `ssh` argv option-terminator contract.
        if ProcessInfo.processInfo.environment["FM_RUN_PHASE1_HARDENING_TESTS"] == "1" {
            exit(Phase1HardeningSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_HOST_STORE_TESTS"] == "1" {
            exit(HostStoreSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-vault-tab`: same convention, for `VaultSource`'s pure logic
        // (shell-token safety, the two command-string builders, `av doctor --json`
        // parsing) - see VaultDataSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_VAULT_DATA_TESTS"] == "1" {
            exit(VaultDataSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-vault-recipe-export-diverged-fix`: real disposable local
        // bare-repo coverage for `VaultRecipeGit.export`'s ahead/behind/diverged
        // classification - see VaultRecipeGitSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_VAULT_RECIPE_GIT_TESTS"] == "1" {
            exit(VaultRecipeGitSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-live-gap-rootcause-scout`: real-view-hierarchy regression
        // coverage for the captain-reported black/blank right-side window gap -
        // asserts `AppShellController.bodyContainer`'s width tracks the window's
        // real, current content width across a series of resizes, and self-heals
        // if that tie is ever silently broken - see AppShellBodyWidthSelfTest.swift's
        // header.
        if ProcessInfo.processInfo.environment["FM_RUN_APP_SHELL_BODY_WIDTH_TESTS"] == "1" {
            exit(AppShellBodyWidthSelfTest.run() ? 0 : 1)
        }

        // Bootstrap's own single-line, data-derived labels (a firstmate home path, a
        // dotfiles repo path, a git remote URL) sat at `NSTextField`'s default 750
        // horizontal compression resistance - above `NSLayoutPriorityWindowSizeStayPut`
        // - so the longest of those strings became a hard floor on the whole window's
        // width. See BootstrapWindowShrinkSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_BOOTSTRAP_WINDOW_SHRINK_TESTS"] == "1" {
            exit(BootstrapWindowShrinkSelfTest.run() ? 0 : 1)
        }

        // A drill page header's title can render truncated to a few characters
        // after switching away from a destination whose action cluster (or a narrow
        // window) genuinely squeezed the row at some earlier point in the session -
        // see AppShellDrillHeaderTitleSelfTest.swift's header for the root cause
        // (an NSStackView's cross-axis width getting permanently stuck once squeezed).
        if ProcessInfo.processInfo.environment["FM_RUN_DRILL_HEADER_TITLE_TESTS"] == "1" {
            exit(AppShellDrillHeaderTitleSelfTest.run() ? 0 : 1)
        }

        // Daylight Phase 2: the shell that replaced the icon rail and the top bar -
        // module anatomy, span-2 grid math, the locked space table, the canvas's
        // no-store rule, and the bar's window-safety. See
        // DaylightModuleSelfTest.swift's header.
        // The UI modernization audit's A1/A2/A3: the window's titlebar fused into
        // the floating bar, the drill header merged into that bar's leading area,
        // and the shared scroll-edge treatment. Window-backed - every case is a
        // question about a real window's chrome, a real laid-out bar or a real
        // scroll offset. See WindowChromeFusionSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_WINDOW_CHROME_FUSION_TESTS"] == "1" {
            exit(WindowChromeFusionSelfTest.run() ? 0 : 1)
        }

        // The other half of that fusion, which A1 deferred to AppKit and AppKit does
        // not do: the 33pt menu-bar strip macOS reserves above a full-screen window,
        // which renders as the captain-reported solid black band. Window-backed - it
        // mounts a real window and builds the real panel. See
        // FullScreenMenuBarFillSelfTest.swift's header for what it can and cannot
        // assert.
        if ProcessInfo.processInfo.environment["FM_RUN_FULL_SCREEN_MENU_BAR_FILL_TESTS"] == "1" {
            exit(FullScreenMenuBarFillSelfTest.run() ? 0 : 1)
        }

        // The UI modernization audit's B1-B5: the bar's material, its icon row, the
        // launch-time focus ring, the navigation transition, and the three bar
        // dropdowns becoming borderless panels. Window-backed - the focus ring, the
        // panel anchoring and the transition are all questions about a real window.
        // See BarNavigationModernizationSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_BAR_NAV_MODERNIZATION_TESTS"] == "1" {
            exit(BarNavigationModernizationSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-bar-active-state`: every bar square lit while its page is
        // open, by every route, and a real press drawing the pressed tile.
        // Window-backed - it presses the squares of a mounted shell.
        if ProcessInfo.processInfo.environment["FM_RUN_BAR_ACTIVE_STATE_TESTS"] == "1" {
            exit(BarActiveStateSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-topbar-icon-tiles`: the same row's shortcuts as coloured
        // tiles - the per-destination hue, its legibility in all 26 palettes, the
        // three states, the controls deliberately left plain, and the guard that the
        // row's footprint did not move. Pure logic: layer colours and frames off a
        // hand-laid-out bar, no window.
        if ProcessInfo.processInfo.environment["FM_RUN_BAR_ICON_TILE_TESTS"] == "1" {
            exit(DaylightBarIconTileSelfTest.run() ? 0 : 1)
        }

        // The same audit's C, D and E - the canvas and its cards, row/list density,
        // and the reusable controls. Window-backed: hover, press, focus and a real
        // scroll offset all need a real window.
        // See CanvasListsControlsSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CANVAS_LISTS_CONTROLS_TESTS"] == "1" {
            exit(CanvasListsControlsSelfTest.run() ? 0 : 1)
        }

        // P1 of the Grand Line vs Automic Vault polish report: hover and press
        // feedback that really eases, measured as `layer.animationKeys()` straight
        // after the real entry point, in both Reduce Motion states. Window-backed.
        // See HoverPressEasingSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_HOVER_PRESS_EASING_TESTS"] == "1" {
            exit(HoverPressEasingSelfTest.run() ? 0 : 1)
        }

        // P3 of the same report: panels and page changes that move both ways, and
        // pages that keep the captain's place. Window-backed.
        // See PanelAndPageMotionSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_PANEL_AND_PAGE_MOTION_TESTS"] == "1" {
            exit(PanelAndPageMotionSelfTest.run() ? 0 : 1)
        }

        // P11 of the same report: the four pages that read their store on the main
        // thread in viewWillAppear read it off the main thread instead. Window-backed.
        // See PageLoadOffMainSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_PAGE_LOAD_OFF_MAIN_TESTS"] == "1" {
            exit(PageLoadOffMainSelfTest.run() ? 0 : 1)
        }

        // P4 of the same report: the density rule - every module card is a bounded
        // summary that says when it shows fewer rows than it has. Pure logic. See
        // BoundedSummarySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_BOUNDED_SUMMARY_TESTS"] == "1" {
            exit(BoundedSummarySelfTest.run() ? 0 : 1)
        }

        // P9 of the same report: seven pages' columns as real split-view sidebars.
        // Window-backed. See SplitSidebarSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SPLIT_SIDEBAR_TESTS"] == "1" {
            exit(SplitSidebarSelfTest.run() ? 0 : 1)
        }

        // P6 of the same report: the compact-mode status item's right-click menu.
        // Pure logic. See StatusMenuSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_STATUS_MENU_TESTS"] == "1" {
            exit(StatusMenuSelfTest.run() ? 0 : 1)
        }

        // P5 of the same report: keyboard parity for hand-built lists, bar panels
        // and form sheets. Window-backed. See KeyboardParitySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_KEYBOARD_PARITY_TESTS"] == "1" {
            exit(KeyboardParitySelfTest.run() ? 0 : 1)
        }

        // P7 of the same report: Increase Contrast and Reduce Transparency, read
        // through HelmDisplayAccessibility. Window-backed. See
        // DisplayAccessibilitySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DISPLAY_ACCESSIBILITY_TESTS"] == "1" {
            exit(DisplayAccessibilitySelfTest.run() ? 0 : 1)
        }

        // P2 of the same report: a refresh updates rows and cards in place, keeping
        // the same objects. Window-backed. See KeyedRefreshSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_KEYED_REFRESH_TESTS"] == "1" {
            exit(KeyedRefreshSelfTest.run() ? 0 : 1)
        }

        // P8 of the same report: the one motion table (`HelmMotion.swift`'s header),
        // a guard against literal UI durations and against `allowsImplicitAnimation`
        // on a layer property, and `animateLayers` on a plain layer. Pure logic.
        // See MotionTableSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_MOTION_TABLE_TESTS"] == "1" {
            exit(MotionTableSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-hosts-page-redesign`: the redesigned Hosts page's two-column
        // layout, and that every panel beside the list is fed by a real store rather
        // than the reference mockup's demo data. Window-backed (it mounts the real
        // controller), so it sits in `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_HOSTS_REDESIGN_TESTS"] == "1" {
            exit(HostsRedesignSelfTest.run() ? 0 : 1)
        }

        // Review #3's bug list (`data/grandline-full-review-3/report.md` §1/§1b), for
        // the findings with no existing suite of their own. Window-backed - most of
        // them are geometry, and geometry with no window is geometry nobody measured -
        // so it sits in `run-all-tests.sh`'s `NEEDS_SESSION` list.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT3_UI_FIXES_TESTS"] == "1" {
            exit(Audit3UIFixesSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT3_BUG_FIXES_TESTS"] == "1" {
            exit(Audit3BugFixesSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_MODULE_TESTS"] == "1" {
            exit(DaylightModuleSelfTest.run() ? 0 : 1)
        }

        // The modular-shell migration's stage 1: `ModuleTable` (step 0) agrees with
        // the six tables it restates, and every feature the code has has a row in
        // `docs/modular-shell/feature-inventory.md`. Both pure logic.
        if ProcessInfo.processInfo.environment["FM_RUN_MODULE_TABLE_TESTS"] == "1" {
            exit(ModuleTableSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_FEATURE_INVENTORY_TESTS"] == "1" {
            exit(FeatureInventorySelfTest.run() ? 0 : 1)
        }
        // Stage 2: `AppShellController` split into the floating-bar shell's chrome
        // and the parts any shell hosts. Pure logic - source guards plus scratch
        // stores.
        if ProcessInfo.processInfo.environment["FM_RUN_SHELL_SPLIT_TESTS"] == "1" {
            exit(ShellSplitSelfTest.run() ? 0 : 1)
        }
        // Stage 3: the sidebar shell (`MainSplitShellController`) behind the window
        // layout setting. The model half is pure logic; the shell half mounts the
        // real shell in an off-screen window.
        if ProcessInfo.processInfo.environment["FM_RUN_SPLIT_SHELL_MODEL_TESTS"] == "1" {
            exit(SplitShellModelSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_MAIN_SPLIT_SHELL_TESTS"] == "1" {
            exit(MainSplitShellSelfTest.run() ? 0 : 1)
        }
        // The later page work: the host, key, snippet and credential tables with the
        // shell's inspector, Knowledge with no tree (stage 7) and Crew › Needs you, in
        // a real off-screen sidebar shell - and the floating bar's same pages
        // unchanged.
        if ProcessInfo.processInfo.environment["FM_RUN_PAGE_REDESIGNS_TESTS"] == "1" {
            exit(PageRedesignsSelfTest.run() ? 0 : 1)
        }
        // The polish stage: the sidebar layout's badges as pure logic (every honest
        // state, the words, the contrast, and the source guards that keep the
        // monitor a listener), then the badges and the motion in a real off-screen
        // sidebar shell.
        if ProcessInfo.processInfo.environment["FM_RUN_WORKSPACE_SIGNALS_TESTS"] == "1" {
            exit(WorkspaceSignalsSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_SIDEBAR_POLISH_TESTS"] == "1" {
            exit(SidebarPolishSelfTest.run() ? 0 : 1)
        }

        // Stage 6 of the modular-shell migration: Connections, Logs and Health laid
        // out as the prototype draws them in the sidebar layout, in a real off-screen
        // sidebar shell - and the floating bar's same pages unchanged.
        if ProcessInfo.processInfo.environment["FM_RUN_SIDEBAR_PAGE_FIXES_TESTS"] == "1" {
            exit(SidebarPageFixesSelfTest.run() ? 0 : 1)
        }

        // Stage 7 of the modular-shell migration: the sidebar at the Large size, Quick
        // Connect's two icons, Knowledge with no tree, Setup's four tabs and Tasks'
        // four as the prototype draws them. The models and source guards first (pure,
        // CI's blocking lane), then the pages in a real off-screen sidebar shell - and
        // the floating bar's same pages unchanged.
        if ProcessInfo.processInfo.environment["FM_RUN_SIDEBAR_REDESIGNS_MODEL_TESTS"] == "1" {
            exit(SidebarRedesignsModelSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_SIDEBAR_REDESIGNS_TESTS"] == "1" {
            exit(SidebarRedesignsSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-engineering-cards-stale-counts`: a hub summary card must
        // reflect a change the captain made through its own detail page. Window-backed
        // (it mounts a real shell and drives the real pages), so it sits in
        // `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_SUMMARY_FRESHNESS_TESTS"] == "1" {
            exit(SummaryFreshnessSelfTest.run() ? 0 : 1)
        }

        // The lock screen's Daylight Harbour restyle - the last pre-Daylight surface
        // (fm/grandline-home-login-redesign-plan). Window-backed: focus, rendering and
        // the off-screen render probe all need a real window, so it sits in
        // run-all-tests.sh's NEEDS_SESSION list. See LockScreenSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_LOCK_SCREEN_TESTS"] == "1" {
            exit(LockScreenSelfTest.run() ? 0 : 1)
        }

        // The full-app audit's §7.1: a source guard cross-checking every window-backed
        // suite in `SelfTests/` against `Scripts/run-all-tests.sh`'s `NEEDS_SESSION`
        // list, which CI's `--ci` / `--session-only` split depends on being accurate.
        if ProcessInfo.processInfo.environment["FM_RUN_E2E_TESTING_POLICY_TESTS"] == "1" {
            exit(E2ETestingPolicySelfTest.run() ? 0 : 1)
        }

        // Proof that a self-test's own window never reaches the captain's display -
        // the measured half of `OffScreenProbeWindow.swift`, whose predecessor
        // convention was documented as invisible and was not.
        if ProcessInfo.processInfo.environment["FM_RUN_OFF_SCREEN_PROBE_TESTS"] == "1" {
            exit(OffScreenProbeSelfTest.run() ? 0 : 1)
        }

        // The full-app audit's §7: regression coverage for the Docs Playbook's
        // WKWebView subresource-cache fix (`fm/grandline-docs-webview-cache-fix`),
        // which shipped with none.
        if ProcessInfo.processInfo.environment["FM_RUN_DOCS_PLAYBOOK_RELOAD_TESTS"] == "1" {
            exit(DocsPlaybookReloadSelfTest.run() ? 0 : 1)
        }

        // The full-app audit's §7: the general Console tab-lifecycle suite - create,
        // duplicate, rename, close, reconnect and the numbered-name convention, none
        // of which had permanent coverage despite being the app's most-patched area.
        if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_TAB_LIFECYCLE_TESTS"] == "1" {
            exit(ConsoleTabLifecycleSelfTest.run() ? 0 : 1)
        }

        // The full-app audit's §7: first coverage for the Setup/Bootstrap data layer,
        // via the `UpdatesDataTestSeam`/`DotfilesDataTestSeam` transport seams.
        if ProcessInfo.processInfo.environment["FM_RUN_SETUP_DATA_LAYER_TESTS"] == "1" {
            exit(SetupDataLayerSelfTest.run() ? 0 : 1)
        }

        // What the Updates page says when an update cannot finish in the background:
        // a timeout reads as one, never as the child's `Error: SIGTERM`, and a cask
        // upgrade that would run `sudo` is handed to the Terminal instead of started.
        if ProcessInfo.processInfo.environment["FM_RUN_UPDATES_FAILURE_TESTS"] == "1" {
            exit(UpdatesFailureSelfTest.run() ? 0 : 1)
        }

        // The Security card's Disable action: the removal the shipped command really
        // performs, run against scratch files, plus the status split that decides
        // which enabled state may offer that button at all.
        if ProcessInfo.processInfo.environment["FM_RUN_SUDO_TOUCHID_DISABLE_TESTS"] == "1" {
            exit(SudoTouchIDDisableSelfTest.run() ? 0 : 1)
        }

        // Daylight Phase 6 (the last phase): the accessibility sweep and the Reduce
        // Motion audit. Dusk's own colour derivation is measured by
        // FM_RUN_CONTRAST_TESTS, where the palette maths already lives. See
        // DaylightHardeningSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_HARDENING_TESTS"] == "1" {
            exit(DaylightHardeningSelfTest.run() ? 0 : 1)
        }

        // Daylight Phase 4: one suite per slice of the per-destination restyle.
        // Slice 1 also covers the shared drill-page components (§6.4-6.14). See each
        // DaylightDrillPage*SelfTest.swift's own header.
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE5_TESTS"] == "1" {
            exit(DaylightDrillPageSlice5SelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE4_TESTS"] == "1" {
            exit(DaylightDrillPageSlice4SelfTest.run() ? 0 : 1)
        }
        // `fm/grand-line-schedules-page-redesign`: the redesigned Schedules page's own
        // honesty claims - see SchedulesRedesignSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULES_REDESIGN_TESTS"] == "1" {
            exit(SchedulesRedesignSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE3_TESTS"] == "1" {
            exit(DaylightDrillPageSlice3SelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS"] == "1" {
            exit(DaylightDrillPageSlice2SelfTest.run() ? 0 : 1)
        }
        // Daylight Phase 4 slice 6: the last two destinations in §7's table, Tools and
        // Settings. See DaylightDrillPageSlice6SelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE6_TESTS"] == "1" {
            exit(DaylightDrillPageSlice6SelfTest.run() ? 0 : 1)
        }
        // Daylight Phase 5: the chrome that is not a destination page - editor sheets,
        // the ⌘K palette, the notification panel, toasts and empty states. See
        // DaylightChromeSelfTest.swift's header.
        // The UI modernization audit's §3F - inputs and forms (F1/F2/F3). See
        // FormsModernizationSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_FORMS_MODERNIZATION_TESTS"] == "1" {
            exit(FormsModernizationSelfTest.run() ? 0 : 1)
        }
        // The UI modernization audit's §3G - toasts, notifications and progress
        // (G1/G2/G4). See FeedbackModernizationSelfTest.swift's header.
        // The UI modernization audit's §3G G3 - the 30-site confirm migration. See
        // ConfirmMigrationSelfTest.swift's header.
        // The UI modernization audit's §3H - overlays (H1-H4). See
        // OverlaysModernizationSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_OVERLAYS_MODERNIZATION_TESTS"] == "1" {
            exit(OverlaysModernizationSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_ICONS_TYPOGRAPHY_TESTS"] == "1" {
            exit(IconsTypographySelfTest.run() ? 0 : 1)
        }
        // The UI modernization audit's §3K/§3L/§3M - Dusk as the daily theme, the
        // theme crossfade, the motion spec's last gap, and the two web-island
        // seam-hiders. K2's own contrast measurements live in
        // `HelmContrastSelfTest.checkTerminalCard`. See
        // ThemeMotionWebIslandsSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_THEME_MOTION_WEB_ISLANDS_TESTS"] == "1" {
            exit(ThemeMotionWebIslandsSelfTest.run() ? 0 : 1)
        }
        // The six families the captain picked off the theme-suggestions board
        // (`fm/grandline-new-themes-nord-dracula-etc`). Two suites, split the way
        // AGENTS.md's "Writing a self-test" requires: the family pairing and the
        // palette shape assert nothing that needs a window and therefore guard CI's
        // blocking lane, while the real painted render of a real page under each new
        // palette is window-backed and lives in `NEEDS_SESSION`. Their *contrast* is
        // `HelmContrastSelfTest`'s, which sweeps `HelmTheme.allThemes` and needed no
        // edit at all.
        if ProcessInfo.processInfo.environment["FM_RUN_THEME_FAMILY_TESTS"] == "1" {
            exit(ThemeFamilySelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_THEME_FAMILY_VIEW_TESTS"] == "1" {
            exit(ThemeFamilyRenderSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CONFIRM_MIGRATION_TESTS"] == "1" {
            exit(ConfirmMigrationSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_FEEDBACK_MODERNIZATION_TESTS"] == "1" {
            exit(FeedbackModernizationSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_CHROME_TESTS"] == "1" {
            exit(DaylightChromeSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_TESTS"] == "1" {
            exit(DaylightDrillPageSelfTest.run() ? 0 : 1)
        }

        // GL-37: the destination table and lazy-mount-with-permanent-retention -
        // only the eager slots exist at launch, a first visit builds exactly one,
        // and a revisit reuses it. See DestinationMountingSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DESTINATION_MOUNTING_TESTS"] == "1" {
            exit(DestinationMountingSelfTest.run() ? 0 : 1)
        }

        // The launch-path half of the 2026-10 end-to-end review's performance
        // findings (PERF-01, PERF-02, PERF-08 and T-14d's signposts). Pure logic. See
        // LaunchPathSelfTest.swift's header.
        // PERF-07 of the 2026-10 end-to-end review: a background tab's scrollback
        // shrinks after a grace period and comes back on select. Pure logic (real
        // terminals, no window, no process). See BackgroundScrollbackSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_BACKGROUND_SCROLLBACK_TESTS"] == "1" {
            exit(BackgroundScrollbackSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_LAUNCH_PATH_TESTS"] == "1" {
            exit(LaunchPathSelfTest.run() ? 0 : 1)
        }

        // fm/grandline-app-lock: same convention, for `AppLockController`'s idle/
        // hard-logout timing math against a fake clock/idle-time provider - see
        // AppLockSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_APP_LOCK_TESTS"] == "1" {
            exit(AppLockControllerSelfTest.run() ? 0 : 1)
        }

        // R2-ARCH-08: every store with a change signal can be watched by any number
        // of readers (`StoreObservableSelfTest`, pure logic).
        if ProcessInfo.processInfo.environment["FM_RUN_STORE_OBSERVABLE_TESTS"] == "1" {
            exit(StoreObservableSelfTest.run() ? 0 : 1)
        }

        // R2-ARCH-04: the floating bar's presentation of each page sits in a
        // `+Classic.swift` file of its own (`ClassicPresentationSelfTest`, pure logic).
        if ProcessInfo.processInfo.environment["FM_RUN_CLASSIC_PRESENTATION_TESTS"] == "1" {
            exit(ClassicPresentationSelfTest.run() ? 0 : 1)
        }

        // The second full review's UX findings and the captain's three UI items: the
        // pure half - models, menus and source guards (`ReviewTwoUXModelSelfTest`).
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW2_UX_MODEL_TESTS"] == "1" {
            exit(ReviewTwoUXModelSelfTest.run() ? 0 : 1)
        }

        // ...and the window-backed half: a real sidebar shell, a real Settings page
        // and real pixels (`ReviewTwoUXSelfTest`, in `NEEDS_SESSION`).
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW2_UX_TESTS"] == "1" {
            exit(ReviewTwoUXSelfTest.run() ? 0 : 1)
        }

        // R2-PERF-01: the launch path's signposts, timed in process - the real
        // app delegate, its shell per layout and a first display, against this
        // process's scratch stores. Window-backed.
        if ProcessInfo.processInfo.environment["FM_RUN_LAUNCH_TIMING_TESTS"] == "1" {
            exit(LaunchTimingSelfTest.run() ? 0 : 1)
        }

        // The second full review's accessibility and performance findings
        // (R2-A11Y-03 to 05, R2-PERF-01 to 06): the pure half - the label words,
        // the Updates check record and the attention card's staleness check.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW2_A11Y_PERF_MODEL_TESTS"] == "1" {
            exit(ReviewTwoA11yPerfModelSelfTest.run() ? 0 : 1)
        }

        // ...and the window-backed half: a real sidebar shell, its toolbar and
        // its outline view (`ReviewTwoA11yPerfSelfTest`, in `NEEDS_SESSION`).
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW2_A11Y_PERF_TESTS"] == "1" {
            exit(ReviewTwoA11yPerfSelfTest.run() ? 0 : 1)
        }

        // R2-UX-01 (a): the app lock as an opt-in - the first launch's settlement, the
        // lock screen settling an undecided install, and Check again. Pure logic.
        if ProcessInfo.processInfo.environment["FM_RUN_APP_LOCK_OPT_IN_TESTS"] == "1" {
            exit(AppLockOptInSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-log-analyzer-build`: same convention, for the Log Analyzer's
        // whole pure-logic layer - redaction (including byte-level greps of a built
        // AI prompt and a saved investigation for planted secrets), source detection,
        // severity/grouping, timeline, correlation, AI reply parsing, Command Library
        // matching, artifact rendering, comparison, storage, and the terminal-capture
        // scope rule - see LogAnalyzerSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_LOG_ANALYZER_TESTS"] == "1" {
            exit(LogAnalyzerSelfTest.run() ? 0 : 1)
        }

        // P2-P6 (`data/grand-line-e2e-audit/report.md`): the performance findings that
        // are testable as behaviour - see AuditPerfFixesSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_PERF_FIXES_TESTS"] == "1" {
            exit(AuditPerfFixesSelfTest.run() ? 0 : 1)
        }

        // `data/grand-line-appkit-expert-audit/report.md`: the AppKit-expert audit's
        // smaller findings, one case per finding id - see AppKitAuditSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_APPKIT_AUDIT_TESTS"] == "1" {
            exit(AppKitAuditSelfTest.run() ? 0 : 1)
        }

        // Section 3 of `data/grandline-full-app-audit/report.md`: the standing
        // per-session energy costs - see AuditEnergyFixesSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_ENERGY_FIXES_TESTS"] == "1" {
            exit(AuditEnergyFixesSelfTest.run() ? 0 : 1)
        }

        // B3-B9 (`data/grand-line-e2e-audit/report.md`): the Section 2 UI bugs, one
        // case per finding id - see AuditUIFixesSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_UI_FIXES_TESTS"] == "1" {
            exit(AuditUIFixesSelfTest.run() ? 0 : 1)
        }

        // The UI-section findings from `data/grandline-full-app-audit/report.md`
        // (`fm/grandline-audit-ui-fixes`), one case per finding - see
        // FullAppAuditUISelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_FULL_APP_AUDIT_UI_TESTS"] == "1" {
            exit(FullAppAuditUISelfTest.run() ? 0 : 1)
        }

        // The UI and UX findings of the 2026-09-27 full-application review: the 17
        // rendered UI defects and X1..X7 - see ReviewUIUXSelfTest.swift's header.
        // Pure logic and source guards, so it runs in CI's blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_UI_UX_TESTS"] == "1" {
            exit(ReviewUIUXSelfTest.run() ? 0 : 1)
        }

        // Section 5 of `data/grandline-full-app-audit/report.md`: the security
        // findings, one case per finding id - see AuditSecurityFixesSelfTest.swift's
        // header. Pure logic, so it runs in CI; §5.1's window-backed half is the
        // separate suite below.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_SECURITY_FIXES_TESTS"] == "1" {
            exit(AuditSecurityFixesSelfTest.run() ? 0 : 1)
        }

        // §5.1's behavioural half: builds the two real palettes and reads their
        // registration back off the lock gate - see AuditSecurityLockSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_SECURITY_LOCK_TESTS"] == "1" {
            exit(AuditSecurityLockSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT2_SECURITY_FIXES_TESTS"] == "1" {
            exit(Audit2SecurityFixesSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT2_FEATURE_ENHANCEMENTS_TESTS"] == "1" {
            exit(Audit2FeatureEnhancementsSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_LOCK_GATE_COVERAGE_TESTS"] == "1" {
            exit(LockGateCoverageSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT2_SECURITY_LOCK_TESTS"] == "1" {
            exit(Audit2SecurityLockSelfTest.run() ? 0 : 1)
        }

        // B1 (`data/grand-line-e2e-audit/report.md`): same convention, for the Vault
        // page's (Automic Vault's hardening panel) failed/pending read states - see
        // VaultLoadingStateSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_VAULT_LOADING_STATE_TESTS"] == "1" {
            exit(VaultLoadingStateSelfTest.run() ? 0 : 1)
        }

        // E3 (`data/grand-line-e2e-audit/report.md`): same convention, for the
        // backgrounded poll tier - see AppActivityStateSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_APP_ACTIVITY_STATE_TESTS"] == "1" {
            exit(AppActivityStateSelfTest.run() ? 0 : 1)
        }

        // E1 (`data/grand-line-e2e-audit/report.md`): same convention, for the
        // terminal display gating that closed the app's dominant battery drain - see
        // TerminalDisplayGatingSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_DISPLAY_GATING_TESTS"] == "1" {
            exit(TerminalDisplayGatingSelfTest.run() ? 0 : 1)
        }

        // PF1 of the 2026-09-25 full review: the per-row CoreText render cache that
        // closed the background terminal's ~0.1-core repaint cost - see
        // TerminalRowRenderCacheSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_ROW_RENDER_CACHE_TESTS"] == "1" {
            exit(TerminalRowRenderCacheSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-shell-selection-investigate-fix`: same convention, for the
        // Shell tab's own text selection measured from real rendered pixels - see
        // TerminalSelectionRenderSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_SELECTION_RENDER_TESTS"] == "1" {
            exit(TerminalSelectionRenderSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-dictation-mvp`: same convention, for `DictationHotkey`'s
        // hold/release detection over synthetic `.flagsChanged` events - see
        // DictationHotkeySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_HOTKEY_TESTS"] == "1" {
            exit(DictationHotkeySelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-capture-global-hotkey-configurable`: the same convention for
        // `ShiftGlobalHotkey` - its matching predicate over synthetic events, and the
        // structural "which monitors did `start()` actually install" checks the class
        // shipped without. See ShiftGlobalHotkeySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_QUICK_CAPTURE_HOTKEY_TESTS"] == "1" {
            exit(ShiftGlobalHotkeySelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-dictation-phase2`: same convention, for `DictationStore`'s
        // history/vocabulary persistence and `KeyChord`'s encode/decode +
        // display-string logic - see DictationDataSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_DATA_TESTS"] == "1" {
            exit(DictationDataSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-dictation-phase3`: same convention, for `DictationCleanup`'s
        // `claude -p` invocation/parsing/fallback logic - see
        // DictationCleanupSelfTest.swift's header.
        // Phase 3's own structural guards - the release-binary exclusion (GL-27), the
        // text floor (GL-32), the growth caps (GL-35) and the undo slot (GL-33). See
        // `SelfTests/Phase3PolishSelfTest.swift`.
        if ProcessInfo.processInfo.environment["FM_RUN_PHASE3_POLISH_TESTS"] == "1" {
            exit(Phase3PolishSelfTest.run() ? 0 : 1)
        }

        // GL-16 (Phase 3): what the accessibility sweep guarantees - roles, labels,
        // press actions, keyboard activation, focus rings and Reduce Motion, asserted
        // in the shared components. See `AccessibilitySelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_ACCESSIBILITY_TESTS"] == "1" {
            exit(AccessibilitySelfTest.run() ? 0 : 1)
        }

        // GL-29 (Phase 3): `BackgroundSignalsPoller`'s pass latch (GL-03's own fix) and
        // `ServiceHealthRegistry`'s verdicts. See `BackgroundSignalsSelfTest.swift`.
        if ProcessInfo.processInfo.environment["FM_RUN_BACKGROUND_SIGNALS_TESTS"] == "1" {
            exit(BackgroundSignalsSelfTest.run() ? 0 : 1)
        }

        // GL-29 (Phase 3): the SSH credential path - `SSHKeyGenerator`,
        // `SSHKeyMaterializer`, and the Keychain contract. See
        // `CredentialPathSelfTest.swift`'s header for what it does and does not touch.
        if ProcessInfo.processInfo.environment["FM_RUN_CREDENTIAL_PATH_TESTS"] == "1" {
            exit(CredentialPathSelfTest.run() ? 0 : 1)
        }

        // S11: a saved host's startup snippet is staged at the prompt rather than
        // executed 1.5 seconds after `ssh` starts. Pure logic plus a source guard.
        if ProcessInfo.processInfo.environment["FM_RUN_STARTUP_SNIPPET_GATE_TESTS"] == "1" {
            exit(StartupSnippetGateSelfTest.run() ? 0 : 1)
        }

        // B4 of the Grand Line vs Automic Vault polish report: a self-test or tour
        // process never starts the captain's real `av`, `brew`, `gh`, `herdr` or
        // firstmate scripts. Recording stubs first on PATH, asserting zero launches.
        // Pure logic. See ExternalToolGuardSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_EXTERNAL_TOOL_GUARD_TESTS"] == "1" {
            exit(ExternalToolGuardSelfTest.run() ? 0 : 1)
        }

        // R2-SEC-01: a self-test or tour process sends no request anywhere but
        // loopback. A tripwire behind the gate counts anything that gets past it.
        // Pure logic. See NetworkGateSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_NETWORK_GATE_TESTS"] == "1" {
            exit(NetworkGateSelfTest.run() ? 0 : 1)
        }

        // R2-PROC-02: one `ProcessMode` decides what a test process is, an isolated
        // process never resolves the real data root, and every suite runs in a scratch
        // root of its own. Pure logic plus source guards over the runner and ci.yml.
        // See ProcessModeSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_PROCESS_MODE_TESTS"] == "1" {
            exit(ProcessModeSelfTest.run() ? 0 : 1)
        }

        // The second full review's security findings (R2-SEC-01 to R2-SEC-12): the
        // source guards that every pasteboard read, network session, AI call, log
        // line, synced commit and data-derived URL open takes its one shared path.
        // Pure logic. See SecretBoundariesSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SECRET_BOUNDARIES_TESTS"] == "1" {
            exit(SecretBoundariesSelfTest.run() ? 0 : 1)
        }

        // GL-29 (Phase 3): `FleetDataSource`/`OpenPRsSource` - the pair behind Overview
        // and Review, including the merge action's argv. See
        // `FleetDataSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_FLEET_DATA_TESTS"] == "1" {
            exit(FleetDataSelfTest.run() ? 0 : 1)
        }

        // F4: notification action routing - which action maps to which real function
        // call, and whether the merge gate genuinely blocks a non-green PR. See
        // `NotificationActionsSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_ACTIONS_TESTS"] == "1" {
            exit(NotificationActionsSelfTest.run() ? 0 : 1)
        }

        // GL-29 (Phase 3): `DictationEngine`'s finish/race/timeout state machine -
        // three real shipped bugs, previously verified only by reverted probes. See
        // `DictationEngineSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_ENGINE_TESTS"] == "1" {
            exit(DictationEngineSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_CLEANUP_TESTS"] == "1" {
            exit(DictationCleanupSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-dictation-autopaste-not-firing`: the floating HUD's own
        // misleading-status regression - window-backed, since it asserts a real
        // painted label. See `DictationAutopasteHUDSelfTest.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_AUTOPASTE_HUD_TESTS"] == "1" {
            exit(DictationAutopasteHUDSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-dictation-whisper-engine`: same convention, for the vendored
        // whisper.cpp wrapper's model validation, audio resampling, and (when a real
        // model path is provided) real load/transcribe - see
        // WhisperEngineSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_ENGINE_TESTS"] == "1" {
            exit(WhisperEngineSelfTest.run() ? 0 : 1)
        }

        // Child-process-only entry point `testMetalFallbackDoesNotCrash()` spawns
        // with `FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed at an empty directory -
        // see that test's own doc comment for why this needs a genuinely separate
        // process rather than an in-process assertion.
        if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_METAL_FALLBACK_ONLY_TEST"] == "1" {
            exit(WhisperEngineSelfTest.runRealModelOnly() ? 0 : 1)
        }

        // `fm/grandline-docs-knowledge-foundation`: same convention, for
        // `DocsRunbookStore`'s CRUD/title-slug logic and `DocsKnowledgeSearch`'s
        // scoped search, plus (against a real disposable local bare repo, never
        // `manjesh-config`) `ShiftGitSync`'s repo-layout migration - see
        // DocsRunbookDataSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_DOCS_RUNBOOK_TESTS"] == "1" {
            exit(DocsRunbookDataSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-sre-lead-postmortem`: same convention, for
        // `SRELeadPostmortem.generate`'s `claude -p` invocation/parsing/fallback
        // logic - see SRELeadPostmortemSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_POSTMORTEM_TESTS"] == "1" {
            exit(SRELeadPostmortemSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-console-command-composer`: same convention, for
        // `ConsoleCommandComposer.generate`'s `claude -p` invocation/parsing/fallback
        // logic - see ConsoleCommandComposerSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_COMMAND_COMPOSER_TESTS"] == "1" {
            exit(ConsoleCommandComposerSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-whiteboard-excalidraw`: the Whiteboard destination. Two
        // suites, split by what they need - `WhiteboardSelfTest` is pure logic (asset
        // resolution, the page's offline CSP, the AI prompt and parse, the destination
        // tables) and runs in CI; `WhiteboardViewSelfTest` mounts a real `WKWebView`
        // in a real window, loads the real vendored Excalidraw bundle and measures the
        // hidden-view gating, so it is window-backed and lives in
        // `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_TESTS"] == "1" {
            exit(WhiteboardSelfTest.run() ? 0 : 1)
        }
        // `fm/grand-line-whiteboard-component-icons-overhaul`: the component artwork
        // and the two caption bugs it fixed. Pure logic, so it runs in CI - the live
        // half is in the window-backed view suite.
        if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_ICONS_TESTS"] == "1" {
            exit(WhiteboardIconsSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_VIEW_TESTS"] == "1" {
            exit(WhiteboardViewSelfTest.run() ? 0 : 1)
        }
        // `fm/grandline-devops-space-and-diagram-tool`: the deterministic
        // text-to-diagram layer beside the AI one. Pure logic and **CI-runnable** -
        // unlike its AI sibling, which needs a fake `claude` on disk, the whole point
        // of this layer is that no such thing is involved.
        // F15 of full review #3 §8 (`fm/grandline-feature-f15-screenshot-annotate`):
        // screenshot capture -> Whiteboard -> annotate -> copy. Two suites, split the
        // same way the Whiteboard's own pair is - `ScreenCaptureAnnotateSelfTest` is
        // pure logic (the capture decision, the pasteboard intake, the encode and the
        // placement maths) and runs in CI; `WhiteboardCaptureViewSelfTest` drives a
        // real Excalidraw canvas and pixel-samples the flattened export, so it needs a
        // session.
        if ProcessInfo.processInfo.environment["FM_RUN_SCREEN_CAPTURE_ANNOTATE_TESTS"] == "1" {
            exit(ScreenCaptureAnnotateSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_CAPTURE_VIEW_TESTS"] == "1" {
            exit(WhiteboardCaptureViewSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_DSL_TESTS"] == "1" {
            exit(WhiteboardDSLSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-quota-percent-fix`: same convention, for `QuotaSource.parse`
        // against `quota-axi`'s real `percentRemaining`-keyed output - see
        // QuotaDataSelfTest.swift's header.
        // `fm/grandline-monaco-code-preview`: the Code Preview destination. Two
        // suites, split the same way the Whiteboard's are and for the same reason -
        // `CodePreviewSelfTest` is pure logic (asset resolution, the page's offline
        // CSP, the language table, paste-time detection, the store's disk round trip,
        // the syntax palette's measured contrast) and runs in CI; `CodePreviewViewSelfTest`
        // mounts a real `WKWebView`, loads the real vendored Monaco bundle and reads
        // Monaco's own tokenizer output back, so it is window-backed and lives in
        // `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_TESTS"] == "1" {
            exit(CodePreviewSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_VIEW_TESTS"] == "1" {
            exit(CodePreviewViewSelfTest.run() ? 0 : 1)
        }
        // `fm/grandline-codepreview-file-sidebar`: Code Preview's snippet list, split
        // the same way - `CodePreviewSidebarSelfTest` is pure logic (the list's order,
        // the filter, the icon table, the remembered visibility and width, the ⌘B menu
        // item) and runs in CI; `CodePreviewSidebarViewSelfTest` mounts the real page
        // in a real window and is in NEEDS_SESSION.
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_SIDEBAR_TESTS"] == "1" {
            exit(CodePreviewSidebarSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_SIDEBAR_VIEW_TESTS"] == "1" {
            exit(CodePreviewSidebarViewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-feature-f11-code-preview-run-format` (F11 of full review #3
        // §8): Run and Format in Code Preview. Split the same way again, and the split
        // matters more here than usual - `CodeRunnerSelfTest` is the suite that asserts
        // the `sandbox-exec` profile's denials, the wall clock and the pruned
        // environment, and those are exactly the checks that must guard the *blocking*
        // CI lane. It needs no window: a real subprocess round trip does not (it is
        // skipped out loud on a machine with no `python3`), and every
        // machine-dependent decision above it runs against an injected
        // `CodeToolProbing`. `CodeRunnerViewSelfTest` mounts the real Code Preview
        // page in a real window to drive the real Run/Format buttons and read the real
        // output pane back, so that half is window-backed.
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_RUNNER_TESTS"] == "1" {
            exit(CodeRunnerSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CODE_RUNNER_VIEW_TESTS"] == "1" {
            exit(CodeRunnerViewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-feature-f1-notebook` (F1 of full review #3 §8).
        // `NotebookSelfTest` is pure logic - the markdown parser, the wiki-link
        // scanner, the resolver's tie-break order, the backlink index, the daily-note
        // naming, the store's disk round trip and its path-escape refusal - and runs
        // in CI's blocking lane. `NotebookViewSelfTest` mounts the real destination in
        // a real window (and the real vendored Monaco bundle), so it is window-backed
        // and lives in `run-all-tests.sh`'s NEEDS_SESSION list. The split is AGENTS.md's
        // own rule: the test is what the suite asserts, never what it imports.
        // `fm/grandline-feature-f2-f3-capture-clipboard` (F2 of full review #3 §8).
        // `CaptureRouterSelfTest` is pure logic - the chord map, the shared draft
        // parse, the derived store names, the crew classifier's prompt and reply
        // parsing, and the concealed-pasteboard refusal - and runs in CI's blocking
        // lane. `CaptureRouterViewSelfTest` mounts the real ⌥Space panel and drives
        // real key equivalents and real tile clicks, so it is window-backed and lives
        // in `run-all-tests.sh`'s NEEDS_SESSION list. The split is AGENTS.md's own
        // rule: the test is what the suite asserts, never what it imports.
        // `fm/grandline-feature-f2-f3-capture-clipboard` (F3 of full review #3 §8).
        // `ClipboardHistorySelfTest` is pure logic - the capture rule, the Poneglyph
        // exclusion proved in both directions, the rolling eviction and what a pin
        // does to it, the sealed round trip, GL-01's unreadable-file state and the
        // shared `changeCount` watch - and runs in CI's blocking lane.
        // `ClipboardHistoryViewSelfTest` builds the real ⌘⇧V panel, so it is
        // window-backed and lives in `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_CLIPBOARD_HISTORY_TESTS"] == "1" {
            exit(ClipboardHistorySelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CLIPBOARD_HISTORY_VIEW_TESTS"] == "1" {
            exit(ClipboardHistoryViewSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_CAPTURE_ROUTER_TESTS"] == "1" {
            exit(CaptureRouterSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_CAPTURE_ROUTER_VIEW_TESTS"] == "1" {
            exit(CaptureRouterViewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-feature-f4-reading-list` (F4 of full review #3 §8).
        // `ReadingListSelfTest` is pure logic - URL detection and normalisation, tag
        // folding, the read-state and filter rules, the AI prompt and reply parse, the
        // store's disk round trip, its GL-01 refusal and its forward-compatible decode
        // - and runs in CI's blocking lane. `ReadingListViewSelfTest` mounts the real
        // destination in a real window and reads painted colours back out of a render,
        // so it is window-backed and lives in `run-all-tests.sh`'s NEEDS_SESSION list.
        // The split is AGENTS.md's own rule: the test is what the suite asserts, never
        // what it imports.
        if ProcessInfo.processInfo.environment["FM_RUN_READING_LIST_TESTS"] == "1" {
            exit(ReadingListSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_READING_LIST_VIEW_TESTS"] == "1" {
            exit(ReadingListViewSelfTest.run() ? 0 : 1)
        }

        // F9's scratchpad calculator (`fm/grandline-feature-f9-scratchpad-calculator`).
        // Two suites, split the way AGENTS.md's "Writing a self-test" requires: the
        // engine (lexer, parser, units, currency, dates, formatting) asserts nothing
        // that needs a window and therefore guards CI's blocking lane, while the pad's
        // own two-column view is measured in a real `NSWindow` and lives in
        // `NEEDS_SESSION`.
        if ProcessInfo.processInfo.environment["FM_RUN_SCRATCHPAD_TESTS"] == "1" {
            exit(ScratchpadEngineSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_SCRATCHPAD_VIEW_TESTS"] == "1" {
            exit(ScratchpadPadViewSelfTest.run() ? 0 : 1)
        }

        // F12's snippet expander (`fm/grandline-feature-f12-snippet-expander`). Two
        // suites, split the way AGENTS.md's "Writing a self-test" requires: the
        // trigger grammar, the lookup, the placeholders and the scope/exclusion policy
        // assert nothing that needs a window and therefore guard CI's blocking lane,
        // while the Snippets page's own card, rows and editor sheet are measured in a
        // real `NSWindow` and live in `NEEDS_SESSION`.
        if ProcessInfo.processInfo.environment["FM_RUN_SNIPPET_EXPANSION_TESTS"] == "1" {
            exit(SnippetExpansionSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_SNIPPET_EXPANDER_VIEW_TESTS"] == "1" {
            exit(SnippetExpanderViewSelfTest.run() ? 0 : 1)
        }

        // F22's menu-bar (compact) mode. Two suites, split the way AGENTS.md's
        // "Writing a self-test" requires: the mode's policy, its hotkey chord, its
        // tab table and the whole Today/Notes derivation assert nothing that needs a
        // window and therefore guard CI's blocking lane, while the popover's chrome,
        // its pane swapping and its rendered colours are measured in a real
        // `NSWindow` and live in `NEEDS_SESSION`.
        if ProcessInfo.processInfo.environment["FM_RUN_COMPACT_MODE_TESTS"] == "1" {
            exit(CompactModeSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_COMPACT_MODE_VIEW_TESTS"] == "1" {
            exit(CompactModeViewSelfTest.run() ? 0 : 1)
        }

        // F24: the five new `.glbackup` sections - the file archive, the per-file
        // diff, the merge-not-overwrite apply and the sealed vault's round trip. Pure
        // logic; deliberately NOT in `NEEDS_SESSION`.
        if ProcessInfo.processInfo.environment["FM_RUN_BACKUP_STORES_TESTS"] == "1" {
            exit(BackupStoreSectionsSelfTest.run() ? 0 : 1)
        }
        // F21: the five App Intent actions and, above all, Copy Credential's
        // auth-gating. Pure logic - the vault unlock and the biometric challenge are
        // both injected, so nothing here needs a fingerprint.
        if ProcessInfo.processInfo.environment["FM_RUN_APP_INTENT_ACTIONS_TESTS"] == "1" {
            exit(AppIntentActionsSelfTest.run() ? 0 : 1)
        }
        // F21/F24's UI halves: the two new Settings cards, mounted in a real window.
        if ProcessInfo.processInfo.environment["FM_RUN_INTENTS_BACKUP_VIEW_TESTS"] == "1" {
            exit(IntentsBackupSettingsViewSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_NOTEBOOK_TESTS"] == "1" {
            exit(NotebookSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_NOTEBOOK_VIEW_TESTS"] == "1" {
            exit(NotebookViewSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_QUOTA_DATA_TESTS"] == "1" {
            exit(QuotaDataSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-claude-status-card-implement`: window-backed - it builds a
        // real `HelmModuleCard` in a real probe window and reads back rendered
        // geometry plus a real rasterised pixel. Listed in `NEEDS_SESSION` in
        // `Scripts/run-all-tests.sh` accordingly.
        if ProcessInfo.processInfo.environment["FM_RUN_CLAUDE_STATUS_CARD_TESTS"] == "1" {
            exit(ClaudeStatusCardSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-notification-center`: pure store logic (add/clear/dismiss/
        // dedup/badge count) - see GrandLineNotificationCenterSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_TESTS"] == "1" {
            exit(GrandLineNotificationCenterSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-notification-center-redesign`: window-backed - it mounts the
        // real "Waiting for you" panel in a real `OffScreenProbe` window and reads
        // back rendered geometry, real hover state and a real rasterised pixel.
        // Listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh` accordingly.
        // `fm/grandline-notification-rows-not-interactive`: window-backed, and it has
        // to be - it dispatches real `NSEvent`s through the real `HelmBarPanel` window
        // the bell opens, which is the only place gesture arbitration between the
        // row's recognizer and its nested buttons is observable. Listed in
        // `NEEDS_SESSION` in `Scripts/run-all-tests.sh` accordingly.
        if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_ROW_INTERACTION_TESTS"] == "1" {
            exit(NotificationRowInteractionSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_REDESIGN_TESTS"] == "1" {
            exit(NotificationCenterRedesignSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-notification-ambient-expand-fix`: pure logic - it drives the
        // poller's own ambient pass and reads the published entry back, with no window
        // anywhere. Deliberately *not* in `NEEDS_SESSION`: whether a row has children
        // at all is what this guards, and it belongs in the blocking lane.
        if ProcessInfo.processInfo.environment["FM_RUN_AMBIENT_SIGNAL_CHILDREN_TESTS"] == "1" {
            exit(AmbientSignalChildrenSelfTest.run() ? 0 : 1)
        }

        // The trickiest of the nine signals - SRE Lead replying on a tab you're not
        // looking at - driven against a real `ConsoleController`, same convention as
        // `SRELeadPerTabSelfTest.swift`. See NotificationCenterSRELeadSelfTest.swift's
        // header.
        if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS"] == "1" {
            exit(NotificationCenterSRELeadSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-design-audit-phase0`: WCAG contrast floors for the shared
        // pill, icon tiles and `HelmTheme.mutedInk`, across every real palette - see
        // HelmContrastSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CONTRAST_TESTS"] == "1" {
            exit(HelmContrastSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-review-page-stuck-loading-fix`: the Review page's loading ->
        // loaded state transition (drives `render(_:)` directly via
        // `ReviewController`'s own "Probe / self-test surface", no real network
        // fetch) - see ReviewControllerLoadingStateSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_LOADING_STATE_TESTS"] == "1" {
            exit(ReviewControllerLoadingStateSelfTest.run() ? 0 : 1)
        }

        // The full review's page-level polish findings UXP-01 to UXP-20. Window-backed:
        // every case mounts a real page in an `OffScreenProbe` window.
        if ProcessInfo.processInfo.environment["FM_RUN_PAGE_POLISH_UXP_TESTS"] == "1" {
            exit(PagePolishUXPSelfTest.run() ? 0 : 1)
        }

        // The UI modernization audit's one functional finding: "ready to merge" was
        // answered by three different questions in one frame. Mounts the real Review
        // and Overview surfaces and reads the numbers off the rendered views, plus a
        // source guard against the next surface bringing its own filter - see
        // ReadyToMergeCountSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_READY_TO_MERGE_TESTS"] == "1" {
            exit(ReadyToMergeCountSelfTest.run() ? 0 : 1)
        }

        // The volume measurement that proves the fix above - a demand-driven
        // `NSTableView` renders hundreds of PR rows without the plain-`NSStackView`
        // blowup #221 shipped. See ReviewPRListVolumeSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_LIST_VOLUME_TESTS"] == "1" {
            exit(ReviewPRListVolumeSelfTest.run() ? 0 : 1)
        }

        // The row-width/button-visibility contract that regressed a second time when
        // #227 ported this row into a reused NSTableView cell view without carrying
        // forward the "reused row, toggling button visibility" fix
        // `HostsListRecordView` already established. See
        // ReviewPRRowButtonLayoutSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_ROW_BUTTON_LAYOUT_TESTS"] == "1" {
            exit(ReviewPRRowButtonLayoutSelfTest.run() ? 0 : 1)
        }

        // F11: the scheduler's due / missed-while-asleep / catch-up decision, the
        // store's anchoring rules, and the notify-on gate. See
        // ScheduleRunnerSelfTest.swift's header for why the missed-run case is the one
        // worth pinning: every symptom of getting it wrong is a run that did not
        // happen, which looks exactly like a quiet night.
        if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_RUNNER_TESTS"] == "1" {
            exit(ScheduleRunnerSelfTest.run() ? 0 : 1)
        }

        // F11 follow-up: the one-time seed of the "daily-github-sync" schedule -
        // seeds once using the pre-existing `.forkSync` action, never resurrects
        // itself after the captain edits or deletes it, and introduces no new
        // schedulable action. See `ScheduleSeeding.swift`'s header.
        if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_SEEDING_TESTS"] == "1" {
            exit(ScheduleSeedingSelfTest.run() ? 0 : 1)
        }

        // Run History status clarity + "View Log": the plain succeeded/failed/
        // needs-attention chip, the run's own output persisting through
        // `ScheduleRunHistoryEntry.log` (with truncation and old-format tolerance),
        // and the Run History sheet's "View Log" button/`ScheduleRunLogController`
        // pair. Window-backed - mounts real `ScheduleHistoryController`/
        // `ScheduleRunLogController` instances. See
        // ScheduleRunHistoryStatusAndLogSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_RUN_HISTORY_STATUS_LOG_TESTS"] == "1" {
            exit(ScheduleRunHistoryStatusAndLogSelfTest.run() ? 0 : 1)
        }

        // F12 (`fm/grandline-feature-f12-morning-briefing`): the morning briefing's
        // local composer (what data goes in, and the unknown-is-not-zero rule) plus
        // its degradation path, driven through the real `ClaudeOneShot` against a
        // disposable fake `claude`. See MorningBriefingSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_MORNING_BRIEFING_TESTS"] == "1" {
            exit(MorningBriefingSelfTest.run() ? 0 : 1)
        }

        // F20 (`fm/grandline-feature-f20-daily-review-briefing`): the daily review's
        // composer - what is due, which follow-ups are waiting, and the stated-gap
        // rule (a section that could not be read says so rather than showing a
        // zero). Pure logic, so it guards the blocking CI lane.
        if ProcessInfo.processInfo.environment["FM_RUN_DAILY_REVIEW_TESTS"] == "1" {
            exit(DailyReviewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-remove-today-calendar-1792553365`: the Today page and the
        // calendar integration stay removed - no destination, no space pill, no
        // source that names them, no calendar usage description in either bundle,
        // and a one-time launch cleanup that deletes what they left on the Mac. Pure
        // logic with a scratch defaults domain, a prefixed Keychain service and a
        // scratch file, so it guards the blocking CI lane.
        if ProcessInfo.processInfo.environment["FM_RUN_TODAY_CALENDAR_REMOVAL_TESTS"] == "1" {
            exit(TodayCalendarRemovalSelfTest.run() ? 0 : 1)
        }

        // The Home page's Needs Attention card - the captain's move of the Today
        // page's "Due today" and "Follow-ups" sections. Same split for the same
        // reason: `NeedsAttentionSelfTest` is a function over a struct and guards
        // CI's blocking lane, `NeedsAttentionViewSelfTest` mounts the real hub in a
        // real window and lives in `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_NEEDS_ATTENTION_TESTS"] == "1" {
            exit(NeedsAttentionSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["FM_RUN_NEEDS_ATTENTION_VIEW_TESTS"] == "1" {
            exit(NeedsAttentionViewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-home-page-visual-overhaul`: the hub's hand-placed dashboard,
        // split the same way and for the same reason as the pair above -
        // `HomeDashboardSelfTest` is arithmetic over numbers and guards CI's
        // blocking lane, `HomeDashboardViewSelfTest` reads resolved frames out of a
        // real window and lives in `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_HOME_DASHBOARD_TESTS"] == "1" {
            exit(HomeDashboardSelfTest.run() ? 0 : 1)
        }
        // `fm/grandline-claude-widget-refresh-shift`: `HelmModuleCard`'s header
        // keeps its status column hard against the header's trailing control on
        // every rebuild of the card. See ModuleCardHeaderStabilitySelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_MODULE_CARD_HEADER_TESTS"] == "1" {
            exit(ModuleCardHeaderStabilitySelfTest.run() ? 0 : 1)
        }
        // PERF-05 of the 2026-10 end-to-end review: the four data-scaled lists keep
        // their rows across a refresh. Window-backed. See KeyedListsViewSelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_KEYED_LISTS_VIEW_TESTS"] == "1" {
            exit(KeyedListsViewSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_HOME_DASHBOARD_VIEW_TESTS"] == "1" {
            exit(HomeDashboardViewSelfTest.run() ? 0 : 1)
        }
        // `fm/grandline-home-fit-implement`: the hub fits the window at the three
        // measured sizes and the attention list scrolls inside its own card.
        // Window-backed - it mounts the real shell to read the bar-reduced viewport -
        // so it is listed in `run-all-tests.sh`'s NEEDS_SESSION.
        if ProcessInfo.processInfo.environment["FM_RUN_HOME_FIT_TESTS"] == "1" {
            exit(HomeFitSelfTest.run() ? 0 : 1)
        }
        // `fm/grandline-layout-breaks-refresh-reply`: the Fleet reply composer never
        // widens the window, a widened window does not outlive its page, and Home
        // holds its columns and height through a refresh and every loading state.
        // Window-backed (it orders its window in), so listed in NEEDS_SESSION.
        if ProcessInfo.processInfo.environment["FM_RUN_LAYOUT_STABILITY_TESTS"] == "1" {
            exit(LayoutStabilitySelfTest.run() ? 0 : 1)
        }

        // F9 (v1, multi-host command execution): the host-selection logic - tag
        // matching, the never-preselected invariant, the risk gate firing once per
        // host, and the unfilled-parameter refusal applied across a whole selection.
        // See MultiHostSendSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_MULTI_HOST_SEND_TESTS"] == "1" {
            exit(MultiHostSendSelfTest.run() ? 0 : 1)
        }

        // F6 (fleet history / captain's log): the event store's append/retention/
        // kind-filter contract, the day grouping, the one-line title sanitiser, and
        // the merge with Shift's own activity YAML. See FleetLogSelfTest.swift's
        // header for why the retention cap in particular is worth pinning - it is the
        // one property no amount of using the app would ever surface.
        // F7 (`fm/grandline-feature-f7-answer-crew-from-cockpit`): the reply-routing
        // logic behind Overview's Reply affordance - the decision-key fold, the
        // exactly-one `--resolve-key` rule, the argv, and `fm-send.sh`'s three-way
        // exit-status contract. See `FleetActionsSelfTest.swift`'s header for what is
        // faked (the script itself) and what is genuinely exercised.
        if ProcessInfo.processInfo.environment["FM_RUN_FLEET_ACTIONS_TESTS"] == "1" {
            exit(FleetActionsSelfTest.run() ? 0 : 1)
        }

        // F7's rendering half - a real off-screen `FleetController`, real Reply
        // clicks. Window-backed, so `Scripts/run-all-tests.sh` lists it in
        // NEEDS_SESSION alongside its peers.
        if ProcessInfo.processInfo.environment["FM_RUN_FLEET_REPLY_LAYOUT_TESTS"] == "1" {
            exit(FleetReplyLayoutSelfTest.run() ? 0 : 1)
        }

        // Phase 0 of the Daylight UI migration: the click-answering focus ring (D1),
        // themed text selection (D4), the shared search well, and Health's pill/font/
        // title fixes (D3/D5/D6) - see InputSurfaceSelfTest.swift's header. Window-
        // backed (focus is meaningless without a window), so `run-all-tests.sh` lists
        // it in NEEDS_SESSION.
        if ProcessInfo.processInfo.environment["FM_RUN_INPUT_SURFACE_TESTS"] == "1" {
            exit(InputSurfaceSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_FLEET_LOG_TESTS"] == "1" {
            exit(FleetLogSelfTest.run() ? 0 : 1)
        }

        // F8 (incident mode): the incident record's create/append/end round trip on
        // real disk, the one-active-incident-per-host rule, the redaction boundary
        // (grepped in the real bytes), the aggregate the postmortem generator is fed,
        // and the F6 log wiring. See IncidentStoreSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_INCIDENT_TESTS"] == "1" {
            exit(IncidentStoreSelfTest.run() ? 0 : 1)
        }

        // Audit §6.2's relaunch-continuity half. Window-backed (it mounts a real
        // `ConsoleController`), so it belongs in `run-all-tests.sh`'s NEEDS_SESSION
        // list rather than beside the pure-logic store suite above.
        if ProcessInfo.processInfo.environment["FM_RUN_INCIDENT_RESUME_TESTS"] == "1" {
            exit(IncidentResumeSelfTest.run() ? 0 : 1)
        }

        // GL-32's row-height half (audit §6.1). Pure measurement - no window - so it
        // runs in CI alongside the other arithmetic suites.
        if ProcessInfo.processInfo.environment["FM_RUN_TEXT_SCALE_ROW_HEIGHT_TESTS"] == "1" {
            exit(TextScaleRowHeightSelfTest.run() ? 0 : 1)
        }

        // GL-32's font half (review bug B33) and the raw log pane's row fit (B38).
        // Builds plain `NSView`s and one `LogRawPaneView` off-screen - no window - so
        // it runs in CI alongside the row-height suite next door.
        if ProcessInfo.processInfo.environment["FM_RUN_TEXT_SCALE_FONT_TESTS"] == "1" {
            exit(TextScaleFontSelfTest.run() ? 0 : 1)
        }

        // X11: every AI surface states where the captain's data goes, and the claim
        // matches the behaviour. Source-reading and string comparison - runs in CI.
        if ProcessInfo.processInfo.environment["FM_RUN_AI_TRANSPARENCY_TESTS"] == "1" {
            exit(AITransparencySelfTest.run() ? 0 : 1)
        }

        // Audit §6.10's P3 leftovers. Pure logic - runs in CI.
        if ProcessInfo.processInfo.environment["FM_RUN_P3_LEFTOVERS_TESTS"] == "1" {
            exit(Phase4P3LeftoversSelfTest.run() ? 0 : 1)
        }

        // F5's command-palette providers: every domain's matching, the grouping the
        // mockup shows, the "never send a half-substituted command" rule, and the
        // source guards that keep the destructive-command gate a single definition the
        // palette cannot bypass. See UnifiedSearchSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_UNIFIED_SEARCH_TESTS"] == "1" {
            exit(UnifiedSearchSelfTest.run() ? 0 : 1)
        }

        // The palette's own layout - the chip staying a chip under `.fill`, the panel
        // being as tall as a grouped list, and the title truncating rather than
        // running under the chip. Window-backed, so the runner skips it in a headless
        // CI container; its provider/matching sibling above stays CI-enforced. See
        // UnifiedSearchLayoutSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_UNIFIED_SEARCH_LAYOUT_TESTS"] == "1" {
            exit(UnifiedSearchLayoutSelfTest.run() ? 0 : 1)
        }

        // A real, captain-reported theming bug on Setup > Updates: the "Refresh"
        // pill rendered washed-out on a fresh light-mode load and only rendered
        // correctly after a dark -> light round trip. See
        // UpdatesRefreshButtonThemeSelfTest.swift's header for the root cause.
        // The two captain-requested Setup > GitHub Sync changes: the page's leading
        // subtitle is gone, and the page carries the same shared `HelmRefreshPill`
        // Setup > Updates does. Its sharpest check is a source guard that the Refresh
        // action can never reach this page's mutating `sync` path - see
        // GitHubSyncRefreshSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_GITHUB_SYNC_REFRESH_TESTS"] == "1" {
            exit(GitHubSyncRefreshSelfTest.run() ? 0 : 1)
        }

        // A real, captain-reported bug on Setup > Updates: most tool rows rendered
        // an empty gap where the "Check" button should be, revealing it only on
        // hover, while other rows in the same list showed it at rest - see
        // UpdatesActionVisibilitySelfTest.swift's header for the root cause.
        if ProcessInfo.processInfo.environment["FM_RUN_UPDATES_ACTION_VISIBILITY_TESTS"] == "1" {
            exit(UpdatesActionVisibilitySelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_UPDATES_REFRESH_BUTTON_THEME_TESTS"] == "1" {
            exit(UpdatesRefreshButtonThemeSelfTest.run() ? 0 : 1)
        }

        // A real, captain-reported bug on Setup > GitHub Sync and Setup > Updates:
        // rows reporting the identical status ("In Sync", "Update Available")
        // rendered with two different status-pill treatments at once, because the
        // pill was painted only on a *status* change while a theme change left it
        // alone - see StatusPillThemeSelfTest.swift's header for the root cause.
        if ProcessInfo.processInfo.environment["FM_RUN_STATUS_PILL_THEME_TESTS"] == "1" {
            exit(StatusPillThemeSelfTest.run() ? 0 : 1)
        }

        // A real, captain-reported bug on the top nav's space pills
        // (`DaylightBarController`): clicking a pill and leaving the cursor in
        // place left its label blended into a stale, pre-click background, in both
        // light and dark mode - see TopNavPillPressedStateSelfTest.swift's header
        // for the root cause (a missing `HoverHighlightView.hoverColor` repaint
        // while already hovering).
        if ProcessInfo.processInfo.environment["FM_RUN_TOPNAV_PILL_PRESSED_STATE_TESTS"] == "1" {
            exit(TopNavPillPressedStateSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-session-switcher`: the persistent live-session strip, the
        // Hosts list's per-row live state, the ⌘K palette's pinned "Active sessions"
        // group and the ⌘⌃1…9 / ⌘] / ⌘[ shortcut arithmetic. Window-backed (it mounts
        // a real `AppShellController`), so it sits in `run-all-tests.sh`'s
        // `NEEDS_SESSION` list.
        // The pure-logic half of the full-app audit's "Bugs" section (§4), fixed in
        // `fm/grandline-audit-bug-fixes`: IncidentStore's GL-21 read-failure class, the
        // two JSONL stores' trim paths deleting lines they could not decode, the
        // `SSHKey`/`Snippet` synthesized-`Decodable` landmine, and CodePreviewStore's
        // swallowed delete. No views, so it runs in CI.
        if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_BUG_FIXES_TESTS"] == "1" {
            exit(AuditBugFixesSelfTest.run() ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["FM_RUN_SESSION_SWITCHER_TESTS"] == "1" {
            exit(SessionSwitcherSelfTest.run() ? 0 : 1)
        }

        // A real, captain-reported structural bug: Settings' whole page LAYOUT (card
        // columns, and the Appearance grid's own swatch density) changed depending
        // on which of the 14 themes was selected, not just its colours - see
        // SettingsThemeLayoutParitySelfTest.swift's header for the root cause
        // (`rebuildCardLayout()`'s two-column decision was gated on `theme.
        // isDaylight` as well as on width).
        if ProcessInfo.processInfo.environment["FM_RUN_SETTINGS_THEME_LAYOUT_PARITY_TESTS"] == "1" {
            exit(SettingsThemeLayoutParitySelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-settings-page-sidebar-redesign`: Settings is a sidebar-
        // navigated master/detail page now. The risk that suite exists for is silent
        // loss of reach - a setting that still works and has no row that reveals it
        // - so it asserts the category partition, a real row press swapping the
        // pane, and a representative control per category writing through.
        if ProcessInfo.processInfo.environment["FM_RUN_SETTINGS_SIDEBAR_TESTS"] == "1" {
            exit(SettingsSidebarNavigationSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-settings-page-redesign`: the page was rebuilt to the
        // captain's own HTML reference, and this covers the five behaviours that
        // rebuild introduced - sidebar search, back/forward history, the theme grid's
        // filter and selection, dependent-row dimming, and the OAuth fields' reveal.
        // See SettingsRedesignSelfTest.swift's header for why each one can break
        // silently.
        if ProcessInfo.processInfo.environment["FM_RUN_SETTINGS_REDESIGN_TESTS"] == "1" {
            exit(SettingsRedesignSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-settings-page-redesign`: "Follow system appearance" and its
        // light/dark pair. Pure logic, so it guards the blocking CI job - see that
        // file's header for why the fallbacks are the part worth guarding.
        if ProcessInfo.processInfo.environment["FM_RUN_SYSTEM_APPEARANCE_TESTS"] == "1" {
            exit(SystemAppearanceFollowerSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-console-claude-usage-button`: the "Claude usage" toolbar
        // button restored beside Compose - its availability must mirror Compose's
        // own byte-for-byte across tab-selection transitions, on both the shared
        // Firstmate console and a dedicated host page. See
        // ConsoleClaudeUsageSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS"] == "1" {
            exit(ConsoleClaudeUsageSelfTest.run() ? 0 : 1)
        }

        // A scout investigation (`data/grand-line-energy-regression-scout/report.md`,
        // section 2) traced "clicking through several pages in one session feels
        // disproportionately expensive" to Updates/Bootstrap/Automation each
        // independently re-running the same 13-item `DependencyCatalog` sweep on
        // first mount. `DependencyCheckCache` is the shared, TTL'd cache they now all
        // read from - see `DependencyCheckCacheSelfTest.swift`'s header for what this
        // proves (caching, coalescing concurrent callers, and forceRefresh always
        // bypassing both).
        if ProcessInfo.processInfo.environment["FM_RUN_DEPENDENCY_CHECK_CACHE_TESTS"] == "1" {
            exit(DependencyCheckCacheSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-terminal-selection-sidebar-bleed`: the "Forward Drags to This
        // Tab's Program" per-tab toggle's tab-lifecycle wiring (chip closures,
        // duplicate propagation, a fresh tab never inheriting a sibling's state) -
        // the mouse-routing formula itself is proven from real pixels by
        // TerminalSelectionRenderSelfTest's case 7. See TabForwardDragsToggleSelfTest.swift's
        // header.
        if ProcessInfo.processInfo.environment["FM_RUN_TAB_FORWARD_DRAGS_TOGGLE_TESTS"] == "1" {
            exit(TabForwardDragsToggleSelfTest.run() ? 0 : 1)
        }

        // F2, session restoration (audit §2 item 1) - the persisted state's shape and
        // backward compatibility, the pure host-restore plan, and the load-bearing
        // safety property that a restored host page does NOT connect until it is
        // opened. See SessionRestoreSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_SESSION_RESTORE_TESTS"] == "1" {
            exit(SessionRestoreSelfTest.run() ? 0 : 1)
        }

        // Command Library Phase 3's AI actions (audit §2 item 4's approved slice) -
        // the prompts, the Improve reply parse (the one thing that can write over a
        // saved command), the real `claude -p` round trip through a disposable fake,
        // and the popover's own save gating. See CommandLibraryAISelfTest.swift.
        if ProcessInfo.processInfo.environment["FM_RUN_COMMAND_LIBRARY_AI_TESTS"] == "1" {
            exit(CommandLibraryAISelfTest.run() ? 0 : 1)
        }

        // Audit §2 item 7: the Console/Tools tab keyboard shortcuts restored after the
        // Tab menu's removal - the pure matching table (including the near-misses it
        // must NOT claim, notably the session switcher's own ⌘⌃1-9) plus the monitor's
        // real gating, driven through real NSEvents against a real ConsoleController.
        // See TerminalShortcutsSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_SHORTCUTS_TESTS"] == "1" {
            exit(TerminalShortcutsSelfTest.run() ? 0 : 1)
        }

        // See TabKeyboardShortcutsSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_TAB_KEYBOARD_SHORTCUTS_TESTS"] == "1" {
            exit(TabKeyboardShortcutsSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-k8s-context-badge`: the context/namespace safety badge's
        // parsing (`KubeContextParser`) and marker-injection mechanism
        // (`KubeContextBridge`) - busy/single-flight/cross-bridge-collision guards,
        // timeout, discard-on-typing, and the busy-vs-success retry cadence. See
        // KubeContextBridgeSelfTest.swift's header for what this covers versus the
        // Python allowlist widening's own tests in `test_sre_kubectl_mcp.py`.
        if ProcessInfo.processInfo.environment["FM_RUN_KUBE_CONTEXT_BRIDGE_TESTS"] == "1" {
            exit(KubeContextBridgeSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-k8s-cluster-tail`: the shared `KubeBridge` plumbing both the
        // Cluster browser and the Log Tail consume - its serialized queue, both
        // terminal guards, the queue deadline, and the backoff/give-up the task brief
        // names explicitly - plus `KubeResourceParser`'s column parsing and
        // `KubeLogMerger`'s ordering/dedupe. Pure logic, so it runs in CI; the
        // window-backed half is `FM_RUN_KUBERNETES_DESTINATION_TESTS`.
        if ProcessInfo.processInfo.environment["FM_RUN_KUBE_BRIDGE_TESTS"] == "1" {
            exit(KubeBridgeSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-k8s-cluster-tail`: the real `.kubernetes` destination mounted
        // in a real window - the scope strip's honest empty state, feed-tab adoption,
        // a full Cluster sweep landing real parsed rows, the describe drawer, a real
        // Log Tail poll producing merged coloured lines, the Shape-C deep link, and
        // the give-up state's own UI. Window-backed, so it sits in
        // `run-all-tests.sh`'s NEEDS_SESSION list.
        if ProcessInfo.processInfo.environment["FM_RUN_KUBERNETES_DESTINATION_TESTS"] == "1" {
            exit(KubernetesDestinationSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-herdr-selection-color-sync`: `HerdrConfigPatcher`'s surgical
        // TOML edit (in place, insert into an existing table, create a fresh table,
        // every abort condition) plus `HerdrThemeSync`'s real-disk read/patch/write
        // pipeline against a scratch file. See HerdrThemeSyncSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_HERDR_THEME_SYNC_TESTS"] == "1" {
            exit(HerdrThemeSyncSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-sticky-board`: the Sticky Board's own persistence/parsing
        // layer - color contrast, the YAML round trip, the GL-01 refuse-to-overwrite
        // guard, the `FM_SHIFT_DIR` fallback, and a real commit+push against a
        // disposable local bare repo landing notes under the new
        // `GrandLineDocs/sticky-board/` folder. See StickyBoardSelfTest.swift's
        // header.
        if ProcessInfo.processInfo.environment["FM_RUN_STICKY_BOARD_TESTS"] == "1" {
            exit(StickyBoardSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-sticky-board`: the window-backed half - the real destination
        // in a real window, a theme sweep proving the board/chrome (never the
        // notes) tracks the active theme, real synthesized drag mechanics, and a
        // real Toast Undo button click. See StickyBoardViewSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_STICKY_BOARD_VIEW_TESTS"] == "1" {
            exit(StickyBoardViewSelfTest.run() ? 0 : 1)
        }

        // The credential vault's storage layer - PBKDF2/AES-GCM/HKDF round trips and
        // their negative cases, the store's CRUD and audit log, a byte-level grep of
        // the real file proving nothing readable (titles included) reaches disk, the
        // wrong-password and escalating-throttle branches, GL-01's refuse-to-overwrite
        // guard, older-payload decoding, a master-password re-key, the clipboard's
        // changeCount guard, and a real push to a disposable local bare repo read back
        // out of a fresh clone. See CredentialVaultSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CREDENTIAL_VAULT_TESTS"] == "1" {
            exit(CredentialVaultSelfTest.run() ? 0 : 1)
        }

        // F16/F17 (`fm/grandline-feature-f16-f17-poneglyph-totp-recovery`): the
        // Poneglyph additions' pure-logic half - RFC 6238 against the RFC's own eight
        // published test vectors across SHA1/SHA256/SHA512, base32's RFC 4648 vectors
        // and its refusals, `otpauth://` parsing, the password generator's alphabets
        // and entropy arithmetic, the recovery key's wrap/unwrap round trip through a
        // real store on a scratch directory (including the wrong-key and
        // re-key-invalidates-the-kit cases), and the three CSV importers against real
        // export headers. See PoneglyphTOTPRecoverySelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_PONEGLYPH_TOTP_TESTS"] == "1" {
            exit(PoneglyphTOTPRecoverySelfTest.run() ? 0 : 1)
        }

        // The credential vault's window-backed half: the real destination in a real
        // window, driving the real Reveal and Copy buttons on a real list row - and
        // asserting both directions of the captain's split (Copy must not reveal,
        // Reveal must not copy). Plus the gate's three states, GL-01's
        // no-create-over-an-unreadable-vault rule, search/category filtering,
        // auto-lock, the editor round trip, and a theme sweep. See
        // CredentialVaultViewSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_CREDENTIAL_VAULT_VIEW_TESTS"] == "1" {
            exit(CredentialVaultViewSelfTest.run() ? 0 : 1)
        }

        // F16/F17's window-backed half: the countdown ring on a real list row driven
        // by a fabricated instant through the app's one TOTP clock, the Add sheet's
        // kind switch / generator / Two-factor field, the Recovery & import sheet end
        // to end (print a key, then import a CSV into a real vault and grep the file
        // for the imported values), the printed card asserted by pixel, and the
        // menu-bar popover including both states it must refuse to show. See
        // PoneglyphTOTPRecoveryViewSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_PONEGLYPH_TOTP_VIEW_TESTS"] == "1" {
            exit(PoneglyphTOTPRecoveryViewSelfTest.run() ? 0 : 1)
        }

        // `fm/grandline-recents-navigation`: the "Recents" dropdown on the top bar -
        // `RecentDestinations`'s own dedup/reorder/cap logic (pure Swift), a real
        // `AppShellController`'s `show(_:)`/`switchToSession` navigation recording
        // the destination being left (never the one being entered), the popover's
        // real rows and click-to-navigate, and the bar button's own placement (after
        // the space pills, before the search pill - the captain's explicit
        // correction) and theming across a real light and dark theme. See
        // RecentDestinationsSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_RECENT_DESTINATIONS_TESTS"] == "1" {
            exit(RecentDestinationsSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-herdr-restart-button`: the Console toolbar's "Herdr" restart
        // button - `HerdrStatusParser`/`HerdrSnapshotParser` against literal (and
        // live-captured) JSON fixtures, `HerdrRestartSource`'s
        // checkStatus/fetchSnapshotSummary/stopServer driven against a real,
        // disposable fake `herdr` script, and `HerdrRestartButtonStatus`'s own
        // title/tint/tooltip/isActionable mapping. Pure logic, no window, so it runs
        // in CI. See HerdrRestartSelfTest.swift's header for why the real,
        // currently-running shared herdr server is never touched by this suite.
        if ProcessInfo.processInfo.environment["FM_RUN_HERDR_RESTART_TESTS"] == "1" {
            exit(HerdrRestartSelfTest.run() ? 0 : 1)
        }

        // `fm/grand-line-herdr-restart-button`: the window-backed half - a real
        // `ConsoleController` mounted in a real `NSWindow`, proving the button's real
        // presence/absence per console kind and the real background-check/click/
        // restart pipeline against a fake `herdr` script. Window-backed, so it sits
        // in `run-all-tests.sh`'s NEEDS_SESSION list, like its
        // `FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS` sibling. See
        // HerdrRestartButtonSelfTest.swift's header.
        if ProcessInfo.processInfo.environment["FM_RUN_HERDR_RESTART_BUTTON_TESTS"] == "1" {
            exit(HerdrRestartButtonSelfTest.run() ? 0 : 1)
        }

        // A suite flag that gets this far named no suite, because every real one above
        // `exit()`s. Falling through would start the app itself under a test flag (the
        // legacy-name migration, the single-instance guard, a window), and the runner
        // would report the typo as a pass. Measured while writing the modular-shell
        // inventory: the HelmKit guard's flag, misspelt with an extra word, "passed"
        // in 0.1s through `run-all-tests.sh` and ran nothing.
        //
        // R2-SEC-09: any key with the suite prefix at all, whatever its suffix or
        // value. The redirect block above arms on the prefix alone, so a flag missing
        // its `_TESTS` suffix, or set to `yes` instead of `1`, used to arm it, match
        // no suite, and fall through to `SingleInstanceGuard.acquire()` - which
        // activates the captain's running app and exits 0. (No flag is spelt out
        // here: `run-all-tests.sh` discovers suites by grepping this file.)
        let unknownSuiteFlags = SelfTestFlags.unknownSuiteFlags(in: ProcessInfo.processInfo.environment)
        if !unknownSuiteFlags.isEmpty {
            print("no suite answers to \(unknownSuiteFlags.joined(separator: ", ")) - "
                  + "check the spelling against the flags this file dispatches")
            exit(2)
        }
    }
}

#endif
