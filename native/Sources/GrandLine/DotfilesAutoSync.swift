// Grand Line - native macOS app.
//
// Auto-commit and push for the captain's *live* dotfiles tree
// (`fm/grandline-bootstrap-dotfiles-autocommit`).
//
// The problem this closes: `home.nix` declares several dotfiles as
// `mkOutOfStoreSymlink "${dotfiles}/home/<path>"`, so `~/.config/herdr/config.toml`
// and friends are not copies - they *are* the tracked files in the
// `manjesh-config` checkout at `~/.dotfiles`. Anything that edits one edits the
// repo in place: herdr's own theme picker, and this app's own
// `HerdrThemeSync` (which writes `[theme.custom]` into that exact file on every
// Helm theme change). Bootstrap's "Uncommitted changes" banner already detected
// the result correctly - see `DotfilesData.swift`'s `DotfilesRepoState.dirtyFiles`
// - but only flagged it, so every such edit needed the captain to notice and
// commit it by hand. This commits and pushes it instead.
//
// **This is the fifth copy of a shape, not a new one.** `ShiftGitSync`,
// `DocsRunbookGitSync`, `StickyBoardGitSync` and `CredentialVaultGitSync` all do
// debounced-commit-and-push against a clone of `manjesh-config`, and this
// follows `CredentialVaultGitSync` closely on purpose: the same status enum
// shape, the same `observeStatus` contract, the same `GL-28` lock over the
// status, the same `ConfigRepoPrivacy` gate before any push, the same
// `Subprocess.git` runner and token injection, the same bounded git calls.
// Read that file (and `ShiftGitSync.swift`, the original) before changing
// anything structural here.
//
// **Three things are genuinely different, and each one is the reason this is a
// separate class rather than another `ShiftGitSync` subpath.**
//
//   1. **The working tree is the captain's own checkout, not the app's.** Every
//      sibling syncs `~/Library/Application Support/GrandLine/shift-repo` - a
//      clone this app created and owns. This one operates on `~/.dotfiles`,
//      which `bootstrap.sh` created, which home-manager symlinks live into the
//      home directory, and which the captain uses by hand. So: this class never
//      clones, never resets, never checks out a branch, never force-pushes, and
//      does nothing at all when there is no checkout there. It gets its own
//      serial queue because it is a *different* working tree - the shared-queue
//      rule exists to stop two queues racing on one `.git/index.lock`, which
//      does not apply across two repositories.
//
//   2. **Nothing in this app calls `markDirty()`.** Every sibling is told about
//      a write by the store that just performed it. The writes here come from
//      *outside* the app (herdr, an editor, `darwin-rebuild`), so the trigger is
//      a real recursive FSEvents watch on `<repo>/home`, debounced so a picker
//      that rewrites its file three times in a second still produces one commit.
//
//   3. **The scope is a hard boundary, not a convention.** `manjesh-config` also
//      holds `automatic-vault-details-backup/`, `grand-line-vault-backup/`,
//      `export-backup/` and `GrandLineDocs/` - folders with their own deliberate
//      write and backup semantics, several of them written by the siblings
//      above. Sweeping a half-written backup into an automatic commit is exactly
//      the failure this must not have. So every git write here is pathspec-
//      limited to `home` (see `Self.autoCommitSubpath`), including the commit
//      itself: `git commit -- home` builds the commit from those paths alone and
//      ignores anything else that happens to be staged, which makes the boundary
//      a property of the command rather than of the caller's discipline.
//      `DotfilesAutoSyncSelfTest.checkBackupFoldersAreNeverAutoCommitted`
//      asserts it against a real repository.
//
// **Divergence is refused, never resolved.** `syncNow()` fetches first. A clean
// fast-forward is applied and then pushed; anything else - the captain edited
// the same file on a second machine, or has unpushed work of his own that origin
// has moved past - stops with `.diverged`, having committed nothing and pushed
// nothing, and the banner says so. This mirrors `syncFork`/`syncManual`'s own
// "refuse rather than overwrite real diverged work" rule in `GitHubSyncData.swift`
// and `ShiftGitSync.pullNow`'s `.diverged` case. There is no force-push path in
// this file and a source guard in the suite fails the run if one appears.

import Foundation
import CoreServices

final class DotfilesAutoSync {

    // MARK: Status

    enum Status: Equatable {
        /// The captain turned auto-commit off (Settings/Bootstrap toggle).
        case off
        /// No `~/.dotfiles` checkout on this machine - nothing to sync, and
        /// deliberately not an error. GL-14: this is a stated state, not a
        /// silent "synced".
        case noRepo
        case synced
        case localChanges
        case syncing
        /// Local and remote both moved. Nothing was committed or pushed; the
        /// captain resolves it by hand. The payload is what to tell them.
        case diverged(String)
        case failed(String)
    }

    /// What one `syncNow()` pass actually did. Returned for tests and for
    /// callers that want more than the pill; the pill only ever reads `status`.
    enum Outcome: Equatable {
        case off
        case noRepo
        case nothingToDo
        case pushed(fileCount: Int)
        case diverged(String)
        case failed(String)
    }

    // MARK: Scope

    /// **The one path auto-commit ever touches.** Every `git add`, `git commit`
    /// and `git status` below is pathspec-limited to this and nothing else -
    /// see this file's header, point 3.
    static let autoCommitSubpath = "home"

    /// Sibling top-level folders in the same repository that this class must
    /// never commit, listed here so the rule is testable rather than implied.
    /// Not used to *exclude* anything (the pathspec above already does that by
    /// only ever including `home`) - it is the fixture list
    /// `DotfilesAutoSyncSelfTest` dirties to prove the pathspec holds.
    static let neverAutoCommitted = [
        "automatic-vault-details-backup",
        "grand-line-vault-backup",
        "export-backup",
        "GrandLineDocs",
    ]

    /// Every commit this class makes carries this prefix, and it is load-
    /// bearing rather than cosmetic: it is how `ownUnpushedCommitCount()` tells
    /// "a push of ours failed earlier and should be retried" apart from "the
    /// captain has his own unpushed commit here", which this class must not
    /// push on his behalf.
    static let commitMessagePrefix = "Dotfiles auto-sync:"

    // MARK: Configuration

    let workingTree: URL
    private let remoteURL: String
    private let debounceInterval: TimeInterval
    private let safetyNetInterval: TimeInterval
    private let watcherLatency: CFTimeInterval
    private let isEnabled: () -> Bool
    private let queue: DispatchQueue

    /// `<workingTree>/home` - what the FSEvents stream watches.
    var homeRoot: URL { workingTree.appendingPathComponent(Self.autoCommitSubpath, isDirectory: true) }

    // MARK: State (GL-28)

    /// `status` and `statusHandlers` are written on `queue` and read from the
    /// main thread (Bootstrap's card). One lock over both, never held across a
    /// handler call - `ShiftGitSync`'s own fix, applied here from the start.
    private let stateLock = NSLock()
    private var _status: Status = .synced
    private(set) var status: Status {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _status }
        set { stateLock.lock(); _status = newValue; stateLock.unlock() }
    }
    private var _statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?
    private var eventStream: FSEventStreamRef?
    private var safetyNetTimer: DispatchSourceTimer?

    // MARK: Init

    init(
        workingTree: URL,
        remoteURL: String = DotfilesSource.cloneURL,
        debounceInterval: TimeInterval = 5.0,
        safetyNetInterval: TimeInterval = 600,
        watcherLatency: CFTimeInterval = 1.0,
        queueLabel: String = "com.manjesh.grandline.dotfiles-auto-sync",
        isEnabled: @escaping () -> Bool = { AppSettings.shared.dotfilesAutoCommitEnabled }
    ) {
        self.workingTree = workingTree
        self.remoteURL = remoteURL
        self.debounceInterval = debounceInterval
        self.safetyNetInterval = safetyNetInterval
        self.watcherLatency = watcherLatency
        self.isEnabled = isEnabled
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// `~/.dotfiles`'s resolved target, overridable via
    /// `FM_DOTFILES_AUTOSYNC_PATH` - the same `FM_*` convention every other
    /// local-state path in this app honours, and what lets a self-test (and
    /// `main.swift`'s `#if FM_SELFTESTS` redirect block) point a real instance
    /// at a disposable repository instead of the captain's own checkout.
    ///
    /// Falls back to the unresolved `~/.dotfiles` when there is no such marker
    /// on this machine, so the "is there a `.git` here" check below is the one
    /// place absence is decided - rather than having two different meanings of
    /// "no repo".
    static func resolveDefaultWorkingTree() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_DOTFILES_AUTOSYNC_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        // This store's real target is `~/.dotfiles`, which is nowhere near
        // Application Support, so it cannot pick up `FM_SCRATCH_ROOT` by
        // nesting under `AppPaths.dataRoot()` the way the file-backed stores
        // do. It has to ask. Getting this wrong is not a stale read: this
        // watcher *commits and pushes*, so a probe or a suite that resolved
        // the captain's real checkout would write to their real dotfiles repo
        // (review bug B4).
        if AppPaths.isScratchRedirected() {
            return AppPaths.dataRoot().appendingPathComponent("dotfiles", isDirectory: true)
        }
        if let resolved = DotfilesSource.resolvedDotfilesPath() {
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
        return URL(fileURLWithPath: (DotfilesSource.dotfilesMarker as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The one production instance. Swift statics are lazy, so the path above
    /// is resolved at first access - `start()`, from `main.swift` - not at
    /// image load. A machine that clones its dotfiles *during* a session needs
    /// a relaunch before this picks them up, the same standing limitation
    /// `FirstmateHome.root` documents for its own once-per-process resolution.
    static let shared = DotfilesAutoSync(workingTree: resolveDefaultWorkingTree())

    // MARK: Status observation

    /// Fires immediately with the current status, then on every change - the
    /// same contract as `ShiftGitSync.observeStatus`. Always delivered on main.
    func observeStatus(_ handler: @escaping (Status) -> Void) {
        stateLock.lock()
        _statusHandlers.append(handler)
        let current = _status
        stateLock.unlock()
        DispatchQueue.main.async { handler(current) }
    }

    private func setStatus(_ newStatus: Status) {
        stateLock.lock()
        _status = newStatus
        let handlers = _statusHandlers
        stateLock.unlock()
        switch newStatus {
        case .synced:
            AppLog.gitSync.debug("dotfiles auto-sync: synced")
            ServiceHealthRegistry.shared.recordSuccess(.dotfilesAutoSync)
        case .failed(let reason):
            AppLog.gitSync.error("dotfiles auto-sync failed: \(reason, privacy: .public)")
            ServiceHealthRegistry.shared.recordFailure(.dotfilesAutoSync, reason)
        case .diverged(let reason):
            AppLog.gitSync.error("dotfiles auto-sync: diverged - \(reason, privacy: .public)")
            ServiceHealthRegistry.shared.recordFailure(.dotfilesAutoSync, reason)
        default:
            break
        }
        DispatchQueue.main.async { handlers.forEach { $0(newStatus) } }
    }

    // MARK: Startup

    /// Production entry point, called once from `main.swift`. Never blocks the
    /// caller: everything real happens on `queue`.
    func start() {
        ServiceHealthRegistry.shared.register(.dotfilesAutoSync)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isEnabled() else { self.setStatus(.off); return }
            guard self.hasCheckout() else { self.setStatus(.noRepo); return }
            self.startWatching()
            self.startSafetyNet()
            // A launch-time pass covers two real cases the watcher cannot: an
            // edit made while the app was not running, and a push of ours that
            // failed in a previous session (the in-memory "we have something
            // to push" flag every sibling keeps does not survive a relaunch,
            // which is why `ownUnpushedCommitCount()` reads it back out of git
            // instead).
            _ = self.syncNow()
        }
    }

    /// Tears the watcher and the safety net down. Production never calls this
    /// (the singleton lives as long as the process); a test instance must, so
    /// the FSEvents stream does not outlive the object it holds unretained.
    func stop() {
        queue.sync {
            stopWatching()
            safetyNetTimer?.cancel()
            safetyNetTimer = nil
            pendingCommit?.cancel()
            pendingCommit = nil
        }
    }

    /// Re-reads the toggle and starts or stops accordingly - what the
    /// Bootstrap card's switch calls. Safe to call repeatedly.
    func settingChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isEnabled() {
                guard self.hasCheckout() else { self.setStatus(.noRepo); return }
                self.startWatching()
                self.startSafetyNet()
                _ = self.syncNow()
            } else {
                self.stopWatching()
                self.safetyNetTimer?.cancel()
                self.safetyNetTimer = nil
                self.pendingCommit?.cancel()
                self.pendingCommit = nil
                self.setStatus(.off)
            }
        }
    }

    // MARK: The watcher

    /// A real recursive FSEvents stream on `<repo>/home`. `DispatchSource`'s
    /// `makeFileSystemObjectSource` - the shape `SRELeadBridge` uses - watches
    /// one directory and does not recurse, and the file that started all of
    /// this (`home/.config/herdr/config.toml`) is three levels down, so that
    /// shape genuinely does not fit here.
    ///
    /// `kFSEventStreamCreateFlagFileEvents` reports the individual file rather
    /// than only its directory, which keeps the stream's own coalescing from
    /// hiding a second edit inside one directory notification.
    private func startWatching() {
        guard eventStream == nil else { return }
        guard FileManager.default.fileExists(atPath: homeRoot.path) else {
            AppLog.gitSync.info("dotfiles auto-sync: no \(Self.autoCommitSubpath, privacy: .public)/ tree in the checkout; nothing to watch")
            return
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DotfilesAutoSync>.fromOpaque(info).takeUnretainedValue().fileSystemChanged()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [homeRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            watcherLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            // GL-11 / GL-14: log and degrade to the safety net rather than
            // pretending everything is fine. The periodic pass still catches
            // edits, just later.
            AppLog.gitSync.error("dotfiles auto-sync: could not watch \(self.homeRoot.path, privacy: .public); falling back to the periodic pass alone")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// The debounce. Called on `queue` by the FSEvents callback, and directly
    /// by tests standing in for one.
    ///
    /// A theme picker rewrites its config file more than once per selection,
    /// and browsing a theme list rewrites it once per arrow key - so the timer
    /// is restarted on every event and the commit only runs once the tree has
    /// been quiet for `debounceInterval`. That is "wait for the edits to
    /// settle", and it is the same `pendingCommit?.cancel()` + `asyncAfter`
    /// shape every sibling sync class uses.
    func fileSystemChanged() {
        queue.async { [weak self] in
            guard let self, self.isEnabled() else { return }
            self.setStatus(.localChanges)
            self.pendingCommit?.cancel()
            let item = DispatchWorkItem { [weak self] in _ = self?.syncNow() }
            self.pendingCommit = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }

    /// The safety net: one local `git status` every `safetyNetInterval`, which
    /// only reaches the network when it finds something to sync.
    ///
    /// Deliberately **not** gated on `AppActivityState.isBackgrounded`, unlike
    /// `ShiftGitSync`'s pull timer (GL-13). The edits this exists to catch are
    /// made *in another application* - herdr's theme picker, an editor - so
    /// "the captain is not looking at Grand Line" is precisely when this
    /// feature has work to do, and gating it would make the common case the
    /// broken one. The cost is bounded to one local subprocess every ten
    /// minutes on a clean tree.
    private func startSafetyNet() {
        guard safetyNetTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safetyNetInterval, repeating: safetyNetInterval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in _ = self?.syncNow() }
        safetyNetTimer = timer
        timer.resume()
    }

    /// The captain pressing "Sync now".
    ///
    /// B25: Bootstrap's button called `syncNow()` straight off a global queue,
    /// which is the one thing this class's serial queue exists to prevent -
    /// two `git` runs against one working tree race `.git/index.lock`, and the
    /// debounce timer could fire into the middle of it. (`syncNow`'s own
    /// header already said "production always reaches it on `queue`"; that
    /// call site did not.)
    ///
    /// Onto `queue`, and the pending debounce is cancelled **inside** the
    /// queue block - the same shape the git-backed stores' terminate-time
    /// flush uses, and for the same reason: cancelling from the caller's
    /// thread races the timer it is trying to cancel. `completion` runs on
    /// main, once.
    func syncNowFromUI(completion: @escaping (Outcome) -> Void = { _ in }) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.off) }
                return
            }
            // The captain just asked for exactly what the debounce was
            // waiting to do, so the wait is over rather than duplicated.
            self.pendingCommit?.cancel()
            self.pendingCommit = nil
            let outcome = self.syncNow()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: The synchronous core (what the tests drive directly)

    /// Fetch, fast-forward if that is clean, commit `home/`, push. Every early
    /// exit leaves the working tree exactly as it found it.
    ///
    /// Safe to call from any thread only in a test; production always reaches
    /// it on `queue`, through `fileSystemChanged`'s debounce, the safety-net
    /// timer, or `syncNowFromUI`. A UI call site that reaches this directly
    /// off a global queue is B25.
    @discardableResult
    func syncNow() -> Outcome {
        guard isEnabled() else { setStatus(.off); return .off }
        guard hasCheckout() else { setStatus(.noRepo); return .noRepo }
        guard let branch = currentBranch() else {
            let reason = "\(workingTree.path) is not on a branch (detached HEAD) - auto-commit needs one to push to."
            setStatus(.failed(reason))
            return .failed(reason)
        }

        let dirty = uncommittedHomeFiles()
        // Nothing local *and* nothing of ours left over from a failed push.
        // The second half is what makes a push that failed while offline
        // recover on the next pass instead of sitting forever.
        if dirty.isEmpty, ownUnpushedCommitCount(branch: branch) == 0 {
            setStatus(.synced)
            return .nothingToDo
        }

        setStatus(.syncing)

        let fetch = runGit(["fetch", "origin", branch], authenticated: true)
        guard fetch.status == 0 else {
            let reason = "git fetch failed: \(fetch.stderr.isEmpty ? "unreachable remote" : fetch.stderr)"
            setStatus(.failed(reason))
            return .failed(reason)
        }

        // The same two ancestor questions `ShiftGitSync.pullNow` asks, and the
        // same answer to "neither": stop, touch nothing.
        let headBehindOrEqual = runGit(["merge-base", "--is-ancestor", "HEAD", "origin/\(branch)"], authenticated: false).status == 0
        let originBehindOrEqual = runGit(["merge-base", "--is-ancestor", "origin/\(branch)", "HEAD"], authenticated: false).status == 0
        guard headBehindOrEqual || originBehindOrEqual else {
            let reason = "\(workingTree.path) and origin/\(branch) have both moved on. Nothing was committed or pushed - resolve it by hand (git pull --rebase), then auto-sync resumes."
            setStatus(.diverged(reason))
            return .diverged(reason)
        }

        if headBehindOrEqual, !originBehindOrEqual {
            // Strictly behind: fast-forward before committing. `--ff-only`
            // never rewrites or discards anything, and git refuses outright
            // when an incoming change would overwrite the very file that is
            // locally modified - which is the real-conflict case, and is
            // reported rather than forced past.
            let merge = runGit(["merge", "--ff-only", "origin/\(branch)"], authenticated: false)
            guard merge.status == 0 else {
                let reason = "Could not fast-forward \(workingTree.path) onto origin/\(branch) - a dotfile changed on both sides. Nothing was committed or pushed; resolve it by hand. (\(merge.stderr.isEmpty ? "would not fast-forward" : merge.stderr))"
                setStatus(.diverged(reason))
                return .diverged(reason)
            }
        }

        if !dirty.isEmpty {
            let add = runGit(["add", "-A", "--", Self.autoCommitSubpath], authenticated: false)
            guard add.status == 0 else {
                let reason = "git add failed: \(add.stderr)"
                setStatus(.failed(reason))
                return .failed(reason)
            }
            // `git commit -- <pathspec>` builds the commit from these paths
            // alone, ignoring anything else already staged. That is what makes
            // the scope boundary a property of the command - see the header.
            let message = "\(Self.commitMessagePrefix) \(dirty.count) file\(dirty.count == 1 ? "" : "s") under \(Self.autoCommitSubpath)/"
            let commit = runGit(["commit", "-m", message, "--", Self.autoCommitSubpath], authenticated: false)
            guard commit.status == 0 else {
                let reason = "git commit failed: \(commit.stderr.isEmpty ? commit.stdout : commit.stderr)"
                setStatus(.failed(reason))
                return .failed(reason)
            }
        }

        guard ownUnpushedCommitCount(branch: branch) > 0 else {
            // The fast-forward brought in exactly what we were about to write,
            // or the dirty files turned out to match HEAD. Nothing to send.
            setStatus(.synced)
            return .nothingToDo
        }

        // GL-22, and the same scoping rule every sibling uses: only the real
        // remote is checked, so a self-test against a disposable local repo
        // never shells out to `gh`.
        if remoteURL == DotfilesSource.cloneURL, !ConfigRepoPrivacy.check().allowsPush {
            setStatus(.failed(ConfigRepoPrivacy.publicRepoRefusalMessage))
            return .failed(ConfigRepoPrivacy.publicRepoRefusalMessage)
        }

        // A plain fast-forward push. Never `--force`, never `--force-with-lease`:
        // a rejection here means origin moved between the fetch above and now,
        // and the honest answer is to report it and let the next pass fetch
        // again.
        let push = runGit(["push", "origin", "HEAD:\(branch)"], authenticated: true)
        guard push.status == 0 else {
            let reason = "git push failed: \(push.stderr.isEmpty ? "unknown error" : push.stderr)"
            setStatus(.failed(reason))
            return .failed(reason)
        }
        setStatus(.synced)
        return .pushed(fileCount: dirty.count)
    }

    // MARK: Git reads

    private func hasCheckout() -> Bool {
        FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path)
    }

    /// `nil` on a detached HEAD, which is the one repository state this class
    /// refuses to act on rather than guessing a branch to push to.
    private func currentBranch() -> String? {
        let result = runGit(["rev-parse", "--abbrev-ref", "HEAD"], authenticated: false)
        guard result.status == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "HEAD") ? nil : name
    }

    /// `git status --short -- home` lines. What decides whether there is
    /// anything worth committing, and what `.localChanges` actually means -
    /// never a timer-driven guess.
    func uncommittedHomeFiles() -> [String] {
        let result = runGit(["status", "--short", "--", Self.autoCommitSubpath], authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// How many commits this class itself made that origin does not have yet,
    /// matched by `commitMessagePrefix`.
    ///
    /// The prefix match is the point. A bare "is HEAD ahead of origin" test
    /// would also be true of the captain's own unpushed work in this
    /// repository, and pushing that on his behalf is not what he asked for -
    /// this class publishes its own commits and nothing else. A pass that finds
    /// only his commits ahead therefore reports nothing to do, leaves them
    /// alone, and still commits and pushes its own the moment a dotfile changes
    /// (at which point his ride along, which is unavoidable and is an ordinary
    /// fast-forward of his own branch).
    private func ownUnpushedCommitCount(branch: String) -> Int {
        let result = runGit(["log", "--pretty=format:%s", "origin/\(branch)..HEAD"], authenticated: false)
        guard result.status == 0 else { return 0 }
        return result.stdout
            .split(separator: "\n")
            .filter { $0.hasPrefix(Self.commitMessagePrefix) }
            .count
    }

    // MARK: Process plumbing

    /// GL-02/GL-15: one runner, one copy of the token injection, and bounded -
    /// an unbounded `fetch`/`push` against an unreachable remote would park
    /// this class's serial queue, and a parked queue means dotfile edits stop
    /// syncing with no signal. Generous, because a `fetch` over a slow link is
    /// legitimately slow and this is still a bound.
    private static let gitTimeout: TimeInterval = 300

    private func runGit(_ args: [String], authenticated: Bool) -> SubprocessResult {
        #if FM_SELFTESTS
        DotfilesAutoSyncTestSeam.record(args)
        #endif
        return Subprocess.git(args, cwd: workingTree,
                              authenticateFor: authenticated ? remoteURL : nil,
                              timeout: Self.gitTimeout)
    }

    #if FM_SELFTESTS
    /// Whether a debounced commit is still outstanding - read on `queue`, where
    /// `pendingCommit` is only ever touched. Mirrors
    /// `CredentialVaultGitSync.hasPendingCommitForTests`.
    var hasPendingCommitForTests: Bool { queue.sync { pendingCommit != nil } }

    /// Blocks until everything already queued has run - what a suite uses to
    /// observe the debounce instead of sleeping a guessed interval.
    func drainQueueForTests() { queue.sync {} }
    #endif
}

#if FM_SELFTESTS
/// Records the argv of every `git` this class runs, so a suite can assert the
/// *shape* of a command (GL-38's rule: assert the argv, because nothing else
/// can see it) - in particular that no push ever carries a force flag and that
/// every write carries the `-- home` pathspec. Compiled out of release
/// entirely (GL-27).
enum DotfilesAutoSyncTestSeam {
    /// Written from the sync queue and read from the suite's own thread, so it
    /// takes a lock for the same reason `GL-28` puts one around `status`.
    private static let lock = NSLock()
    private static var _invocations: [[String]] = []
    static var invocations: [[String]] {
        lock.lock(); defer { lock.unlock() }; return _invocations
    }
    static func record(_ args: [String]) {
        lock.lock(); _invocations.append(args); lock.unlock()
    }
    static func reset() {
        lock.lock(); _invocations = []; lock.unlock()
    }
}
#endif
