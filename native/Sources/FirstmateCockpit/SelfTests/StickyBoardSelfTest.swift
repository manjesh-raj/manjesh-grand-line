// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the Sticky Board (`fm/grandline-sticky-board`),
// run via `FM_RUN_STICKY_BOARD_TESTS=1 .build/debug/FirstmateCockpit` - same
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

import Foundation
import Yaml

enum StickyBoardSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
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

        // MARK: Report

        if failures.isEmpty {
            print("[sticky-board] OK - all StickyBoard checks passed")
            return true
        }
        for failure in failures { print("[sticky-board] FAIL: \(failure)") }
        return false
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
