// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated coverage for the pure-logic half of the full-app
// audit's "Bugs" section (`data/grandline-full-app-audit/report.md` §4), fixed
// in `fm/grandline-audit-bug-fixes`. Run with:
//
//   swift build && FM_RUN_AUDIT_BUG_FIXES_TESTS=1 .build/debug/FirstmateCockpit
//
// Four findings live here because each is a store or a value type with no view
// involved, so all of them run in CI. The other six are covered where their
// own subject already has a suite: 4.1 in `KubernetesDestinationSelfTest`
// (needs a real console *and* a real Kubernetes page), 4.2/4.6 in
// `StickyBoardSelfTest`, 4.3 in `RecentDestinationsSelfTest`, 4.7 in
// `SessionSwitcherSelfTest`, 4.9 in `StickyBoardViewSelfTest`.
//
// What each case pins, and why reading the code is not enough:
//
//  - **4.4 (IncidentStore, GL-21 class).** "No incidents exist" and "I could
//    not read the directory" produced the same answer, so an unreadable tree
//    reissued a live id and `directory(forID:)`'s prefix scan then resolved
//    the *older* incident's folder. The failure is silent and corrupts two
//    records at once, which is exactly the shape no amount of UI testing
//    surfaces - it needs a directory that genuinely cannot be enumerated.
//  - **4.5 (JSONL trim).** Both stores' headers promise "one bad line can only
//    ever cost itself", and both broke that promise on the trim path, which
//    rewrote the file from *decoded* records. A test that only appends and
//    reads back passes either way; the failure needs a file that already
//    contains a line this build cannot decode, plus enough appends to cross
//    the cap.
//  - **4.8 (`SSHKey`/`Snippet` decoders).** Nothing is broken today - this is
//    the preventive half. The test therefore has to *simulate* the future
//    field addition by decoding JSON that predates it, which is precisely
//    what a reading of the struct cannot tell you.
//  - **4.10 (`CodePreviewStore.delete`).** A swallowed delete is invisible by
//    construction: the panel has already closed the tab, so the only symptom
//    is the snippet coming back on the next launch.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum AuditBugFixesSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-bug-fixes-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            // An unreadable directory has to be made readable again or the
            // cleanup itself fails and leaks it into the temp dir.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scratch.appendingPathComponent("incidents-unreadable").path)
            try? FileManager.default.removeItem(at: scratch)
        }

        check4_4_incidentStoreDistinguishesUnreadableFromEmpty(scratch, check)
        check4_5_fleetLogTrimPreservesUndecodableLines(scratch, check)
        check4_5_scheduleHistoryPrunePreservesUndecodableLines(scratch, check)
        check4_8_decodersTolerateAMissingDefaultedField(check)
        check4_10_codePreviewDeleteReportsAFailure(scratch, check)

        for failure in failures { print("AuditBugFixesSelfTest FAIL - \(failure)") }
        print(failures.isEmpty ? "AuditBugFixesSelfTest: all checks passed"
                               : "AuditBugFixesSelfTest: FAILED (\(failures.count))")
        return failures.isEmpty
    }

    /// `PersistenceFailureReporter.report` hops to the main queue, and a
    /// headless suite never turns the run loop on its own.
    private static func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    // MARK: 4.4 - IncidentStore reads a failed enumeration as "no incidents"

    private static func check4_4_incidentStoreDistinguishesUnreadableFromEmpty(
        _ scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let fm = FileManager.default

        // (a) A genuinely empty (in fact, not-yet-created) tree is *complete*:
        //     nothing has ever written an incident, and refusing to start one
        //     because of that would break the first incident on every machine.
        let emptyRoot = scratch.appendingPathComponent("incidents-empty", isDirectory: true)
        let emptyStore = IncidentStore(root: emptyRoot)
        check(emptyStore.all().isEmpty, "4.4: a fresh store should report no incidents")
        check(emptyStore.rescanIsComplete(),
              "4.4: a directory that does not exist yet is genuinely empty, not unreadable")
        check(emptyStore.nextIncidentID() == "INC-001",
              "4.4: the first id on an empty tree should be INC-001, was \(emptyStore.nextIncidentID() ?? "nil")")

        switch emptyStore.start(title: "Checkout latency", hostID: "h1", hostLabel: "Prod Bastion") {
        case .success(let incident):
            check(incident.id == "INC-001", "4.4: first incident should be INC-001, was \(incident.id)")
        case .failure(let error):
            check(false, "4.4: starting the first incident on an empty tree failed with \(error)")
        }
        check(emptyStore.nextIncidentID() == "INC-002",
              "4.4: with INC-001 on disk the next id should be INC-002, was \(emptyStore.nextIncidentID() ?? "nil")")

        // (b) A tree that exists but cannot be enumerated is NOT empty - and
        //     this is the whole finding. Seed a real incident first, then take
        //     read permission away: a store that folds the failure into "[]"
        //     hands back INC-001 again, which `directory(forID:)` then resolves
        //     to the *existing* INC-001's folder.
        let blockedRoot = scratch.appendingPathComponent("incidents-unreadable", isDirectory: true)
        let seeding = IncidentStore(root: blockedRoot)
        guard case .success = seeding.start(title: "Seeded", hostID: "h1", hostLabel: "Prod Bastion") else {
            check(false, "4.4: could not seed an incident to block the directory on")
            return
        }
        let incidentsDir = blockedRoot.appendingPathComponent("incidents", isDirectory: true)
        guard fm.fileExists(atPath: incidentsDir.path) else {
            check(false, "4.4: expected an incidents/ directory after seeding")
            return
        }
        // Chmod 000 makes `contentsOfDirectory` throw for a non-root user.
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: incidentsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: incidentsDir.path) }

        guard (try? fm.contentsOfDirectory(atPath: incidentsDir.path)) == nil else {
            // Running as root, or a filesystem that ignores the mode bits.
            print("AuditBugFixesSelfTest NOTE - 4.4: this environment can still read a 0o000 "
                  + "directory (root, or a permissive filesystem), so the unreadable half is skipped")
            return
        }

        let blocked = IncidentStore(root: blockedRoot)
        check(!blocked.rescanIsComplete(),
              "4.4: an incidents directory that cannot be enumerated must NOT report a complete scan")
        check(blocked.nextIncidentID() == nil,
              "4.4: no id may be issued from a partial read - it can collide with a live one "
              + "(got \(blocked.nextIncidentID() ?? "nil"))")
        switch blocked.start(title: "Second", hostID: "h2", hostLabel: "DEV Bastion") {
        case .failure(.couldNotRead):
            break // correct: refuses rather than reusing INC-001
        case .failure(let other):
            check(false, "4.4: expected .couldNotRead on an unreadable tree, got \(other)")
        case .success(let incident):
            check(false, "4.4: started \(incident.id) from an unreadable tree - this is the "
                  + "duplicate-id corruption the finding is about")
        }
    }

    // MARK: 4.5 - a trim must not delete a line it could not decode

    private static func check4_5_fleetLogTrimPreservesUndecodableLines(
        _ scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let dir = scratch.appendingPathComponent("fleet-log-trim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("events.jsonl")

        // A line no build of this app can decode - the stand-in for "an old
        // line a future schema change made unreadable", which is the realistic
        // way this fires.
        let opaque = #"{"schemaVersion":99,"kind":"something-this-build-has-never-heard-of"}"#
        try? (opaque + "\n").write(to: file, atomically: true, encoding: .utf8)

        let store = FleetLogStore(directory: dir)
        check(store.events().isEmpty, "4.5: an undecodable line must not surface as an event")

        // Cross the cap so the trim path - the one that rewrites the file -
        // actually runs. Below the cap this is a plain append and the bug is
        // invisible, which is why the count matters.
        let total = FleetLogStore.maxEvents + FleetLogStore.trimSlack + 5
        for index in 0..<total {
            store.append(FleetLogSources.merged(prNumber: index, prTitle: "PR \(index)",
                                                repo: "repo", url: "https://example.invalid/\(index)"))
        }

        store.debugForgetCache()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(text.contains(opaque),
              "4.5: the trim deleted the line it could not decode - the exact behaviour "
              + "FleetLogStore's own header promises never happens")

        // The cap must still bound the *events*, and must not be defeated by
        // the preserved line. The trim fires once, at `maxEvents + trimSlack`,
        // and cuts back to `maxEvents` - so the 5 appends after it are simply
        // still there. (Unchanged from before the fix; asserted so a trim that
        // stopped counting events, or started counting opaque lines toward the
        // cap, is caught.)
        let overshoot = total - (FleetLogStore.maxEvents + FleetLogStore.trimSlack)
        let expectedEvents = FleetLogStore.maxEvents + overshoot
        let events = store.events()
        check(events.count == expectedEvents,
              "4.5: the cap still counts events - expected \(expectedEvents), got \(events.count)")
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        check(lines.count == expectedEvents + 1,
              "4.5: expected \(expectedEvents) events + 1 preserved line, got \(lines.count) lines")
        // And the oldest *events* are what went, not the newest.
        check(!text.contains("\"PR 0\""), "4.5: the oldest event should have been trimmed")
        check(text.contains("PR \(total - 1)"), "4.5: the newest event must survive the trim")
    }

    private static func check4_5_scheduleHistoryPrunePreservesUndecodableLines(
        _ scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let dir = scratch.appendingPathComponent("schedule-history-trim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("runs.jsonl")

        let opaque = #"{"schemaVersion":99,"verdict":"a-verdict-this-build-cannot-read"}"#
        try? (opaque + "\n").write(to: file, atomically: true, encoding: .utf8)

        let store = ScheduleRunHistoryStore(directory: dir)
        let scheduleID = UUID()
        // One entry old enough to be pruned, so the rewrite path runs, plus a
        // fresh one to trigger it.
        let stale = ScheduleRunHistoryEntry(scheduleID: scheduleID,
                                            at: Date().addingTimeInterval(-30 * 24 * 3600),
                                            verdict: .clean, summary: "old run", actionTitle: "Fork sync")
        store.append(stale)
        store.append(ScheduleRunHistoryEntry(scheduleID: scheduleID, at: Date(),
                                             verdict: .clean, summary: "new run", actionTitle: "Fork sync"))

        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(text.contains(opaque),
              "4.5: the prune deleted the line it could not decode (schedule run history)")
        check(text.contains("new run"), "4.5: the fresh entry must survive the prune")
        check(!text.contains("old run"), "4.5: the aged-out entry should have been pruned")
    }

    // MARK: 4.8 - the synthesized-Decodable landmine, preventively removed

    private static func check4_8_decodersTolerateAMissingDefaultedField(_ check: (Bool, String) -> Void) {
        let decoder = JSONDecoder()

        // The exact shape the bug takes: JSON written before a field existed.
        // With the synthesized decoder these throw, `SSHKeyStore.load()`
        // correctly reads that as a corrupt file, and every saved key is
        // replaced by an empty list - which is precisely what `blockViewOptIn`
        // once did to `hosts.json`.
        let legacyKey = #"""
        {"id":"6C8D8B8E-0A1E-4F7B-9F0C-1B2A3C4D5E6F","label":"Prod bastion key","type":"ed25519",
         "publicKey":"ssh-ed25519 AAAAC3Nz key","fingerprint":"SHA256:abc"}
        """#
        do {
            let key = try decoder.decode(SSHKey.self, from: Data(legacyKey.utf8))
            check(key.label == "Prod bastion key", "4.8: SSHKey label lost on decode")
            check(key.hasPassphrase == false, "4.8: a missing hasPassphrase should fall back to false")
            check(key.certificate == nil, "4.8: a missing certificate should decode as nil")
            check(key.type == .ed25519, "4.8: SSHKey type lost on decode")
        } catch {
            check(false, "4.8: an SSHKey written before `hasPassphrase` existed no longer decodes "
                  + "(\(error)) - this is how a whole keys.json is lost")
        }

        // Nothing but the genuinely required field.
        let minimalKey = #"{"label":"Only a label"}"#
        do {
            let key = try decoder.decode(SSHKey.self, from: Data(minimalKey.utf8))
            check(key.label == "Only a label", "4.8: minimal SSHKey label lost")
            check(key.publicKey.isEmpty && key.fingerprint.isEmpty,
                  "4.8: missing optional-with-default SSHKey fields should be empty, not a throw")
        } catch {
            check(false, "4.8: a minimal SSHKey did not decode: \(error)")
        }

        let legacySnippet = #"{"id":"3F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","label":"Tail logs","command":"tail -f x"}"#
        do {
            let snippet = try decoder.decode(Snippet.self, from: Data(legacySnippet.utf8))
            check(snippet.label == "Tail logs" && snippet.command == "tail -f x",
                  "4.8: Snippet fields lost on decode")
        } catch {
            check(false, "4.8: a normal Snippet no longer decodes: \(error)")
        }

        let minimalSnippet = #"{"label":"No command yet"}"#
        do {
            let snippet = try decoder.decode(Snippet.self, from: Data(minimalSnippet.utf8))
            check(snippet.command.isEmpty, "4.8: a missing Snippet command should fall back to empty")
        } catch {
            check(false, "4.8: a Snippet missing a defaulted field did not decode: \(error)")
        }

        // The round trip still works - a decoder fix that broke encoding would
        // be a worse bug than the one it fixed.
        let original = SSHKey(label: "Round trip", type: .rsa, publicKey: "ssh-rsa AAAA",
                              fingerprint: "SHA256:xyz", certificate: "cert", hasPassphrase: true)
        do {
            let data = try JSONEncoder().encode(original)
            let back = try decoder.decode(SSHKey.self, from: data)
            check(back == original, "4.8: SSHKey does not survive an encode/decode round trip")
        } catch {
            check(false, "4.8: SSHKey round trip threw: \(error)")
        }
    }

    // MARK: 4.10 - a swallowed delete resurrects the snippet

    private static func check4_10_codePreviewDeleteReportsAFailure(
        _ scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("code-preview", isDirectory: true)
        let store = CodePreviewStore(root: root)
        _ = store.save(name: "notes.txt", content: "hello")
        check(fm.fileExists(atPath: root.appendingPathComponent("notes.txt").path),
              "4.10: the fixture snippet was not written")

        // `report` hops to the main queue, so an earlier case's failure can
        // still be in flight - drain first, then reset, or this case inherits
        // it. Every assertion below is also scoped to this case's own file
        // names rather than to "the log is empty", for the same reason.
        drainMainQueue()
        PersistenceFailureReporter.resetForTests()
        store.delete(name: "notes.txt")
        drainMainQueue()
        check(!fm.fileExists(atPath: root.appendingPathComponent("notes.txt").path),
              "4.10: a normal delete did not remove the file")
        check(!PersistenceFailureReporter.recent.contains { $0.what.contains("notes.txt") },
              "4.10: a successful delete must not report a failure")

        // Deleting something already gone is success, not a reported failure -
        // the caller's intent is satisfied either way, and a store that cried
        // wolf on it would make the Health card useless.
        store.delete(name: "notes.txt")
        drainMainQueue()
        check(!PersistenceFailureReporter.recent.contains { $0.what.contains("notes.txt") },
              "4.10: deleting an already-absent snippet must not report a failure")

        // A delete that genuinely cannot happen must be reported, not
        // swallowed: the panel has already closed the tab, so this is the only
        // signal that the snippet is still on disk and still synced.
        _ = store.save(name: "locked.txt", content: "cannot go")
        drainMainQueue()
        PersistenceFailureReporter.resetForTests()
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        guard !fm.isWritableFile(atPath: root.path) else {
            print("AuditBugFixesSelfTest NOTE - 4.10: this environment ignores directory write "
                  + "permissions (root?), so the reported-failure half is skipped")
            return
        }
        store.delete(name: "locked.txt")
        drainMainQueue()
        check(PersistenceFailureReporter.recent.contains { $0.what.contains("locked.txt") },
              "4.10: a delete that failed was swallowed - the snippet is still on disk, still "
              + "synced to GitHub, and nothing anywhere says so")
        PersistenceFailureReporter.resetForTests()
    }
}

#endif
