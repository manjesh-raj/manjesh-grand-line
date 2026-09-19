// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_VAULT_CONCURRENT_WRITE_TESTS=1 .build/debug/FirstmateCockpit`
//
// Full review #3's **S2** (MEDIUM/HIGH): the unlocked vault never re-read the
// file a git pull had changed underneath it, and every `persist()` rewrote
// the whole thing from memory.
//
// The captain-facing scenario, which is what these cases reproduce:
//
//   Mac A has the vault unlocked. Mac B adds a credential and pushes. A's
//   `ShiftGitSync.pullNow` fast-forwards `vault.enc.json` on disk five
//   minutes later while A's `file`/`credentials` stay exactly as they were.
//   A's five-minute **auto-lock** then fires, `lock()` persists its audit
//   record, and the whole file is rewritten from A's stale set. B's
//   credential is gone from the live file, and the debounced commit pushes
//   the loss onward.
//
// Nothing about that needs a race to reproduce: the two machines never write
// at the same instant, and the second write simply does not know about the
// first. So these cases use **two real `CredentialVaultStore`s over one
// directory** - the honest stand-in for two Macs sharing one synced file -
// rather than threads. `CredentialVaultSelfTest.checkGitPortability` already
// established that shape for "a new Mac cloned `manjesh-config`".
//
// ## Pure logic plus real disk (AGENTS.md's "Writing a self-test")
//
// No view, no window, no window server - real files in a scratch directory
// and the store's own API. This belongs in the **blocking** `--ci` lane and
// is deliberately not listed in `NEEDS_SESSION`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum CredentialVaultConcurrentWriteSelfTest {

    private static let password = "test-master-password-s2"

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.recordNarrated(condition, message, into: &failures)
        }

        print("== credential vault concurrent-write self-test (full review #3, S2) ==")

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("vault-concurrent-write-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        checkALockDoesNotOverwriteAnotherMacsNewCredential(scratch: scratch, check)
        checkAnEditElsewhereIsAdoptedRatherThanReverted(scratch: scratch, check)
        checkThisMachinesOwnEditSurvivesTheMerge(scratch: scratch, check)
        checkALocalDeleteIsNotUndoneByTheMerge(scratch: scratch, check)
        checkARekeyElsewhereIsRefusedRatherThanOverwritten(scratch: scratch, check)
        checkRevealDoesNotWriteOrCommitImmediately(scratch: scratch, check)
        checkPendingUseRecordsSurviveALock(scratch: scratch, check)
        checkAuditWritesDoNotTriggerACommit(check)

        print(failures.isEmpty
            ? "== PASS (vault concurrent write) =="
            : "== FAIL (vault concurrent write): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - The data-loss path itself

    /// **The case the finding is about.** Revert `persist`'s
    /// `adoptOnDiskChangesIfNeeded` call and this fails by name.
    private static func checkALockDoesNotOverwriteAnotherMacsNewCredential(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("autolock", isDirectory: true)
        guard let macA = makeVault(root, check) else { return }
        _ = macA.add(credential(title: "Mac A's own item", secret: "secret-A"))

        // Mac B: a second store over the same file, which is exactly what a
        // git pull leaves behind - a file this process did not write.
        guard let macB = unlockedStore(root, check, label: "Mac B") else { return }
        check(macB.credentials.count == 1, "fixture: Mac B sees Mac A's item before adding its own")
        _ = macB.add(credential(title: "Mac B's new item", secret: "secret-B"))

        // The fixture's own discriminating power: the new credential really
        // is on disk before the lock, so a failure below is the lock
        // destroying it rather than Mac B never having written it.
        check(onDiskTitles(root, check).contains("Mac B's new item"),
              "fixture: Mac B's credential reached the shared file before Mac A locked")

        // Mac A, still unlocked and still holding its stale set, auto-locks.
        macA.lock(reason: "5 minutes idle")

        let after = onDiskTitles(root, check)
        check(after.contains("Mac B's new item"),
              "S2: Mac A's auto-lock destroyed the credential Mac B had added (on disk: \(after.sorted()))")
        check(after.contains("Mac A's own item"),
              "the merge must not lose this machine's own item either (on disk: \(after.sorted()))")
    }

    private static func checkAnEditElsewhereIsAdoptedRatherThanReverted(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("edited-elsewhere", isDirectory: true)
        guard let macA = makeVault(root, check) else { return }
        guard case .success(let item) = macA.add(credential(title: "Router", secret: "old-secret")) else {
            check(false, "fixture: could not seed the credential")
            return
        }

        guard let macB = unlockedStore(root, check, label: "Mac B") else { return }
        guard var theirs = macB.credential(id: item.id) else {
            check(false, "fixture: Mac B could not see the seeded credential")
            return
        }
        theirs.secret = "rotated-secret"
        _ = macB.update(theirs)

        // Mac A has not touched this item, so the rotation is the only
        // opinion in play and must win.
        macA.lock(reason: "manual")

        guard let reopened = unlockedStore(root, check, label: "after") else { return }
        check(reopened.credential(id: item.id)?.secret == "rotated-secret",
              "an edit made elsewhere, untouched here, should survive this machine's next write")
    }

    private static func checkThisMachinesOwnEditSurvivesTheMerge(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("local-edit", isDirectory: true)
        guard let macA = makeVault(root, check) else { return }
        guard case .success(let item) = macA.add(credential(title: "Router", secret: "old-secret")) else {
            check(false, "fixture: could not seed the credential")
            return
        }

        // Mac B adds something unrelated, so there is genuine drift to merge
        // but no conflict on this item.
        guard let macB = unlockedStore(root, check, label: "Mac B") else { return }
        _ = macB.add(credential(title: "Unrelated", secret: "secret-B"))

        // Mac A now makes its own edit on top of a file it has not re-read.
        guard var ours = macA.credential(id: item.id) else {
            check(false, "fixture: Mac A lost sight of its own credential")
            return
        }
        ours.secret = "typed-here"
        _ = macA.update(ours)

        guard let reopened = unlockedStore(root, check, label: "after") else { return }
        check(reopened.credential(id: item.id)?.secret == "typed-here",
              "the edit a human just made here must not be reverted by adopting an unrelated remote change")
        check(reopened.credentials.contains { $0.title == "Unrelated" },
              "and the unrelated remote addition must still be there")
    }

    private static func checkALocalDeleteIsNotUndoneByTheMerge(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("local-delete", isDirectory: true)
        guard let macA = makeVault(root, check) else { return }
        guard case .success(let doomed) = macA.add(credential(title: "Retired key", secret: "s")) else {
            check(false, "fixture: could not seed the credential")
            return
        }

        // Mac B adds something else, so the next write on A has drift to
        // reconcile and will walk every on-disk item - including the one A is
        // about to delete, which is still on disk from A's own earlier write.
        guard let macB = unlockedStore(root, check, label: "Mac B") else { return }
        _ = macB.add(credential(title: "Kept", secret: "s"))

        _ = macA.delete(id: doomed.id)

        let after = onDiskTitles(root, check)
        check(!after.contains("Retired key"),
              "a delete made here must not be resurrected by the merge (on disk: \(after.sorted()))")
        check(after.contains("Kept"),
              "and the remote addition must still be adopted alongside it (on disk: \(after.sorted()))")
    }

    /// A password change on another Mac replaces the KDF header and verifier,
    /// so this machine's key opens nothing in the new file. There is no merge
    /// available, and writing anyway would replace a vault we cannot read
    /// with one the other Mac cannot.
    private static func checkARekeyElsewhereIsRefusedRatherThanOverwritten(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("rekeyed", isDirectory: true)
        guard let macA = makeVault(root, check) else { return }
        _ = macA.add(credential(title: "Before the re-key", secret: "s"))

        guard let macB = unlockedStore(root, check, label: "Mac B") else { return }
        var changed: Result<Void, Error>?
        waitFor(timeout: 60) { done in
            macB.changeMasterPassword(currentPassword: password, newPassword: "a-brand-new-master-password") {
                changed = $0
                done()
            }
        }
        guard case .success = changed else {
            check(false, "fixture: the password change on Mac B did not succeed")
            return
        }
        let afterRekey = onDiskBytes(root, check)
        check(afterRekey != nil, "fixture: the re-keyed file is on disk")

        // Mac A, still holding the old key, tries to write.
        let outcome = macA.add(credential(title: "Written with the old key", secret: "s"))
        if case .failure(let error) = outcome {
            check(error as? CredentialVaultStoreError == .rekeyedElsewhere,
                  "a write against a re-keyed file should report rekeyedElsewhere, got \(error)")
        } else {
            check(false, "a write against a file re-keyed elsewhere should fail rather than overwrite it")
        }
        check(onDiskBytes(root, check) == afterRekey,
              "the re-keyed file on disk must be byte-identical afterwards - nothing was overwritten")
    }

    // MARK: - Reveal / copy no longer write or commit

    private static func checkRevealDoesNotWriteOrCommitImmediately(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("reveal", isDirectory: true)
        guard let store = makeVault(root, check) else { return }
        guard case .success(let item) = store.add(credential(title: "Watched", secret: "s")) else {
            check(false, "fixture: could not seed the credential")
            return
        }
        guard let before = onDiskBytes(root, check) else { return }

        store.recordReveal(id: item.id)
        store.recordCopy(id: item.id)

        check(onDiskBytes(root, check) == before,
              "reveal/copy should not rewrite the whole vault file synchronously - "
              + "that was both a full overwrite from memory and a commit timestamp recording when a secret was viewed")
        check(store.credential(id: item.id)?.lastUsedAt != nil,
              "the use is still recorded in memory - batching must not mean discarding")

        // And the batch really does reach disk, or this would be a silent
        // loss of the audit trail rather than a deferral of it.
        store.flushPendingAuditWritesNow()
        check(onDiskBytes(root, check) != before,
              "the batched use record should reach disk once flushed")
    }

    private static func checkPendingUseRecordsSurviveALock(
        scratch: URL, _ check: (Bool, String) -> Void
    ) {
        let root = scratch.appendingPathComponent("flush-on-lock", isDirectory: true)
        guard let store = makeVault(root, check) else { return }
        guard case .success(let item) = store.add(credential(title: "Used", secret: "s")) else {
            check(false, "fixture: could not seed the credential")
            return
        }
        store.recordCopy(id: item.id)
        // No flush call - the lock is what has to carry it, since a lock
        // always follows a use and is where the key goes away.
        store.lock(reason: "manual")

        guard let reopened = unlockedStore(root, check, label: "after lock") else { return }
        check(reopened.credential(id: item.id)?.lastUsedAt != nil,
              "a use recorded just before a lock must still be on disk after it")
        check(reopened.auditLog.contains { $0.kind == .copied },
              "and the copy event itself must be in the persisted audit log")
    }

    /// The source half. There is no observable git sync on a
    /// `CredentialVaultStore(root:)` - that initializer deliberately never
    /// reaches one - so "does not commit" cannot be asserted behaviourally
    /// here at all. A source guard is the honest instrument for it, and it
    /// catches the regression the behavioural cases above cannot see: someone
    /// putting `markDirty()` back.
    private static func checkAuditWritesDoNotTriggerACommit(_ check: (Bool, String) -> Void) {
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("NOTE: could not locate the app's sources; skipping the audit-commit source guard")
            return
        }
        guard let source = try? String(contentsOf: root.appendingPathComponent("CredentialVaultStore.swift"),
                                       encoding: .utf8) else {
            check(false, "audit-commit guard: could not read CredentialVaultStore.swift")
            return
        }
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // Fixture discrimination: the sweep is looking at the right file, and
        // `markDirty` is still a thing that exists in it - otherwise the
        // assertion below would pass against an empty string.
        check(code.contains("func persistAuditOnly"), "fixture: found persistAuditOnly in the source")
        check(code.contains("markDirty()"),
              "fixture: real mutations still mark the sync dirty - only audit-only writes stopped")

        guard let auditBody = methodBody(named: "private func persistAuditOnly", in: code) else {
            check(false, "audit-commit guard: could not find persistAuditOnly's body")
            return
        }
        check(!auditBody.contains("markDirty"),
              "persistAuditOnly calls markDirty - an unlock/lock/reveal/copy must not produce a git commit, "
              + "because the commit timestamps then record when the captain looked at which secret")

        guard let useBody = methodBody(named: "private func recordUse", in: code) else {
            check(false, "audit-commit guard: could not find recordUse's body")
            return
        }
        check(!useBody.contains("finishWrite"),
              "recordUse goes through finishWrite again - that is the synchronous full-file rewrite plus commit "
              + "this finding removed")
        check(useBody.contains("scheduleAuditFlush"),
              "recordUse no longer batches its write - the whole point of the change")
    }

    /// One method's body out of comment-stripped source, delimited by the
    /// closing brace at method indentation.
    ///
    /// Deliberately **not** delimited by the next doc comment: `stripComments`
    /// removes `///` lines along with `//` ones, so a `\n    /// ` delimiter
    /// silently matches nothing and hands back the rest of the file - which
    /// reads as "this method mentions markDirty" for every method below it.
    /// That is exactly how the first version of this guard failed, and it is
    /// the fail-open direction, so the `nil` return is load-bearing.
    private static func methodBody(named signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature) else { return nil }
        let rest = code[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Helpers

    private static func credential(title: String, secret: String) -> VaultCredential {
        VaultCredential(title: title, category: .other, account: "account",
                        secret: secret, location: "", tags: [], notes: "")
    }

    /// A store over a fresh scratch root with a vault already created, or
    /// `nil` having recorded the failure - so no case ever asserts against a
    /// store that was never set up.
    private static func makeVault(_ root: URL, _ check: (Bool, String) -> Void) -> CredentialVaultStore? {
        let store = CredentialVaultStore(root: root)
        guard case .success = store.createVault(masterPassword: password) else {
            check(false, "fixture: could not create the scratch vault at \(root.lastPathComponent)")
            return nil
        }
        return store
    }

    /// A second, genuinely separate store over the same directory, unlocked -
    /// the stand-in for another Mac whose write arrived through a git pull.
    private static func unlockedStore(_ root: URL, _ check: (Bool, String) -> Void, label: String)
        -> CredentialVaultStore? {
        let store = CredentialVaultStore(root: root)
        var outcome: VaultUnlockOutcome?
        waitFor(timeout: 60) { done in
            store.unlock(masterPassword: password) { outcome = $0; done() }
        }
        guard outcome == .unlocked else {
            check(false, "fixture: \(label) could not unlock the shared vault (got \(String(describing: outcome)))")
            return nil
        }
        return store
    }

    /// The titles actually in the file on disk, read back through a fresh
    /// store - never through the in-memory model of a store under test, which
    /// is the very thing these cases doubt.
    private static func onDiskTitles(_ root: URL, _ check: (Bool, String) -> Void) -> Set<String> {
        guard let store = unlockedStore(root, check, label: "reader") else { return [] }
        return Set(store.credentials.map(\.title))
    }

    private static func onDiskBytes(_ root: URL, _ check: (Bool, String) -> Void) -> Data? {
        let url = root.appendingPathComponent(CredentialVaultGitSync.vaultFileName)
        guard let data = try? Data(contentsOf: url) else {
            check(false, "fixture: no vault file at \(url.path)")
            return nil
        }
        return data
    }

    private static func waitFor(timeout: TimeInterval, _ body: (@escaping () -> Void) -> Void) {
        var finished = false
        body { finished = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

#endif
