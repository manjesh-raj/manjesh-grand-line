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
