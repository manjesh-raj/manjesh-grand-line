// Manjesh Grand Line - native macOS app.
//
// The credential vault's portability: the encrypted file itself is committed
// and pushed into the captain's private `manjesh-config` clone, so a fresh
// install or a new Mac gets every credential back with no export/import step.
//
// **This is the requirement the existing Vault tab could not meet, and why the
// mechanism is different rather than merely renamed.** `VaultRecipeGit.swift`
// syncs Automic Vault's *recipe* - a list of secret names, zero values - and
// its own header records that a literal secret export was rejected earlier in
// this app's history as "recreating the exact plaintext-exfiltration risk
// Automic Vault exists to prevent". That judgement was right about plaintext
// and is not being overturned: what changed is that the bytes being pushed here
// are AES-256-GCM ciphertext under a key derived from a password that is never
// stored anywhere, so a leaked clone or a compromised GitHub account discloses
// exactly what a stolen powered-off laptop would - nothing. The encryption is
// what does the work, rather than the choice of what to omit.
//
// **This class is deliberately the fourth copy of a shape, not a new one.**
// `ShiftGitSync`, `DocsRunbookGitSync` and `StickyBoardGitSync` already do
// debounced-commit-and-push against one shared clone of `manjesh-config`, and
// this follows `DocsRunbookGitSync` almost line for line: the same shared
// working tree, the same shared serial queue (two independent queues issuing
// `git` against one working tree race on `.git/index.lock`), the same
// `ConfigRepoPrivacy` gate before any push, the same `Subprocess.git` runner
// and token injection.
//
// **The one real difference: the subpath.** `grand-line-vault-backup/`, at the
// repo root - a sibling of `automatic-vault-details-backup/`, not a child of
// `GrandLineDocs/`. That is the captain's explicit instruction from the live
// review ("the encrypted vault file lives in a new dedicated folder, not the
// existing `automatic-vault-details-backup` folder, which must stay
// untouched"), and it is also the honest layout: `GrandLineDocs/` is where this
// app's *documents* sync, and this is not a document.

import Foundation

final class CredentialVaultGitSync {

    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    /// The one place the repo-relative path lives. See this file's header for
    /// why it sits at the repo root rather than under `GrandLineDocs/`.
    static let vaultSubpath = "grand-line-vault-backup"

    /// The encrypted file's name, identical in the local Application Support
    /// copy and in the repo - one format, one filename, so "the same bytes
    /// arrived with the clone" is literally true.
    static let vaultFileName = "vault.enc.json"

    let workingTree: URL
    /// `<workingTree>/grand-line-vault-backup/` - the directory the store
    /// reads and writes when git sync is active.
    let dataRoot: URL

    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let sharesProductionWorkingTree: Bool

    /// GL-28: written on `queue`, read from the main thread (the page's sync
    /// pill). One lock over both, and no lock held across a handler call -
    /// `ShiftGitSync`'s own fix, applied here from the start rather than after
    /// the fact.
    private let stateLock = NSLock()
    private var _status: Status = .synced
    private(set) var status: Status {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _status }
        set { stateLock.lock(); _status = newValue; stateLock.unlock() }
    }
    private var _statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?

    /// Audit 2 §4.3's budget, and the same number `StickyBoardGitSync` uses.
    /// Short on purpose: what a timeout abandons is only the *push*, and the
    /// local encrypted file has already been written synchronously by the time
    /// this is ever called - `ensureReadyNow()` re-reports the dirty tree on
    /// the next launch and re-commits it.
    static let terminateFlushBudget: TimeInterval = 3.0

    init(workingTree: URL,
         remoteURL: String,
         branch: String = "main",
         debounceInterval: TimeInterval = 3.0,
         queue: DispatchQueue,
         sharesProductionWorkingTree: Bool = false) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.vaultSubpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.sharesProductionWorkingTree = sharesProductionWorkingTree
    }

    /// The one production instance. Shares `ShiftGitSync.shared`'s working
    /// tree, remote and serial queue - see this file's header.
    static let shared = CredentialVaultGitSync(
        workingTree: ShiftGitSync.shared.workingTree,
        remoteURL: ShiftGitSync.resolveDefaultRemoteURL(),
        queue: ShiftGitSync.shared.sharedQueue,
        sharesProductionWorkingTree: true
    )

    func observeStatus(_ handler: @escaping (Status) -> Void) {
        stateLock.lock()
        _statusHandlers.append(handler)
        stateLock.unlock()
        let current = status
        DispatchQueue.main.async { handler(current) }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        stateLock.lock()
        let handlers = _statusHandlers
        stateLock.unlock()
        DispatchQueue.main.async { handlers.forEach { $0(newStatus) } }
    }

    /// Production entry point - never blocks the caller (the store's `init`,
    /// on the main thread). A test that needs to observe the result calls
    /// `ensureReadyNow()` directly, matching every sibling sync class.
    func start() {
        queue.async { [weak self] in self?.ensureReadyNow() }
    }

    @discardableResult
    func ensureReadyNow() -> Bool {
        let ok = sharesProductionWorkingTree
            ? ShiftGitSync.shared.ensureWorkingTreeNow()
            : ensureStandaloneWorkingTreeNow()
        try? FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: SensitiveFile.directoryMode]
        )
        SensitiveFile.restrictDirectory(dataRoot)
        let dirty = !uncommittedFiles().isEmpty
        setStatus(dirty ? .localChanges : .synced)
        if dirty { markDirty() }
        return ok
    }

    @discardableResult
    private func ensureStandaloneWorkingTreeNow() -> Bool {
        let fm = FileManager.default
        let gitDir = workingTree.appendingPathComponent(".git")
        guard !fm.fileExists(atPath: gitDir.path) else { return true }
        setStatus(.syncing)
        try? fm.createDirectory(at: workingTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clone = runGit(["clone", remoteURL, workingTree.path], cwd: nil, authenticated: true)
        guard clone.status == 0 else {
            try? fm.createDirectory(
                at: dataRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: SensitiveFile.directoryMode]
            )
            SensitiveFile.restrictDirectory(dataRoot)
            setStatus(.failed("Could not clone \(remoteURL): \(clone.stderr.isEmpty ? "unknown error" : clone.stderr)"))
            return false
        }
        return true
    }

    /// Called right after the encrypted file has already been written
    /// synchronously - the same debounce shape as every sibling.
    func markDirty() {
        setStatus(.localChanges)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCommit?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.commitAndPushNow() }
            self.pendingCommit = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }

    /// Quit-time flush - audit 2 §4.3's fix, written this way from the start
    /// rather than as the direct `commitAndPushNow()` call that finding was
    /// about. Three properties, each load-bearing: it runs **on** `queue` (so
    /// it cannot race a sibling class's `git` against the same working tree),
    /// it **cancels the pending debounce inside the queue block** (where
    /// `pendingCommit` is only ever touched, so the cancel takes if the item
    /// has not started and is moot if it has), and it is **bounded**.
    @discardableResult
    func flushForTerminationNow() -> Bool {
        let lock = NSLock()
        var committed = false
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else { done.signal(); return }
            self.pendingCommit?.cancel()
            self.pendingCommit = nil
            let result = self.commitAndPushNow()
            lock.lock()
            committed = result
            lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + Self.terminateFlushBudget) == .timedOut {
            AppLog.lifecycle.info("""
                credential vault: quit-time git flush still running after \
                \(Self.terminateFlushBudget, privacy: .public)s - letting the app quit; \
                the encrypted file is already on disk and the next launch re-commits
                """)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    @discardableResult
    func commitAndPushNow() -> Bool {
        guard FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path) else {
            setStatus(.failed("No local git checkout at \(workingTree.path)"))
            return false
        }
        let dirty = uncommittedFiles()
        guard !dirty.isEmpty else { return pushOnly() }
        setStatus(.syncing)
        let add = runGit(["add", "-A", "--", Self.vaultSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        // The message is deliberately contentless. A commit subject naming what
        // changed ("added AWS root account") would publish to the repo's plain-
        // text history exactly the item titles the file format goes out of its
        // way to encrypt - see `CredentialVaultModels.swift`'s rule 1.
        let commit = runGit(["commit", "-m", "Poneglyph: encrypted credential store updated"],
                            cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        // GL-22. Same gate and the same scoping rule as every sibling: only the
        // *real* remote is checked, so a self-test against a disposable local
        // bare repo never shells out to `gh`. This matters more here than
        // anywhere else it is used - if `manjesh-config` were ever public, this
        // is the push that would put the captain's whole encrypted credential
        // store on the open internet. Ciphertext, but there is no reason to
        // hand an attacker the file to work on offline.
        if remoteURL == DotfilesSource.cloneURL, !ConfigRepoPrivacy.check().allowsPush {
            setStatus(.failed(ConfigRepoPrivacy.publicRepoRefusalMessage))
            return false
        }
        let push = runGit(["push", "origin", "HEAD:\(branch)"], cwd: workingTree, authenticated: true)
        guard push.status == 0 else {
            setStatus(.failed("git push failed: \(push.stderr.isEmpty ? "unknown error" : push.stderr)"))
            return false
        }
        setStatus(.synced)
        return true
    }

    private func uncommittedFiles() -> [String] {
        let result = runGit(["status", "--short", "--", Self.vaultSubpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // GL-15: one shared runner, one copy of the token injection. Bounded for
    // the reason every sibling is - this class shares another's serial queue,
    // so an unbounded fetch here parks both.
    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> SubprocessResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? remoteURL : nil,
                       timeout: 600)
    }

    #if FM_SELFTESTS
    /// Whether a debounced commit is still outstanding - read on `queue`,
    /// where `pendingCommit` is only ever touched. Mirrors
    /// `StickyBoardGitSync.hasPendingCommitForTests`.
    var hasPendingCommitForTests: Bool { queue.sync { pendingCommit != nil } }
    #endif
}
