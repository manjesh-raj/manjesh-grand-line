// Grand Line - native macOS app.
//
// Permanent self-test for the Sticky Board (`fm/grandline-sticky-board`),
// run via `FM_RUN_STICKY_BOARD_TESTS=1 .build/debug/GrandLine` - same
// convention as `ShiftStoreSelfTest.swift`/`IncidentStoreSelfTest.swift` (see
// main.swift's gate list).
//
// Six things, in order: the six paper/ink color pairs clear WCAG AA's 4.5:1
// text floor (the one contract `StickyBoardModels.swift` makes explicit
// about its deliberately-literal colors); a full CRUD round trip through
// `StickyBoardStore(root:)` survives being read back by a FRESH store
// instance over the same directory (a real disk round trip, not just an
// in-memory cache); GL-01's refuse-to-overwrite guard on a genuinely
// corrupted `notes.yaml`; the `FM_STICKY_BOARD_DIR`/`FM_SHIFT_DIR` override
// order (mirroring `IncidentStoreSelfTest`'s own "FM_SHIFT_DIR is honoured"
// case); that the sticky-board subtree is a genuinely new, dedicated folder
// distinct from Shift's `personal-tasks/` and Docs' `runbooks/`; and a real
// commit+push against a disposable local bare git repository - never the
// captain's actual `manjesh-config` - proving notes really do land under
// `GrandLineDocs/sticky-board/notes.yaml` in a fresh clone. This last part
// mirrors `ShiftGitSyncSelfTest.swift`'s own harness and helper functions
// (`makeBareRemote`/`seedRemote`/`commitCount`/`waitForSynced`/`shell`)
// rather than reinventing them.
//
// GL-27: compiled into debug builds only. Do not remove this guard when
// editing this file - `Phase3PolishSelfTest` asserts every file in this
// directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation
import Yaml

enum StickyBoardSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let fm = FileManager.default

        // MARK: 1. Color contrast - every (paper, ink) pair clears WCAG AA's
        // 4.5:1 text floor, using the exact formula `HelmContrast` uses
        // elsewhere in this app (`HelmContrast.ratio`), not a re-derivation.
        for color in StickyNoteColor.allCases {
            let paper = HelmTheme.nsColor(color.paperHex)
            let ink = HelmTheme.nsColor(color.inkHex)
            let ratio = HelmContrast.ratio(paper, ink)
            check(ratio >= HelmContrast.textTarget,
                  "\(color.rawValue): ink/paper contrast is \(ratio), below the \(HelmContrast.textTarget) floor")
        }
        // No two colors should be so close that a captain can't tell notes
        // apart at a glance - a soft sanity check, not a contrast law.
        check(Set(StickyNoteColor.allCases.map(\.paperHex)).count == StickyNoteColor.allCases.count,
              "every note color should have a distinct paper hex")

        let scratch = fm.temporaryDirectory.appendingPathComponent("sticky-board-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // MARK: 2. Full CRUD round trip, no git - `StickyBoardStore(root:)`
        // is the test seam every other case here (and every future caller)
        // uses to stay off the captain's real synced clone.
        do {
            let root = scratch.appendingPathComponent("plain-store", isDirectory: true)
            let store = StickyBoardStore(root: root)
            check(store.notes.isEmpty, "a fresh store should have no notes")
            check(store.gitSync == nil, "the root:-seam constructor must never reach git sync")

            let now = Date()
            let n1 = store.addNote(text: "Buy milk", color: .yellow, x: 40, y: 60,
                                    rotationDegrees: -2.5, now: now)
            let n2 = store.addNote(text: "Call mom\nTonight, not tomorrow", color: .blue,
                                    x: 300.25, y: 120.5, rotationDegrees: 3.75,
                                    now: now.addingTimeInterval(5))
            check(store.notes.count == 2, "both notes should be in memory right after creation")

            // Re-read from a FRESH instance over the same directory - proves
            // a real disk round trip, not just the store's own in-memory
            // array surviving because nothing cleared it.
            let reloaded = StickyBoardStore(root: root)
            check(reloaded.notes.count == 2, "reloaded store should see both persisted notes, got \(reloaded.notes.count)")

            if let r1 = reloaded.notes.first(where: { $0.id == n1.id }) {
                check(r1.text == "Buy milk", "note 1's text should survive a reload, got \(r1.text.debugDescription)")
                check(r1.color == .yellow, "note 1's color should survive a reload, got \(r1.color)")
                check(abs(r1.x - 40) < 0.001 && abs(r1.y - 60) < 0.001,
                      "note 1's position should survive a reload, got (\(r1.x), \(r1.y))")
                check(abs(r1.rotationDegrees - (-2.5)) < 0.001,
                      "note 1's rotation should survive a reload, got \(r1.rotationDegrees)")
                check(abs(r1.createdAt.timeIntervalSince1970 - now.timeIntervalSince1970) < 1,
                      "note 1's created timestamp should survive a reload")
            } else {
                failures.append("note 1 was not found after reloading from a fresh store instance")
            }
            if let r2 = reloaded.notes.first(where: { $0.id == n2.id }) {
                check(r2.text == "Call mom\nTonight, not tomorrow",
                      "note 2's multi-line text should survive a reload byte for byte, got \(r2.text.debugDescription)")
                check(r2.color == .blue, "note 2's color should survive a reload")
                check(abs(r2.x - 300.25) < 0.001 && abs(r2.y - 120.5) < 0.001,
                      "note 2's fractional position should survive a reload, got (\(r2.x), \(r2.y))")
            } else {
                failures.append("note 2 was not found after reloading from a fresh store instance")
            }

            // Edit text and position - both should persist independently.
            store.updateText(id: n1.id, text: "Buy oat milk")
            store.updatePosition(id: n1.id, x: 500, y: 250)
            let afterEdit = StickyBoardStore(root: root)
            if let edited = afterEdit.notes.first(where: { $0.id == n1.id }) {
                check(edited.text == "Buy oat milk", "a text edit should persist to disk")
                check(abs(edited.x - 500) < 0.001 && abs(edited.y - 250) < 0.001,
                      "a position edit (a drag-end) should persist to disk")
                check(edited.color == .yellow, "editing text/position must not disturb the note's color")
            } else {
                failures.append("edited note not found after reload")
            }

            // Delete + undo (GL-33: restore the exact value already in hand).
            let removed = store.deleteNote(id: n2.id)
            check(removed?.id == n2.id, "deleteNote should return the removed note, for the undo toast")
            check(store.notes.count == 1, "one note should remain in memory after a delete")
            let afterDelete = StickyBoardStore(root: root)
            check(afterDelete.notes.count == 1, "a delete should persist to disk")

            if let removed {
                store.restoreNote(removed)
                check(store.notes.count == 2, "restoreNote should bring the deleted note back into memory")
                let afterRestore = StickyBoardStore(root: root)
                check(afterRestore.notes.contains(where: { $0.id == removed.id && $0.text == removed.text }),
                      "restoreNote should persist the exact restored note to disk")
                // A doubled restore (an accidental second undo click) must
                // not duplicate the note.
                store.restoreNote(removed)
                check(store.notes.filter({ $0.id == removed.id }).count == 1,
                      "restoring an already-present note twice must not duplicate it")
            } else {
                failures.append("deleteNote did not return the removed note")
            }
        }

        // MARK: 3. GL-01 - a corrupted notes.yaml is backed up once and
        // never silently overwritten, matching `ShiftStore`'s own guard
        // (see `StickyBoardStore.swift`'s header for the incident this
        // prevents: a hand-edited syntax error read as "zero notes," then
        // immediately overwritten and pushed as the wipe).
        do {
            let root = scratch.appendingPathComponent("corrupt-store", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let notesPath = root.appendingPathComponent("notes.yaml")
            let garbage = "notes:\n  - id: \"unterminated\n    text: [oops\n"
            try? garbage.write(to: notesPath, atomically: true, encoding: .utf8)

            let store = StickyBoardStore(root: root)
            check(store.isInFailedLoadState, "a store over a genuinely unparseable file should report a failed load")

            let siblings = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            check(siblings.contains(where: { $0.hasPrefix("notes.yaml.corrupt-") }),
                  "a corrupt notes.yaml should be backed up before anything can overwrite it, saw \(siblings)")

            // A write attempted while in the failed-load state must be
            // refused outright - never a silent overwrite of the real (if
            // currently unreadable) file.
            _ = store.addNote(text: "should never reach disk", color: .green, x: 0, y: 0, rotationDegrees: 0)
            let stillOnDisk = try? String(contentsOf: notesPath, encoding: .utf8)
            check(stillOnDisk == garbage,
                  "GL-01: a write must be refused while the store is in a failed-load state")

            // Fixing the file by hand and reloading clears the failed state.
            try? "notes: []\n".write(to: notesPath, atomically: true, encoding: .utf8)
            store.reloadAll()
            check(!store.isInFailedLoadState, "reloading a hand-fixed file should clear the failed-load state")
            check(store.notes.isEmpty, "the recovered file legitimately has zero notes")
        }

        // MARK: 4. `FM_STICKY_BOARD_DIR` and the `FM_SHIFT_DIR` fallback.
        //
        // The lesson `CommandLibraryStore` learned the hard way (AGENTS.md):
        // a store whose folder needs protecting from the captain's real
        // synced clone should honor the SAME broad bypass
        // (`FM_SHIFT_DIR`) every existing self-test harness in this app
        // already sets, not only its own narrow variable - so adding this
        // store never required hunting down and patching every harness
        // individually the way `FM_DOCS_RUNBOOKS_DIR` did.
        do {
            let savedSticky = ProcessInfo.processInfo.environment["FM_STICKY_BOARD_DIR"]
            let savedShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]

            let narrowRoot = scratch.appendingPathComponent("narrow-env", isDirectory: true)
            unsetenv("FM_SHIFT_DIR")
            setenv("FM_STICKY_BOARD_DIR", narrowRoot.path, 1)
            let narrowStore = StickyBoardStore()
            check(narrowStore.root.path == narrowRoot.path,
                  "FM_STICKY_BOARD_DIR should redirect the store directly, got \(narrowStore.root.path)")
            check(narrowStore.gitSync == nil, "an FM_STICKY_BOARD_DIR override must never reach git sync")
            unsetenv("FM_STICKY_BOARD_DIR")

            let shiftRoot = scratch.appendingPathComponent("shift-env", isDirectory: true)
            setenv("FM_SHIFT_DIR", shiftRoot.path, 1)
            let fallbackStore = StickyBoardStore()
            let expected = shiftRoot.appendingPathComponent("sticky-board", isDirectory: true).path
            check(fallbackStore.root.path == expected,
                  "FM_SHIFT_DIR should redirect the store to <shift dir>/sticky-board, got \(fallbackStore.root.path)")
            check(fallbackStore.gitSync == nil, "an FM_SHIFT_DIR override must never reach git sync")

            if let savedSticky { setenv("FM_STICKY_BOARD_DIR", savedSticky, 1) } else { unsetenv("FM_STICKY_BOARD_DIR") }
            if let savedShift { setenv("FM_SHIFT_DIR", savedShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }

        // MARK: 5. A genuinely new, dedicated subpath - the captain's own
        // instruction, not shared with Shift's `personal-tasks/` or Docs
        // Runbooks' `runbooks/`.
        check(StickyBoardGitSync.stickyBoardSubpath == "GrandLineDocs/sticky-board",
              "the sticky board folder should be GrandLineDocs/sticky-board, got \(StickyBoardGitSync.stickyBoardSubpath)")
        check(StickyBoardGitSync.stickyBoardSubpath != ShiftGitSync.shiftSubpath,
              "sticky board must not share Shift's own personal-tasks/ subtree")
        check(StickyBoardGitSync.stickyBoardSubpath != DocsRunbookGitSync.runbooksSubpath,
              "sticky board must not share Docs Runbooks' own runbooks/ subtree")

        // MARK: 6. Real commit+push against a disposable local bare git
        // repository - never the captain's actual `manjesh-config`. Mirrors
        // `ShiftGitSyncSelfTest.swift`'s own harness (its `shell` helper is
        // copied verbatim below rather than reinvented).

        let gitScratch = scratch.appendingPathComponent("git", isDirectory: true)
        try? fm.createDirectory(at: gitScratch, withIntermediateDirectories: true)

        func makeBareRemote(name: String) -> URL {
            let path = gitScratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }

        func seedRemote(_ remote: URL) {
            let seedDir = gitScratch.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let readme = seedDir.appendingPathComponent("README.md")
            try? "seed\n".write(to: readme, atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com",
                                        "-c", "user.name=Sticky Board Test", "commit", "-m", "seed"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])
        }

        func commitCount(_ repo: URL, gitDir: Bool = false) -> Int {
            let args = gitDir ? ["--git-dir", repo.path, "log", "--oneline"] : ["-C", repo.path, "log", "--oneline"]
            let result = shell("/usr/bin/git", args)
            guard result.status == 0 else { return 0 }
            return result.stdout.split(separator: "\n").count
        }

        func waitForSynced(_ sync: StickyBoardGitSync, timeout: TimeInterval = 5.0) {
            let deadline = Date().addingTimeInterval(timeout)
            while sync.status != .synced && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        do {
            let remote = makeBareRemote(name: "remote-push")
            seedRemote(remote)
            let wt = gitScratch.appendingPathComponent("wt-push", isDirectory: true)
            let sync = StickyBoardGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2,
                                          queue: DispatchQueue(label: "sticky-board-selftest-push"))
            check(sync.ensureReadyNow(), "ensureReadyNow should succeed cloning a real local bare remote")
            check(sync.status == .synced, "status should be .synced right after a clean clone, got \(sync.status)")
            check(sync.dataRoot.path == wt.appendingPathComponent("GrandLineDocs/sticky-board").path,
                  "dataRoot should be the working tree's GrandLineDocs/sticky-board subfolder")

            let before = commitCount(remote, gitDir: true)
            let notesPath = sync.dataRoot.appendingPathComponent("notes.yaml").path
            try? ShiftYaml.writeList(path: notesPath, key: "notes", items: [
                .dictionary({
                    var m = YamlOrderedMap()
                    m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str("real-commit-note")
                    m[ShiftYamlBridge.key("text")] = ShiftYamlBridge.str("Hello from a disposable repo")
                    return m
                }()),
            ])
            sync.markDirty()
            check(sync.status == .localChanges,
                  "status should flip to .localChanges immediately on markDirty(), before any commit runs")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle back to .synced once the debounced commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "exactly one new commit should have reached the remote, before=\(before) after=\(after)")

            // Prove it via a completely fresh clone of the remote, reading
            // the file back at the exact dedicated path - not by trusting
            // the working tree that just pushed it.
            let verifyClone = gitScratch.appendingPathComponent("verify-clone", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, verifyClone.path])
            let pushedPath = verifyClone.appendingPathComponent("GrandLineDocs/sticky-board/notes.yaml")
            let pushedContent = try? String(contentsOf: pushedPath, encoding: .utf8)
            check(pushedContent?.contains("Hello from a disposable repo") == true,
                  "a fresh clone of the remote should contain the pushed note at GrandLineDocs/sticky-board/notes.yaml")
            check(!(pushedContent ?? "").isEmpty, "the pushed notes.yaml should not be empty")
        }

        // MARK: 6b. Rapid successive edits batch into one commit, not one
        // per edit - the debounce `markDirty()` exists for (rapid note
        // drags/edits should not spam the repo).
        do {
            let remote = makeBareRemote(name: "remote-batch")
            seedRemote(remote)
            let wt = gitScratch.appendingPathComponent("wt-batch", isDirectory: true)
            let sync = StickyBoardGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.5,
                                          queue: DispatchQueue(label: "sticky-board-selftest-batch"))
            check(sync.ensureReadyNow(), "ensureReadyNow should succeed for the batching scenario")
            let before = commitCount(remote, gitDir: true)

            let notesPath = sync.dataRoot.appendingPathComponent("notes.yaml").path
            for i in 0..<5 {
                try? ShiftYaml.writeList(path: notesPath, key: "notes", items: [
                    .dictionary({
                        var m = YamlOrderedMap()
                        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str("n\(i)")
                        return m
                    }()),
                ])
                sync.markDirty()
                Thread.sleep(forTimeInterval: 0.1)  // well under the 0.5s debounce window
            }
            check(sync.status == .localChanges, "status should still be .localChanges immediately after the last rapid edit")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle to .synced once the single batched commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "5 rapid edits within the debounce window should produce exactly 1 commit, before=\(before) after=\(after)")
        }

        // MARK: 6c. Audit 2 §4.3 - the quit-time flush runs on the shared
        // serial git queue, with a bound, and cancels the pending debounce
        // first.
        //
        // `StickyBoardController.shutdown()` used to call
        // `commitAndPushNow()` directly from `applicationWillTerminate`, i.e.
        // on the main thread and off `queue` - the one queue every other
        // invocation in this app serializes on, shared with Shift's, Docs'
        // and Code Preview's own commits against the *same* working tree. So
        // a flush could run `git` concurrently with a sibling's (fighting for
        // `.git/index.lock`), and quitting could block on a real network
        // push. It also never cancelled the still-pending debounced commit,
        // which could then fire again during or after the flush and commit
        // the same work twice.
        do {
            let remote = makeBareRemote(name: "remote-terminate")
            seedRemote(remote)
            let wt = gitScratch.appendingPathComponent("wt-terminate", isDirectory: true)
            // A long debounce, so the pending commit is genuinely still
            // outstanding when the flush runs - which is the race being
            // closed, not a theoretical one.
            let queue = DispatchQueue(label: "sticky-board-selftest-terminate")
            let sync = StickyBoardGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 60,
                                          queue: queue, sharesProductionWorkingTree: false)
            check(sync.ensureReadyNow(), "ensureReadyNow should succeed for the terminate scenario")
            let before = commitCount(remote, gitDir: true)

            let notesPath = sync.dataRoot.appendingPathComponent("notes.yaml").path
            try? ShiftYaml.writeList(path: notesPath, key: "notes", items: [
                .dictionary({
                    var m = YamlOrderedMap()
                    m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str("terminate-note")
                    m[ShiftYamlBridge.key("text")] = ShiftYamlBridge.str("Written just before quit")
                    return m
                }()),
            ])
            sync.markDirty()
            check(sync.status == .localChanges, "markDirty should mark the tree dirty before the flush")

            // The flush itself: the work reaches the remote, and it reaches
            // it from a call the caller can rely on having finished.
            check(sync.flushForTerminationNow(),
                  "the terminate flush should report a completed commit+push, got status \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1,
                  "the terminate flush should land exactly one commit on the remote, before=\(before) after=\(after)")

            let verify = gitScratch.appendingPathComponent("verify-terminate", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, verify.path])
            let pushed = try? String(contentsOf: verify.appendingPathComponent("GrandLineDocs/sticky-board/notes.yaml"),
                                     encoding: .utf8)
            check(pushed?.contains("Written just before quit") == true,
                  "a fresh clone should carry the note the terminate flush pushed")

            // The debounce was cancelled, not merely outrun: waiting past
            // what is left of the 60s window is not an option, so this is
            // asserted the one way it can be - the pending item is gone, so
            // nothing can fire a second, duplicate commit after the flush.
            check(!sync.hasPendingCommitForTests,
                  "the terminate flush left the debounced commit pending - it can still fire a duplicate")

            // And the git work genuinely ran *on the shared queue*, never on
            // the caller's thread. Proven by occupying the queue: whatever
            // the flush does has to queue behind this block, so a flush that
            // ran inline would finish before the barrier ever released.
            let barrier = DispatchSemaphore(value: 0)
            let occupied = DispatchSemaphore(value: 0)
            queue.async {
                occupied.signal()
                barrier.wait()
            }
            occupied.wait()
            try? ShiftYaml.writeList(path: notesPath, key: "notes", items: [
                .dictionary({
                    var m = YamlOrderedMap()
                    m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str("second-note")
                    return m
                }()),
            ])
            let queuedStart = Date()
            // The queue is held, so this cannot get on it and must give up on
            // its own bound rather than running inline or waiting forever.
            let ranWhileQueueWasHeld = sync.flushForTerminationNow()
            let waited = Date().timeIntervalSince(queuedStart)
            barrier.signal()
            // Let the queue drain before touching git from this thread
            // again: the abandoned flush's own work item is still on there,
            // and `ensureReadyNow()` runs git on the *caller's* thread, so
            // racing the two would reproduce the very index-lock contention
            // this finding is about - inside the test.
            queue.sync {}
            check(!ranWhileQueueWasHeld,
                  "the flush reported success while the shared queue was held - it ran off-queue, on the caller's thread")
            check(waited >= StickyBoardGitSync.terminateFlushBudget - 0.5,
                  "the flush gave up in \(waited)s, before its own budget - it never reached the queue at all")
            check(waited < StickyBoardGitSync.terminateFlushBudget + 3,
                  "the flush held its caller for \(waited)s, well past its \(StickyBoardGitSync.terminateFlushBudget)s budget")
            // Whatever the bound abandoned is not *lost*, which is what
            // makes a short bound the right answer: the work item finishes
            // once the queue frees (as it just did), and had the process
            // genuinely exited first, the next launch's `ensureReadyNow()`
            // re-reports the dirty tree and calls `markDirty()` itself. Both
            // routes are asserted here - the commit landed, and a fresh
            // readiness check over the same tree still reports clean.
            check(commitCount(remote, gitDir: true) == before + 2,
                  "the work an abandoned flush left behind never reached the remote at all")
            check(sync.ensureReadyNow(), "ensureReadyNow should still succeed after an abandoned flush")
            waitForSynced(sync, timeout: 10)
            check(sync.status == .synced,
                  "the tree should read clean once the abandoned flush's own commit landed, got \(sync.status)")
        }

        // MARK: 6d. Audit 2 §4.3's wiring, as a source guard.
        //
        // 6c proves `flushForTerminationNow()` behaves; this proves the quit
        // path is what calls it. Nothing observable distinguishes the two
        // (both commit the same work when the queue happens to be free), so
        // a behavioural check cannot see `shutdown()` slipping back to the
        // direct, unbounded, off-queue `commitAndPushNow()`.
        do {
            if let dir = SelfTestSources.appSourceDirectory() {
                let path = dir.appendingPathComponent("StickyBoardController.swift")
                if let text = try? String(contentsOf: path, encoding: .utf8) {
                    // Strip whole-line comments first: this file's own fix
                    // note names `commitAndPushNow()` in order to explain why
                    // it is no longer called, and a naive grep trips on that.
                    let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                        .joined(separator: "\n")
                    check(code.contains("flushForTerminationNow()"),
                          "StickyBoardController no longer uses the bounded, serial-queue terminate flush")
                    check(!code.contains("commitAndPushNow()"),
                          "StickyBoardController calls commitAndPushNow() directly again - back on the main "
                          + "thread, off the shared git queue, with no bound (audit 2 §4.3)")
                    check(code.contains("flushPendingWrite()"),
                          "shutdown() no longer writes the captain's own note data before the git flush")
                } else {
                    print("[sticky-board] NOTE: could not read StickyBoardController.swift - wiring guard skipped")
                }
            } else {
                print("[sticky-board] NOTE: app source directory not found - wiring guard skipped")
            }
        }

        // MARK: 7. Rotation is a fixed, persisted value - never re-randomized
        // on a later reload (matches `StickyBoardModels.swift`'s own
        // contract).
        do {
            let root = scratch.appendingPathComponent("rotation-store", isDirectory: true)
            let store = StickyBoardStore(root: root)
            let note = store.addNote(text: "", color: .pink, x: 10, y: 10, rotationDegrees: 1.25)
            for _ in 0..<3 {
                let reloaded = StickyBoardStore(root: root)
                check(reloaded.notes.first(where: { $0.id == note.id })?.rotationDegrees == 1.25,
                      "rotation must survive repeated reloads unchanged")
            }
        }

        // MARK: 8. Title + size persist exactly like text and position do
        // (`fm/grandline-sticky-code-preview-polish`).
        do {
            let root = scratch.appendingPathComponent("title-size-store", isDirectory: true)
            let store = StickyBoardStore(root: root)
            let note = store.addNote(title: "IDEA #01", text: "body", color: .yellow,
                                     x: 40, y: 60, rotationDegrees: 0)
            check(note.width == Double(StickyBoardMetrics.noteSize.width),
                  "a new note should start at the default width")

            store.updateTitle(id: note.id, title: "QUESTION")
            store.updateSize(id: note.id, width: 320, height: 260)

            // A genuinely fresh instance over the same directory - the only
            // reading that proves the FILE carries the value rather than the
            // in-memory array.
            let reloaded = StickyBoardStore(root: root).notes.first { $0.id == note.id }
            check(reloaded?.title == "QUESTION", "an edited title must survive a reload, got \(reloaded?.title ?? "nil")")
            check(reloaded?.width == 320 && reloaded?.height == 260,
                  "a resized note must survive a reload, got \(reloaded?.width ?? -1)x\(reloaded?.height ?? -1)")

            // Clamped on the way in, so a size outside the metric bounds can
            // never reach the file whatever wrote it.
            store.updateSize(id: note.id, width: 5, height: 99_999)
            let clamped = StickyBoardStore(root: root).notes.first { $0.id == note.id }
            check(clamped?.width == Double(StickyBoardMetrics.minNoteSize.width),
                  "an undersized note should clamp to the minimum width")
            check(clamped?.height == Double(StickyBoardMetrics.maxNoteSize.height),
                  "an oversized note should clamp to the maximum height")
        }

        // MARK: 9. A note written BEFORE title/width/height existed still
        // loads, with sane defaults and nothing dropped.
        //
        // This is the "a new field needs a real fallback, not just a
        // Swift-side default" lesson AGENTS.md records this app losing a whole
        // `hosts.json` to. This decoder is hand-written rather than synthesised
        // `Decodable` (which is where that bug actually lives), but the rule is
        // the same and is worth pinning against a real pre-upgrade file rather
        // than trusting the reading of the code.
        do {
            let root = scratch.appendingPathComponent("legacy-store", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let legacy = """
            notes:
              - id: "legacy-1"
                text: "written before this feature existed"
                color: "blue"
                x: 12.0
                y: 34.0
                rotation: 2.5
                created_at: "2026-01-02T03:04:05Z"
            """
            try? legacy.write(to: root.appendingPathComponent("notes.yaml"), atomically: true, encoding: .utf8)

            let store = StickyBoardStore(root: root)
            check(store.notes.count == 1, "a pre-upgrade notes.yaml should still load, got \(store.notes.count) note(s)")
            let note = store.notes.first
            check(note?.title == "", "a note with no stored title should default to empty, got \(note?.title ?? "nil")")
            check(note?.width == Double(StickyBoardMetrics.noteSize.width)
                    && note?.height == Double(StickyBoardMetrics.noteSize.height),
                  "a note with no stored size should default to the standard note size")
            // Everything that WAS in the old file has to survive untouched -
            // the failure mode worth guarding is a decoder that starts
            // returning nil (or a fresh note) rather than one that mis-defaults.
            check(note?.text == "written before this feature existed", "the legacy text must be preserved")
            check(note?.color == .blue && note?.x == 12 && note?.y == 34 && note?.rotationDegrees == 2.5,
                  "every pre-existing field must survive the upgrade unchanged")
            // UX10's own new field, under the same rule: a file written before
            // the archive existed has no `archived_at`, and that has to decode
            // as "on the board" rather than as a failure.
            check(note?.archivedAt == nil && note?.isArchived == false,
                  "UX10: a pre-archive note must load un-archived, not fail to decode")
            check(store.activeNotes.count == 1 && store.archivedNotes.isEmpty,
                  "UX10: a pre-archive note belongs on the board")
        }

        // MARK: 9b. UX10 - the archive, and the promotion to a task.
        //
        // Review #3: "no archive/done […] it is beautiful and currently a dead
        // end after ~12 notes", and "no linking a note to a task ('promote to
        // task' is the obvious gesture for a scratch-thought tool)".
        do {
            let root = scratch.appendingPathComponent("archive-store", isDirectory: true)
            let store = StickyBoardStore(root: root)
            let now = Date()
            let keep = store.addNote(text: "still thinking about this", color: .yellow,
                                     x: 10, y: 10, rotationDegrees: 0, now: now)
            let done = store.addNote(text: "dealt with", color: .green,
                                     x: 20, y: 20, rotationDegrees: 0, now: now.addingTimeInterval(1))
            check(store.activeNotes.count == 2 && store.archivedNotes.isEmpty,
                  "UX10: both new notes should start on the board")

            let archived = store.setArchived(id: done.id, archived: true, now: now.addingTimeInterval(10))
            check(archived?.isArchived == true, "UX10: archiving should mark the note archived")
            check(store.activeNotes.map(\.id) == [keep.id],
                  "UX10: the board should be left with only the un-archived note")
            check(store.archivedNotes.map(\.id) == [done.id],
                  "UX10: the archived note should be in the archive")
            // Archiving is NOT deleting - the finding's whole point is
            // somewhere to put a note, not a bin.
            check(store.notes.count == 2, "UX10: archiving must not delete the note")

            // Idempotent: a doubled click must not move `archivedAt`, or the
            // archive's newest-first order reshuffles under the captain.
            let stamp = store.archivedNotes.first?.archivedAt
            _ = store.setArchived(id: done.id, archived: true, now: now.addingTimeInterval(99))
            check(store.archivedNotes.first?.archivedAt == stamp,
                  "UX10: re-archiving an archived note moved its timestamp")

            // It survives a real disk round trip on a fresh instance.
            let reread = StickyBoardStore(root: root)
            check(reread.archivedNotes.map(\.id) == [done.id],
                  "UX10: the archive did not survive a reload - got \(reread.archivedNotes.map(\.id))")
            check(reread.activeNotes.map(\.id) == [keep.id],
                  "UX10: the board did not survive a reload")

            // And it comes back.
            _ = reread.setArchived(id: done.id, archived: false)
            check(reread.activeNotes.count == 2 && reread.archivedNotes.isEmpty,
                  "UX10: un-archiving should put the note back on the board")

            // The promotion mapping the finding spells out: title\u{2192}title,
            // text\u{2192}description, colour\u{2192}priority.
            let titled = StickyNote(id: "t", title: "Ship the thing", text: "and tell the crew",
                                    color: .pink, x: 0, y: 0, width: 200, height: 200,
                                    rotationDegrees: 0, createdAt: now)
            let promoted = StickyNotePromotion.task(from: titled)
            check(promoted.title == "Ship the thing", "UX10: the note's title should become the task's title")
            check(promoted.description == "and tell the crew",
                  "UX10: the note's text should become the task's description")
            check(promoted.priority == .high, "UX10: a pink note should promote as high priority")
            check(promoted.status == .todo, "UX10: a promoted note should arrive as a to-do")

            // An untitled note - the one a captain jots fastest - borrows its
            // first line, and must still carry its **whole** text across.
            // Silently dropping the line that became the title would be the
            // worst possible failure for a promotion.
            let untitled = StickyNote(id: "u", title: "", text: "call the bank\nask about the fee",
                                      color: .blue, x: 0, y: 0, width: 200, height: 200,
                                      rotationDegrees: 0, createdAt: now)
            let promotedUntitled = StickyNotePromotion.task(from: untitled)
            check(promotedUntitled.title == "call the bank",
                  "UX10: an untitled note should take its first line as the task title, got \"\(promotedUntitled.title)\"")
            check(promotedUntitled.description == "call the bank\nask about the fee",
                  "UX10: the promoted task lost part of the note's text")
            check(promotedUntitled.priority == .low, "UX10: a blue note should promote as low priority")

            // Every colour maps to something - a new colour with no mapping
            // would silently take whatever the switch's last case was.
            for color in StickyNoteColor.allCases {
                let note = StickyNote(id: color.rawValue, title: "t", text: "", color: color,
                                      x: 0, y: 0, width: 200, height: 200,
                                      rotationDegrees: 0, createdAt: now)
                check(ShiftPriority.allCases.contains(StickyNotePromotion.task(from: note).priority),
                      "UX10: \(color.rawValue) has no priority mapping")
            }
            // And the mapping discriminates - if every colour produced the
            // same priority, every check above would still pass.
            check(Set(StickyNoteColor.allCases.map(StickyNotePromotion.priority(for:))).count > 1,
                  "UX10: every note colour maps to the same priority - the mapping asserts nothing")
        }

        // MARK: 10. The fonts genuinely resolve.
        //
        // `NSFont(name:size:)` returns nil for a name macOS does not have and
        // the usual `?? .systemFont` then hides it completely - a typo ships
        // as "the handwriting font silently didn't apply". So this asserts the
        // resolved face is NOT the system font rather than merely that a font
        // came back.
        do {
            let system = NSFont.systemFont(ofSize: 14).fontName
            for (role, font) in [("hand", StickyFont.hand(14)),
                                 ("handBold", StickyFont.handBold(14)),
                                 ("typewriter", StickyFont.typewriter(14))] {
                check(font.fontName != system,
                      "StickyFont.\(role) fell back to the system font (\(font.fontName)) - none of its candidates resolved")
                check(abs(font.pointSize - 14) < 0.01, "StickyFont.\(role) should honour the requested size")
            }
            // The fallback chain itself works when nothing resolves, rather
            // than crashing or returning a zero-size font.
            let missing = StickyFont.resolve(["NoSuchFace-Regular", "AlsoNotAFont"], size: 12)
            check(missing.fontName == NSFont.systemFont(ofSize: 12, weight: .semibold).fontName,
                  "an all-missing chain should fall back to the system font")
        }

        // MARK: 11. The cork surface: a real drawn texture whose tone follows
        // light/dark mode, and a deterministic grain.
        do {
            let light = StickyBoardCork.baseHex(dark: false)
            let dark = StickyBoardCork.baseHex(dark: true)
            check(light != dark, "the cork base must differ between light and dark mode")
            check(StickyBoardCork.frameHex(dark: false) != StickyBoardCork.frameHex(dark: true),
                  "the wood frame must differ between light and dark mode")
            let lum: (String) -> Double = { HelmContrast.relativeLuminance(HelmContrast.components(HelmTheme.nsColor($0))) }
            check(lum(light) > lum(dark), "light mode's cork should be the lighter of the two")

            // Cork reads as cork because of the grain; a flat fill does not.
            // Two calls must give byte-identical specks - a `Int.random` grain
            // would re-roll on every relaunch and make an off-screen render
            // impossible to compare against a baseline.
            let a = StickyBoardCanvasView.seededSpecks(side: 84)
            let b = StickyBoardCanvasView.seededSpecks(side: 84)
            check(!a.isEmpty, "the cork tile should draw some grain")
            check(a.count == b.count && zip(a, b).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.angle == $1.angle },
                  "the cork grain must be deterministic across calls")
            check(a.contains(where: { $0.isDark }) && a.contains(where: { !$0.isDark }),
                  "cork grain needs both darker pits and lighter raised flecks")
            check(a.allSatisfy { $0.x >= 0 && $0.x <= 84 && $0.y >= 0 && $0.y <= 84 },
                  "every speck should land inside the tile")
        }

        // MARK: 12. Finding 4.2 - a record this build cannot decode is
        // PRESERVED, never silently deleted and pushed.
        //
        // The realistic trigger is cross-machine version skew through the very
        // git sync this store exists for: a note whose `color` is a
        // `StickyNoteColor` case a *newer* build added cannot be decoded here,
        // and before this fix `reloadAll()` compactMapped it away, the next
        // `persist()` rewrote `notes.yaml` without it, and `markDirty()`
        // committed and pushed the loss. Whole-file parse failure was already
        // GL-01-guarded; per-record failure was not.
        //
        // Note what this cannot be tested with: a *malformed* record. It has to
        // be a well-formed one carrying a value this build does not know, which
        // is exactly the shape a newer build writes.
        do {
            let root = scratch.appendingPathComponent("preserve-unreadable", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let notesPath = root.appendingPathComponent("notes.yaml").path

            // Two notes this build reads, one it does not - and the unreadable
            // one sits in the MIDDLE, so a fix that merely appended survivors
            // to the end would be visible.
            let seeded = """
            notes:
              - id: "aaa"
                title: "First"
                text: "readable"
                color: "yellow"
                x: 10.0
                y: 20.0
                width: 200.0
                height: 180.0
                rotation: 1.0
                created_at: "2026-01-01T00:00:00Z"
              - id: "bbb"
                title: "From a newer build"
                text: "teal is not a case this build knows"
                color: "teal"
                x: 30.0
                y: 40.0
                width: 200.0
                height: 180.0
                rotation: -1.0
                created_at: "2026-01-02T00:00:00Z"
              - id: "ccc"
                title: "Third"
                text: "also readable"
                color: "pink"
                x: 50.0
                y: 60.0
                width: 200.0
                height: 180.0
                rotation: 2.0
                created_at: "2026-01-03T00:00:00Z"

            """
            try? seeded.write(toFile: notesPath, atomically: true, encoding: .utf8)

            let store = StickyBoardStore(root: root)
            check(store.notes.count == 2,
                  "4.2: the two decodable notes should load, got \(store.notes.count)")
            check(store.unreadableRecordCount == 1,
                  "4.2: the unknown-colour record should be counted as preserved, "
                  + "got \(store.unreadableRecordCount)")
            check(!store.isInFailedLoadState,
                  "4.2: one bad record is not a whole-file parse failure")

            // Any edit at all rewrites the file - this is the write that used
            // to destroy the record.
            store.updateText(id: "aaa", text: "edited on the older build")
            store.flushPendingWrite()

            let after = (try? String(contentsOfFile: notesPath, encoding: .utf8)) ?? ""
            check(after.contains("teal"),
                  "4.2: the unreadable record's own colour is gone from the file - it was deleted "
                  + "by an edit made on a build that could not read it, and markDirty() would "
                  + "have pushed that deletion")
            check(after.contains("From a newer build"),
                  "4.2: the unreadable record's content did not survive the rewrite")
            check(after.contains("edited on the older build"),
                  "4.2: the edit that triggered the rewrite was itself lost")

            // Order is preserved by `created_at`, so the record does not drift
            // to the end of the file on every write.
            let firstIdx = after.range(of: "\"aaa\"")?.lowerBound
            let midIdx = after.range(of: "\"bbb\"")?.lowerBound
            let lastIdx = after.range(of: "\"ccc\"")?.lowerBound
            if let firstIdx, let midIdx, let lastIdx {
                check(firstIdx < midIdx && midIdx < lastIdx,
                      "4.2: a preserved record should keep its created_at position, not drift")
            } else {
                check(false, "4.2: expected all three record ids to still be in the file")
            }

            // And it is still there after a reload - i.e. genuinely on disk,
            // not merely still in this instance's memory.
            let reopened = StickyBoardStore(root: root)
            check(reopened.unreadableRecordCount == 1,
                  "4.2: the preserved record did not survive a reload")
            check(reopened.notes.first(where: { $0.id == "aaa" })?.text == "edited on the older build",
                  "4.2: the edit did not survive a reload")
        }

        // MARK: 13. Findings 3.3/4.6 - the local write is debounced, and every
        // flush point genuinely flushes.
        //
        // `persist()` re-serialises every note and writes the whole file
        // synchronously on the main thread; that used to happen once per
        // character typed. A debounce is only safe paired with real flush
        // points, so both halves are pinned: that a text edit does NOT reach
        // disk immediately, and that each of the ways out does write it.
        do {
            let root = scratch.appendingPathComponent("debounce", isDirectory: true)
            let store = StickyBoardStore(root: root)
            let note = store.addNote(text: "start", color: .yellow, x: 10, y: 10, rotationDegrees: 0)
            store.flushPendingWrite()

            // A structural change is immediate - losing a whole note to a
            // crash is a different order of cost from losing a few characters.
            check(!store.hasPendingWrite,
                  "4.6: adding a note should write immediately, not queue")
            let afterAdd = (try? String(contentsOfFile: root.appendingPathComponent("notes.yaml").path,
                                        encoding: .utf8)) ?? ""
            check(afterAdd.contains("start"), "4.6: the added note did not reach disk")

            // A keystroke does not.
            store.updateText(id: note.id, text: "typed one character at a time")
            check(store.hasPendingWrite,
                  "4.6: a text edit should be debounced, not written per keystroke")
            let midEdit = (try? String(contentsOfFile: root.appendingPathComponent("notes.yaml").path,
                                       encoding: .utf8)) ?? ""
            check(!midEdit.contains("typed one character"),
                  "4.6: the text edit reached disk synchronously - the debounce is not in effect")

            // The flush point does.
            store.flushPendingWrite()
            check(!store.hasPendingWrite, "4.6: flushing should clear the queued write")
            let afterFlush = (try? String(contentsOfFile: root.appendingPathComponent("notes.yaml").path,
                                          encoding: .utf8)) ?? ""
            check(afterFlush.contains("typed one character at a time"),
                  "4.6: flushing did not write the pending edit")

            // A title edit is debounced the same way.
            store.updateTitle(id: note.id, title: "A title")
            check(store.hasPendingWrite, "4.6: a title edit should be debounced too")

            // An immediate write carries the pending edit with it - `persist()`
            // always writes the whole in-memory array, which is why the
            // immediate paths only have to cancel the timer rather than order
            // two writes against each other.
            _ = store.addNote(text: "second", color: .blue, x: 40, y: 40, rotationDegrees: 0)
            check(!store.hasPendingWrite,
                  "4.6: an immediate write should cancel the queued one")
            let afterBoth = (try? String(contentsOfFile: root.appendingPathComponent("notes.yaml").path,
                                         encoding: .utf8)) ?? ""
            check(afterBoth.contains("A title") && afterBoth.contains("second"),
                  "4.6: an immediate write must carry the pending debounced edit with it")

            // `reloadAll()` must flush first, or a queued edit is read over.
            store.updateText(id: note.id, text: "not yet on disk")
            check(store.hasPendingWrite, "4.6: expected a queued write before the reload")
            store.reloadAll()
            check(store.notes.first(where: { $0.id == note.id })?.text == "not yet on disk",
                  "4.6: reloadAll() read the file over a queued edit and lost it")

            // The debounce genuinely fires on its own, too - not only when
            // something flushes it.
            store.updateText(id: note.id, text: "left to the timer")
            RunLoop.current.run(until: Date().addingTimeInterval(StickyBoardStore.persistDebounce + 0.6))
            check(!store.hasPendingWrite, "4.6: the debounced write never fired on its own")
            let afterTimer = (try? String(contentsOfFile: root.appendingPathComponent("notes.yaml").path,
                                          encoding: .utf8)) ?? ""
            check(afterTimer.contains("left to the timer"),
                  "4.6: the debounce fired but wrote nothing")
        }

        // MARK: Report

        // MARK: F6 - the checklist variant, the colour->priority mapping,
        // archive/unarchive, and the store's unknown-key passthrough.
        checkChecklistLogic(check)
        checkPromotionMapping(check)
        checkChecklistPersistence(scratch, check)
        checkAChecklistBurstWritesOnceAndLosesNothing(scratch, check)
        checkArchiveLogic(scratch, check)
        checkUnknownKeyPassthrough(scratch, check)

        if failures.isEmpty {
            print("[sticky-board] OK - all StickyBoard checks passed")
            return true
        }
        for failure in failures { print("[sticky-board] FAIL: \(failure)") }
        return false
    }

    // MARK: - F6 (review #3 §8): sticky → task, checklists, archive

    /// The parse/render/toggle/count logic behind a checklist note. Pure
    /// functions, so this runs in CI's **blocking** lane - the classification
    /// rule in AGENTS.md's "Writing a self-test" is about what a suite
    /// asserts, and none of this needs a window.
    private static func checkChecklistLogic(_ check: (Bool, String) -> Void) {
        // Every marker shape a captain might have typed, plus a bare line.
        let source = [
            "- [x] Freeze deploys",
            "- [ ] Snapshot RDS",
            "* [X] Page rota",
            "- Comms draft",
            "Bare line",
            "",
        ].joined(separator: "\n")
        let parsed = StickyChecklist.items(fromText: source)
        check(parsed.count == 5, "five non-empty lines should parse to five items, got \(parsed.count)")
        check(parsed.map(\.text) == ["Freeze deploys", "Snapshot RDS", "Page rota", "Comms draft", "Bare line"],
              "every marker shape should be stripped from the item's own text, got \(parsed.map(\.text))")
        check(parsed.map(\.isDone) == [true, false, true, false, false],
              "only the [x] markers should parse as done, got \(parsed.map(\.isDone))")
        // The blank line is the discriminating half: a parser that kept it
        // would render an empty row, and "five items" above would still pass
        // if the count happened to match for the wrong reason.
        check(!parsed.contains(where: { $0.text.isEmpty }), "a blank line must not become an empty item")
        check(Set(parsed.map(\.id)).count == parsed.count, "every parsed item needs its own id")

        // Round trip: render, re-parse, and the *content* must survive. Ids
        // are deliberately not compared - they are regenerated by a parse,
        // which is exactly why the store persists them rather than
        // re-deriving them (see `StickyChecklistItem`).
        let rendered = StickyChecklist.text(fromItems: parsed)
        check(rendered.contains("- [x] Freeze deploys"),
              "a done item should render as `- [x] `, got \(rendered.debugDescription)")
        check(rendered.contains("- [ ] Snapshot RDS"), "an open item should render as `- [ ] `")
        let reparsed = StickyChecklist.items(fromText: rendered)
        check(reparsed.map(\.text) == parsed.map(\.text) && reparsed.map(\.isDone) == parsed.map(\.isDone),
              "a render/parse round trip must preserve every item's text and done flag")

        // Toggling is a pure transform, and must touch exactly one row.
        let toggled = StickyChecklist.toggling(parsed, id: parsed[1].id)
        check(toggled[1].isDone, "toggling an open item should mark it done")
        check(toggled.map(\.isDone) == [true, true, true, false, false],
              "toggling one item must not disturb any other, got \(toggled.map(\.isDone))")
        check(StickyChecklist.toggling(parsed, id: "no-such-id").map(\.isDone) == parsed.map(\.isDone),
              "toggling an unknown id should be a no-op, not a crash or a scrambled list")

        check(StickyChecklist.summary(parsed) == "2 of 5",
              "the footer should count done/total, got \(StickyChecklist.summary(parsed))")
        check(StickyChecklist.summary([]) == "No items yet",
              "an empty checklist should say so rather than read `0 of 0`, got \(StickyChecklist.summary([]))")
    }

    /// The colour → priority mapping F6 names, asserted as a table rather
    /// than re-derived from the function under test (AGENTS.md: "re-deriving
    /// an expected value from the function under test asserts nothing at
    /// all").
    private static func checkPromotionMapping(_ check: (Bool, String) -> Void) {
        let expected: [StickyNoteColor: ShiftPriority] = [
            .pink: .high, .orange: .high,
            .blue: .low, .green: .low,
            .yellow: .normal, .purple: .normal,
        ]
        check(expected.count == StickyNoteColor.allCases.count,
              "this table must name every paper colour - a new colour needs a deliberate priority, not a default")
        for color in StickyNoteColor.allCases {
            let actual = StickyNotePromotion.priority(for: color)
            check(actual == expected[color], "\(color.rawValue) should promote to \(String(describing: expected[color])), got \(actual)")
        }
        // The mapping is only interesting if it actually discriminates.
        check(Set(expected.values).count == 3, "the mapping must use more than one priority, or it is not a mapping")

        // The whole promotion, including the title fallback and the body.
        let titled = StickyNote(id: "a", title: "Renew wildcard TLS", text: "Expires 16 Oct.",
                                color: .pink, x: 0, y: 0, width: 200, height: 160,
                                rotationDegrees: 0, createdAt: Date())
        let promoted = StickyNotePromotion.task(from: titled)
        check(promoted.title == "Renew wildcard TLS",
              "the note's title should become the task's title, got \(promoted.title.debugDescription)")
        check(promoted.description == "Expires 16 Oct.", "the note's body should become the task's description")
        check(promoted.priority == .high, "a pink note should promote at high priority")

        let untitled = StickyNote(id: "b", title: "", text: "Chase the DNS-01 token\nfrom the vault",
                                  color: .yellow, x: 0, y: 0, width: 200, height: 160,
                                  rotationDegrees: 0, createdAt: Date())
        let fallback = StickyNotePromotion.task(from: untitled)
        check(fallback.title == "Chase the DNS-01 token",
              "an untitled note should borrow its first line as the task title, got \(fallback.title.debugDescription)")
        check(fallback.description == untitled.text,
              "the whole body must carry across even when its first line was borrowed for the title")

        // A checklist note promotes its markdown rendering, which is the
        // point of keeping `text` in sync (see `StickyChecklist`).
        var checklistNote = untitled
        let items = [StickyChecklistItem(id: "i1", text: "Freeze deploys", isDone: true),
                     StickyChecklistItem(id: "i2", text: "Page rota", isDone: false)]
        checklistNote.checklist = items
        checklistNote.text = StickyChecklist.text(fromItems: items)
        let promotedList = StickyNotePromotion.task(from: checklistNote)
        check(promotedList.description.contains("- [x] Freeze deploys")
                && promotedList.description.contains("- [ ] Page rota"),
              "a promoted checklist should arrive as markdown in the task description, got \(promotedList.description.debugDescription)")
    }

    /// A checklist survives a real disk round trip, and `text` stays the
    /// authoritative rendering the rest of the app reads.
    /// PF13 of the 2026-09-25 full review: eight structural mutations wrote
    /// immediately, bypassing the debounce every other mutation goes through.
    /// Most of those eight are one deliberate gesture each and are right to
    /// write at once (see `setChecklist`'s own note, and the corrected comment
    /// on `updatePosition` that the review read). **The checklist is the one
    /// place a real burst reaches this store**: ticking through a ten-item
    /// list, or Return-Return-Return to add rows, was ten whole-file YAML
    /// rewrites in a couple of seconds, each re-serialising every note on the
    /// board.
    ///
    /// The coalescing is the easy half and losing a tick is the dangerous one,
    /// so the data comes first: after a burst and a flush, every toggle, every
    /// added row and every removal has to be on disk, read back through a
    /// fresh store. Only then the write count.
    private static func checkAChecklistBurstWritesOnceAndLosesNothing(
        _ scratch: URL, _ check: (Bool, String) -> Void) {
        let root = scratch.appendingPathComponent("checklist-burst", isDirectory: true)
        let store = StickyBoardStore(root: root)
        let note = store.addNote(title: "Cutover", text: "one\ntwo\nthree\nfour\nfive\nsix",
                                 color: .blue, x: 0, y: 0, rotationDegrees: 0)
        guard let converted = store.convertToChecklist(id: note.id),
              let items = converted.checklist, items.count == 6 else {
            check(false, "the fixture could not build a six-item checklist")
            return
        }

        // The burst: no run loop turn between the mutations, which is what a
        // captain working down a list produces.
        store.debugResetPersistCount()
        for item in items where item.text != "three" {
            store.toggleChecklistItem(noteID: note.id, itemID: item.id)
        }
        _ = store.addChecklistItem(noteID: note.id, text: "seven")
        _ = store.addChecklistItem(noteID: note.id, text: "eight")
        if let doomed = store.notes.first(where: { $0.id == note.id })?.checklist?
            .first(where: { $0.text == "two" }) {
            store.removeChecklistItem(noteID: note.id, itemID: doomed.id)
        }
        let writesDuringBurst = store.debugPersistCount

        check(store.hasPendingWrite,
              "the burst must leave a debounced write outstanding - without one the count "
              + "assertion below would be measuring nothing")
        store.flushPendingWrite()

        let reloaded = StickyBoardStore(root: root)
        guard let back = reloaded.notes.first(where: { $0.id == note.id }),
              let backItems = back.checklist else {
            check(false, "the note did not survive the burst at all")
            return
        }
        check(backItems.map(\.text) == ["one", "three", "four", "five", "six", "seven", "eight"],
              "the burst's adds and removal did not all reach disk, got \(backItems.map(\.text))")
        let done = Set(backItems.filter(\.isDone).map(\.text))
        check(done == ["one", "four", "five", "six"],
              "the burst's toggles did not all reach disk, done is \(done.sorted())")
        check(back.text == StickyChecklist.text(fromItems: backItems),
              "`text` must stay in step with the checklist across a coalesced write")

        check(writesDuringBurst == 0,
              "the burst itself wrote the whole board \(writesDuringBurst) times; PF13 is "
              + "exactly this - it must coalesce into the one write the flush then does")
        check(store.debugPersistCount == 1,
              "the flush wrote once, got \(store.debugPersistCount)")
    }

    private static func checkChecklistPersistence(_ scratch: URL, _ check: (Bool, String) -> Void) {
        let root = scratch.appendingPathComponent("checklist-store", isDirectory: true)
        let store = StickyBoardStore(root: root)
        let note = store.addNote(title: "Cutover", text: "Freeze deploys\nSnapshot RDS\nPage rota",
                                 color: .blue, x: 10, y: 20, rotationDegrees: 0)
        check(!note.isChecklist, "a new note is a text note until it is converted")

        guard let converted = store.convertToChecklist(id: note.id) else {
            check(false, "convertToChecklist returned nil for a text note")
            return
        }
        check(converted.checklist?.count == 3,
              "three body lines should convert to three items, got \(converted.checklist?.count ?? -1)")
        check(converted.text == "- [ ] Freeze deploys\n- [ ] Snapshot RDS\n- [ ] Page rota",
              "converting must re-render `text` as the checklist's markdown, got \(converted.text.debugDescription)")
        check(store.convertToChecklist(id: note.id) == nil,
              "converting an existing checklist again must be a no-op, or a doubled click re-ids every row")

        guard let firstItem = converted.checklist?.first else {
            check(false, "converted checklist has no first item to toggle")
            return
        }
        store.toggleChecklistItem(noteID: note.id, itemID: firstItem.id)
        // PF13: checklist mutations come in bursts and are debounced now, so a
        // read-back has to drain first - exactly as leaving the destination,
        // a field giving up focus and `applicationWillTerminate` all do.
        store.flushPendingWrite()

        let reloaded = StickyBoardStore(root: root)
        guard let r = reloaded.notes.first(where: { $0.id == note.id }) else {
            check(false, "the checklist note was not found after reloading from a fresh store")
            return
        }
        check(r.isChecklist, "the checklist must survive a reload as a checklist, not collapse to a text note")
        check(r.checklist?.count == 3, "all three items should survive a reload, got \(r.checklist?.count ?? -1)")
        check(r.checklist?.first?.isDone == true, "the toggled item's done flag should survive a reload")
        check(r.checklist?.first?.id == firstItem.id, "an item's id must be persisted, not regenerated on load")
        check(r.text.hasPrefix("- [x] Freeze deploys"),
              "`text` must stay in step with the checklist across a write, got \(r.text.debugDescription)")

        // Item-level edits.
        store.addChecklistItem(noteID: note.id, text: "Comms draft")
        check(store.notes.first(where: { $0.id == note.id })?.checklist?.count == 4,
              "addChecklistItem should append a row")
        store.removeChecklistItem(noteID: note.id, itemID: firstItem.id)
        let afterRemove = store.notes.first(where: { $0.id == note.id })
        check(afterRemove?.checklist?.count == 3, "removeChecklistItem should drop exactly one row")
        check(afterRemove?.checklist?.contains(where: { $0.id == firstItem.id }) == false,
              "removeChecklistItem should drop the row it was asked for")

        // Turning it back off keeps the content and drops the structure.
        guard let back = store.convertToText(id: note.id) else {
            check(false, "convertToText returned nil for a checklist note")
            return
        }
        check(back.checklist == nil, "converting back must clear the checklist")
        check(back.text == afterRemove?.text, "converting back must keep the markdown the captain was looking at")
        check(store.convertToText(id: note.id) == nil, "converting a text note to text again must be a no-op")

        // Empty is a real state, distinct from nil.
        store.setChecklist(id: note.id, items: [])
        check(store.notes.first(where: { $0.id == note.id })?.isChecklist == true,
              "an emptied checklist is still a checklist - collapsing it would surprise the captain mid-edit")
        let reloadedEmpty = StickyBoardStore(root: root)
        check(reloadedEmpty.notes.first(where: { $0.id == note.id })?.checklist?.isEmpty == true,
              "an empty checklist must round trip as empty, not as absent")
    }

    /// Archive, unarchive, and the two collections the board draws from.
    private static func checkArchiveLogic(_ scratch: URL, _ check: (Bool, String) -> Void) {
        // Its own directory: case 9b above already owns `archive-store`, and
        // two cases sharing one store see each other's notes - which is how
        // this case first failed.
        let root = scratch.appendingPathComponent("f6-archive-store", isDirectory: true)
        let store = StickyBoardStore(root: root)
        let now = Date()
        let a = store.addNote(text: "older", color: .yellow, x: 0, y: 0, rotationDegrees: 0, now: now)
        let b = store.addNote(text: "newer", color: .pink, x: 0, y: 0, rotationDegrees: 0,
                              now: now.addingTimeInterval(10))
        check(store.activeNotes.count == 2 && store.archivedNotes.isEmpty, "a fresh board has everything active")

        store.setArchived(id: a.id, archived: true, now: now.addingTimeInterval(100))
        check(store.activeNotes.map(\.id) == [b.id], "an archived note must leave the active set")
        check(store.archivedNotes.map(\.id) == [a.id], "an archived note must appear in the archive")

        // Idempotence: the drawer is newest-archived first, so a doubled
        // click must not move a note's own place in it.
        store.setArchived(id: b.id, archived: true, now: now.addingTimeInterval(200))
        store.setArchived(id: a.id, archived: true, now: now.addingTimeInterval(300))
        check(store.archivedNotes.map(\.id) == [b.id, a.id],
              "the archive is newest-first and re-archiving must not move a note, got \(store.archivedNotes.map(\.id))")

        check(StickyBoardStore(root: root).archivedNotes.count == 2, "archiving must persist to disk")

        store.setArchived(id: a.id, archived: false)
        check(store.activeNotes.map(\.id) == [a.id], "unarchiving must put the note back on the board")
        check(store.notes.first(where: { $0.id == a.id })?.archivedAt == nil, "unarchiving must clear the timestamp")
        check(store.setArchived(id: "no-such-note", archived: true) == nil, "an unknown id must return nil, not throw")
    }

    /// **F6's stated prerequisite**: a record this build decodes but which
    /// carries a key it does not know must survive a rewrite.
    ///
    /// Injected as a real `notes.yaml` written by hand, because that is what
    /// a newer build's file actually looks like on the other side of the git
    /// sync - not as a synthetic `Yaml` value handed straight to the
    /// serialiser, which would skip the decoder that is half the mechanism.
    private static func checkUnknownKeyPassthrough(_ scratch: URL, _ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("passthrough-store", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("notes.yaml")
        let fixture = [
            "notes:",
            "  - id: \"from-a-newer-build\"",
            "    title: \"Has a field this build never heard of\"",
            "    text: \"body\"",
            "    color: \"green\"",
            "    x: 12.0",
            "    y: 34.0",
            "    width: 220.0",
            "    height: 180.0",
            "    rotation: 1.5",
            "    created_at: \"2026-01-02T03:04:05Z\"",
            "    pinned_by: \"the future\"",
            "    reminder_at: \"2027-09-09T09:09:09Z\"",
            "",
        ].joined(separator: "\n")
        do {
            try fixture.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            check(false, "could not seed the passthrough fixture: \(error)")
            return
        }

        let store = StickyBoardStore(root: root)
        check(store.notes.count == 1, "the record decodes fine on this build - only its extra keys are foreign")
        check(store.unreadableRecordCount == 0,
              "a decodable record with an unknown key must NOT be filed as unreadable - that is the other mechanism")
        // The discriminating half: prove the fixture really carries keys this
        // build does not write, so a drifted fixture fails loudly instead of
        // passing vacuously.
        check(!StickyBoardStore.knownKeys.contains("pinned_by") && !StickyBoardStore.knownKeys.contains("reminder_at"),
              "the fixture's extra keys must genuinely be unknown to this build, or this case proves nothing")

        // Any ordinary edit rewrites the whole file - that is the moment the
        // keys used to vanish.
        store.updateText(id: "from-a-newer-build", text: "edited on the older build")
        store.flushPendingWrite()

        guard let written = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "could not read notes.yaml back after the rewrite")
            return
        }
        check(written.contains("pinned_by") && written.contains("the future"),
              "an unknown key and its value must survive a rewrite by a build that does not understand it")
        check(written.contains("reminder_at") && written.contains("2027-09-09T09:09:09Z"),
              "every unknown key must survive, not just the first")
        check(written.contains("edited on the older build"), "the edit itself must still have landed")

        // And exactly once - a build that treats its own output as foreign
        // would duplicate every key on the second write.
        store.updateColor(id: "from-a-newer-build", color: .purple)
        guard let twice = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "could not read notes.yaml back after the second rewrite")
            return
        }
        check(twice.components(separatedBy: "pinned_by").count - 1 == 1,
              "an unknown key must appear exactly once after two rewrites, not accumulate")
        // Keys are written double-quoted (`ShiftYamlBridge.key`), so the
        // needle has to be too - counting a bare `color:` finds nothing and
        // the check would fail for the wrong reason.
        check(twice.components(separatedBy: "\"color\":").count - 1 == 1,
              "a known key must not be duplicated by the passthrough merge")
        check(StickyBoardStore(root: root).notes.first?.color == .purple, "the second edit must still have landed")
    }

    private struct ShellResult { let status: Int32; let stdout: String }

    private static func shell(_ executable: String, _ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ShellResult(status: proc.terminationStatus, stdout: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

#endif
