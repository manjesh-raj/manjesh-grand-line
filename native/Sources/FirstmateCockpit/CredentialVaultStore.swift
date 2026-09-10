// Manjesh Grand Line - native macOS app.
//
// The credential vault's store: the encrypted file, the unlock/lock state
// machine, CRUD, the audit log and the settings. The one place any of those
// touch disk.
//
// **Where the file actually lives.** Two copies of one format, which is the
// whole portability story:
//
//   * locally, `~/Library/Application Support/FirstmateCockpit/grand-line-vault/vault.enc.json`
//   * in the captain's private clone, `manjesh-config/grand-line-vault-backup/vault.enc.json`
//
// When git sync is active the *repo* copy is the live file - the store reads
// and writes it directly and `CredentialVaultGitSync` commits it - so there is
// no separate export step and no second copy to drift. The Application Support
// path is the fallback for a machine with no clone yet (and the destination of
// the one-time adoption below).
//
// **How a new machine gets everything back.** Bootstrap's existing "Dotfiles &
// machine config" step clones `manjesh-config`; the encrypted file arrives with
// it; the first `unlock` here opens it. There is no restore action to remember
// or forget, which is exactly the hard requirement the existing recipe-only
// backup could not meet (`VaultRecipe.swift`'s header explains why it never
// tried).
//
// **The master password never reaches this file's stored state.** `unlock`
// takes it, hands it to `CredentialVaultCrypto.deriveKey` once, and keeps only
// the derived key - in memory, for the length of the session. There is no
// property here, and no field in the file format, that a password could be
// written into.
//
// **Threading.** Everything public here is main-thread, matching every sibling
// store, with one deliberate exception: `unlock` runs PBKDF2 (hundreds of
// milliseconds by design) and therefore takes a completion handler and does the
// derivation on a background queue. Its completion is always delivered on the
// main thread.

import Foundation

// MARK: - Outcomes

enum VaultUnlockOutcome: Equatable {
    case unlocked
    case wrongPassword(attemptsUntilDelay: Int)
    /// Too many wrong attempts: the report's "five failed unlock attempts
    /// trigger an escalating delay".
    case throttled(retryAfter: TimeInterval)
    /// The file exists but could not be read or decoded. Never treated as
    /// "start a fresh vault" - see `LoadState`.
    case unreadable(String)
    case noVaultYet
    case failed(String)
}

/// Whether a vault exists, and - if reading it went wrong - the fact that it
/// went wrong, kept distinct from "there is no vault".
///
/// GL-01's rule, and the reason it matters more here than anywhere else in the
/// app: collapsing "unreadable" into "absent" would offer the captain a
/// *create a new vault* screen while his real, intact, encrypted credentials
/// sat on disk one directory away - and the first write would overwrite them.
enum VaultLoadState: Equatable {
    case absent
    case present
    case unreadable(reason: String, backupPath: String?)
}

// MARK: - Store

final class CredentialVaultStore {

    // MARK: Location

    let root: URL
    var fileURL: URL { root.appendingPathComponent(CredentialVaultGitSync.vaultFileName) }

    /// `nil` when an `FM_*` override points `root` at a scratch directory
    /// (every self-test, and any captain who wants a purely local vault with no
    /// git backing) - the same convention `ShiftStore.gitSync` established.
    let gitSync: CredentialVaultGitSync?

    // MARK: Session state

    /// The derived key, or nil when locked. The only place it is held, and it
    /// is cleared by `lock()`.
    private var vaultKey: CredentialVaultKey?
    private var file: CredentialVaultFile?

    private(set) var credentials: [VaultCredential] = []
    private(set) var auditLog: [VaultAuditEvent] = []
    private(set) var settings: VaultSettings = .default

    var isUnlocked: Bool { vaultKey != nil }

    /// Fired whenever the unlocked contents change, so the page re-renders
    /// without polling. Also fired on lock, with an empty model.
    var onChange: (() -> Void)?

    /// GL-01: set when the file on disk failed to decode, so the page can say
    /// so - and never offer to create a new vault over it.
    private(set) var loadFailureBackupPath: String?

    // MARK: Throttling

    /// The report's own number: five failed attempts before a delay starts.
    static let attemptsBeforeThrottle = 5
    private var failedAttempts = 0
    private var throttledUntil: Date?

    /// The audit log's cap. A personal vault generates a handful of events a
    /// day, so this is years of history - but it is a real cap and the file has
    /// to stay bounded (it is committed and pushed on every change), so it is
    /// stated here rather than left implicit. Same shape and the same number as
    /// `FleetLogStore.maxEvents`.
    static let maxAuditEvents = 2000

    // MARK: Init

    /// Root resolution mirrors every sibling store in this app, **including
    /// honouring `FM_SHIFT_DIR`** - the root override that means "keep away
    /// from the captain's real `manjesh-config` clone". `CommandLibraryStore`'s
    /// own note records why a store that ignores it is a real hermeticity hole
    /// rather than an inconsistency: without it, a self-test constructing this
    /// store with no override of its own reaches
    /// `CredentialVaultGitSync.shared`, which shares
    /// `ShiftGitSync.shared`'s production working tree - a real clone of the
    /// captain's actual private repo.
    ///
    /// `main.swift`'s `#if FM_SELFTESTS` block sets `FM_CREDENTIAL_VAULT_DIR`
    /// too, so this fallback is not the only defence - it is the one that
    /// covers a suite run by hand with just `FM_SHIFT_DIR` set.
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_CREDENTIAL_VAULT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("grand-line-vault", isDirectory: true)
            gitSync = nil
        } else {
            let sync = CredentialVaultGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
            // No eager `createDirectory` on this branch, matching
            // `DocsRunbookStore`: `ensureReadyNow()` makes it itself, after the
            // clone has landed.
            adoptLocalOnlyVaultIfNeeded()
            return
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// An explicit root, for self-tests and for any future caller that wants a
    /// vault somewhere specific. Never reaches git sync.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The local-only fallback path, used before a clone exists. Resolved the
    /// same way every sibling store resolves its own (`HostStore`,
    /// `DictationStore`, `FleetLogStore`, ...) - there is no shared helper for
    /// it in this codebase, so this matches the established shape rather than
    /// introducing one for a single caller.
    static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("grand-line-vault", isDirectory: true)
    }

    /// One-time adoption: if a vault was created before the clone existed (the
    /// Application Support fallback path) and the repo copy is absent, move it
    /// into the repo so it starts syncing.
    ///
    /// A move rather than a copy, and only when the destination is genuinely
    /// absent: two live copies of one vault, each being written independently,
    /// is a data-loss shape rather than a redundancy. Deliberately silent when
    /// both exist - the repo copy wins by being the one git tracks, and the
    /// stale local file is left on disk rather than deleted, so nothing is
    /// destroyed by a decision this code made on its own.
    private func adoptLocalOnlyVaultIfNeeded() {
        let fm = FileManager.default
        let localFile = Self.applicationSupportRoot.appendingPathComponent(CredentialVaultGitSync.vaultFileName)
        guard fm.fileExists(atPath: localFile.path) else { return }
        let repoFile = root.appendingPathComponent(CredentialVaultGitSync.vaultFileName)
        guard !fm.fileExists(atPath: repoFile.path) else {
            AppLog.store.info("credential vault: both a local-only and a repo copy exist - using the repo copy, leaving the local file untouched")
            return
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.moveItem(at: localFile, to: repoFile)
            AppLog.store.info("credential vault: adopted the local-only vault into the config clone - it syncs from now on")
            gitSync?.markDirty()
        } catch {
            AppLog.store.error("credential vault: could not adopt the local-only vault: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Load state

    /// The last `loadState()` answer, and the file identity it was computed
    /// for. See `loadState()`.
    private var cachedLoadState: (state: VaultLoadState, modified: Date, size: Int)?

    /// Whether a vault exists on disk, and whether it can be read at all.
    ///
    /// **Memoized on the file's own (modification date, size)**, which is not
    /// tidiness: this is called by the unlock screen's every render *and* by the
    /// Home canvas's vault card (`HomeCanvasController.credentialVaultState`),
    /// which runs on every hub render and every space switch - and the honest
    /// implementation decodes the whole file. That is a main-thread JSON parse
    /// per render, the exact per-render cost class this app's audit §3.5 and
    /// GL-20 spent a phase removing. A `stat` is cheap; a parse is not.
    ///
    /// Invalidated by file *identity* rather than by a flag, so a write from
    /// this process and a `git pull` that brought in another machine's copy are
    /// both picked up with no bookkeeping anyone can forget to update.
    func loadState() -> VaultLoadState {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            cachedLoadState = nil
            return .absent
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes?[.size] as? Int) ?? -1
        if let cached = cachedLoadState, cached.modified == modified, cached.size == size {
            return cached.state
        }
        let state = computeLoadState(at: url)
        cachedLoadState = (state, modified, size)
        return state
    }

    /// The real work behind `loadState()`. Separate so the memoization above
    /// reads as one decision rather than being threaded through this function's
    /// several exits.
    private func computeLoadState(at url: URL) -> VaultLoadState {
        var backup: String?
        guard let decoded = StoreLoadFailure.decodeJSON(CredentialVaultFile.self,
                                                        at: url,
                                                        label: "credential vault",
                                                        didBackUp: &backup) else {
            loadFailureBackupPath = backup
            return .unreadable(reason: "The vault file could not be read.", backupPath: backup)
        }
        guard decoded.formatVersion <= CredentialVaultFile.currentFormatVersion else {
            // A *newer* build wrote it. Refusing is the only safe answer: this
            // build cannot know what it would be dropping, and the first write
            // would drop it permanently.
            return .unreadable(reason: "This vault was written by a newer version of Grand Line (format \(decoded.formatVersion)). Update the app to open it.",
                               backupPath: nil)
        }
        return .present
    }

    // MARK: Create

    /// Create a brand-new vault. Refuses if one already exists, so this can
    /// never be the call that destroys real credentials.
    @discardableResult
    func createVault(masterPassword: String) -> Result<Void, Error> {
        guard case .absent = loadState() else {
            return .failure(CredentialVaultStoreError.vaultAlreadyExists)
        }
        do {
            let salt = CredentialVaultCrypto.newSalt()
            let key = try CredentialVaultCrypto.deriveKey(password: masterPassword, salt: salt)
            let newFile = CredentialVaultFile(
                kdf: .init(salt: salt),
                verifier: try CredentialVaultCrypto.makeVerifier(key),
                items: [],
                auditLog: try CredentialVaultCrypto.seal([VaultAuditEvent](), vaultKey: key, purpose: Self.auditPurpose),
                settings: try CredentialVaultCrypto.seal(VaultSettings.default, vaultKey: key, purpose: Self.settingsPurpose)
            )
            vaultKey = key
            file = newFile
            credentials = []
            auditLog = []
            settings = .default
            failedAttempts = 0
            throttledUntil = nil
            append(.init(kind: .unlocked, detail: "new vault created"))
            try persist()
            onChange?()
            return .success(())
        } catch {
            vaultKey = nil
            file = nil
            return .failure(error)
        }
    }

    // MARK: Unlock / lock

    /// Unlock with the master password. Runs PBKDF2 off the main thread; the
    /// completion is always delivered on the main thread.
    func unlock(masterPassword: String, completion: @escaping (VaultUnlockOutcome) -> Void) {
        if let wait = throttleRemaining() {
            completion(.throttled(retryAfter: wait))
            return
        }
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(.noVaultYet)
            return
        }
        var backup: String?
        guard let onDisk = StoreLoadFailure.decodeJSON(CredentialVaultFile.self,
                                                       at: url,
                                                       label: "credential vault",
                                                       didBackUp: &backup) else {
            loadFailureBackupPath = backup
            completion(.unreadable("The vault file could not be read."))
            return
        }
        // A non-empty password is the caller's own precondition; deriving from
        // an empty one would throw and read as "wrong password", which is a
        // worse message than the truth.
        guard !masterPassword.isEmpty else {
            completion(.wrongPassword(attemptsUntilDelay: max(0, Self.attemptsBeforeThrottle - failedAttempts)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let derived: Result<CredentialVaultKey, Error>
            do {
                derived = .success(try CredentialVaultCrypto.deriveKey(password: masterPassword,
                                                                       salt: onDisk.kdf.salt,
                                                                       rounds: onDisk.kdf.rounds,
                                                                       algorithm: onDisk.kdf.algorithm))
            } catch {
                derived = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                completion(self.finishUnlock(derived, file: onDisk, method: "password"))
            }
        }
    }

    /// Unlock with the Touch ID key. Same finish path, so an unlock is recorded
    /// and counted identically however it happened - only the audit detail
    /// differs.
    func unlockWithTouchID(completion: @escaping (VaultUnlockOutcome) -> Void) {
        if let wait = throttleRemaining() {
            completion(.throttled(retryAfter: wait))
            return
        }
        var backup: String?
        guard let onDisk = StoreLoadFailure.decodeJSON(CredentialVaultFile.self,
                                                       at: fileURL,
                                                       label: "credential vault",
                                                       didBackUp: &backup) else {
            loadFailureBackupPath = backup
            completion(.unreadable("The vault file could not be read."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded: Result<CredentialVaultKey, Error>
            do {
                loaded = .success(try CredentialVaultKeyStore.loadKey(salt: onDisk.kdf.salt,
                                                                      reason: "Unlock your Grand Line vault"))
            } catch {
                loaded = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = loaded {
                    // A cancelled Touch ID sheet is the captain saying no, not
                    // a failed attempt: it must not burn an unlock attempt or
                    // move the throttle, exactly as the SSH-key connect path
                    // treats the same three `LAError` codes.
                    // `if case`, not `==`: `KeychainError` is deliberately not
                    // `Equatable` (one case carries an `OSStatus`), and making
                    // it so for two comparisons here would widen a type this
                    // feature only reads.
                    if case KeychainError.userCancelled = error {
                        completion(.failed("Touch ID cancelled."))
                        return
                    }
                    if case KeychainError.notFound = error {
                        completion(.failed("No Touch ID key is stored on this Mac. Unlock with your master password."))
                        return
                    }
                    completion(.failed(error.localizedDescription))
                    return
                }
                completion(self.finishUnlock(loaded, file: onDisk, method: "Touch ID"))
            }
        }
    }

    private func finishUnlock(_ derived: Result<CredentialVaultKey, Error>,
                              file onDisk: CredentialVaultFile,
                              method: String) -> VaultUnlockOutcome {
        switch derived {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let key):
            guard CredentialVaultCrypto.verifierOpens(onDisk.verifier, with: key) else {
                failedAttempts += 1
                if failedAttempts >= Self.attemptsBeforeThrottle {
                    // Escalating: 30s after the fifth, doubling each further
                    // failure, capped so a mistyped password can never lock the
                    // captain out of his own credentials for an unbounded time.
                    let over = failedAttempts - Self.attemptsBeforeThrottle
                    let delay = min(Self.maxThrottleSeconds, 30.0 * pow(2.0, Double(over)))
                    throttledUntil = Date().addingTimeInterval(delay)
                    AppLog.keychain.error("credential vault: \(self.failedAttempts, privacy: .public) failed unlock attempts - delaying \(Int(delay), privacy: .public)s")
                    return .throttled(retryAfter: delay)
                }
                return .wrongPassword(attemptsUntilDelay: Self.attemptsBeforeThrottle - failedAttempts)
            }

            // The key is right. Everything below is a decrypt of bytes that
            // already authenticated, so a failure here means the file was
            // modified - reported as unreadable rather than as a bad password.
            do {
                let items = try onDisk.items.map { entry -> VaultCredential in
                    try CredentialVaultCrypto.open(VaultCredential.self,
                                                   from: entry.payload,
                                                   vaultKey: key,
                                                   purpose: CredentialVaultCrypto.itemPurpose(entry.id))
                }
                let log: [VaultAuditEvent] = onDisk.auditLog.isEmpty ? [] :
                    try CredentialVaultCrypto.open([VaultAuditEvent].self,
                                                   from: onDisk.auditLog,
                                                   vaultKey: key,
                                                   purpose: Self.auditPurpose)
                let loadedSettings: VaultSettings = onDisk.settings.isEmpty ? .default :
                    try CredentialVaultCrypto.open(VaultSettings.self,
                                                   from: onDisk.settings,
                                                   vaultKey: key,
                                                   purpose: Self.settingsPurpose)

                vaultKey = key
                file = onDisk
                credentials = items
                auditLog = log
                settings = loadedSettings
                failedAttempts = 0
                throttledUntil = nil
                append(.init(kind: .unlocked, detail: method))
                persistAuditOnly("unlock record")
                onChange?()
                return .unlocked
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
    }

    static let maxThrottleSeconds: TimeInterval = 15 * 60

    /// Seconds left on the throttle, or nil when not throttled.
    func throttleRemaining() -> TimeInterval? {
        guard let throttledUntil else { return nil }
        let remaining = throttledUntil.timeIntervalSinceNow
        guard remaining > 0 else {
            self.throttledUntil = nil
            return nil
        }
        return remaining
    }

    /// Lock the vault: drop the key and every decrypted value from memory.
    ///
    /// The audit event is appended and persisted *before* the key goes, since
    /// writing it needs the key. `reason` is values-free context ("5 minutes
    /// idle", "manual").
    func lock(reason: String) {
        guard isUnlocked else { return }
        append(.init(kind: .locked, detail: reason))
        persistAuditOnly("lock record")
        vaultKey = nil
        file = nil
        credentials = []
        auditLog = []
        settings = .default
        // A locked vault has no business clearing a pasteboard the captain may
        // since have filled from elsewhere - see that method's own note.
        CredentialVaultClipboard.shared.abandonPendingClear()
        onChange?()
    }

    // MARK: CRUD

    @discardableResult
    func add(_ credential: VaultCredential) -> Result<VaultCredential, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        var stored = credential
        stored.createdAt = Date()
        stored.updatedAt = stored.createdAt
        credentials.append(stored)
        append(.init(kind: .created, itemID: stored.id, itemTitle: stored.title))
        return finishWrite(returning: stored)
    }

    /// Edit in place. `changedFields` is what the audit log records - the field
    /// *names*, never their values, which is the report's own wording for what
    /// an audit trail means here.
    @discardableResult
    func update(_ credential: VaultCredential) -> Result<VaultCredential, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else {
            return .failure(CredentialVaultStoreError.notFound)
        }
        let before = credentials[index]
        var stored = credential
        stored.createdAt = before.createdAt
        stored.updatedAt = Date()
        // Preserved rather than taken from the caller: an editor form has no
        // business resetting when the value was last used.
        stored.lastUsedAt = before.lastUsedAt
        credentials[index] = stored
        append(.init(kind: .updated,
                     itemID: stored.id,
                     itemTitle: stored.title,
                     detail: Self.changedFieldNames(from: before, to: stored)))
        return finishWrite(returning: stored)
    }

    @discardableResult
    func delete(id: String) -> Result<VaultCredential, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        guard let index = credentials.firstIndex(where: { $0.id == id }) else {
            return .failure(CredentialVaultStoreError.notFound)
        }
        let removed = credentials.remove(at: index)
        append(.init(kind: .deleted, itemID: removed.id, itemTitle: removed.title))
        switch finishWrite(returning: removed) {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        }
    }

    /// Put a deleted credential back - GL-33's undo window.
    ///
    /// Restores the record wholesale, id and timestamps included, so the undone
    /// delete leaves no trace beyond the two audit events that honestly
    /// describe what happened.
    @discardableResult
    func restore(_ credential: VaultCredential) -> Result<VaultCredential, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        guard !credentials.contains(where: { $0.id == credential.id }) else {
            return .failure(CredentialVaultStoreError.duplicate)
        }
        credentials.append(credential)
        append(.init(kind: .created, itemID: credential.id, itemTitle: credential.title, detail: "restored by undo"))
        return finishWrite(returning: credential)
    }

    func credential(id: String) -> VaultCredential? {
        credentials.first { $0.id == id }
    }

    // MARK: Use (reveal / copy)

    /// Record that a value was revealed on screen. Distinct from `recordCopy`
    /// by design - see `VaultAuditEvent.Kind`.
    func recordReveal(id: String) {
        recordUse(id: id, kind: .revealed)
    }

    func recordCopy(id: String) {
        recordUse(id: id, kind: .copied)
    }

    private func recordUse(id: String, kind: VaultAuditEvent.Kind) {
        guard isUnlocked, let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        credentials[index].lastUsedAt = Date()
        append(.init(kind: kind, itemID: id, itemTitle: credentials[index].title))
        // Persisted like any other change: an audit trail that only survived
        // while the window stayed open would not be one.
        _ = finishWrite(returning: ())
    }

    // MARK: Settings

    @discardableResult
    func updateSettings(_ newSettings: VaultSettings) -> Result<Void, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        let before = settings
        settings = newSettings
        var changed: [String] = []
        if before.autoLockSeconds != newSettings.autoLockSeconds { changed.append("auto-lock") }
        if before.clipboardClearSeconds != newSettings.clipboardClearSeconds { changed.append("clipboard timeout") }
        if before.touchIDUnlockEnabled != newSettings.touchIDUnlockEnabled { changed.append("Touch ID unlock") }
        if !changed.isEmpty {
            append(.init(kind: .updated, detail: "settings: \(changed.joined(separator: ", "))"))
        }
        return finishWrite(returning: ())
    }

    // MARK: Master password

    /// Change the master password: re-derive a new key with a **new salt** and
    /// re-seal every item, the log and the settings under it.
    ///
    /// A new salt rather than reusing the old one, so the new file shares no
    /// derivation input with the old - and every payload is re-sealed rather
    /// than re-wrapped, because there is no key-wrapping indirection here to
    /// re-wrap (the report's "envelope" is the per-item HKDF subkey, which is
    /// derived from the vault key rather than stored beside it).
    ///
    /// **Takes a completion and derives on a background queue, exactly like
    /// `unlock` - and that shape is the fix for a real HIGH-severity defect
    /// rather than a stylistic choice.** This used to be a plain synchronous
    /// `Result`-returning method, which the Settings sheet's own closure then
    /// ran *whole* on `DispatchQueue.global` (two PBKDF2 derivations at
    /// 600k rounds each are genuinely too slow for the main thread). But every
    /// line after the derivations - `vaultKey = newKey`, `file = ...`, the
    /// audit `append`, `persist()`, the Keychain removal and `onChange?()` -
    /// ran inline on that background thread, and `onChange` is
    /// `CredentialVaultController.render()`: **a full AppKit view rebuild off
    /// the main thread**, which is undefined behaviour. Worse, the auto-lock
    /// `Timer` runs in `.common` mode (so it fires even while the modal
    /// Settings sheet is up) and its `lock(reason:)` mutates the same
    /// `vaultKey`/`file`/`auditLog` on **main** - a genuine data race on a
    /// Swift array and two optionals during the app's most security-sensitive
    /// operation.
    ///
    /// So the split here is the same one `unlock`/`finishUnlock` already
    /// established, and it keeps this store's "public API = main-thread"
    /// contract intact: **only the two derivations and the new verifier's seal
    /// happen off-main** (all three are pure functions of their inputs and
    /// touch none of this object's state), and every state mutation, the
    /// verifier check, `persist()`, the Keychain removal and `onChange?()`
    /// happen back on main in `finishPasswordChange`.
    ///
    /// The completion is always delivered on the main thread.
    func changeMasterPassword(currentPassword: String, newPassword: String,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        // The entry point is main-thread, like every other public method here.
        // Stated rather than assumed: the whole point of this method's shape is
        // that the caller must *not* be the one hopping to a background queue.
        dispatchPrecondition(condition: .onQueue(.main))
        guard isUnlocked, let onDisk = file else {
            completion(.failure(CredentialVaultStoreError.locked))
            return
        }
        // Only the KDF parameters cross the thread boundary - never `self`'s
        // state, and never the `CredentialVaultFile` itself (the copy could be
        // stale by the time the derivation finishes, which is exactly what
        // `finishPasswordChange` re-checks for).
        let kdf = onDisk.kdf
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let derived: Result<DerivedRekey, Error>
            do {
                let currentKey = try CredentialVaultCrypto.deriveKey(password: currentPassword,
                                                                     salt: kdf.salt,
                                                                     rounds: kdf.rounds,
                                                                     algorithm: kdf.algorithm)
                let newSalt = CredentialVaultCrypto.newSalt()
                let newKey = try CredentialVaultCrypto.deriveKey(password: newPassword, salt: newSalt)
                derived = .success(DerivedRekey(currentKey: currentKey,
                                                newKey: newKey,
                                                newSalt: newSalt,
                                                newVerifier: try CredentialVaultCrypto.makeVerifier(newKey)))
            } catch {
                derived = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure(CredentialVaultStoreError.locked))
                    return
                }
                completion(self.finishPasswordChange(derived, derivedAgainstSalt: kdf.salt))
            }
        }
    }

    /// What the background derivation produced. A value type carrying nothing
    /// but pure outputs, so the hop back to main hands over no shared state.
    private struct DerivedRekey {
        let currentKey: CredentialVaultKey
        let newKey: CredentialVaultKey
        let newSalt: Data
        let newVerifier: Data
    }

    /// The main-thread half of a password change: the verifier check and every
    /// mutation. `finishUnlock`'s counterpart, and for the same reason.
    private func finishPasswordChange(_ derived: Result<DerivedRekey, Error>,
                                      derivedAgainstSalt: Data) -> Result<Void, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        let rekey: DerivedRekey
        switch derived {
        case .failure(let error): return .failure(error)
        case .success(let value): rekey = value
        }
        // The vault can have moved under the derivation: the auto-lock timer
        // fires in `.common` mode, so it runs even while the modal Settings
        // sheet is up, and a lock in that window drops the key this change was
        // about to replace. Re-checked here rather than trusted from before the
        // hop - and by salt, because that is the one field a *concurrent*
        // password change would have moved (an ordinary write re-persists the
        // items and leaves the KDF header alone), so it is the exact test for
        // "is the key I derived still the key this file needs".
        guard isUnlocked, let onDisk = file else {
            return .failure(CredentialVaultStoreError.locked)
        }
        guard onDisk.kdf.salt == derivedAgainstSalt else {
            return .failure(CredentialVaultStoreError.locked)
        }
        // No `do`/`catch` around the block below any more: the only throwing
        // calls a password change makes (the two derivations and the new
        // verifier's seal) now happen on the background queue, and `persist()`
        // keeps its own inner `do` because its failure is the one this method
        // has to roll back rather than merely report.
        guard CredentialVaultCrypto.verifierOpens(onDisk.verifier, with: rekey.currentKey) else {
            return .failure(CredentialVaultCryptoError.wrongPassword)
        }
        let newSalt = rekey.newSalt
        let newKey = rekey.newKey

        // The re-key is all-or-nothing. `persist()` is what actually writes
        // the new-key file, so if it throws, the previous key and file
        // header are put back - otherwise memory would be holding the new
        // key while disk still had the old one, and the captain would be
        // told "failed" about a vault that had in fact half-changed its
        // password. Either the old password still works or the new one
        // does; never neither, and never "it depends what you do next".
        let previousKey = vaultKey
        let previousFile = file
        let previousTouchID = settings.touchIDUnlockEnabled
        vaultKey = newKey
        file = CredentialVaultFile(kdf: .init(salt: newSalt),
                                   // Sealed on the background queue with
                                   // the derivations - it is a pure
                                   // function of `newKey`.
                                   verifier: rekey.newVerifier,
                                   items: [],
                                   auditLog: Data(),
                                   settings: Data())
        append(.init(kind: .passwordChanged))
        // Any stored Touch ID key was the *old* derived key and no longer
        // opens anything - forgetting it is correctness, not tidiness.
        let hadStoredKey = CredentialVaultKeyStore.hasStoredKey
        if hadStoredKey {
            CredentialVaultKeyStore.remove()
            settings.touchIDUnlockEnabled = false
        }
        do {
            try persist()
        } catch {
            vaultKey = previousKey
            file = previousFile
            settings.touchIDUnlockEnabled = previousTouchID
            if !auditLog.isEmpty { auditLog.removeLast() }
            PersistenceFailureReporter.report(what: "the credential vault's new master password",
                                              path: fileURL.path, error: error)
            // The Keychain key is deliberately NOT restored: it was removed
            // because the *old* derived key is the one it held, and this
            // code no longer has that key to write back. Re-enabling Touch
            // ID is one toggle, and a stale key that opens nothing would be
            // worse than none.
            return .failure(error)
        }
        gitSync?.markDirty()
        onChange?()
        return .success(())
    }

    /// Store the current derived key for Touch ID unlock. Only reachable while
    /// unlocked, which means the captain has already proven they know the
    /// password.
    @discardableResult
    func enableTouchIDUnlock() -> Result<Void, Error> {
        guard let vaultKey else { return .failure(CredentialVaultStoreError.locked) }
        do {
            try CredentialVaultKeyStore.store(vaultKey)
            var updated = settings
            updated.touchIDUnlockEnabled = true
            return updateSettings(updated)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    func disableTouchIDUnlock() -> Result<Void, Error> {
        CredentialVaultKeyStore.remove()
        var updated = settings
        updated.touchIDUnlockEnabled = false
        return updateSettings(updated)
    }

    // MARK: Sync

    /// Ask the sync to push now - the Settings screen's "Sync now". A no-op for
    /// a store with no git backing.
    func syncNow() {
        guard let gitSync else { return }
        if isUnlocked {
            append(.init(kind: .synced))
            persistAuditOnly("sync record")
        }
        gitSync.markDirty()
    }

    /// Quit-time flush, forwarded to the sync's bounded on-queue flush.
    func flushForTermination() {
        gitSync?.flushForTerminationNow()
    }

    // MARK: Persistence

    private static let auditPurpose = "grand-line-vault/audit"
    private static let settingsPurpose = "grand-line-vault/settings"

    private func append(_ event: VaultAuditEvent) {
        auditLog.append(event)
        if auditLog.count > Self.maxAuditEvents {
            // Oldest first. Capping the newest instead would leave the log
            // permanently stale rather than merely bounded - `FleetLogStore`'s
            // own reasoning for trimming the same direction.
            auditLog.removeFirst(auditLog.count - Self.maxAuditEvents)
        }
    }

    /// Re-seal everything and write it, then tell the sync. Every mutator ends
    /// here, so there is exactly one write path and exactly one place the
    /// debounced commit is triggered from.
    private func persist() throws {
        guard let vaultKey, let current = file else { throw CredentialVaultStoreError.locked }
        let entries = try credentials.map { credential in
            CredentialVaultFile.Entry(
                id: credential.id,
                payload: try CredentialVaultCrypto.seal(credential,
                                                        vaultKey: vaultKey,
                                                        purpose: CredentialVaultCrypto.itemPurpose(credential.id))
            )
        }
        var updated = current
        updated.formatVersion = CredentialVaultFile.currentFormatVersion
        updated.items = entries
        updated.auditLog = try CredentialVaultCrypto.seal(auditLog, vaultKey: vaultKey, purpose: Self.auditPurpose)
        updated.settings = try CredentialVaultCrypto.seal(settings, vaultKey: vaultKey, purpose: Self.settingsPurpose)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        try AtomicWrite.data(data, to: fileURL)
        file = updated
    }

    /// Persist a write whose *outcome the caller does not branch on* - an
    /// unlock/lock/sync audit event. GL-10's rule still applies: the failure is
    /// reported rather than swallowed by a `try?`, which is what three call
    /// sites here originally did. It deliberately returns nothing: an unlock
    /// must not fail because its own audit event could not be written.
    private func persistAuditOnly(_ what: String) {
        do {
            try persist()
            PersistenceFailureReporter.reportSuccess()
            gitSync?.markDirty()
        } catch {
            PersistenceFailureReporter.report(what: "the credential vault's \(what)",
                                              path: fileURL.path, error: error)
        }
    }

    /// GL-10/GL-30: a write that fails is reported, never swallowed. The
    /// in-memory model deliberately keeps the change so the captain can retry
    /// rather than losing the edit twice.
    private func finishWrite<T>(returning value: T) -> Result<T, Error> {
        do {
            try persist()
            PersistenceFailureReporter.reportSuccess()
            gitSync?.markDirty()
            onChange?()
            return .success(value)
        } catch {
            PersistenceFailureReporter.report(what: "the credential vault", path: fileURL.path, error: error)
            onChange?()
            return .failure(error)
        }
    }

    /// Which fields differ, by name. Never a value - see `update`.
    private static func changedFieldNames(from before: VaultCredential, to after: VaultCredential) -> String? {
        var changed: [String] = []
        if before.title != after.title { changed.append("title") }
        if before.category != after.category { changed.append("category") }
        if before.account != after.account { changed.append("account") }
        if before.secret != after.secret { changed.append("secret value") }
        if before.location != after.location { changed.append("location") }
        if before.tags != after.tags { changed.append("tags") }
        if before.notes != after.notes { changed.append("notes") }
        if before.requiresTouchIDToReveal != after.requiresTouchIDToReveal { changed.append("Touch ID gate") }
        return changed.isEmpty ? nil : changed.joined(separator: ", ")
    }

    #if FM_SELFTESTS
    /// The raw bytes on disk, so a suite can grep the real file for a planted
    /// secret rather than reasoning about whether the format encrypts it. The
    /// only honest way to assert "nothing readable leaks", and the same
    /// technique `BackupSelfTest` uses for the `.glbackup` bundle.
    func rawFileBytesForTests() -> Data? { try? Data(contentsOf: fileURL) }

    /// Force the throttle, so the escalating-delay branch can be driven without
    /// five real PBKDF2 rounds.
    func setFailedAttemptsForTests(_ count: Int) { failedAttempts = count }
    var failedAttemptsForTests: Int { failedAttempts }
    #endif
}

enum CredentialVaultStoreError: LocalizedError, Equatable {
    case locked
    case notFound
    case duplicate
    case vaultAlreadyExists

    var errorDescription: String? {
        switch self {
        case .locked: return "The vault is locked."
        case .notFound: return "That credential is no longer in the vault."
        case .duplicate: return "That credential is already in the vault."
        case .vaultAlreadyExists: return "A vault already exists here. Unlock it instead of creating a new one."
        }
    }
}
