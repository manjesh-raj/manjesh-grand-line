// Grand Line - native macOS app.
//
// Permanent self-test for `ShiftGitSync` (cockpit-shift-git-sync, phase 4 of
// the Shift build), run via `FM_RUN_SHIFT_GIT_SYNC_TESTS=1
// .build/debug/GrandLine` - same convention as
// `ShiftStoreSelfTest.swift`/`DiffEngineSelfTest.swift` (see main.swift's
// gate list).
//
// Every scenario here runs against a real, disposable local bare git
// repository created fresh under a scratch temp directory - never the
// captain's real `manjesh-config`. This is deliberate: it proves out the
// actual clone/commit/push/pull/debounce/status-pill logic against a real
// `git` subprocess and a real second "remote" repo, not mocked network calls
// - the acceptance bar this phase was built against explicitly calls for
// this kind of end-to-end verification instead of reasoning about the code.
//
// Status is read directly from `ShiftGitSync.status` after each synchronous
// call, not via `observeStatus`'s callback - that callback is dispatched
// through `DispatchQueue.main`, which never drains here since this self-test
// runs on the main thread with no run loop pumping (main.swift calls this
// before `app.run()`). Reading `.status` directly is safe for this test's
// purposes: every check below happens strictly after the call that mutates
// it has already returned or after a sleep long enough to cover the
// background queue's async work.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ShiftGitSyncSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("shift-git-sync-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeBareRemote(name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }

        func seedRemote(_ remote: URL) {
            let seedDir = scratch.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let personalTasks = seedDir.appendingPathComponent("GrandLineDocs/personal-tasks", isDirectory: true)
            try? fm.createDirectory(at: personalTasks, withIntermediateDirectories: true)
            try? "seed".write(to: personalTasks.appendingPathComponent(".keep"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])
        }

        func commitCount(_ repo: URL, gitDir: Bool = false) -> Int {
            let args = gitDir ? ["--git-dir", repo.path, "log", "--oneline"] : ["-C", repo.path, "log", "--oneline"]
            let result = shell("/usr/bin/git", args)
            guard result.status == 0 else { return 0 }
            return result.stdout.split(separator: "\n").count
        }

        // `String.write(to:)` does NOT create missing parent directories (unlike
        // `ShiftYaml.writeList`, which this test deliberately doesn't go
        // through so it can write arbitrary content directly) - every write
        // below needs this or it silently no-ops and the test would wrongly
        // read that as "git saw no changes."
        func writeTaskFile(_ content: String, to url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }

        // Polls rather than sleeping a fixed amount - the debounced commit+
        // push runs on a real background queue against a real (if local)
        // git subprocess, and this machine's actual scheduling latency isn't
        // something this test should hardcode a guess for. Still bounded
        // (5s), so a genuine hang fails the test instead of hanging forever.
        func waitForSynced(_ sync: ShiftGitSync, timeout: TimeInterval = 5.0) {
            let deadline = Date().addingTimeInterval(timeout)
            while sync.status != .synced && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        // MARK: 1. Instant local write, independent of network - simulate
        // network unavailable via a remote URL that can never be reached.

        do {
            let wt = scratch.appendingPathComponent("wt-offline", isDirectory: true)
            let sync = ShiftGitSync(
                workingTree: wt, remoteURL: "https://127.0.0.1.invalid/does-not-exist/repo.git",
                debounceInterval: 0.2, periodicPullInterval: 999_999
            )
            let ok = sync.ensureWorkingTreeNow()
            check(!ok, "ensureWorkingTreeNow should report failure when the remote is unreachable")
            if case .failed = sync.status {} else { failures.append("status should be .failed after an unreachable clone, got \(sync.status)") }
            check(fm.fileExists(atPath: sync.dataRoot.path), "dataRoot should exist locally even when the initial clone fails (offline-first)")

            let start = Date()
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            try? fm.createDirectory(at: taskFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "tasks: []\n".write(to: taskFile, atomically: true, encoding: .utf8)
            let elapsed = Date().timeIntervalSince(start)
            check(elapsed < 0.5, "local YAML write should be instant regardless of network state, took \(elapsed)s")
            check((try? String(contentsOf: taskFile, encoding: .utf8)) == "tasks: []\n", "local write should have actually landed on disk")
        }

        // MARK: 2. Real commit+push reaches a real disposable remote.

        var pushedRemote: URL!
        var pushedWT: URL!
        do {
            let remote = makeBareRemote(name: "remote-push")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-push", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            // UI-19: before anything has happened, the initial `.synced` is a
            // default, not a status - the Tasks page must not say "Synced".
            check(!sync.hasReportedStatus, "a fresh sync has reported no status yet")
            check(sync.ensureWorkingTreeNow(), "ensureWorkingTreeNow should succeed cloning a real local bare remote")
            check(sync.status == .synced, "status should be .synced right after a clean clone, got \(sync.status)")

            let before = commitCount(remote, gitDir: true)
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: t1\n", to: taskFile)
            sync.markDirty()
            check(sync.status == .localChanges, "status should flip to .localChanges immediately on markDirty(), before any commit runs")
            check(sync.hasReportedStatus, "a real status change counts as reported")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle back to .synced once the debounced commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "exactly one new commit should have reached the remote, before=\(before) after=\(after)")

            pushedRemote = remote
            pushedWT = wt
        }

        // MARK: 3. Debounce actually batches several rapid edits into one
        // commit, not one commit per edit.

        do {
            let remote = makeBareRemote(name: "remote-batch")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-batch", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.5, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "ensureWorkingTreeNow should succeed for the batching scenario")
            let before = commitCount(remote, gitDir: true)

            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            for i in 0..<5 {
                writeTaskFile("tasks:\n  - id: t\(i)\n", to: taskFile)
                sync.markDirty()
                Thread.sleep(forTimeInterval: 0.1)  // well under the 0.5s debounce window
            }
            check(sync.status == .localChanges, "status should still be .localChanges immediately after the last rapid edit")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle to .synced once the single batched commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "5 rapid edits within the debounce window should produce exactly 1 commit, before=\(before) after=\(after)")
        }

        // MARK: 4. A real pull (via a second clone pushing new content)
        // brings changes back into the app.

        do {
            let remote = makeBareRemote(name: "remote-pull")
            seedRemote(remote)

            // "Machine B" clones first, at the seed state - before A pushes
            // anything - so it genuinely has an older history to pull.
            let wtB = scratch.appendingPathComponent("wt-pull-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "machine B should clone successfully")
            let bTaskFileBefore = try? String(contentsOf: syncB.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check((bTaskFileBefore ?? "").contains("from-machine-a") == false, "machine B should not see A's change before A has even pushed it")

            // "Machine A": clones after B, then pushes a new task.
            let wtA = scratch.appendingPathComponent("wt-pull-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "machine A should clone successfully")
            let taskFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-machine-a\n", to: taskFile)
            syncA.markDirty()
            waitForSynced(syncA)
            check(syncA.status == .synced, "machine A should reach .synced after pushing, got \(syncA.status)")

            // Now B pulls and should see A's change.
            let outcome = syncB.pullNow()
            check(outcome == .fastForwarded, "pullNow() should fast-forward cleanly, got \(outcome)")
            check(syncB.status == .synced, "machine B should be .synced after a clean pull with no local edits")
            let bTaskFileAfter = try? String(contentsOf: syncB.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check((bTaskFileAfter ?? "").contains("from-machine-a"), "machine B's local file should contain A's change after pulling")
        }

        // MARK: 5. A forced failure (unreachable remote after a successful
        // clone) shows "Failed" without losing the local edit - the commit
        // already landed locally, only the push failed.

        if let remote = pushedRemote, let wt = pushedWT {
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            // Simulate "remote became unreachable" by deleting the bare repo
            // out from under an already-cloned working tree - a real push
            // will now fail exactly like a network drop or revoked auth
            // would, without this test needing real network conditions.
            try? fm.removeItem(at: remote)

            let localCommitsBefore = commitCount(wt)
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: will-fail-to-push\n", to: taskFile)
            let committed = sync.commitAndPushNow()
            check(!committed, "commitAndPushNow() should report failure when the remote has vanished")
            if case .failed = sync.status {} else { failures.append("status should be .failed after a push failure, got \(sync.status)") }
            let localCommitsAfter = commitCount(wt)
            check(localCommitsAfter == localCommitsBefore + 1, "the local commit should still exist even though the push failed - no data loss")
            let onDisk = try? String(contentsOf: taskFile, encoding: .utf8)
            check(onDisk?.contains("will-fail-to-push") == true, "the local file itself must be untouched by the failed push")
        }

        // MARK: 6. Non-fast-forward (diverged) history stops safely - no
        // force, no data loss, clear "Failed" status.

        do {
            let remote = makeBareRemote(name: "remote-diverge")
            seedRemote(remote)

            let wtA = scratch.appendingPathComponent("wt-diverge-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "diverge scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-diverge-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "diverge scenario: machine B should clone successfully")

            // A pushes a change.
            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-a\n", to: aFile)
            syncA.markDirty()
            waitForSynced(syncA)
            check(syncA.status == .synced, "diverge scenario: A should push its change cleanly, got \(syncA.status)")

            // B, without pulling first, makes its own local commit -
            // genuine divergence from origin once B tries to sync.
            let bFile = syncB.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-b\n", to: bFile)
            _ = shell("/usr/bin/git", ["-C", wtB.path, "add", "-A", "--", "GrandLineDocs/personal-tasks"])
            _ = shell("/usr/bin/git", ["-C", wtB.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "B's own local commit"])

            let bCommitsBefore = commitCount(wtB)
            let outcome = syncB.pullNow()
            check(outcome == .diverged, "pullNow() should report .diverged, got \(outcome)")
            if case .failed = syncB.status {} else { failures.append("status should be .failed on divergence, got \(syncB.status)") }
            let bCommitsAfter = commitCount(wtB)
            check(bCommitsBefore == bCommitsAfter, "a diverged pull must not add, drop, or rewrite any local commit")
            let bContent = try? String(contentsOf: bFile, encoding: .utf8)
            check(bContent?.contains("from-b") == true, "B's own local edit must survive a diverged pull untouched")
        }

        // MARK: 7. Repo-layout migration (fm/grandline-docs-knowledge-
        // foundation): a remote still on the OLD top-level `personal-tasks/`
        // layout gets `git mv`'d to `GrandLineDocs/personal-tasks/` on first
        // clone, with zero data loss, and never re-fires on a later clone.

        do {
            let remote = makeBareRemote(name: "remote-layout-migration")
            // Seed with the OLD layout directly (not via seedRemote, which
            // already seeds the NEW layout) - real task content, not just a
            // `.keep` file, to prove zero data loss.
            let seedDir = scratch.appendingPathComponent("seed-old-layout-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let oldTasks = seedDir.appendingPathComponent("personal-tasks", isDirectory: true)
            writeTaskFile("tasks:\n  - id: pre-migration-task\n    title: \"Survives the move\"\n", to: oldTasks.appendingPathComponent("tasks/active.yaml"))
            writeTaskFile("follow_ups: []\n", to: oldTasks.appendingPathComponent("follow-ups/follow-ups.yaml"))
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed old layout"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])

            let wt = scratch.appendingPathComponent("wt-layout-migration", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "layout migration: clone of an old-layout remote should still succeed")
            waitForSynced(sync)
            check(fm.fileExists(atPath: wt.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "layout migration: data should now live at GrandLineDocs/personal-tasks/ locally")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("personal-tasks").path),
                  "layout migration: the old top-level personal-tasks/ should be gone after git mv")
            let movedContent = try? String(contentsOf: sync.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(movedContent?.contains("pre-migration-task") == true, "layout migration: the real task content must survive the move with zero loss")

            // Confirm the move landed on the remote too (re-clone fresh).
            let freshClone = scratch.appendingPathComponent("fresh-after-layout-migration", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            check(fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "layout migration: the move must have been pushed to the remote, not just applied locally")
            check(!fm.fileExists(atPath: freshClone.appendingPathComponent("personal-tasks").path),
                  "layout migration: a fresh clone from the remote should never see the old top-level folder again")

            // A second client cloning after the migration must NOT re-migrate
            // or duplicate anything - it should just see the new layout.
            let wt2 = scratch.appendingPathComponent("wt-layout-migration-second-client", isDirectory: true)
            let sync2 = ShiftGitSync(workingTree: wt2, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync2.ensureWorkingTreeNow(), "layout migration: a second client cloning post-migration should succeed normally")
            waitForSynced(sync2)
            check(sync2.status == .synced, "layout migration: a second client's clone should settle to .synced with no further migration commit, got \(sync2.status)")
            let secondClientContent = try? String(contentsOf: sync2.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(secondClientContent?.contains("pre-migration-task") == true, "layout migration: a second client should see the already-migrated data intact")
        }

        // MARK: 8. Repo-layout migration must not nest when the NEW dataRoot
        // path already exists (e.g. a lone file salvaged there by
        // `ShiftStore.init()`'s own premature-write race, documented in
        // `ensureWorkingTreeNow`, landing before this migration runs) - a
        // real bug this migration's own live verification against a
        // disposable repo caught: a naive `git mv personal-tasks
        // GrandLineDocs/personal-tasks` nests the whole old folder one level
        // too deep (`GrandLineDocs/personal-tasks/personal-tasks/...`)
        // whenever the destination directory already exists.

        do {
            let remote = makeBareRemote(name: "remote-layout-migration-race")
            let seedDir = scratch.appendingPathComponent("seed-old-layout-race-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let oldTasks = seedDir.appendingPathComponent("personal-tasks", isDirectory: true)
            writeTaskFile("tasks:\n  - id: race-task\n    title: \"Survives a raced destination\"\n", to: oldTasks.appendingPathComponent("tasks/active.yaml"))
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed old layout"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])

            let wt = scratch.appendingPathComponent("wt-layout-migration-race", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            // Simulate the exact race: a lone `settings.yaml` already sitting
            // at the NEW dataRoot path, on disk, before `ensureWorkingTreeNow()`
            // (and therefore the migration inside it) ever runs - exactly
            // what `ShiftStore.init()`'s premature write can produce.
            writeTaskFile("captain: \"test\"\n", to: sync.dataRoot.appendingPathComponent("settings.yaml"))

            check(sync.ensureWorkingTreeNow(), "raced-destination migration: clone should still succeed")
            waitForSynced(sync)
            check(fm.fileExists(atPath: sync.dataRoot.appendingPathComponent("tasks/active.yaml").path),
                  "raced-destination migration: the real task data should land directly at GrandLineDocs/personal-tasks/, not nested")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("GrandLineDocs/personal-tasks/personal-tasks").path),
                  "raced-destination migration: must never produce a nested GrandLineDocs/personal-tasks/personal-tasks/ folder")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("personal-tasks").path),
                  "raced-destination migration: the old top-level personal-tasks/ should be gone")
            let content = try? String(contentsOf: sync.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(content?.contains("race-task") == true, "raced-destination migration: the real task content must survive with zero loss")
            let settingsContent = try? String(contentsOf: sync.dataRoot.appendingPathComponent("settings.yaml"), encoding: .utf8)
            check(settingsContent?.contains("captain") == true, "raced-destination migration: the pre-existing salvaged file at the new path must also survive, untouched")

            let freshClone = scratch.appendingPathComponent("fresh-after-layout-migration-race", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            check(fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "raced-destination migration: the (non-nested) move must have been pushed to the remote")
            check(!fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/personal-tasks").path),
                  "raced-destination migration: the remote itself must not carry a nested folder either")
        }

        // MARK: Real binary attachment file reaches a real disposable remote
        // (grandline-shift-task-image-attachments) - `commitAndPushNow`'s
        // `git add -A -- shiftSubpath` needs no special-casing for a new
        // binary file under `attachments/`, but this proves that rather
        // than assumes it, and confirms the pushed bytes match exactly.

        do {
            let remote = makeBareRemote(name: "remote-attachment")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-attachment", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "attachment push: clone should succeed")

            let fakeImageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<512).map { UInt8($0 % 256) })
            let attachmentURL = sync.dataRoot.appendingPathComponent("attachments/task-attach-test.png")
            try? fm.createDirectory(at: attachmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fakeImageBytes.write(to: attachmentURL)

            sync.markDirty()
            check(sync.status == .localChanges, "attachment push: status should flip to .localChanges immediately after markDirty(), got \(sync.status)")
            waitForSynced(sync)
            check(sync.status == .synced, "attachment push: status should reach .synced once the debounced commit+push completes, got \(sync.status)")

            // Not just "present in the local working tree" - clone the
            // remote fresh and read the file back from THAT clone, so this
            // proves the binary genuinely landed on the remote, not just on
            // disk locally.
            let freshClone = scratch.appendingPathComponent("fresh-after-attachment-push", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            let clonedAttachmentPath = freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/attachments/task-attach-test.png")
            check(fm.fileExists(atPath: clonedAttachmentPath.path), "attachment push: the attachment file should exist in a fresh clone of the remote")
            let clonedBytes = try? Data(contentsOf: clonedAttachmentPath)
            check(clonedBytes == fakeImageBytes, "attachment push: the pushed bytes should match exactly what was written locally")

            // `git show <sha>:<path>` on the remote itself (not the clone)
            // confirms the commit that reached the remote directly carries
            // this file, matching the acceptance bar's own wording.
            let logResult = shell("/usr/bin/git", ["--git-dir", remote.path, "log", "-1", "--format=%H"])
            let sha = logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let showResult = shell("/usr/bin/git", ["--git-dir", remote.path, "show", "\(sha):GrandLineDocs/personal-tasks/attachments/task-attach-test.png"])
            check(showResult.status == 0, "attachment push: git show <sha>:<path> against the bare remote should find the attachment")
        }

        // MARK: A failed push after an attachment write still leaves the
        // attachment safely committed locally, matching every other Shift
        // write's failure contract - never silently lost.

        do {
            let remote = makeBareRemote(name: "remote-attachment-then-gone")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-attachment-push-fail", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "attachment push failure: clone should succeed")

            // Make the remote unreachable out from under an already-cloned
            // working tree - the real "offline, or remote diverged" shape
            // this scenario is meant to cover.
            try? fm.removeItem(at: remote)

            let attachmentBytes = Data([0x89, 0x50, 0x4E, 0x47] + [1, 2, 3, 4, 5])
            let attachmentURL = sync.dataRoot.appendingPathComponent("attachments/will-not-push.png")
            try? fm.createDirectory(at: attachmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? attachmentBytes.write(to: attachmentURL)

            sync.markDirty()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if case .failed = sync.status { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if case .failed = sync.status {} else { failures.append("attachment push failure: status should be .failed once the push can't reach the (now-gone) remote, got \(sync.status)") }
            check(fm.fileExists(atPath: attachmentURL.path), "attachment push failure: the attachment file must still exist locally after a failed push")
            let logAfterFailure = shell("/usr/bin/git", ["-C", wt.path, "log", "-1", "--format=%s"])
            check(logAfterFailure.stdout.contains("file(s) updated"), "attachment push failure: the local commit should have succeeded even though the push failed")
        }

        // MARK: REL-23. The quit-time flush runs a pending debounced commit
        // now, and a launch-time pull that finds uncommitted files schedules
        // the commit instead of only flipping the pill.

        do {
            let remote = makeBareRemote(name: "remote-rel23")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-rel23", isDirectory: true)
            // A debounce far longer than the test, so only the flush can commit.
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 600, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "REL-23: the quit-flush fixture clones")
            let before = commitCount(remote, gitDir: true)
            writeTaskFile("tasks:\n  - id: quit-edit\n", to: sync.dataRoot.appendingPathComponent("tasks/active.yaml"))
            sync.markDirty()
            check(sync.hasPendingCommitForTests, "REL-23: the edit is waiting on the debounce (the fixture is not vacuous)")
            check(sync.flushForTerminationNow(), "REL-23: the quit-time flush finishes inside its budget")
            check(commitCount(remote, gitDir: true) == before + 1,
                  "REL-23: the pending edit is committed and pushed at quit, before=\(before) after=\(commitCount(remote, gitDir: true))")
            check(!sync.hasPendingCommitForTests, "REL-23: nothing is left pending after the flush")

            // The next launch: a file left uncommitted (a quit that ran out
            // of budget, or a crash) must be scheduled for commit by the pull.
            writeTaskFile("tasks:\n  - id: left-by-a-crash\n", to: sync.dataRoot.appendingPathComponent("tasks/active.yaml"))
            check(sync.pullNow() == .upToDate, "REL-23: the pull itself is a no-op")
            check(sync.hasPendingCommitForTests,
                  "REL-23: a pull that finds uncommitted files schedules their commit, not just the pill")
            check(sync.flushForTerminationNow(), "REL-23: and that commit can be flushed too")
        }

        // MARK: REL-24. The clone swap copies, verifies, then removes: a local
        // file that cannot be copied into the fresh clone keeps the old folder
        // (moved aside) instead of being deleted with it.

        do {
            let remote = makeBareRemote(name: "remote-rel24-salvage")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-rel24-salvage", isDirectory: true)
            let raced = wt.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: written-before-the-clone\n", to: raced)
            check(SelfTestFaults.makeUnreadable(raced), "REL-24: the raced local file is unreadable (the fault took)")
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 600, periodicPullInterval: 999_999)
            _ = sync.ensureWorkingTreeNow()
            let siblings = (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []
            let keptAside = siblings.first { $0.hasPrefix("wt-rel24-salvage.unsalvaged-") }
            check(keptAside != nil, "REL-24: a local file that could not be copied keeps the old folder, got \(siblings)")
            if let keptAside {
                let file = scratch.appendingPathComponent(keptAside)
                    .appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml")
                SelfTestFaults.restoreReadable(file)
                check((try? String(contentsOf: file, encoding: .utf8))?.contains("written-before-the-clone") == true,
                      "REL-24: the kept folder still holds the file the copy could not take")
            } else {
                SelfTestFaults.restoreReadable(raced)
            }
            check(fm.fileExists(atPath: wt.appendingPathComponent(".git").path), "REL-24: the fresh clone is still in place")
        }

        // The legacy-data migration moves the old folder aside only once
        // every copy landed. `legacyLocalRoot()` resolves through
        // `AppPaths.dataRoot()`, so `FM_SCRATCH_ROOT` points it at scratch -
        // and the case refuses to run unless it really did.
        do {
            let legacyRootDir = scratch.appendingPathComponent("rel24-scratch-root", isDirectory: true)
            let previous = ProcessInfo.processInfo.environment[AppPaths.scratchRootVariable]
            setenv(AppPaths.scratchRootVariable, legacyRootDir.path, 1)
            defer {
                if let previous { setenv(AppPaths.scratchRootVariable, previous, 1) } else { unsetenv(AppPaths.scratchRootVariable) }
            }
            let legacy = AppPaths.dataRoot().appendingPathComponent("shift", isDirectory: true)
            if legacy.path.hasPrefix(scratch.path) {
                writeTaskFile("tasks:\n  - id: legacy-task\n", to: legacy.appendingPathComponent("tasks/active.yaml"))
                let settings = legacy.appendingPathComponent("settings.yaml")
                writeTaskFile("theme: legacy\n", to: settings)
                check(SelfTestFaults.makeUnreadable(settings), "REL-24: the legacy settings file is unreadable (the fault took)")
                let remote = makeBareRemote(name: "remote-rel24-legacy")
                seedRemote(remote)
                let wt = scratch.appendingPathComponent("wt-rel24-legacy", isDirectory: true)
                let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 600,
                                        periodicPullInterval: 999_999, migratesLegacyData: true)
                _ = sync.ensureWorkingTreeNow()
                SelfTestFaults.restoreReadable(settings)
                check(fm.fileExists(atPath: settings.path),
                      "REL-24: a legacy folder with a file that failed to copy is left in place, not moved aside")
                let migrated = ((try? fm.contentsOfDirectory(atPath: legacy.deletingLastPathComponent().path)) ?? [])
                    .filter { $0.hasPrefix("shift.migrated-") }
                check(migrated.isEmpty, "REL-24: nothing was renamed to shift.migrated-*, got \(migrated)")
            } else {
                check(false, "REL-24: FM_SCRATCH_ROOT did not move the legacy root under scratch - refusing to touch \(legacy.path)")
            }
        }

        // MARK: REL-30. A released instance stops its periodic pull timer.
        do {
            let remote = makeBareRemote(name: "remote-rel30")
            seedRemote(remote)
            var timer: Timer?
            weak var released: ShiftGitSync?
            autoreleasepool {
                let wt = scratch.appendingPathComponent("wt-rel30", isDirectory: true)
                let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 600, periodicPullInterval: 999_999)
                sync.start()
                let deadline = Date().addingTimeInterval(5)
                while sync.debugPullTimer == nil, Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                timer = sync.debugPullTimer
                // Let `start()`'s clone finish so its queue block releases it.
                sync.sharedQueue.sync {}
                released = sync
            }
            for _ in 0..<20 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            check(timer != nil && released == nil,
                  "REL-30: the fixture needs a started pull timer and an instance that deallocates (timer: \(timer != nil), released: \(released == nil))")
            check(timer?.isValid == false, "REL-30: a released instance's periodic pull timer is invalidated")
        }

        // The terminate path calls both flushes on the shared queue. A source
        // guard rather than a behaviour check, because `applicationWillTerminate`
        // cannot run inside a suite; the behaviour is the case above.
        if let dir = SelfTestSources.appSourceDirectory(),
           let main = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8),
           let start = main.range(of: "func applicationWillTerminate(") {
            let body = String(main[start.lowerBound...].prefix(9000))
            check(body.contains("ShiftGitSync.shared.flushForTerminationNow("),
                  "REL-23: applicationWillTerminate flushes the tasks repo's pending commit")
            check(body.contains("DocsRunbookGitSync.shared.flushForTerminationNow("),
                  "REL-23: applicationWillTerminate flushes the runbooks' pending commit")
        } else {
            check(false, "REL-23: could not read main.swift - the terminate-path guard would silently pass")
        }

        if !failures.isEmpty {
            for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
        }
        return failures.isEmpty
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
