# Review bugs B1-B14

The fourteen bugs from the 2026-09-25 full-application review (AppKit expert
pass, at `main` 88a6c45), fixed on one branch at the captain's request:
`fm/grand-line-review-bugs-b1-b14`.

One commit per bug, in the order below.
The review itself is not in this repository - what it found is restated here,
because a bug report that only exists in a task directory is a bug report that
is gone next week.

---

## The three that had to come first

B4, B1 and B5 are one story: the app had no way to point a whole process at
scratch state, so a probe reached real data, and one of those reaches destroyed
a real clipboard history.

### B4 - `FM_SCRATCH_ROOT`

`Scripts/build-probe-app.sh` carried the whole safety promise in a
hand-maintained `ENV_ARGS` list, described in the script as "every FM_*
location override, in one place, so a launch cannot reach real data through a
store somebody forgot".

It was a list, so it drifted.
The review diffed it against `grep -rhoE '"FM_[A-Z0-9_]+"' Sources/GrandLine`
and found seven stores it did not redirect: the sealed clipboard history, the
session-restore file, the scratchpad, the widget snapshot, the dotfiles
auto-sync working tree, and both git clone roots.

The fix moves the guarantee out of the script and into the app.
`AppPaths.dataRoot()` resolves `FM_SCRATCH_ROOT`, and nineteen stores' defaults
come through it instead of each building `base + applicationSupportFolderName`
for itself.
Three things cannot ride a path redirect and are handled directly:

- `DotfilesAutoSync`, whose real target is `~/.dotfiles`, asks
  `AppPaths.isScratchRedirected()`.
- The widget container is a shared App Group, and that file is compiled into the
  extension too, so it reads the variable by name;
  `ProbeScratchRootSelfTest` asserts the two spellings agree.
- The Google account and OAuth client stores are Keychain-backed, and are
  swapped for their in-memory equivalents in `main.swift` - deliberately
  outside `#if FM_SELFTESTS`, because the hazard is the process rather than the
  build configuration.
  Both rename migrations are skipped under a scratch root for the same reason:
  they operate on real locations by construction.

**What makes it stay fixed** is `ProbeScratchRootSelfTest`, in CI's blocking
lane: a source grep failing on any production file that resolves
`.applicationSupportDirectory` itself (three stated exemptions), plus a
behavioural half that sets the root and drives thirteen real resolvers.

Verified live: a probe launch wrote its shift clone, schedules, widget snapshot
and instance lock into the scratch directory, while
`~/Library/Application Support/GrandLine` (18 entries), `~/.dotfiles` and the
real widget snapshot were unchanged.

### B1 - the clipboard history

Three `.corrupt-*` files appeared in the captain's Application Support folder
within five minutes on 2026-09-25, two of them 49KB holding roughly 200 real
entries each.

`ClipboardHistoryKey.read()` returned `Data?`, so every `OSStatus` that was not
`errSecSuccess` - `errSecInteractionNotAllowed`, `errSecAuthFailed` after an
ACL denial, `errSecUserCanceled`, any transient `securityd` failure - reached
`load(create:)` looking exactly like a fresh machine.
`load` then minted a new key and deleted the old item, leaving the real history
sealed by a key that no longer existed anywhere.

Three changes:

- `read` is tri-state (`found` / `notFound` / `failed(OSStatus)`), and `load`
  mints **only** on `notFound`.
- `load` reads the pre-rename service name before minting.
  The store is built during shell load while `LegacyNameMigration` copies that
  service two seconds later on a background queue, so on the first launch after
  the rename the store asked before the copy arrived - and the migration then
  counted the minted item as `alreadyPresent`.
  Reading the legacy name removes the race rather than reordering around it.
- A shelved file is recorded and the picker says so.
  It read "Nothing copied yet" over two 49KB histories, which is GL-14's exact
  prohibition and why the loss went unnoticed for three days.

The same one-line defect in the two Google stores is fixed the same way: a
Keychain refusal no longer caches as "not connected" or "no client configured",
either of which offers a re-setup that would delete and replace the real item.

**One thing worth knowing before writing a test near this code.**
`ClipboardHistoryKey.write` calls `remove()` first, so a suite that drives
`load(create:)` far enough to mint deletes the captain's real clipboard key.
That happened during this task's own first injection round.
`debugWriteOverride` exists to make it impossible; any suite touching that path
installs it.

### B5 - the Keychain items a self-test run left behind

`security dump-keychain` on the captain's machine: **91 items** under the
production service `com.manjesh.grandline.sshkey`, in `.key`/`.pass` pairs, one
pair per suite run over two days, each holding the literals
`THIS-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE` and
`correct-horse-battery-staple-THIS-MUST-NEVER-LEAK`.
Plus **33 orphaned** `com.manjesh.grandline.selftest.rename.<uuid>.legacy`
items.

`main.swift`'s redirect block had covered every *file*-backed store for years.
The Keychain had no equivalent, and unlike a stray file in a temp directory a
Keychain item outlives the run, the reboot and the branch.

`KeychainService.resolve` is now the single point every service name is built
at, honouring `FM_KEYCHAIN_SERVICE_PREFIX` under `#if FM_SELFTESTS` and
returning the literal unchanged in a release build.
`KeychainServiceSweep` deletes everything under this process's prefix on
`atexit`, plus anything carrying the marker that an interrupted earlier run
left behind - the same one-run-late honesty `SelfTestDefaultsGuard` documents,
since a signal still cannot be caught.

The second leak was its own bug, and it generalises:
**`SecItemDelete` removes one matching item per call on the file-based login
keychain.**
`LegacyRenameMigrationSelfTest.purge` called it once, so it left its second
seeded account behind on every run, 33 times.

The 124 already-leaked items were deliberately **not** deleted by this branch.
The PR carries the exact filter instead, because the `sshkey` service also holds
the captain's two real keys and a blanket delete would take them too.

---

## The crashes

### B2 - SIGABRT on quit after a dictation

`GrandLine-2026-09-24-210949.ips` and `GrandLine-2026-09-25-122236.ips`, both
the packaged app, both SIGABRT on the main thread:
`-[NSApplication terminate:]` -> `exit` -> `__cxa_finalize_ranges` -> the
destructor of ggml's static `std::vector<unique_ptr<ggml_metal_device>>` ->
`ggml_metal_device_free` -> `ggml_metal_rsets_free`
(`GGML_ASSERT([rsets->data count] == 0)`) -> `ggml_abort`.

That destructor runs past anything AppKit can hook, so the fix is to leave it
nothing to free: `applicationWillTerminate` releases the Whisper engine, whose
`whisper_free` runs `ggml_metal_rsets_free` itself.
It is also why the crash only followed a *recent* dictation - the two-minute
idle unload already did this, and a quit after that window never aborted.

The guard is scoped to `applicationWillTerminate`'s own extracted body rather
than grepping the file: `releaseWhisperEngine` has three other callers, so a
file-wide grep stays green with the terminate call deleted.
Confirmed by moving the identical call to a sibling method one line above -
the case still failed.

### B3 - stack overflow in the traffic-light hit test

`GrandLine-2026-09-25-131709.ips`: "Thread stack size exceeded due to excessive
recursion", with `-[NSView(NSTrackingArea) cursorUpdate:]` ->
`-[NSTitlebarContainerView _nextResponderForEvent:]` ->
`ChromeFusionRootView.hitTest(_:)` -> `trafficLightHitTest`, repeating.

`trafficLightHitTest` returns a button that lives in the **titlebar container**,
not in the content view - that is the whole point of the forwarding, since A1
repositions the cluster outside its own superview.
So when AppKit forwards a `cursorUpdate:` up that button's responder chain, the
container hit-tests the content view again, gets the same button back, and the
two feed each other.
Full screen returns nil before any of it, which is why the captain (who runs
the app full screen) had not hit it.

**The fix is a deny-list, not the review's suggested click allow-list, and the
reason is what could be verified.**
An allow-list rests on `NSApp.currentEvent` being the mouse-down while AppKit
hit-tests for one, and this repository cannot check that: the suite's own
real-click case (`test_a1ZoomButtonReallyZooms`) skips because a headless
process cannot make a window key, and `NSWindow.sendEvent` called directly
never sets `currentEvent`.
Getting it wrong would trade a rare crash for close/minimise/zoom being dead
again - the captain-reported bug the forwarding was written for.
So the cursor and tracking family is refused, and `hitTestDepth` refuses a
re-entrant call whatever the event, which covers the rest structurally.

Not verified: the crash itself.
`cursorUpdate:` comes from the window server's own tracking areas, so it cannot
be driven from a suite - the review could not reproduce it by posting
`mouseMoved` either.

---

## The data-loss pair

### B6 - Shift git sync

Three independent ways the same sync lost records between two machines.

1. **A fast-forward reached nobody.**
   `pullNow()`'s `.fastForwarded` set a status and stopped; the sole consumer
   was the sync pill.
   `ShiftStore` went on holding the pre-pull tasks, and the next edit rewrote
   the whole file from that memory and pushed it.
   `observeRemoteChanges` is the new signal, deliberately separate from
   `observeStatus` because a status change is a repaint (GL-24) and this is a
   reload.
2. **`merge -s ours` kept the local side of every file the record-level merge
   does not re-resolve.**
   Only the three list files are rewritten;
   `tasks/completed/<month>.yaml`, `activity/`, `attachments/`, `notes.yaml`
   and `settings.yaml` silently took the local side, so a task *completed* on
   the other machine vanished and the merge commit published that deletion as
   deliberate.
   The merge now checks out the remote side of every other changed path first.
   Paths that exist locally and not on the remote are left alone - deleting a
   local file to fix this would be the same bug pointed the other way.
3. **An unparseable revision read as an empty list.**
   `loadRecords` returned `[]` for "absent at that revision" and for "will not
   parse" alike, so a half-written push read as "the other machine has no
   tasks" and the three-way merge resolved every one of the captain's tasks as
   deleted remotely.

The third injection reproduced the loss outright: a seeded base task was gone
from the merged result (`got ["b-only"]`).

### B7 - the Notebook's auto-title rename

New page, type `# Title`, wait for the debounce, keep typing, click the page.
The paragraph is gone.

`pageEdited` set `currentID`, reloaded, and called `sidebar.select(renamed)` -
and `HelmPageSidebar.select` moves the selection without firing `onSelect`, so
`open(pageID:)` never ran.
Monaco stayed registered under the old page id and went on posting `change` for
it, and the next debounce hit `pageEdited`'s own `guard store.exists(id:)` and
dropped every keystroke.

**Every assertion the existing auto-title case makes passed with the bug
present**: `currentID` was already the new id, the sidebar row was already
selected, the file was already renamed, and the link retarget already worked.
The editor's `<slug>.md` caption is written by `open` and by nothing else, so
that is what the new case reads.

Second half: `NotebookController.shutdown()` documented itself as "called on
quit" and had no caller at all.

---

## The rest

- **B8 - compact mode.**
  `policy` was seeded with `.current()`, so on a session starting with the mode
  already on, `previous` and `policy` matched on the first refresh and the
  window was never hidden.
  And the main window never set `isReleasedWhenClosed = false`, which only
  matters inside this mode - there the red button closes the window without
  quitting.
  **The review called the crash half "a strong suspicion"; it reproduces.**
  With both fixes reverted and an env-gated probe driving the real launch order
  plus `performClose`, the binary exited **139 (SIGSEGV)** on the first access
  to `self.window` afterwards.
- **B9 - the focus timer.**
  `start` handed the displaced session back with its live segment unbanked, so
  switching tasks logged nothing for the first one.
  And a session left running across a closed lid logged the whole sleep -
  measured at 29,100s across an eight-hour sleep where 300s were worked.
  `observeSleepAndWake` banks at `willSleep` and resumes at `didWake`, through
  the engine's own pause/resume; `pausedForSleep` keeps a captain's own pause
  from being overridden by the machine waking.
- **B10 / B11 - two wrapping-label defects, same family.**
  See the AppKit gotcha added for this: a wrapping label's
  `preferredMaxLayoutWidth` must never be derived from its own (or its stack's)
  resolved width.
  B11 also turned up that `labelWithString` builds a cell whose `wraps` is
  false, so `maximumNumberOfLines = 0` alone changes nothing.
- **B12 - "Quit GrandLine".**
  Built from `ProcessInfo.processInfo.processName`, the *executable* name.
  `AppPaths.displayName` is the single definition now, beside
  `applicationSupportFolderName` for the on-disk half.
  Neither AGENTS.md's naming rule nor `LegacyRenameMigrationSelfTest` could see
  this, because the sources spell no name at all there.
- **B13 - the Sticky Board's sync caption.**
  Hard-coded "synced to manjesh-config" in both branches, so it claimed a sync
  under an override where the store has no `gitSync` at all.
  Notebook and Reading List already derived it; this is their wording verbatim.
- **B14 - the Whiteboard's drill header.**
  Six actions with four of them labelled left the title 4.5pt short at 1512pt
  ("Whiteboard" needs 88.5, got 84.0), so it rendered "Whitebo...".
  The four labels are shortened; the tooltips, where the full sentence always
  lived, are untouched.

---

## Process notes

- **`screencapture` does not work from an agent shell on this machine.**
  `screencapture -x` fails with "could not create image from display".
  The review found this and this task confirmed it independently.
  AGENTS.md's claim that Screen Recording had been granted was stale and is
  corrected.
  Env-gated instrumentation and off-screen renders are the substitutes, and
  both were used here.
- **`System Events` cannot see another process's windows without
  Accessibility**, which is also not granted - a window count came back `0` for
  a process that demonstrably had one. Do not read that as evidence.
- Every fix in this branch was confirmed by reverting it and watching a named
  case fail, then restoring it. The commit messages carry the failure text.

## Moved from AGENTS.md: stores, subprocesses and secrets (P-04, 2026-11-25)

P-04 of the 2026-11-25 full review moved the incidents and measurements out of AGENTS.md's "Stores, subprocesses and secrets" section, which keeps one rule for each.
The text below is that section as it stood, unchanged.


- **The app has exactly one name, one identifier prefix and one data folder,
  and all three have a single definition.** The display name is **"Grand
  Line"** (never "Manjesh Grand Line", never "Firstmate Cockpit"), the Swift
  module and the shipped executable are `GrandLine`, every identifier this app
  owns is `com.manjesh.grandline…`, and every file-backed store nests under
  `AppPaths.applicationSupportFolderName`. A hand-written copy of any of those
  is how half a rename gets left behind - `LegacyRenameMigrationSelfTest`
  fails the run on a source that spells a pre-rename name, and on a fourth
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
  must ask `AppPaths.isScratchRedirected()` instead. **That alone covers the
  probe and nothing else**, because a suite or a tour does not set
  `FM_SCRATCH_ROOT`: such a store also needs its own narrow override, set in
  the redirect block in `SelfTests/SelfTestDispatch.swift`. `DotfilesSource.dotfilesLocation` is the
  worked example, and missing it ran a real `git fetch` of the captain's
  dotfiles clone from every tour.
- **Every store also honours its own narrow `FM_*` override**, which wins over
  the root; the repo-root README has the complete index. A store nested under
  Shift's data root must honour `FM_SHIFT_DIR` as a fallback, not only its own
  narrow variable - and it needs an entry in the redirect block in
  `SelfTests/SelfTestDispatch.swift`, which is the backstop for a store reachable from a bare
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
  and nothing unattended may call it.** A timer, a retry loop or any other
  unattended caller takes `VaultSource.loadToolStatus()` (`av doctor --json`,
  which never prompts); `VaultSource.loadSnapshot()` is reached only from
  something the captain just did. It is not an `AppActivityState` question: the
  prompt appears while the app is frontmost too. `BackgroundSignalsSelfTest`
  source-guards the poller, and the one sanctioned exception
  (`ScheduleRunner.vaultRecipeExport`) is documented at its call site. The
  authorization-log measurements are in
  [`14-poneglyph-and-vault.md`](docs/history/14-poneglyph-and-vault.md).

- **`SubprocessResult.stdout` is trimmed, so never parse a fixed-column tool
  output by offset.** The first line of a `git status --short` whose field is
  ` M` loses its leading space, so a `dropFirst(3)` eats the first character of
  the path. Split on the field separator instead;
  `BootstrapController.statusLinePath` is the copy to reach for. The measured
  case is in
  [`09-setup-updates-bootstrap.md`](docs/history/09-setup-updates-bootstrap.md).
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
  and those carry one marker rather than this app's three. The readers
  today are the clipboard history's capture loop, ⌥Space's pasteboard chip
  and its insert, the Reading List's paste/drop route
  (`ReadingListController.pasteTapped`, `ReadingListDropRootView.acceptableURL`),
  F12's `{{clipboard}}` placeholder (`SnippetExpander.clipboardText`), the
  vault editor's 2FA paste and the Log Analyzer's two clipboard actions
  (`LogAnalyzerController.clipboardTextForEvidence`) - and a second hard-coded copy of
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
