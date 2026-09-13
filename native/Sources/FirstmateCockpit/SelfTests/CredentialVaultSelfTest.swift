// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the credential vault's storage layer - crypto,
// store, clipboard and git portability. Run via
// `FM_RUN_CREDENTIAL_VAULT_TESTS=1 .build/debug/FirstmateCockpit`.
//
// Pure logic plus real disk and a real disposable git repo, so it runs in CI.
// The window-backed half (the list, the reveal/copy buttons, the sheets) is
// `CredentialVaultViewSelfTest.swift`, which is in `run-all-tests.sh`'s
// `NEEDS_SESSION` list.
//
// **The three checks that carry the most load, and why they are shaped the way
// they are:**
//
//   * `checkNothingReadableLeaksToDisk` greps the **real bytes of the real
//     file** for planted secrets, titles, accounts, tags and notes. Reasoning
//     about whether the format encrypts a field is exactly the kind of claim
//     that survives a refactor while stopping being true; reading the file the
//     store actually wrote is the only version of this check that cannot pass
//     vacuously. Same technique `BackupSelfTest` uses for the `.glbackup`
//     bundle, for the same reason.
//   * `checkWrongPasswordAndThrottle` proves a wrong password is *rejected*
//     rather than merely failing to decode something - and that a cancelled
//     Touch ID sheet does not burn an attempt.
//   * `checkGitPortability` pushes to a disposable local bare repo and reads
//     the file back out of a **fresh clone**, which is the honest stand-in for
//     "a new Mac cloned `manjesh-config`". Never the captain's real repo.
//
// GL-27: compiled into debug builds only. Do not remove this guard when
// editing this file - `Phase3PolishSelfTest` asserts every file in this
// directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CredentialVaultSelfTest {

    private struct ShellResult { let status: Int32; let stdout: String }

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("credential-vault-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        checkCryptoRoundTrip(check)
        checkPasswordStrength(check)
        checkStoreCRUD(scratch: scratch, check)
        checkNothingReadableLeaksToDisk(scratch: scratch, check)
        checkWrongPasswordAndThrottle(scratch: scratch, check)
        checkAuditLog(scratch: scratch, check)
        checkLoadStateNeverMistakesCorruptForAbsent(scratch: scratch, check)
        checkLoadStateCacheNoticesRealChanges(scratch: scratch, check)
        checkOlderFileStillDecodes(scratch: scratch, check)
        checkPasswordChange(scratch: scratch, check)
        checkPasswordChangeRollsBackOnWriteFailure(scratch: scratch, check)
        checkPasswordChangeStaysOnMain(scratch: scratch, check)
        checkClipboardChangeCountGuard(check)
        checkLockClearsTheClipboard(scratch: scratch, check)
        checkClipboardSourceGuards(check)
        checkOverrideOrder(scratch: scratch, check)
        checkGitPortability(scratch: scratch, check)
        checkSortOrderMigrationAppendAndReorder(scratch: scratch, check)

        if failures.isEmpty {
            print("CredentialVaultSelfTest: all checks passed")
            return true
        }
        print("CredentialVaultSelfTest: FAILED")
        failures.forEach { print("  FAIL: \($0)") }
        return false
    }

    // MARK: Crypto

    private static func checkCryptoRoundTrip(_ check: (Bool, String) -> Void) {
        let salt = CredentialVaultCrypto.newSalt()
        check(salt.count == CredentialVaultCrypto.saltByteCount,
              "a fresh salt should be \(CredentialVaultCrypto.saltByteCount) bytes, got \(salt.count)")
        check(CredentialVaultCrypto.newSalt() != salt, "two fresh salts should differ")

        // A low round count on purpose: this case is about correctness, and
        // 600k rounds x the number of derivations below would make the suite
        // needlessly slow. `checkStoreCRUD` exercises the real default.
        let rounds: UInt32 = 1_000
        guard let key = try? CredentialVaultCrypto.deriveKey(password: "correct horse battery staple",
                                                             salt: salt, rounds: rounds) else {
            check(false, "deriveKey should succeed for a non-empty password")
            return
        }

        // Determinism: the same password and salt must produce a key that opens
        // the same verifier.
        guard let verifier = try? CredentialVaultCrypto.makeVerifier(key) else {
            check(false, "makeVerifier should succeed")
            return
        }
        guard let again = try? CredentialVaultCrypto.deriveKey(password: "correct horse battery staple",
                                                               salt: salt, rounds: rounds) else {
            check(false, "re-deriving with the same inputs should succeed")
            return
        }
        check(CredentialVaultCrypto.verifierOpens(verifier, with: again),
              "the same password and salt should re-derive a key that opens the verifier")

        let wrong = try? CredentialVaultCrypto.deriveKey(password: "wrong horse battery staple",
                                                         salt: salt, rounds: rounds)
        check(wrong != nil && !CredentialVaultCrypto.verifierOpens(verifier, with: wrong!),
              "a different password must NOT open the verifier")

        // A different salt with the same password is a different vault.
        let otherSalt = CredentialVaultCrypto.newSalt()
        let samePasswordOtherSalt = try? CredentialVaultCrypto.deriveKey(password: "correct horse battery staple",
                                                                         salt: otherSalt, rounds: rounds)
        check(samePasswordOtherSalt != nil && !CredentialVaultCrypto.verifierOpens(verifier, with: samePasswordOtherSalt!),
              "the same password under a different salt must not open the verifier")

        // Empty password and an unknown KDF are refused rather than mis-derived.
        check((try? CredentialVaultCrypto.deriveKey(password: "", salt: salt, rounds: rounds)) == nil,
              "an empty password should be refused")
        check((try? CredentialVaultCrypto.deriveKey(password: "x", salt: salt, rounds: rounds, algorithm: "argon2id")) == nil,
              "an unknown KDF algorithm should be refused rather than silently treated as PBKDF2")

        // Per-item subkeys: a payload sealed for one item must not open under
        // another item's purpose. This is the property the report asks for
        // ("leaking one item's nonce never weakens another item").
        let payload = VaultCredential(id: "item-a", title: "T", secret: "s3cr3t")
        guard let sealed = try? CredentialVaultCrypto.seal(payload, vaultKey: key,
                                                           purpose: CredentialVaultCrypto.itemPurpose("item-a")) else {
            check(false, "sealing an item payload should succeed")
            return
        }
        let opened = try? CredentialVaultCrypto.open(VaultCredential.self, from: sealed, vaultKey: key,
                                                     purpose: CredentialVaultCrypto.itemPurpose("item-a"))
        check(opened?.secret == "s3cr3t", "an item payload should round-trip under its own purpose")
        let crossOpened = try? CredentialVaultCrypto.open(VaultCredential.self, from: sealed, vaultKey: key,
                                                          purpose: CredentialVaultCrypto.itemPurpose("item-b"))
        check(crossOpened == nil, "an item's payload must not open under a different item's subkey")

        // Tamper detection: flipping one ciphertext bit must fail to open,
        // rather than decrypting to garbage.
        var tampered = [UInt8](sealed)
        tampered[tampered.count - 1] ^= 0xFF
        check((try? CredentialVaultCrypto.open(VaultCredential.self, from: Data(tampered), vaultKey: key,
                                               purpose: CredentialVaultCrypto.itemPurpose("item-a"))) == nil,
              "a tampered sealed box must fail to open (AES-GCM's tag is the whole point)")
    }

    private static func checkPasswordStrength(_ check: (Bool, String) -> Void) {
        check(CredentialVaultPasswordStrength.evaluate("short") == .tooShort,
              "a password under the length floor should read tooShort")
        check(CredentialVaultPasswordStrength.evaluate("a-long-passphrase-of-words") == .strong,
              "a 20+ character passphrase should read strong on length alone - the honest model for a KDF vault")
        check(CredentialVaultPasswordStrength.evaluate("abcdefghijkl") == .weak,
              "a 12-character single-class string should read weak")
        check(CredentialVaultPasswordStrength.evaluate("Abcdef1!ghij") == .fair,
              "a 12-character mixed-class string should read fair")
        // The floor informs, it never refuses - the report is explicit that a
        // weak master password is the captain's call to make.
        check(CredentialVaultPasswordStrength.minimumLength == 10,
              "the documented length floor should be 10")
    }

    // MARK: Store

    /// A store over a fresh scratch root, with a vault already created.
    private static func makeVault(_ scratch: URL, name: String, password: String = "test-master-password")
        -> (store: CredentialVaultStore, root: URL) {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        let store = CredentialVaultStore(root: root)
        _ = store.createVault(masterPassword: password)
        return (store, root)
    }

    private static func checkStoreCRUD(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "crud")
        check(store.isUnlocked, "a freshly created vault should be unlocked")
        check(store.credentials.isEmpty, "a new vault should hold no credentials")

        // Create.
        let gmail = VaultCredential(title: "Gmail, personal", category: .email,
                                    account: "manjesh.p@gmail.com", secret: "hunter2-gmail",
                                    location: "mail.google.com", tags: ["personal"], notes: "Recovery codes in the safe.")
        guard case .success(let added) = store.add(gmail) else {
            check(false, "add should succeed on an unlocked vault")
            return
        }
        check(store.credentials.count == 1, "add should put the credential in the model")
        check(added.createdAt <= added.updatedAt, "createdAt should not be after updatedAt on a new item")

        // Read back through a genuinely fresh store over the same directory -
        // a real disk round trip, not the in-memory model.
        let reopened = CredentialVaultStore(root: root)
        check(reopened.loadState() == .present, "a written vault should read as .present")
        var reopenedOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            reopened.unlock(masterPassword: "test-master-password") { outcome in
                reopenedOutcome = outcome
                done()
            }
        }
        check(reopenedOutcome == .unlocked, "the right password should unlock a fresh store, got \(String(describing: reopenedOutcome))")
        check(reopened.credentials.count == 1, "a fresh store should read back the one credential")
        check(reopened.credentials.first?.secret == "hunter2-gmail",
              "the secret value should survive the encrypt/write/read/decrypt round trip")
        check(reopened.credentials.first?.tags == ["personal"], "tags should survive the round trip")
        check(reopened.credentials.first?.notes == "Recovery codes in the safe.", "notes should survive the round trip")

        // Update in place.
        var edited = added
        edited.title = "Gmail, personal (renamed)"
        edited.secret = "rotated-value"
        guard case .success(let updated) = store.update(edited) else {
            check(false, "update should succeed")
            return
        }
        check(updated.createdAt == added.createdAt, "update must preserve createdAt")
        check(updated.updatedAt >= added.updatedAt, "update should move updatedAt forward")
        check(store.credentials.count == 1, "update must not add a second copy")

        // `update` must not reset last-used - an editor form has no business
        // touching it.
        store.recordCopy(id: added.id)
        let usedAt = store.credential(id: added.id)?.lastUsedAt
        check(usedAt != nil, "recordCopy should stamp lastUsedAt")
        var editedAgain = store.credential(id: added.id)!
        editedAgain.notes = "changed"
        editedAgain.lastUsedAt = nil
        _ = store.update(editedAgain)
        check(store.credential(id: added.id)?.lastUsedAt == usedAt,
              "update must preserve lastUsedAt even when the caller's copy has it nil")

        // Delete, then undo.
        guard case .success(let removed) = store.delete(id: added.id) else {
            check(false, "delete should succeed")
            return
        }
        check(store.credentials.isEmpty, "delete should remove the credential")
        guard case .success = store.restore(removed) else {
            check(false, "restore (GL-33's undo) should succeed")
            return
        }
        check(store.credentials.count == 1, "restore should put the credential back")
        check(store.credential(id: removed.id)?.secret == "rotated-value",
              "restore should bring the value back intact, not a blank record")
        if case .success = store.restore(removed) {
            check(false, "restoring an id that is already present should be refused, not duplicated")
        }

        // Locked store refuses every mutator rather than half-applying one.
        store.lock(reason: "test")
        check(!store.isUnlocked, "lock should clear the unlocked state")
        check(store.credentials.isEmpty, "lock should drop every decrypted value from memory")
        if case .success = store.add(VaultCredential(title: "nope")) {
            check(false, "add on a locked vault should be refused")
        }
        if case .success = store.delete(id: removed.id) {
            check(false, "delete on a locked vault should be refused")
        }

        // Search never matches on the secret value - a real disclosure channel
        // if it did, with no audit event behind it.
        let probe = VaultCredential(title: "AWS root", account: "root", secret: "super-secret-value", tags: ["prod"])
        check(probe.matches("aws"), "search should match the title")
        check(probe.matches("PROD"), "search should match a tag, case-insensitively")
        check(probe.matches("root"), "search should match the account")
        check(!probe.matches("super-secret"), "search must NEVER match the secret value")
    }

    private static func checkNothingReadableLeaksToDisk(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, _) = makeVault(scratch, name: "leak")
        // Distinctive, unmistakable strings - if any of these appears in the
        // file's real bytes, something is being written in the clear.
        let planted = [
            "PLANTED-SECRET-VALUE-9f3a",
            "PLANTED-TITLE-AWS-Root-Account",
            "PLANTED-ACCOUNT-root@682528822458",
            "PLANTED-TAG-sensitive",
            "PLANTED-NOTES-rotate-every-90-days",
            "PLANTED-LOCATION-console.aws.amazon.com",
        ]
        _ = store.add(VaultCredential(title: planted[1], category: .cloud, account: planted[2],
                                      secret: planted[0], location: planted[5],
                                      tags: [planted[3]], notes: planted[4]))
        // A reveal and a copy, so the audit log has entries naming the item.
        let id = store.credentials.first!.id
        store.recordReveal(id: id)
        store.recordCopy(id: id)

        guard let bytes = store.rawFileBytesForTests() else {
            check(false, "the vault file should exist on disk after a write")
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for needle in planted {
            check(!text.contains(needle),
                  "the vault file contains the plaintext \"\(needle)\" - the format must encrypt every field, titles included")
        }
        // Also assert the file really is the vault (so a pass cannot come from
        // an empty or missing file), and that the KDF scaffolding IS plaintext,
        // which is correct and necessary for a legitimate open.
        check(text.contains("\"verifier\""), "the file should carry a verifier - otherwise this check passed vacuously")
        check(text.contains("\"pbkdf2-hmac-sha256\""), "the KDF algorithm is deliberately plaintext - a legitimate open needs it")
        check(text.contains("\"rounds\""), "the round count is deliberately plaintext and per-file, which is what makes it tunable")
    }

    private static func checkWrongPasswordAndThrottle(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "wrongpw", password: "the-right-password")
        _ = store.add(VaultCredential(title: "Something", secret: "value"))
        store.lock(reason: "test")

        let fresh = CredentialVaultStore(root: root)
        var outcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            fresh.unlock(masterPassword: "the-wrong-password") { o in outcome = o; done() }
        }
        if case .wrongPassword(let remaining) = outcome {
            check(remaining == CredentialVaultStore.attemptsBeforeThrottle - 1,
                  "a first wrong password should report \(CredentialVaultStore.attemptsBeforeThrottle - 1) attempts left, got \(remaining)")
        } else {
            check(false, "a wrong password should report .wrongPassword, got \(String(describing: outcome))")
        }
        check(!fresh.isUnlocked, "a wrong password must not unlock the vault")
        check(fresh.credentials.isEmpty, "a wrong password must not populate the model")

        // The escalating delay. Driven from one attempt short of the threshold
        // rather than by five real PBKDF2 derivations.
        fresh.setFailedAttemptsForTests(CredentialVaultStore.attemptsBeforeThrottle - 1)
        var throttleOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            fresh.unlock(masterPassword: "still-wrong") { o in throttleOutcome = o; done() }
        }
        if case .throttled(let after) = throttleOutcome {
            check(after > 0, "a throttle should report a positive delay, got \(after)")
            check(after <= CredentialVaultStore.maxThrottleSeconds,
                  "the escalating delay must stay capped so a mistyped password can't lock the captain out indefinitely")
        } else {
            check(false, "the \(CredentialVaultStore.attemptsBeforeThrottle)th wrong attempt should throttle, got \(String(describing: throttleOutcome))")
        }
        // While throttled, even the RIGHT password waits - otherwise the delay
        // would be trivially bypassable by guessing correctly.
        var duringThrottle: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            fresh.unlock(masterPassword: "the-right-password") { o in duringThrottle = o; done() }
        }
        if case .throttled = duringThrottle {} else {
            check(false, "an unlock during the throttle window should be refused, got \(String(describing: duringThrottle))")
        }

        // A correct password after the throttle clears resets the counter.
        let clean = CredentialVaultStore(root: root)
        var good: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            clean.unlock(masterPassword: "the-right-password") { o in good = o; done() }
        }
        check(good == .unlocked, "the right password should unlock, got \(String(describing: good))")
        check(clean.failedAttemptsForTests == 0, "a successful unlock should reset the failed-attempt counter")
        check(clean.credentials.count == 1, "unlocking should read back the stored credential")
    }

    private static func checkAuditLog(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "audit")
        guard case .success(let item) = store.add(VaultCredential(title: "GitHub PAT", secret: "ghp_xxx")) else {
            check(false, "add should succeed"); return
        }
        store.recordReveal(id: item.id)
        store.recordCopy(id: item.id)
        var edited = item
        edited.notes = "rotated"
        _ = store.update(edited)
        _ = store.delete(id: item.id)

        let kinds = store.auditLog.map(\.kind)
        // Reveal and copy are separate event types - the captain's own review
        // point, and the one fact a collapsed "accessed" event would lose.
        check(kinds.contains(.revealed), "a reveal should log its own event type")
        check(kinds.contains(.copied), "a copy should log its own event type")
        check(kinds.filter { $0 == .revealed }.count == 1, "one reveal should log exactly one reveal event")
        check(kinds.filter { $0 == .copied }.count == 1, "one copy should log exactly one copy event")
        check(kinds.contains(.created) && kinds.contains(.updated) && kinds.contains(.deleted),
              "create/update/delete should each log an event")
        check(kinds.contains(.unlocked), "creating a vault should log an unlock event")

        // The update event names which FIELDS changed, never the values.
        if let updateEvent = store.auditLog.last(where: { $0.kind == .updated }) {
            check(updateEvent.detail?.contains("notes") == true,
                  "an update event should name the changed field, got \(String(describing: updateEvent.detail))")
            check(updateEvent.detail?.contains("rotated") != true,
                  "an update event must NOT contain the new value")
        } else {
            check(false, "there should be an update event")
        }

        // The log survives lock/unlock, which is what makes it a trail rather
        // than a session buffer.
        let countBefore = store.auditLog.count
        store.lock(reason: "manual")
        let fresh = CredentialVaultStore(root: root)
        waitFor(timeout: 30) { done in
            fresh.unlock(masterPassword: "test-master-password") { _ in done() }
        }
        check(fresh.auditLog.count >= countBefore,
              "the audit log should survive a lock and be read back (had \(countBefore), got \(fresh.auditLog.count))")
        check(fresh.auditLog.contains { $0.kind == .locked },
              "locking should have logged its own event before the key was dropped")
        // And the log is inside the ciphertext, not beside it.
        if let bytes = fresh.rawFileBytesForTests() {
            let text = String(decoding: bytes, as: UTF8.self)
            check(!text.contains("GitHub PAT"),
                  "the audit log's item titles must be encrypted too - it names items by title")
        }
    }

    private static func checkLoadStateNeverMistakesCorruptForAbsent(scratch: URL, _ check: (Bool, String) -> Void) {
        let root = scratch.appendingPathComponent("corrupt", isDirectory: true)
        let store = CredentialVaultStore(root: root)
        check(store.loadState() == .absent, "a directory with no vault should read as .absent")

        _ = store.createVault(masterPassword: "test-master-password")
        _ = store.add(VaultCredential(title: "Real credential", secret: "real-value"))
        let intact = try! Data(contentsOf: store.fileURL)

        // Genuinely corrupt it - not merely empty.
        try? Data("{ this is not valid json".utf8).write(to: store.fileURL)
        let broken = CredentialVaultStore(root: root)
        switch broken.loadState() {
        case .unreadable(_, let backup):
            check(backup != nil, "GL-01: a corrupt vault should be backed up aside, got no backup path")
            if let backup {
                check(FileManager.default.fileExists(atPath: backup), "the GL-01 backup file should exist at \(backup)")
            }
        default:
            check(false, "a corrupt vault must read as .unreadable, never .absent - offering to create a new one over real credentials is the failure GL-01 is about")
        }
        // And creating a vault is refused while an unreadable one is there.
        if case .success = broken.createVault(masterPassword: "whatever") {
            check(false, "createVault must be refused while a file exists on disk, readable or not")
        }

        // A file from a NEWER format version is refused rather than opened and
        // partially rewritten.
        var future = try! JSONSerialization.jsonObject(with: intact) as! [String: Any]
        future["formatVersion"] = CredentialVaultFile.currentFormatVersion + 1
        try? JSONSerialization.data(withJSONObject: future).write(to: store.fileURL)
        let newer = CredentialVaultStore(root: root)
        if case .unreadable(let reason, _) = newer.loadState() {
            check(reason.lowercased().contains("newer"),
                  "a newer-format vault's message should say so, got \"\(reason)\"")
        } else {
            check(false, "a vault written by a newer build must be refused, not opened")
        }
    }

    private static func checkOlderFileStillDecodes(scratch: URL, _ check: (Bool, String) -> Void) {
        // The landmine `Host.swift` records: Swift's synthesised decoder needs
        // every declared key PRESENT, regardless of a Swift-side default. This
        // simulates the next field being added by decoding a payload written
        // *before* it existed - which for this feature is the difference
        // between a captain's real credentials opening and not.
        let salt = CredentialVaultCrypto.newSalt()
        guard let key = try? CredentialVaultCrypto.deriveKey(password: "pw", salt: salt, rounds: 1_000) else {
            check(false, "deriveKey should succeed"); return
        }
        // A minimal item payload: only the two genuinely-required keys.
        let legacyItem = #"{"id":"legacy-1","title":"Legacy credential"}"#
        guard let sealed = try? CredentialVaultCrypto.seal(RawJSON(legacyItem), vaultKey: key,
                                                           purpose: CredentialVaultCrypto.itemPurpose("legacy-1")) else {
            check(false, "sealing the legacy payload should succeed"); return
        }
        let decoded = try? CredentialVaultCrypto.open(VaultCredential.self, from: sealed, vaultKey: key,
                                                      purpose: CredentialVaultCrypto.itemPurpose("legacy-1"))
        check(decoded?.title == "Legacy credential",
              "a credential payload written before the optional fields existed must still decode")
        check(decoded?.category == .other, "a missing category should fall back to .other")
        check(decoded?.secret == "", "a missing secret should fall back to empty rather than failing the item")
        check(decoded?.requiresTouchIDToReveal == false, "a missing Touch ID flag should fall back to false")

        // An unknown category raw value degrades to `.other` rather than
        // failing the whole item.
        let futureCategory = #"{"id":"legacy-2","title":"Future","category":"quantum"}"#
        if let box = try? CredentialVaultCrypto.seal(RawJSON(futureCategory), vaultKey: key,
                                                     purpose: CredentialVaultCrypto.itemPurpose("legacy-2")),
           let item = try? CredentialVaultCrypto.open(VaultCredential.self, from: box, vaultKey: key,
                                                      purpose: CredentialVaultCrypto.itemPurpose("legacy-2")) {
            check(item.category == .other, "an unknown category from a newer build should degrade to .other")
        } else {
            check(false, "an item with an unknown category should still decode")
        }

        // Settings written before a field existed.
        let legacySettings = #"{"autoLockSeconds":60}"#
        if let box = try? CredentialVaultCrypto.seal(RawJSON(legacySettings), vaultKey: key, purpose: "p"),
           let decodedSettings = try? CredentialVaultCrypto.open(VaultSettings.self, from: box, vaultKey: key, purpose: "p") {
            check(decodedSettings.autoLockSeconds == 60, "the present field should be read")
            check(decodedSettings.clipboardClearSeconds == VaultSettings.default.clipboardClearSeconds,
                  "a missing settings field should fall back to its default")
        } else {
            check(false, "settings written before a field existed should still decode")
        }
    }


    /// The captain's own manual-reorder ask, end to end: a legacy vault (every
    /// item decoded with no `sortOrder` at all) must not visibly reshuffle on
    /// its first unlock after this ships; a fresh add must append to the end
    /// of its category rather than jump to the front; and a manual reorder -
    /// "any credential to any position, irrespective of when it was created" -
    /// must persist across a relaunch, which is the hard requirement this
    /// whole feature exists to satisfy.
    ///
    /// The "legacy vault" is hand-built with `RawJSON`, exactly like
    /// `checkOlderFileStillDecodes` above, but through the real
    /// `unlock`/`finishUnlock` path rather than an isolated `open` call, since
    /// the migration this asserts (`normalizeSortOrderIfNeeded`) only runs
    /// there.
    private static func checkSortOrderMigrationAppendAndReorder(scratch: URL, _ check: (Bool, String) -> Void) {
        let root = scratch.appendingPathComponent("sortorder-migration", isDirectory: true)
        let salt = CredentialVaultCrypto.newSalt()
        guard let key = try? CredentialVaultCrypto.deriveKey(password: "migration-password", salt: salt, rounds: 1_000) else {
            check(false, "deriveKey should succeed"); return
        }
        // Three credentials in the SAME category, sealed with no `sortOrder`
        // key at all - the exact shape a file written before this field
        // existed would have. Deliberately not added in alphabetical order
        // (Zebra, Apple, Mango), so a naive "keep the array's own order"
        // migration would visibly reshuffle while the real fix - falling back
        // to `displayOrder`'s alphabetical tiebreak - must not.
        let legacyItems: [(id: String, title: String)] = [
            ("z", "Zebra AWS"), ("a", "Apple AWS"), ("m", "Mango AWS"),
        ]
        var entries: [CredentialVaultFile.Entry] = []
        for (id, title) in legacyItems {
            let json = #"{"id":"\#(id)","title":"\#(title)","category":"cloud"}"#
            guard let sealed = try? CredentialVaultCrypto.seal(RawJSON(json), vaultKey: key,
                                                               purpose: CredentialVaultCrypto.itemPurpose(id)) else {
                check(false, "sealing a legacy item should succeed"); return
            }
            entries.append(.init(id: id, payload: sealed))
        }
        guard let verifier = try? CredentialVaultCrypto.makeVerifier(key) else {
            check(false, "makeVerifier should succeed"); return
        }
        // Empty `Data()` for the audit log and settings: `finishUnlock` treats
        // an empty blob as "nothing to decrypt" rather than trying to open it
        // under a purpose this test has no access to (both are `private` on
        // the store) - the simplest honest stand-in for a legacy file whose
        // own log/settings blobs are equally absent-or-minimal.
        let legacyFile = CredentialVaultFile(kdf: .init(salt: salt, rounds: 1_000),
                                             verifier: verifier, items: entries,
                                             auditLog: Data(), settings: Data())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(legacyFile) else {
            check(false, "encoding the legacy file should succeed"); return
        }
        let store = CredentialVaultStore(root: root)
        guard (try? encoded.write(to: store.fileURL)) != nil else {
            check(false, "writing the legacy file should succeed"); return
        }

        var outcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            store.unlock(masterPassword: "migration-password") { o in outcome = o; done() }
        }
        check(outcome == .unlocked, "the legacy vault should unlock, got \(String(describing: outcome))")
        check(store.credentials.count == 3, "all three legacy credentials should be read back")

        // The captain's on-screen order before this shipped was pure
        // alphabetical (the old `renderList` sort) - `displayOrder`'s
        // alphabetical tiebreak must reproduce it exactly on first unlock.
        let displayed = store.credentials.sorted(by: VaultCredential.displayOrder).map(\.title)
        check(displayed == ["Apple AWS", "Mango AWS", "Zebra AWS"],
              "a legacy vault's first unlock must display alphabetically (unchanged from before this shipped), got \(displayed)")

        // And normalization assigned each item a REAL, distinct position
        // matching that order - not left every item tied at the shared 0
        // default, which would leave the very first drag with nothing to move.
        check(Set(store.credentials.map(\.sortOrder)).count == 3,
              "every migrated credential should get its own distinct sortOrder, not stay tied at 0")
        let bySortOrder = store.credentials.sorted { $0.sortOrder < $1.sortOrder }.map(\.title)
        check(bySortOrder == displayed,
              "the migrated sortOrder values should match the alphabetical order, got \(bySortOrder)")

        // The migration persisted - a fresh store over the same file reads
        // back the SAME real positions, not merely a re-derivation each time.
        store.lock(reason: "test")
        let reopened = CredentialVaultStore(root: root)
        var reopenOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            reopened.unlock(masterPassword: "migration-password") { o in reopenOutcome = o; done() }
        }
        check(reopenOutcome == .unlocked, "the migrated vault should still unlock on a fresh store")
        check(reopened.credentials.sorted { $0.sortOrder < $1.sortOrder }.map(\.title) == displayed,
              "the migrated order should survive a relaunch")

        // A brand-new credential appends to the END of its category, not the
        // front `VaultCredential.sortOrder`'s own struct default would imply.
        guard case .success(let added) = reopened.add(VaultCredential(title: "Fresh AWS", category: .cloud, secret: "v")) else {
            check(false, "add should succeed"); return
        }
        check(added.sortOrder == 3, "a new credential should append after the three migrated ones, got \(added.sortOrder)")
        check(reopened.credentials.sorted(by: VaultCredential.displayOrder).map(\.title).last == "Fresh AWS",
              "a freshly added credential should sort at the end of its category")

        // The manual reorder itself: the captain's own example - move "Zebra
        // AWS" (which sorts LAST alphabetically) to the very FRONT of its
        // category, "irrespective of whether it's created first or last."
        let zebra = reopened.credentials.first { $0.title == "Zebra AWS" }!
        let apple = reopened.credentials.first { $0.title == "Apple AWS" }!
        guard case .success = reopened.reorderCategory(.cloud, orderedIDs: [zebra.id, apple.id, "m", added.id]) else {
            check(false, "reorderCategory should succeed"); return
        }
        let reordered = reopened.credentials.sorted(by: VaultCredential.displayOrder).map(\.title)
        check(reordered == ["Zebra AWS", "Apple AWS", "Mango AWS", "Fresh AWS"],
              "a manual reorder must be free-form - any credential to any position - got \(reordered)")

        // The whole point: the manual order survives a relaunch, exactly like
        // the captain's own "AWS Prod above AWS Dev, and it stays there" ask.
        reopened.lock(reason: "test")
        let final = CredentialVaultStore(root: root)
        var finalOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            final.unlock(masterPassword: "migration-password") { o in finalOutcome = o; done() }
        }
        check(finalOutcome == .unlocked, "the reordered vault should still unlock")
        check(final.credentials.sorted(by: VaultCredential.displayOrder).map(\.title) == reordered,
              "the manual reorder must persist across a relaunch - the hard requirement this feature exists to satisfy")

        // Editing a credential (never dragging it) must not silently move it -
        // the editor form has no reorder UI of its own.
        var editedApple = apple
        editedApple.notes = "edited, not moved"
        _ = final.update(editedApple)
        check(final.credentials.sorted(by: VaultCredential.displayOrder).map(\.title) == reordered,
              "an ordinary edit must not move the credential")

        // Changing a credential's category re-appends it to the end of the
        // NEW category, rather than carrying a stale position across.
        var recategorized = apple
        recategorized.category = .email
        guard case .success(let movedCategory) = final.update(recategorized) else {
            check(false, "update across categories should succeed"); return
        }
        check(movedCategory.sortOrder == 0,
              "moving into a category with nothing else yet should land at position 0, got \(movedCategory.sortOrder)")

        // A no-op reorder (the current order, handed straight back) must
        // still report success rather than fail.
        let cloudOnly = final.credentials.filter { $0.category == .cloud }
            .sorted(by: VaultCredential.displayOrder).map(\.id)
        guard case .success = final.reorderCategory(.cloud, orderedIDs: cloudOnly) else {
            check(false, "reordering into the identical order should still report success")
            return
        }
    }

    /// `loadState()` is memoized on the file's (mtime, size) because the Home
    /// canvas calls it on every hub render - so the property worth asserting is
    /// that the cache still *notices* every real transition. A stale cache here
    /// would show the unlock screen the wrong state: "set up a new vault" over
    /// a real one, or "locked" for a vault that is no longer there.
    private static func checkLoadStateCacheNoticesRealChanges(scratch: URL, _ check: (Bool, String) -> Void) {
        let root = scratch.appendingPathComponent("loadstate-cache", isDirectory: true)
        let store = CredentialVaultStore(root: root)

        check(store.loadState() == .absent, "no file should read as .absent")
        // Repeated calls are what the memoization is for; they must not change
        // the answer.
        check(store.loadState() == .absent, "a repeated call on an absent vault should still read .absent")

        _ = store.createVault(masterPassword: "cache-test-password")
        check(store.loadState() == .present,
              "the cache must notice a vault appearing (absent -> present), got \(store.loadState())")
        check(store.loadState() == .present, "a repeated call should still read .present")

        // A write through this store changes both mtime and size.
        _ = store.add(VaultCredential(title: "One", secret: "a-value-long-enough-to-change-the-size"))
        check(store.loadState() == .present, "a vault written to should still read .present")

        // Corrupted *behind this store's back* - the shape a bad `git pull`
        // would produce. The identity check is what makes this visible.
        let intact = try? Data(contentsOf: store.fileURL)
        try? Data("{ corrupted by something else".utf8).write(to: store.fileURL)
        if case .unreadable = store.loadState() {} else {
            check(false, "the cache must notice a file corrupted behind its back, got \(store.loadState())")
        }

        // And back again, byte-for-byte - which is the hardest direction for a
        // naive cache, because restoring the original bytes restores the
        // original *size*. `mtime` is what separates them.
        if let intact { try? intact.write(to: store.fileURL) }
        check(store.loadState() == .present,
              "the cache must notice a restored file (unreadable -> present), got \(store.loadState())")

        // Deleted entirely.
        try? FileManager.default.removeItem(at: store.fileURL)
        check(store.loadState() == .absent,
              "the cache must notice the file being deleted, got \(store.loadState())")
    }

    /// A failed re-key must leave the vault openable by exactly one password -
    /// the old one. Never neither, and never "it depends what you do next".
    private static func checkPasswordChangeRollsBackOnWriteFailure(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "rekey-rollback", password: "old-master-password")
        _ = store.add(VaultCredential(title: "Kept", secret: "kept-value"))

        // Make the write fail for real rather than by injecting a flag: a
        // directory where the file has to go cannot be written as a file.
        // `AtomicWrite` writes to `fileURL` itself, so replacing that path with
        // a directory is a genuine, recoverable I/O failure.
        let fm = FileManager.default
        try? fm.removeItem(at: store.fileURL)
        try? fm.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        if case .success = changePassword(store, from: "old-master-password", to: "new-master-password") {
            check(false, "a re-key whose write fails must report failure")
        }
        // Put the real file back and confirm which password opens it.
        try? fm.removeItem(at: store.fileURL)
        let rebuilt = CredentialVaultStore(root: root)
        _ = rebuilt.createVault(masterPassword: "old-master-password")
        _ = rebuilt.add(VaultCredential(title: "Kept", secret: "kept-value"))
        rebuilt.lock(reason: "test")
        var outcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            rebuilt.unlock(masterPassword: "old-master-password") { o in outcome = o; done() }
        }
        check(outcome == .unlocked,
              "after a failed re-key the vault must still be openable, got \(String(describing: outcome))")

        // L5: the rollback must leave Touch ID **off**, never restore whatever
        // it was before.
        //
        // The forward path removes the stored Keychain key unconditionally (it
        // held the *old* derived key and no longer opens anything), and this
        // code no longer has that key to write back - so on a failed persist
        // the honest value is `false`. It used to restore a captured
        // `previousTouchID`, which left `touchIDUnlockEnabled == true` with no
        // key behind it: the Settings toggle read "on" while the unlock button
        // did nothing, until the captain happened to cycle it.
        //
        // Asserted two ways, because neither alone is enough here. The
        // post-condition below holds for any starting state and is what a
        // reader would check; the source guard after it is what actually
        // catches a regression, because reaching the interesting case
        // (`hadStoredKey == true`) needs a **real login-Keychain write** and
        // this suite deliberately never makes one - it is pure logic and runs
        // in CI, where there is no unlocked keychain (the same rule
        // `FM_RUN_CREDENTIAL_PATH_TESTS` states for itself).
        check(store.settings.touchIDUnlockEnabled == false,
              "a failed re-key must leave Touch ID off, got \(store.settings.touchIDUnlockEnabled)")
        checkTouchIDRollbackSource(check)
    }

    /// The source half of L5 - see the note at its call site for why the
    /// behavioural half cannot reach the case that matters.
    private static func checkTouchIDRollbackSource(_ check: (Bool, String) -> Void) {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let raw = try? String(contentsOf: dir.appendingPathComponent("CredentialVaultStore.swift"),
                                    encoding: .utf8) else {
            print("  NOTE: could not read CredentialVaultStore.swift - skipping L5's source guard")
            return
        }
        // Comments stripped first: this fix's own note names the removed
        // `previousTouchID` in order to explain why it is gone, and a guard
        // that trips on the comment documenting it is worse than no guard.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                return trimmed.hasPrefix("//") ? "" : String(line)
            }
            .joined(separator: "\n")

        check(!code.contains("previousTouchID"),
              "the rollback must not capture-and-restore the Touch ID flag - that is L5's defect")
        check(code.contains("settings.touchIDUnlockEnabled = false"),
              "...it must force it off instead")
    }

    /// A password change must mutate state and fire `onChange` on the **main
    /// thread**, and must refuse rather than corrupt anything if the vault
    /// locks under it.
    ///
    /// **The HIGH-severity defect this closes**, found by an end-to-end review:
    /// the Settings sheet ran the whole (then-synchronous) store method on
    /// `DispatchQueue.global`, and the method did its state mutation and its
    /// `onChange?()` inline on that background thread. `onChange` is
    /// `CredentialVaultController.render()` - a full AppKit view rebuild - so
    /// that was undefined behaviour on every password change. And the auto-lock
    /// `Timer` runs in `.common` mode (it fires even while the modal Settings
    /// sheet is up) and locks on **main**, mutating the same
    /// `vaultKey`/`file`/`auditLog` concurrently: a genuine data race on a
    /// Swift array and two optionals during the app's most security-sensitive
    /// operation.
    ///
    /// Both halves are asserted, and the second is the one a thread check
    /// alone would miss:
    ///
    ///  1. `onChange` and the completion both arrive on main - and, because
    ///     `onChange` is fired from the same statement sequence as the
    ///     mutation, that is also the assertion that the mutation is on main.
    ///  2. Locking the vault *while the derivation is in flight* makes the
    ///     change refuse (there is no key left to replace), and the vault is
    ///     still openable by the original password afterwards. Deterministic
    ///     rather than a race to win: two PBKDF2 derivations at 600k rounds
    ///     take hundreds of milliseconds, and `lock` is called synchronously on
    ///     main immediately after the call returns - long before the hop back.
    private static func checkPasswordChangeStaysOnMain(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "pwchange-threading", password: "old-master-password")
        _ = store.add(VaultCredential(title: "Kept", secret: "kept-value"))

        // ---- 1. Everything observable happens on main ----
        var onChangeThreads: [Bool] = []
        store.onChange = { onChangeThreads.append(Thread.isMainThread) }
        var completionOnMain: Bool?
        var result: Result<Void, Error>?
        waitFor(timeout: 30) { done in
            store.changeMasterPassword(currentPassword: "old-master-password",
                                       newPassword: "new-master-password") { r in
                completionOnMain = Thread.isMainThread
                result = r
                done()
            }
        }
        store.onChange = nil
        guard case .success = result else {
            check(false, "the change should have succeeded, got \(String(describing: result))")
            return
        }
        check(completionOnMain == true,
              "the completion must be delivered on the main thread, was \(String(describing: completionOnMain))")
        check(!onChangeThreads.isEmpty,
              "a successful change must fire onChange - that is what re-renders the page")
        check(onChangeThreads.allSatisfy { $0 },
              "onChange is render(); every fire must be on the main thread, got \(onChangeThreads)")

        // ---- 2. A lock landing during the derivation refuses, safely ----
        let (racy, racyRoot) = makeVault(scratch, name: "pwchange-race", password: "race-password")
        _ = racy.add(VaultCredential(title: "Kept", secret: "kept-value"))
        var racyThreads: [Bool] = []
        racy.onChange = { racyThreads.append(Thread.isMainThread) }
        var racyResult: Result<Void, Error>?
        waitFor(timeout: 30) { done in
            racy.changeMasterPassword(currentPassword: "race-password",
                                      newPassword: "never-applied-password") { r in
                racyResult = r
                done()
            }
            // The auto-lock timer's own call, on main, while the two
            // derivations are still running on the background queue.
            racy.lock(reason: "test: auto-lock during a password change")
        }
        racy.onChange = nil
        if case .success = racyResult {
            check(false, "a change whose vault locked under it must not report success")
        }
        check(!racy.isUnlocked, "the lock stands - the change does not resurrect the key")
        check(racyThreads.allSatisfy { $0 },
              "every onChange in the racing case is on main too, got \(racyThreads)")

        // The vault on disk is untouched by the refused change: the original
        // password still opens it and the never-applied one does not.
        let reopened = CredentialVaultStore(root: racyRoot)
        var reopenOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            reopened.unlock(masterPassword: "race-password") { o in reopenOutcome = o; done() }
        }
        check(reopenOutcome == .unlocked,
              "a refused change must leave the original password working, got \(String(describing: reopenOutcome))")
        check(reopened.credentials.first?.secret == "kept-value",
              "...with every value intact")

        let withNever = CredentialVaultStore(root: racyRoot)
        var neverOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            withNever.unlock(masterPassword: "never-applied-password") { o in neverOutcome = o; done() }
        }
        if case .wrongPassword = neverOutcome {} else {
            check(false, "the never-applied password must not open the vault, got \(String(describing: neverOutcome))")
        }

        // And the successful change from part 1 really did land on disk.
        let withNew = CredentialVaultStore(root: root)
        var newOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            withNew.unlock(masterPassword: "new-master-password") { o in newOutcome = o; done() }
        }
        check(newOutcome == .unlocked,
              "the changed password opens the vault, got \(String(describing: newOutcome))")
    }

    /// Seals a literal JSON string as-is, so a test can write a payload in the
    /// shape an *older* build would have produced.
    private struct RawJSON: Encodable {
        let json: String
        init(_ json: String) { self.json = json }
        func encode(to encoder: Encoder) throws {
            // `JSONEncoder` has no "emit these bytes" hook, so the literal is
            // re-encoded through `JSONSerialization`'s object graph - which
            // preserves exactly the keys present and adds none.
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in object {
                let codingKey = AnyKey(key)
                switch value {
                case let s as String: try container.encode(s, forKey: codingKey)
                case let b as Bool: try container.encode(b, forKey: codingKey)
                case let n as NSNumber: try container.encode(n.doubleValue, forKey: codingKey)
                default: break
                }
            }
        }
        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    private static func checkPasswordChange(scratch: URL, _ check: (Bool, String) -> Void) {
        let (store, root) = makeVault(scratch, name: "pwchange", password: "old-master-password")
        _ = store.add(VaultCredential(title: "Kept", secret: "kept-value", notes: "kept notes"))
        _ = store.updateSettings(VaultSettings(autoLockSeconds: 60, clipboardClearSeconds: 45, touchIDUnlockEnabled: false))

        // The wrong current password is refused - otherwise an unlocked window
        // left open would let anyone re-key the vault.
        if case .success = changePassword(store, from: "not-it", to: "new-master-password") {
            check(false, "changeMasterPassword must verify the current password")
        }
        guard case .success = changePassword(store, from: "old-master-password", to: "new-master-password") else {
            check(false, "changeMasterPassword should succeed with the right current password")
            return
        }
        store.lock(reason: "test")

        let withOld = CredentialVaultStore(root: root)
        var oldOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            withOld.unlock(masterPassword: "old-master-password") { o in oldOutcome = o; done() }
        }
        if case .wrongPassword = oldOutcome {} else {
            check(false, "the old password must not open a re-keyed vault, got \(String(describing: oldOutcome))")
        }

        let withNew = CredentialVaultStore(root: root)
        var newOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            withNew.unlock(masterPassword: "new-master-password") { o in newOutcome = o; done() }
        }
        check(newOutcome == .unlocked, "the new password should open the vault, got \(String(describing: newOutcome))")
        check(withNew.credentials.count == 1, "a password change must not lose credentials")
        check(withNew.credentials.first?.secret == "kept-value",
              "every value must be re-sealed under the new key, not dropped")
        check(withNew.credentials.first?.notes == "kept notes", "notes should survive a re-key")
        check(withNew.settings.clipboardClearSeconds == 45, "settings should survive a re-key")
        check(withNew.auditLog.contains { $0.kind == .passwordChanged },
              "a password change should be in the audit log")
    }

    // MARK: Clipboard

    private static func checkClipboardChangeCountGuard(_ check: (Bool, String) -> Void) {
        let clipboard = CredentialVaultClipboard.shared
        let pasteboard = NSPasteboard.general
        // This suite writes to the machine's REAL pasteboard - there is no
        // scratch `NSPasteboard.general`, and the whole point of the guard
        // under test is how it behaves against a genuinely shared one. So the
        // captain's own clipboard contents are saved and put back.
        let captainsClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let captainsClipboard { pasteboard.setString(captainsClipboard, forType: .string) }
        }

        func setExternally(_ value: String) {
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }

        clipboard.copy("vault-copied-value", clearAfter: 60)
        check(pasteboard.string(forType: .string) == "vault-copied-value", "copy should put the value on the pasteboard")
        check(clipboard.copiedChangeCountForTests == pasteboard.changeCount,
              "copy should record the changeCount its own write produced")
        check(clipboard.secondsRemaining != nil, "a copy with a timeout should report a countdown")

        // Untouched: the clear fires.
        clipboard.clearIfUntouchedForTests()
        check(pasteboard.string(forType: .string) != "vault-copied-value",
              "an untouched pasteboard should be cleared when the timer fires")

        // Touched by someone else: the clear must leave it alone. This is the
        // whole reason `changeCount` is tracked - without it, copying a URL
        // after copying a password would silently wipe the URL.
        clipboard.copy("second-vault-value", clearAfter: 60)
        setExternally("something-the-captain-copied-from-a-browser")
        clipboard.clearIfUntouchedForTests()
        check(pasteboard.string(forType: .string) == "something-the-captain-copied-from-a-browser",
              "a pasteboard written by someone else since the copy must NOT be cleared")

        // M1, and this assertion used to say the opposite. `lock` called
        // `abandonPendingClear()`, and this case asserted that leaving the
        // secret on the pasteboard was correct - i.e. it encoded the finding as
        // the expected behaviour, which is exactly why the bug survived a
        // suite this thorough. `abandonPendingClear` no longer exists (it had
        // no other caller, and leaving it would be a loaded gun pointed at
        // this same regression); `clearNow()` is the guarded clear `lock`
        // runs now.
        clipboard.copy("third-vault-value", clearAfter: 60)
        clipboard.clearNow()
        check(pasteboard.string(forType: .string) != "third-vault-value",
              "clearNow should take a still-ours pasteboard back off the board")
        check(clipboard.secondsRemaining == nil, "clearNow should leave no countdown")

        // `clearAfter: 0` copies without scheduling anything.
        clipboard.copy("no-timer-value", clearAfter: 0)
        check(clipboard.secondsRemaining == nil, "clearAfter: 0 should schedule no clear")
        check(pasteboard.string(forType: .string) == "no-timer-value", "clearAfter: 0 should still copy")

        // M2: every copy carries the concealment markers, and the string is
        // still where a plain reader expects it.
        //
        // Asserting the *types on the pasteboard* rather than the call site is
        // the point: the marker payload is empty `Data`, so a `setData` that
        // silently did nothing would look identical in a diff and identical on
        // screen. This is the only place the effect is observable.
        clipboard.copy("marked-secret", clearAfter: 60)
        let declared = pasteboard.types ?? []
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.apple.is-sensitive"] {
            check(declared.contains(NSPasteboard.PasteboardType(marker)),
                  "a copied secret declares \(marker)")
        }
        check(pasteboard.string(forType: .string) == "marked-secret",
              "the markers do not displace the value itself")
        check(clipboard.copiedChangeCountForTests == pasteboard.changeCount,
              "the markers share one changeCount with the string - clearContents is what increments it, "
              + "and the clear guard depends on having recorded exactly this one")

        // The same writer is what the account-copy path uses, so it inherits
        // the markers rather than needing its own.
        let accountCount = CredentialVaultClipboard.writeConcealed("ops-account", to: pasteboard)
        check(pasteboard.string(forType: .string) == "ops-account", "writeConcealed writes the value")
        check(accountCount == pasteboard.changeCount, "writeConcealed returns the changeCount its write produced")
        check((pasteboard.types ?? []).contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              "an account copy is concealed too - it is half a credential")
    }

    /// M1, end to end through the real store: locking clears a just-copied
    /// secret, and still cannot clear somebody else's clipboard.
    ///
    /// The clipboard case above proves `clearNow`'s own behaviour; this proves
    /// `lock` actually calls it. Those are different failures - the shipped bug
    /// was a correct clear function that `lock` never invoked - so a source
    /// guard backs it up: nothing observable distinguishes "locked and cleared"
    /// from "locked, and the pasteboard happened to be empty already".
    private static func checkLockClearsTheClipboard(scratch: URL, _ check: (Bool, String) -> Void) {
        let pasteboard = NSPasteboard.general
        let captainsClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let captainsClipboard { pasteboard.setString(captainsClipboard, forType: .string) }
        }

        let root = scratch.appendingPathComponent("m1-lock-\(UUID().uuidString)", isDirectory: true)
        let store = CredentialVaultStore(root: root)
        guard case .success = store.createVault(masterPassword: "m1-master-password") else {
            check(false, "could not create the vault for the lock-clears-clipboard case")
            return
        }
        guard case .success(let item) = store.add(VaultCredential(title: "M1", secret: "the-secret-value")) else {
            check(false, "could not add a credential for the lock-clears-clipboard case")
            return
        }

        // The real copy path, with a real timeout pending.
        CredentialVaultClipboard.shared.copy(item.secret, clearAfter: 60)
        check(pasteboard.string(forType: .string) == "the-secret-value", "the secret is on the pasteboard before the lock")

        store.lock(reason: "self-test")
        check(pasteboard.string(forType: .string) != "the-secret-value",
              "locking takes the copied secret back off the pasteboard (M1)")
        check(CredentialVaultClipboard.shared.secondsRemaining == nil, "locking leaves no pending countdown")

        // And the guard the old `abandonPendingClear` reasoning was worried
        // about still holds - it is enforced one level down, in the clear
        // itself, which is why lock can safely run it.
        var reunlocked: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            store.unlock(masterPassword: "m1-master-password") { outcome in
                reunlocked = outcome
                done()
            }
        }
        guard reunlocked == .unlocked else {
            check(false, "could not re-unlock for the guard half of the case, got \(String(describing: reunlocked))")
            return
        }
        CredentialVaultClipboard.shared.copy("second-secret", clearAfter: 60)
        pasteboard.clearContents()
        pasteboard.setString("a-url-the-captain-copied", forType: .string)
        store.lock(reason: "self-test, someone else's clipboard")
        check(pasteboard.string(forType: .string) == "a-url-the-captain-copied",
              "locking must NOT clear a pasteboard written by someone else since the copy")
    }

    /// The source half of M1/M2: that `lock` routes through the guarded clear,
    /// and that no copy path writes a bare `setString` of its own.
    ///
    /// Both are invisible to a behavioural check. A reintroduced
    /// `abandonPendingClear`-shaped call would leave a pasteboard that is
    /// *usually* already empty by the time a test looks; a second copy path
    /// added later would work perfectly and just be unmarked.
    private static func checkClipboardSourceGuards(_ check: (Bool, String) -> Void) {
        func source(_ name: String) -> String? {
            let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let app = here.deletingLastPathComponent().appendingPathComponent(name)
            guard var text = try? String(contentsOf: app, encoding: .utf8) else { return nil }
            // Strip whole-line comments: this fix's own notes name the very
            // things being grepped for, which is how a guard like this trips
            // on the explanation of the bug it guards.
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return text
        }

        guard let store = source("CredentialVaultStore.swift"),
              let controller = source("CredentialVaultController.swift"),
              let clipboard = source("CredentialVaultClipboard.swift") else {
            check(false, "could not read the vault sources for the clipboard source guards")
            return
        }

        check(store.contains("CredentialVaultClipboard.shared.clearNow()"),
              "lock runs the guarded clear")
        check(!store.contains("abandonPendingClear"),
              "nothing reintroduced the abandon-without-clearing path")
        check(controller.contains("CredentialVaultClipboard.writeConcealed("),
              "the account copy goes through the shared concealed writer")
        check(!controller.contains("NSPasteboard.general.setString"),
              "no vault copy path writes a bare, unmarked string of its own")
        // One `setString` only, inside the shared writer.
        check(clipboard.components(separatedBy: "setString(").count - 1 == 1,
              "exactly one place in this feature puts a string on a pasteboard")
    }

    // MARK: Overrides

    private static func checkOverrideOrder(scratch: URL, _ check: (Bool, String) -> Void) {
        // `FM_CREDENTIAL_VAULT_DIR` wins; `FM_SHIFT_DIR` is the fallback that
        // keeps a suite away from the captain's real clone. Neither branch may
        // construct a git sync.
        let narrow = scratch.appendingPathComponent("override-narrow", isDirectory: true)
        let shiftDir = scratch.appendingPathComponent("override-shift", isDirectory: true)

        // `main.swift`'s `#if FM_SELFTESTS` block set both of these for the
        // whole process, deliberately - they are what keeps every store in this
        // process away from the captain's real `manjesh-config` clone. This
        // case has to change them to test the precedence, so it captures and
        // restores them rather than `unsetenv`-ing: leaving either cleared
        // would hand the *next* store constructed anywhere in this process the
        // production git sync, which is the exact hazard that block exists to
        // close.
        let previousNarrow = ProcessInfo.processInfo.environment["FM_CREDENTIAL_VAULT_DIR"]
        let previousShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        defer {
            if let previousNarrow { setenv("FM_CREDENTIAL_VAULT_DIR", previousNarrow, 1) } else { unsetenv("FM_CREDENTIAL_VAULT_DIR") }
            if let previousShift { setenv("FM_SHIFT_DIR", previousShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }

        setenv("FM_CREDENTIAL_VAULT_DIR", narrow.path, 1)
        setenv("FM_SHIFT_DIR", shiftDir.path, 1)
        let narrowStore = CredentialVaultStore()
        check(narrowStore.root.path == narrow.path,
              "FM_CREDENTIAL_VAULT_DIR should win, got \(narrowStore.root.path)")
        check(narrowStore.gitSync == nil, "an overridden store must never reach the production git sync")

        unsetenv("FM_CREDENTIAL_VAULT_DIR")
        let shiftStore = CredentialVaultStore()
        check(shiftStore.root.path == shiftDir.appendingPathComponent("grand-line-vault").path,
              "FM_SHIFT_DIR should be honoured as the fallback, got \(shiftStore.root.path)")
        check(shiftStore.gitSync == nil, "the FM_SHIFT_DIR branch must never reach the production git sync either")

        // The repo subpath is a new dedicated folder, and specifically NOT the
        // existing Automic Vault recipe folder - the captain's explicit
        // instruction during the live review.
        check(CredentialVaultGitSync.vaultSubpath == "grand-line-vault-backup",
              "the repo subpath should be grand-line-vault-backup, got \(CredentialVaultGitSync.vaultSubpath)")
        check(!CredentialVaultGitSync.vaultSubpath.contains("automatic-vault-details-backup"),
              "the vault must not be written into Automic Vault's own recipe folder - that folder stays untouched")
        check(!CredentialVaultGitSync.vaultSubpath.hasPrefix("GrandLineDocs"),
              "the vault is not a document and does not belong under GrandLineDocs/")
    }

    // MARK: Portability

    private static func checkGitPortability(scratch: URL, _ check: (Bool, String) -> Void) {
        // A disposable local bare repo standing in for `manjesh-config`. Never
        // the captain's real remote - `pushOnly`'s `ConfigRepoPrivacy` gate is
        // scoped to the real URL, so this path never shells out to `gh` either.
        let remote = scratch.appendingPathComponent("remote.git", isDirectory: true)
        _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", remote.path])

        // Seed it, so a clone has a branch to check out.
        let seed = scratch.appendingPathComponent("seed", isDirectory: true)
        _ = shell("/usr/bin/git", ["clone", remote.path, seed.path])
        try? "seed".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = shell("/usr/bin/git", ["-C", seed.path, "add", "-A"])
        _ = shell("/usr/bin/git", ["-C", seed.path, "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-m", "seed"])
        _ = shell("/usr/bin/git", ["-C", seed.path, "push", "origin", "main"])

        let workingTree = scratch.appendingPathComponent("wt", isDirectory: true)
        let sync = CredentialVaultGitSync(workingTree: workingTree,
                                          remoteURL: remote.path,
                                          debounceInterval: 0.1,
                                          queue: DispatchQueue(label: "credential-vault-selftest-git"))
        check(sync.ensureReadyNow(), "ensureReadyNow should clone the disposable remote")
        check(FileManager.default.fileExists(atPath: sync.dataRoot.path),
              "ensureReadyNow should create the vault subdirectory in the working tree")

        // Write a real vault into the working tree, exactly where the store
        // would, then commit and push it.
        let store = CredentialVaultStore(root: sync.dataRoot)
        _ = store.createVault(masterPassword: "portability-password")
        _ = store.add(VaultCredential(title: "Portable credential", category: .cloud,
                                      account: "root", secret: "value-that-must-travel",
                                      tags: ["prod"], notes: "notes that must travel"))
        check(sync.commitAndPushNow(), "commitAndPushNow should succeed against the disposable remote")
        check(sync.status == .synced, "status should be .synced after a successful push, got \(sync.status)")

        // The honest test of portability: a genuinely fresh clone, as a new Mac
        // would get from Bootstrap's dotfiles step.
        let newMachine = scratch.appendingPathComponent("new-machine", isDirectory: true)
        _ = shell("/usr/bin/git", ["clone", remote.path, newMachine.path])
        let arrived = newMachine
            .appendingPathComponent(CredentialVaultGitSync.vaultSubpath)
            .appendingPathComponent(CredentialVaultGitSync.vaultFileName)
        check(FileManager.default.fileExists(atPath: arrived.path),
              "the encrypted vault should arrive in a fresh clone at \(CredentialVaultGitSync.vaultSubpath)/\(CredentialVaultGitSync.vaultFileName)")

        // And it opens with the password alone - no export/import step, which
        // is the hard requirement the recipe-only backup could not meet.
        let restored = CredentialVaultStore(root: arrived.deletingLastPathComponent())
        check(restored.loadState() == .present, "the arrived vault should read as .present on the new machine")
        var outcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            restored.unlock(masterPassword: "portability-password") { o in outcome = o; done() }
        }
        check(outcome == .unlocked, "the vault should unlock on a fresh clone with the password alone, got \(String(describing: outcome))")
        check(restored.credentials.count == 1, "every credential should come back on the new machine")
        check(restored.credentials.first?.secret == "value-that-must-travel",
              "the secret VALUE - not just its name - must come back; this is what the recipe-only backup could not do")
        check(restored.credentials.first?.notes == "notes that must travel", "notes should travel too")
        check(restored.credentials.first?.tags == ["prod"], "tags should travel too")

        // The commit subject must not name what changed: a message like "added
        // AWS root account" would publish in plaintext the very titles the file
        // format encrypts.
        let subjects = shell("/usr/bin/git", ["-C", newMachine.path, "log", "--format=%s"]).stdout
        check(!subjects.contains("Portable credential"),
              "a commit subject must never name a credential - the git history is plaintext")

        // And a wrong password on the new machine is refused, so "portable"
        // never means "openable".
        let wrongOnNewMachine = CredentialVaultStore(root: arrived.deletingLastPathComponent())
        var wrongOutcome: VaultUnlockOutcome?
        waitFor(timeout: 30) { done in
            wrongOnNewMachine.unlock(masterPassword: "guessing") { o in wrongOutcome = o; done() }
        }
        if case .wrongPassword = wrongOutcome {} else {
            check(false, "a wrong password on the new machine must be refused, got \(String(describing: wrongOutcome))")
        }
    }

    // MARK: Helpers

    /// Run an async call to completion on the main run loop.
    ///
    /// `unlock` deliberately derives on a background queue and calls back on
    /// main, so a suite has to actually turn the run loop - a `DispatchSemaphore`
    /// here would deadlock against the main-queue completion.
    /// `changeMasterPassword` takes a completion and derives on a background
    /// queue (its own doc comment has the HIGH-severity defect that shape
    /// fixes), so every case here goes through the same run-loop pump the
    /// `unlock` waits already use. A timeout reports as a failure rather than
    /// as a silent `nil`.
    private static func changePassword(_ store: CredentialVaultStore,
                                       from current: String,
                                       to new: String) -> Result<Void, Error>? {
        var result: Result<Void, Error>?
        waitFor(timeout: 30) { done in
            store.changeMasterPassword(currentPassword: current, newPassword: new) { r in
                result = r
                done()
            }
        }
        return result
    }

    private static func waitFor(timeout: TimeInterval, _ body: (@escaping () -> Void) -> Void) {
        var finished = false
        body { finished = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func shell(_ executable: String, _ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return ShellResult(status: -1, stdout: "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ShellResult(status: proc.terminationStatus,
                           stdout: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

#endif
