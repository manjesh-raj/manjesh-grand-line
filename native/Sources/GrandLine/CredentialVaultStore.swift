// Grand Line - native macOS app.
//
// The credential vault's store: the encrypted file, the unlock/lock state
// machine, CRUD, the audit log and the settings. The one place any of those
// touch disk.
//
// **Where the file actually lives.** Two copies of one format, which is the
// whole portability story:
//
//   * locally, `~/Library/Application Support/GrandLine/grand-line-vault/vault.enc.json`
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
    ///
    /// **Live-session only** - see `attemptsBeforeThrottle`'s own note for the
    /// scope this deliberately does and does not claim.
    case throttled(retryAfter: TimeInterval)
    /// The file exists but could not be read or decoded. Never treated as
    /// "start a fresh vault" - see `LoadState`.
    case unreadable(String)
    case noVaultYet
    case failed(String)
    /// The Touch ID key this Mac has stored no longer opens this vault file.
    ///
    /// Review #3's B17. Kept apart from `wrongPassword` because it is not one:
    /// nothing was typed, so there is nothing for the captain to have got
    /// wrong, and the honest next step ("unlock with your password") is the
    /// opposite of the one `wrongPassword` implies. Counting it as a failed
    /// attempt also throttled the *password* path after five taps of a Touch
    /// ID button that could never have worked - a captain locked out of their
    /// own credentials by a key they never chose to use.
    ///
    /// The realistic way to get here is the one this vault is built for: the
    /// file is git-synced, the vault was re-keyed on another Mac, and the
    /// re-keyed file arrived here while this Mac's Keychain still holds the
    /// old derived key (`changeMasterPassword` removes the stored key on the
    /// Mac it runs on, and has no reach into any other).
    case staleTouchIDKey
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
    ///
    /// `didSet` drops PF7's seal cache: every cached ciphertext was produced
    /// with the key that is being replaced, so carrying one across a re-key
    /// (or across a lock) would write an item the new key cannot open. The
    /// cache is therefore invalidated by the one thing that can invalidate it,
    /// at the one place that thing happens.
    private var vaultKey: CredentialVaultKey? {
        didSet { sealedItemCache.removeAll(); sealedSettings = nil }
    }

    // MARK: PF7 - re-seal only what changed
    //
    // PF7 of the 2026-09-25 full review: `persist()` re-sealed **every**
    // credential on every mutation, and every mutation includes the audit-only
    // flush that a reveal, a copy or a lock schedules. Adding one credential to
    // a vault of two hundred did two hundred AES-GCM seals on the main thread;
    // so did unlocking and locking it again.
    //
    // A credential's ciphertext depends on exactly two things: the plaintext
    // and the key. `VaultCredential` is `Equatable`, so an entry whose
    // plaintext is byte-identical to the one this cache was built from can
    // reuse its payload, and the key half is handled by the `didSet` above.
    // Nothing is cached across a process, so a stale cache cannot outlive the
    // session that built it.
    //
    // **What must not happen is a lost edit**, which is why the cache is keyed
    // on the credential's whole value rather than on its id or its
    // `updatedAt`: a mutation that changes any field at all misses, and a miss
    // re-seals. `checkARapidSequenceOfEditsAllPersist` in
    // `CredentialVaultSelfTest` is the standing guard.
    private var sealedItemCache: [String: (credential: VaultCredential, payload: Data)] = [:]
    /// The same idea for the settings blob, which is re-sealed on every write
    /// and changes on almost none of them.
    private var sealedSettings: (settings: VaultSettings, payload: Data)?

    #if FM_SELFTESTS
    /// How many item seals this store has actually performed, so a suite can
    /// prove PF7's cache is doing something rather than only that the data
    /// still round-trips.
    private(set) var debugItemSealCount = 0
    func debugResetItemSealCount() { debugItemSealCount = 0 }
    #endif
    private var file: CredentialVaultFile?

    /// The decrypted credentials as of the last successful load or write -
    /// i.e. what this machine believes is *also* on disk right now.
    ///
    /// Full review #3's **S2**. `credentials` is what the captain has in
    /// front of them and `file` is the sealed snapshot it came from, but
    /// neither answers the question a write actually has to ask: "of the
    /// differences between memory and disk, which are *mine*?" Without a
    /// third, pristine copy there is no way to tell a credential this machine
    /// deleted from one another machine added, so the only available
    /// behaviours were "always overwrite" (the bug) or "always reload" (which
    /// would throw away the captain's own edit instead). See
    /// `adoptOnDiskChangesIfNeeded`.
    private var baseline: [VaultCredential] = []

    /// S2: a scheduled flush of audit-only state (reveal/copy timestamps).
    /// Nil when nothing is pending. See `recordUse`.
    private var pendingAuditFlush: DispatchWorkItem?

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
    ///
    /// **Scope, stated rather than left to be assumed: this is a live-session
    /// speed bump, not a persistent control.** Both counters below are
    /// in-memory, so quitting and relaunching resets them - the end-to-end
    /// review's L4 finding. It is recorded here rather than fixed, and the
    /// reasoning is worth keeping so nobody "completes" it by accident:
    ///
    ///   * The only place this store keeps *cleartext* metadata is the vault
    ///     file's own header (`kdf`/`verifier`) - and that file is committed
    ///     and pushed to `manjesh-config` on every change. Persisting the
    ///     throttle there would publish a failed-attempt count and timestamp
    ///     to a git host in cleartext, against the posture `settings`' own
    ///     comment states ("'auto-lock is off' is itself a fact worth not
    ///     publishing to a git host"), and would produce a commit **and a
    ///     push** on every mistyped password.
    ///   * It cannot go in the encrypted `settings` blob instead: sealing that
    ///     needs the vault key, which a *failed* unlock by definition does not
    ///     have.
    ///   * A separate local sidecar avoids both, but is trivially deleted by
    ///     anyone who can reach the file - so it would not make this a control
    ///     either, while adding a new persisted file, its own GL-01 load-
    ///     failure handling, an `FM_*` override and a `main.swift` self-test
    ///     redirect entry.
    ///
    /// And the reason none of that is worth it: an attacker with the file does
    /// not use this code path at all - they run PBKDF2 against the ciphertext
    /// offline, where no in-app delay exists to hit. What the throttle
    /// genuinely buys is stopping a *shoulder-surfing* guesser at a live,
    /// already-unlocked-and-relocked Mac, and that is exactly a live session.
    /// If it should ever become a real control, the honest version is a
    /// deliberately slower KDF (the rounds are already in the file and
    /// tunable), not a counter.
    static let attemptsBeforeThrottle = 5
    /// In-memory by design - see the note above.
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
        Self.createVaultRoot(root)
    }

    /// An explicit root, for self-tests and for any future caller that wants a
    /// vault somewhere specific. Never reaches git sync.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        Self.createVaultRoot(root)
    }

    /// Create the vault's own directory at 0700 (M3), and tighten it if an
    /// earlier version of this app already made it 0755.
    ///
    /// Only ever the vault's *own* leaf directory. The
    /// `withIntermediateDirectories` parents are deliberately left alone: on
    /// the git-synced path they are the captain's config clone and its working
    /// tree, which other tooling (`rebuild.sh`, git itself) reaches into, and
    /// narrowing somebody else's directory is not this store's call to make.
    ///
    /// It uses `try?` where one caller previously used `try` inside a
    /// `do`/`catch`. That caller (`adoptLocalOnlyVaultIfNeeded`) still reports
    /// the same failure the same way: if the directory genuinely could not be
    /// made, the `moveItem` on the very next line throws into the same catch.
    private static func createVaultRoot(_ root: URL) {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: SensitiveFile.directoryMode]
        )
        SensitiveFile.restrictDirectory(root)
    }

    /// The local-only fallback path, used before a clone exists. Resolved the
    /// same way every sibling store resolves its own (`HostStore`,
    /// `DictationStore`, `FleetLogStore`, ...) - there is no shared helper for
    /// it in this codebase, so this matches the established shape rather than
    /// introducing one for a single caller.
    static var applicationSupportRoot: URL {
        return AppPaths.dataRoot()
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
            Self.createVaultRoot(root)
            try fm.moveItem(at: localFile, to: repoFile)
            // A move carries the source file's own mode across, which for a
            // vault written by a pre-M3 build is 0644.
            SensitiveFile.restrict(repoFile)
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
            baseline = []
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
                completion(self.finishUnlock(loaded, file: onDisk, method: "Touch ID",
                                             keyCameFromKeychain: true))
            }
        }
    }

    private func finishUnlock(_ derived: Result<CredentialVaultKey, Error>,
                              file onDisk: CredentialVaultFile,
                              method: String,
                              keyCameFromKeychain: Bool = false) -> VaultUnlockOutcome {
        switch derived {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let key):
            guard CredentialVaultCrypto.verifierOpens(onDisk.verifier, with: key) else {
                // B17: a stored key that no longer matches is a stale key, not
                // a wrong password - so it is reported as one, it is removed
                // (it can never open this file again, and leaving it there
                // means the same dead end on every later tap), and it is
                // **not** counted. `failedAttempts` and the throttle it drives
                // exist to slow down guessing at the password, and nothing was
                // guessed here.
                if keyCameFromKeychain {
                    CredentialVaultKeyStore.remove()
                    AppLog.keychain.error("credential vault: the stored Touch ID key no longer opens this vault - removed it")
                    return .staleTouchIDKey
                }
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
                // S2: memory and disk agree at this instant, which is what
                // makes this the reference point every later write's merge is
                // measured against.
                baseline = items
                auditLog = log
                settings = loadedSettings
                failedAttempts = 0
                throttledUntil = nil
                append(.init(kind: .unlocked, detail: method))
                // A one-time, idempotent migration for a file predating
                // `sortOrder` - see its own doc comment. `persistAuditOnly`
                // right below always re-seals every credential from current
                // in-memory state regardless, so this needs no write of its
                // own.
                normalizeSortOrderIfNeeded()
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
        // S2: any reveal/copy timestamps still waiting on the debounce are
        // written here rather than dropped. They ride the same `persist` the
        // lock record does, so batching costs the audit trail nothing - a
        // lock is the one event guaranteed to follow every use.
        pendingAuditFlush?.cancel()
        pendingAuditFlush = nil
        append(.init(kind: .locked, detail: reason))
        persistAuditOnly("lock record")
        vaultKey = nil
        // F17: the recovery-unlock flag is a property of the *session*, not
        // of the vault. Leaving it set across a lock would let the next
        // ordinary password unlock re-key without proving the old password,
        // which is precisely what `resetMasterPasswordAfterRecovery`'s gate
        // exists to prevent.
        unlockedViaRecoveryKey = false
        file = nil
        credentials = []
        baseline = []
        auditLog = []
        settings = .default
        // M1: run the guarded clear rather than abandoning it.
        //
        // This used to call `abandonPendingClear()`, on the reasoning that a
        // locked vault has no business reaching into a pasteboard the captain
        // may since have filled from elsewhere. That concern is real and it is
        // *already* handled - one level down, and better: `clearIfUntouched`
        // no-ops unless `changeCount` still reports this app's own copy, so it
        // physically cannot clear somebody else's clipboard content.
        //
        // Abandoning instead had the exact inverted effect: copy a secret, lock
        // within the clear window, and the pending clear was cancelled while
        // the secret stayed on the pasteboard until something else happened to
        // overwrite it. Locking - the one action whose entire purpose is to
        // stop disclosing secrets - made the clipboard *less* safe than not
        // locking at all.
        CredentialVaultClipboard.shared.clearNow()
        onChange?()
    }

    // MARK: CRUD

    @discardableResult
    func add(_ credential: VaultCredential) -> Result<VaultCredential, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        var stored = credential
        stored.createdAt = Date()
        stored.updatedAt = stored.createdAt
        // Append to the end of its category rather than inheriting whatever
        // `sortOrder` the caller's struct happened to carry (`0`, its
        // default) - which would otherwise jump a brand-new item ahead of
        // every credential already given a real, positive position.
        stored.sortOrder = nextSortOrder(inCategory: stored.category)
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
        // The editor form has no way to move a credential's own position -
        // that is drag-and-drop's job alone (`reorderCategory`) - so an
        // ordinary edit must not silently reset it to whatever the caller's
        // struct happened to carry. A category *change* is the one
        // legitimate exception: the old position was scoped to a group this
        // credential no longer belongs to, so it is re-appended to the end
        // of its new category, exactly like a brand-new credential.
        stored.sortOrder = (before.category == stored.category)
            ? before.sortOrder
            : nextSortOrder(inCategory: stored.category)
        credentials[index] = stored
        append(.init(kind: .updated,
                     itemID: stored.id,
                     itemTitle: stored.title,
                     detail: Self.changedFieldNames(from: before, to: stored)))
        return finishWrite(returning: stored)
    }

    /// The `sortOrder` a fresh arrival in `category` should take - one past
    /// whatever is currently the highest position there, so it lands at the
    /// end rather than at the front on `VaultCredential.sortOrder`'s zero
    /// default. Shared by `add` (a brand-new credential) and `update` (one
    /// whose category changed).
    private func nextSortOrder(inCategory category: CredentialCategory) -> Int {
        (credentials.filter { $0.category == category }.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Persist a captain-driven manual reorder within one category:
    /// `orderedIDs` is the complete, desired order for every credential
    /// currently in `category`, and each is assigned a fresh sequential
    /// `sortOrder` matching its position - which is what makes the new order
    /// stick across a relaunch rather than being a purely visual
    /// rearrangement. The captain's own words: "I need that freedom to
    /// rearrange... I should be able to sort anything irrespective of
    /// whether it's created first or last."
    ///
    /// An id not currently in `category` is skipped rather than moved there -
    /// this method reorders, it never re-categorises. That should not
    /// happen given how `CredentialVaultController` builds `orderedIDs` (from
    /// the credential's own category, never a caller-picked one), but a
    /// defensive no-op is cheap and matches this store's usual style.
    @discardableResult
    func reorderCategory(_ category: CredentialCategory, orderedIDs: [String]) -> Result<Void, Error> {
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        var changed = false
        for (position, id) in orderedIDs.enumerated() {
            guard let index = credentials.firstIndex(where: { $0.id == id }),
                  credentials[index].category == category else { continue }
            if credentials[index].sortOrder != position {
                credentials[index].sortOrder = position
                changed = true
            }
        }
        // Dropping a position back where it already was (or a drag that
        // landed exactly where it started) must not be a reason to write and
        // sync - the same "only write on a real change" discipline every
        // other mutator here already follows via `finishWrite`'s callers.
        guard changed else { return .success(()) }
        return finishWrite(returning: ())
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
        // S2: **not** `finishWrite`. Looking at a credential is not a change
        // to it, and treating it as one cost two things that both matter:
        //
        //  - Every reveal and every copy rewrote and re-sealed the entire
        //    file and then told the git sync to commit and push. The commit
        //    timestamps on the git host therefore recorded *when the captain
        //    looked at a credential* - metadata the vault's whole design goes
        //    out of its way not to leak, published to a remote.
        //  - Each of those writes was also a full-file overwrite from memory,
        //    which is the exact shape of the data-loss path above. Reveal and
        //    copy are the two most frequent actions in this feature, so they
        //    were also the most frequent chance to hit it.
        //
        // The timestamp still reaches disk - an audit trail that only
        // survived while the window stayed open would not be one - just
        // batched, and never by itself a reason to commit. `lock()` flushes
        // whatever is still pending, and a lock always follows a use.
        onChange?()
        scheduleAuditFlush()
    }

    /// How long reveal/copy bookkeeping waits before it is written. Long
    /// enough that a captain working through several credentials produces one
    /// write rather than a dozen, short enough that a hard kill loses at most
    /// a few seconds of "last used" timestamps - which is the least valuable
    /// state in this store, and the only state batching can lose.
    static let auditFlushDelay: TimeInterval = 20

    /// Coalesce audit-only writes. Re-arming on each use is deliberate: a run
    /// of reveals inside the window settles into one write at the end of it.
    private func scheduleAuditFlush() {
        pendingAuditFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isUnlocked else { return }
            self.pendingAuditFlush = nil
            self.persistAuditOnly("use record")
        }
        pendingAuditFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.auditFlushDelay, execute: work)
    }

    /// Write any pending audit-only state now. Test seam, and the hook a
    /// future terminate-time flush would use - `lock()` covers the real app's
    /// path today, since the vault is always locked before the key is
    /// dropped.
    func flushPendingAuditWritesNow() {
        guard pendingAuditFlush != nil, isUnlocked else { return }
        pendingAuditFlush?.cancel()
        pendingAuditFlush = nil
        persistAuditOnly("use record")
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
        vaultKey = newKey
        file = CredentialVaultFile(kdf: .init(salt: newSalt),
                                   // Sealed on the background queue with
                                   // the derivations - it is a pure
                                   // function of `newKey`.
                                   verifier: rekey.newVerifier,
                                   items: [],
                                   auditLog: Data(),
                                   settings: Data(),
                                   // F17: `recovery` is deliberately left
                                   // nil. The old wrap holds the OLD vault
                                   // key's bytes, and every payload is about
                                   // to be re-sealed under the new one - so
                                   // unwrapping it would hand back a key
                                   // that opens nothing, which is a far
                                   // worse outcome than "your recovery key
                                   // no longer works". It cannot be re-
                                   // wrapped either: the code was shown once
                                   // and is not stored anywhere (see
                                   // `CredentialVaultRecovery`'s header), so
                                   // the app does not have it. The Settings
                                   // sheet says a new kit must be printed.
                                   recovery: nil)
        append(.init(kind: .passwordChanged))
        // Any stored Touch ID key was the *old* derived key and no longer
        // opens anything - forgetting it is correctness, not tidiness.
        let hadStoredKey = CredentialVaultKeyStore.hasStoredKey
        if hadStoredKey {
            CredentialVaultKeyStore.remove()
            settings.touchIDUnlockEnabled = false
        }
        do {
            // `adoptingOnDiskChanges: false` - see `persist`'s own parameter
            // note. A re-key replaces the header this write is measured
            // against, and this method already did the narrower salt check
            // above.
            try persist(adoptingOnDiskChanges: false)
        } catch {
            vaultKey = previousKey
            file = previousFile
            if !auditLog.isEmpty { auditLog.removeLast() }
            PersistenceFailureReporter.report(what: "the credential vault's new master password",
                                              path: fileURL.path, error: error)
            // The Keychain key is deliberately NOT restored: it was removed
            // because the *old* derived key is the one it held, and this
            // code no longer has that key to write back. Re-enabling Touch
            // ID is one toggle, and a stale key that opens nothing would be
            // worse than none.
            //
            // **Which is exactly why the flag is forced off rather than
            // rolled back** - the review's L5 finding. This used to restore
            // the pre-change value, so a rollback with Touch ID previously on
            // left `touchIDUnlockEnabled == true` with no Keychain key behind
            // it: the Settings toggle read "on" while the unlock button did
            // nothing, until the captain happened to cycle it. The key is
            // gone either way, so `false` is the only value that describes
            // what is actually on this machine. `previousTouchID` is gone
            // with it - there is no state left for it to restore.
            settings.touchIDUnlockEnabled = false
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

    // MARK: Recovery key (F17)

    /// Whether this vault carries a printable recovery key. Read by the
    /// Recovery & import sheet to decide between "print one" and "replace
    /// the one you have".
    var hasRecoveryKey: Bool { file?.recovery != nil }

    /// Whether the file **on disk** carries a recovery wrap, readable while
    /// the vault is locked - which is the only moment it matters, since the
    /// unlock screen has to decide whether to offer that door at all.
    ///
    /// Decodes the file rather than consulting `file` (nil while locked).
    /// That costs a JSON parse of a few tens of kilobytes, and it is only
    /// called from the locked branch of the page's `render()`, so it is not
    /// on any hot path. It reads only the cleartext header - no key is
    /// involved and nothing is decrypted.
    var recoveryKeyExistsOnDisk: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let onDisk = try? JSONDecoder().decode(CredentialVaultFile.self, from: data) else { return false }
        return onDisk.recovery != nil
    }

    /// When the current kit was created, for the printed card's own
    /// provenance line.
    var recoveryKeyCreatedAt: Date? { file?.recovery?.createdAt }

    /// Print a new recovery kit: generate a code, wrap this session's vault
    /// key under it, and persist the wrap.
    ///
    /// Returns the code **once**. Nothing stores it - not this object, not
    /// the Keychain, not the file (which holds only the salt, the round count
    /// and the sealed box). A caller that loses it before the captain writes
    /// it down must enrol again, which is why the sheet renders it before
    /// offering anything else.
    ///
    /// Synchronous, unlike `unlock`/`changeMasterPassword`: it runs exactly
    /// one PBKDF2 derivation, the captain has already pressed a button that
    /// says "print", and the sheet shows a progress state around the call.
    /// Enrolling replaces any existing wrap, which is the honest meaning of
    /// printing a new kit - the old printout stops working, and the sheet
    /// says so before this is called.
    func enrollRecoveryKey() -> Result<String, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let vaultKey, file != nil else { return .failure(CredentialVaultStoreError.locked) }
        let code = CredentialVaultRecovery.newCode()
        do {
            let wrap = try CredentialVaultRecovery.wrap(vaultKey: vaultKey, code: code)
            let previous = file?.recovery
            file?.recovery = wrap
            append(.init(kind: .recoveryKeyPrinted))
            do {
                try persist()
            } catch {
                // All-or-nothing, the same shape `finishPasswordChange`
                // uses: a wrap held in memory but not on disk would let the
                // captain file a printout that the next launch does not
                // honour.
                file?.recovery = previous
                if !auditLog.isEmpty { auditLog.removeLast() }
                PersistenceFailureReporter.report(what: "the credential vault's recovery key",
                                                  path: fileURL.path, error: error)
                return .failure(error)
            }
            gitSync?.markDirty()
            onChange?()
            return .success(code)
        } catch {
            return .failure(error)
        }
    }

    /// Forget the recovery key. The printout stops working immediately.
    @discardableResult
    func removeRecoveryKey() -> Result<Void, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isUnlocked, file?.recovery != nil else { return .failure(CredentialVaultStoreError.locked) }
        let previous = file?.recovery
        file?.recovery = nil
        append(.init(kind: .recoveryKeyRemoved))
        do {
            try persist()
        } catch {
            file?.recovery = previous
            if !auditLog.isEmpty { auditLog.removeLast() }
            PersistenceFailureReporter.report(what: "the credential vault's recovery key",
                                              path: fileURL.path, error: error)
            return .failure(error)
        }
        gitSync?.markDirty()
        onChange?()
        return .success(())
    }

    /// Unlock with a printed recovery key instead of the master password.
    ///
    /// Runs the unwrap's PBKDF2 off the main thread and finishes through
    /// `finishUnlock`, exactly like the password and Touch ID paths - so the
    /// verifier check, the audit record and the throttle behave identically
    /// however the vault was opened. A wrong code counts as a failed attempt
    /// for the same reason a wrong password does: it is a guess.
    func unlockWithRecoveryKey(_ code: String, completion: @escaping (VaultUnlockOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
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
        guard let wrap = onDisk.recovery else {
            completion(.failed(CredentialVaultRecoveryError.noRecoveryKeyEnrolled.localizedDescription))
            return
        }
        guard CredentialVaultRecovery.looksWellFormed(code) else {
            // Not counted as an attempt: nothing was guessed, the string is
            // simply not a recovery key. `.staleTouchIDKey`'s own reasoning.
            completion(.failed(CredentialVaultRecoveryError.malformedRecoveryKey.localizedDescription))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recovered: Result<CredentialVaultKey, Error>
            do {
                recovered = .success(try CredentialVaultRecovery.unwrap(wrap, code: code, vaultSalt: onDisk.kdf.salt))
            } catch {
                recovered = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = recovered {
                    // A wrong code fails the unwrap rather than the
                    // verifier, so it never reaches `finishUnlock`'s own
                    // counting branch - counted here instead, so the
                    // throttle covers this door too.
                    if case CredentialVaultRecoveryError.wrongRecoveryKey = error {
                        completion(self.countFailedAttempt())
                        return
                    }
                    completion(.failed(error.localizedDescription))
                    return
                }
                self.unlockedViaRecoveryKey = true
                let outcome = self.finishUnlock(recovered, file: onDisk, method: "recovery key")
                if case .unlocked = outcome {} else { self.unlockedViaRecoveryKey = false }
                completion(outcome)
            }
        }
    }

    /// Whether the current session was opened with the recovery key rather
    /// than the master password. Cleared by `lock`.
    ///
    /// The one thing it gates is `resetMasterPasswordAfterRecovery` - see
    /// that method for why a normal unlocked session must not be able to
    /// re-key without the current password.
    private(set) var unlockedViaRecoveryKey = false

    /// Set a new master password on a session opened with the recovery key.
    ///
    /// A captain who recovered this way does not know the old password by
    /// definition, so `changeMasterPassword`'s "prove you know the current
    /// one" precondition cannot be met - and leaving the vault openable only
    /// by a printed sheet of paper is not a resting state. This is the exit.
    ///
    /// **Gated on `unlockedViaRecoveryKey`, and that gate is the whole
    /// security argument.** Without it, this would be "any unlocked vault can
    /// be re-keyed without the old password", which weakens every session -
    /// an unattended unlocked window could be permanently taken over. With
    /// it, the caller has already proven possession of a 160-bit secret, so
    /// this is exactly as strong as the password path.
    ///
    /// The re-key drops the recovery wrap like any other password change
    /// (`finishPasswordChange`), so the printout the captain just used stops
    /// working and the sheet asks them to print a new one.
    func resetMasterPasswordAfterRecovery(newPassword: String,
                                          completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard unlockedViaRecoveryKey, isUnlocked, let onDisk = file else {
            completion(.failure(CredentialVaultStoreError.locked))
            return
        }
        guard let currentKey = vaultKey else {
            completion(.failure(CredentialVaultStoreError.locked))
            return
        }
        let kdf = onDisk.kdf
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let derived: Result<DerivedRekey, Error>
            do {
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
                let result = self.finishPasswordChange(derived, derivedAgainstSalt: kdf.salt)
                if case .success = result { self.unlockedViaRecoveryKey = false }
                completion(result)
            }
        }
    }

    /// The failed-attempt bookkeeping `finishUnlock` does inline, reachable
    /// from the recovery path (which fails before the verifier is ever
    /// consulted). One copy, so the two doors cannot end up with two
    /// different throttles.
    private func countFailedAttempt() -> VaultUnlockOutcome {
        failedAttempts += 1
        guard failedAttempts >= Self.attemptsBeforeThrottle else {
            return .wrongPassword(attemptsUntilDelay: Self.attemptsBeforeThrottle - failedAttempts)
        }
        let over = failedAttempts - Self.attemptsBeforeThrottle
        let delay = min(Self.maxThrottleSeconds, 30.0 * pow(2.0, Double(over)))
        throttledUntil = Date().addingTimeInterval(delay)
        AppLog.keychain.error("credential vault: \(self.failedAttempts, privacy: .public) failed unlock attempts - delaying \(Int(delay), privacy: .public)s")
        return .throttled(retryAfter: delay)
    }

    // MARK: Import (F17)

    /// Write a planned CSV import into the vault.
    ///
    /// Every record goes through the same `persist()` every manually-added
    /// credential does, so each one is sealed under its own per-item HKDF
    /// subkey before anything reaches disk - there is no bulk path, no
    /// staging file and no unencrypted intermediate. One write for the whole
    /// batch rather than one per row, because 148 separate re-seals of the
    /// whole file is 148 git-dirty marks for one action.
    ///
    /// `merging` decides what a duplicate (same title and account) does:
    /// `true` updates the existing record's secret in place, `false` adds a
    /// second one. Never silently either - the sheet asks.
    @discardableResult
    func importCredentials(_ incoming: [VaultCredential], merging: Bool) -> Result<Int, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isUnlocked else { return .failure(CredentialVaultStoreError.locked) }
        guard !incoming.isEmpty else { return .success(0) }

        var written = 0
        for var candidate in incoming {
            let existingIndex = credentials.firstIndex {
                $0.title.lowercased() == candidate.title.lowercased()
                    && $0.account.lowercased() == candidate.account.lowercased()
            }
            if let existingIndex, merging {
                var merged = credentials[existingIndex]
                merged.secret = candidate.secret
                if merged.location.isEmpty { merged.location = candidate.location }
                if merged.notes.isEmpty { merged.notes = candidate.notes }
                if merged.totp == nil { merged.totp = candidate.totp }
                merged.tags = Array(Set(merged.tags + candidate.tags)).sorted()
                merged.updatedAt = Date()
                credentials[existingIndex] = merged
                append(.init(kind: .updated, itemID: merged.id, itemTitle: merged.title, detail: "imported"))
            } else {
                candidate.sortOrder = nextSortOrder(inCategory: candidate.category)
                credentials.append(candidate)
                append(.init(kind: .created, itemID: candidate.id, itemTitle: candidate.title, detail: "imported"))
            }
            written += 1
        }
        return finishWrite(returning: written)
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

    /// One-time migration for a vault written before `sortOrder` existed -
    /// see `VaultCredential.sortOrder`'s own doc comment for why this must
    /// not reshuffle anything. Every credential in such a file decodes with
    /// `sortOrder == 0` (rule 2's `decodeIfPresent` fallback), so within any
    /// one category every item is a dead tie and `displayOrder`'s
    /// alphabetical tiebreak already reproduces the exact order the list
    /// showed before this field existed. This assigns each item that same
    /// order as its own real, distinct position, so the captain's very first
    /// drag has real integers to move rather than a field of zeroes.
    ///
    /// A pure in-memory mutation - `finishUnlock`'s own `persistAuditOnly`
    /// call right after this is what actually writes the result, since
    /// `persist()` always re-seals every credential from current state
    /// regardless of what changed. Idempotent: once a category's positions
    /// are already distinct (from this pass, or from a captain's own
    /// drag), re-running it recomputes the identical positions and changes
    /// nothing - so calling it on every unlock never itself triggers a write.
    private func normalizeSortOrderIfNeeded() {
        for category in CredentialCategory.allCases {
            let indices = credentials.indices
                .filter { credentials[$0].category == category }
                .sorted { VaultCredential.displayOrder(credentials[$0], credentials[$1]) }
            for (position, index) in indices.enumerated() where credentials[index].sortOrder != position {
                credentials[index].sortOrder = position
            }
        }
    }

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
    ///
    /// - Parameter adoptingOnDiskChanges: whether to reconcile with whatever
    ///   is on disk first (S2). Only `finishPasswordChange` passes `false`,
    ///   and it has to: a re-key deliberately replaces the KDF header and
    ///   verifier this machine is holding, so from the adoption logic's point
    ///   of view the file it is about to write looks exactly like the "a
    ///   different password was set elsewhere" case it exists to refuse.
    ///   That path does its own drift check by salt, which is the older and
    ///   narrower version of this one.
    private func persist(adoptingOnDiskChanges: Bool = true) throws {
        guard let vaultKey, let current = file else { throw CredentialVaultStoreError.locked }
        let base = adoptingOnDiskChanges
            ? try adoptOnDiskChangesIfNeeded(vaultKey: vaultKey, lastKnown: current)
            : current
        // PF7: re-seal only the credentials whose plaintext actually changed.
        let entries = try credentials.map { credential -> CredentialVaultFile.Entry in
            if let cached = sealedItemCache[credential.id], cached.credential == credential {
                return CredentialVaultFile.Entry(id: credential.id, payload: cached.payload)
            }
            let payload = try CredentialVaultCrypto.seal(
                credential,
                vaultKey: vaultKey,
                purpose: CredentialVaultCrypto.itemPurpose(credential.id))
            #if FM_SELFTESTS
            debugItemSealCount += 1
            #endif
            sealedItemCache[credential.id] = (credential, payload)
            return CredentialVaultFile.Entry(id: credential.id, payload: payload)
        }
        // A deleted credential must not keep its ciphertext alive in memory.
        let liveIDs = Set(credentials.map(\.id))
        sealedItemCache = sealedItemCache.filter { liveIDs.contains($0.key) }
        var updated = base
        updated.formatVersion = CredentialVaultFile.currentFormatVersion
        // F17: the recovery wrap is neither an item nor a header the merge
        // reasons about, so it has to be carried forward by hand or a write
        // that adopted on-disk changes would silently discard an enrolment
        // this session just made. In-memory wins when it has one (this Mac
        // just printed a kit), on-disk otherwise (another Mac did). Both
        // wraps hold the *same* vault key - the key is unchanged by
        // enrolment - so either is correct; what must never happen is
        // ending up with none.
        updated.recovery = current.recovery ?? base.recovery
        updated.items = entries
        updated.auditLog = try CredentialVaultCrypto.seal(auditLog, vaultKey: vaultKey, purpose: Self.auditPurpose)
        // PF7 again: the settings blob changes on almost no write.
        if let cachedSettings = sealedSettings, cachedSettings.settings == settings {
            updated.settings = cachedSettings.payload
        } else {
            let payload = try CredentialVaultCrypto.seal(settings, vaultKey: vaultKey, purpose: Self.settingsPurpose)
            sealedSettings = (settings, payload)
            updated.settings = payload
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        // M3: 0600/0700. The item payloads, the audit log and the settings are
        // all AES-GCM sealed, but the KDF descriptor beside them (salt, round
        // count, algorithm) is cleartext by necessity - a legitimate unlock
        // needs it to derive the key at all - and handing that plus the
        // ciphertext to every other local account is an offline brute-force
        // starter kit rather than a defensible default.
        try AtomicWrite.data(data, to: fileURL, sensitive: true)
        file = updated
        // Memory and disk agree again, so this is the new "what is also on
        // disk" for the next write's three-way merge. Updated only after the
        // write actually succeeded - a failed write leaves the old baseline
        // in place, which is correct: disk still holds the old content.
        baseline = credentials
    }

    /// S2: reconcile with anything that changed the file underneath us, and
    /// return the header to build this write on top of.
    ///
    /// ## The bug this exists for
    ///
    /// `CredentialVaultSync` never pulls, but `ShiftGitSync.pullNow` does a
    /// whole-tree `merge --ff-only` every five minutes - which updates
    /// `vault.enc.json` on disk while `file`/`credentials` stay exactly as
    /// they were. Before this, every `persist()` rewrote the entire file from
    /// that stale memory. So: Mac A has the vault unlocked, Mac B adds a
    /// credential and pushes, A's pull fast-forwards, and A's five-minute
    /// **auto-lock** fires - `lock()` persists its audit record, the whole
    /// file is rewritten from A's stale set, and B's credential is gone from
    /// the live file. Silently, and recoverable only from git history.
    ///
    /// ## What it does instead
    ///
    /// A three-way merge against `baseline` - the decrypted set as of the
    /// last time memory and disk agreed. For each id:
    ///
    /// - on disk but not in `baseline`: **added elsewhere**, so take it.
    /// - in `baseline` but gone from disk: **deleted elsewhere**, and gone
    ///   from memory too, so nothing to do. Still in memory means this
    ///   machine has it open; keeping it is the safe direction, since a
    ///   credential wrongly kept is visible and deletable while one wrongly
    ///   dropped is not.
    /// - in both, and this machine did not touch it: take the on-disk
    ///   version.
    /// - in both, and both sides changed it: this machine's edit wins. It is
    ///   the one a human just made and is looking at, and the losing version
    ///   is still in git history. This is the only genuinely lossy case and
    ///   it is logged as such.
    ///
    /// A re-key elsewhere is **not** merged - see the `verifier` guard.
    private func adoptOnDiskChangesIfNeeded(vaultKey: CredentialVaultKey,
                                            lastKnown: CredentialVaultFile) throws -> CredentialVaultFile {
        guard let data = try? Data(contentsOf: fileURL),
              let onDisk = try? JSONDecoder().decode(CredentialVaultFile.self, from: data) else {
            // No file, or one this build cannot decode. Neither is this
            // write's call to interpret: GL-01's load path
            // (`StoreLoadFailure.decodeJSON`) is what backs an undecodable
            // vault up and reports it, and `createVault` is the legitimate
            // no-file case. Proceeding writes what we have, which is what
            // happened before this method existed.
            return lastKnown
        }
        guard onDisk.items != lastKnown.items else { return lastKnown }

        // The KDF header and verifier are untouched by an ordinary write
        // (`persist` copies them forward), so either one moving means a
        // *password change* landed from another machine. This machine's key
        // does not open that file, so every item in it would fail to
        // authenticate - there is nothing to merge, and writing anyway would
        // replace a vault we cannot read with one the other machine cannot.
        // Refusing is the only non-destructive answer.
        guard onDisk.kdf == lastKnown.kdf, onDisk.verifier == lastKnown.verifier else {
            AppLog.store.error("credential vault: the file on disk was re-keyed elsewhere - refusing to overwrite it")
            throw CredentialVaultStoreError.rekeyedElsewhere
        }

        // B19: the vault file is git-synced too, so a merge can leave two
        // records sharing an id. A trap here would be a crash on the *write*
        // path of the app's most security-sensitive store.
        var mine = Dictionary(credentials.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let base = Dictionary(baseline.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        // The order this machine already had, so a merge replaces *values*
        // without reshuffling the array. Anything genuinely new is appended.
        var order = credentials.map(\.id)
        var adopted = 0
        var conflicts = 0

        for entry in onDisk.items {
            guard let theirs = try? CredentialVaultCrypto.open(
                VaultCredential.self,
                from: entry.payload,
                vaultKey: vaultKey,
                purpose: CredentialVaultCrypto.itemPurpose(entry.id)) else {
                // An item that will not authenticate under a key that opened
                // the rest of the file. Skipping it keeps this machine's
                // write going rather than wedging the vault, and the item is
                // untouched on disk for the load path to report on.
                AppLog.store.error("credential vault: an item on disk did not authenticate during merge - left it alone")
                continue
            }
            let wasKnown = base[entry.id]
            if wasKnown == nil {
                // Added on another machine after our last agreement.
                if mine[entry.id] == nil {
                    adopted += 1
                    order.append(entry.id)
                }
                mine[entry.id] = theirs
            } else if let known = wasKnown, known == theirs {
                // They did not change it; whatever memory holds stands.
                continue
            } else if let ours = mine[entry.id], let known = wasKnown, ours == known {
                // They changed it and we did not.
                mine[entry.id] = theirs
                adopted += 1
            } else if mine[entry.id] != nil {
                // Both changed it. Ours wins, loudly.
                conflicts += 1
            } else {
                // We deleted it and they edited it. The delete is this
                // machine's explicit instruction, so honour it.
                continue
            }
        }

        if adopted > 0 || conflicts > 0 {
            AppLog.store.info("credential vault: the file changed under an unlocked vault - adopted \(adopted, privacy: .public) item(s), \(conflicts, privacy: .public) kept this machine's version")
        }
        credentials = order.compactMap { mine[$0] }
        return onDisk
    }

    /// Persist a write whose *outcome the caller does not branch on* - an
    /// unlock/lock/sync/use audit event. GL-10's rule still applies: the
    /// failure is reported rather than swallowed by a `try?`, which is what
    /// three call sites here originally did. It deliberately returns nothing:
    /// an unlock must not fail because its own audit event could not be
    /// written.
    ///
    /// **It does not `markDirty()`** (S2). Only a real credential mutation is
    /// a reason to commit and push: an audit event records something this
    /// machine *did*, and publishing each one to a git remote turns the
    /// commit log into a timeline of when the captain unlocked their vault
    /// and looked at which secret. The events are still durable - they are
    /// written to the file here, and ride the next real mutation's commit
    /// like any other content of it. `syncNow()` still pushes on demand,
    /// which is what that button is for.
    private func persistAuditOnly(_ what: String) {
        do {
            try persist()
            PersistenceFailureReporter.reportSuccess()
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
    /// S2: the file on disk carries a different KDF header or verifier than
    /// the one this machine unlocked, i.e. the master password was changed on
    /// another machine and pulled in underneath us. This machine's key opens
    /// nothing in that file, so there is no merge to do and overwriting would
    /// destroy it.
    case rekeyedElsewhere

    var errorDescription: String? {
        switch self {
        case .locked: return "The vault is locked."
        case .notFound: return "That credential is no longer in the vault."
        case .duplicate: return "That credential is already in the vault."
        case .vaultAlreadyExists: return "A vault already exists here. Unlock it instead of creating a new one."
        case .rekeyedElsewhere:
            return "The vault's master password was changed on another Mac. Lock and unlock this vault with the new password before saving."
        }
    }
}
