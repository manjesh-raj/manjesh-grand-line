// Grand Line - native macOS app.
//
// Storage for the Sticky Board (`fm/grandline-sticky-board`, captain's own
// request). Every note's text, color, position, rotation and created
// timestamp lives in one batched YAML file
// (`GrandLineDocs/sticky-board/notes.yaml`) inside the SAME local clone of
// `manjesh-config` `ShiftGitSync` already manages - not a second clone of the
// same repo. `StickyBoardGitSync` mirrors `DocsRunbookGitSync.swift` almost
// exactly (see that file's own header for the full reasoning): it shares
// `ShiftGitSync.shared`'s `workingTree` and serial `sharedQueue` so both
// stores' git invocations serialize against the same working tree instead of
// racing on `.git/index.lock`, and relies on
// `ShiftGitSync.shared.ensureWorkingTreeNow()` for the actual
// clone/pull/repo-layout-migration mechanics rather than reimplementing them
// - this class only owns a debounced commit+push scoped to its own
// `GrandLineDocs/sticky-board` subtree, which is a genuinely new, dedicated
// folder (a sibling of `personal-tasks/` and `runbooks/`, not nested inside
// either - the captain's own instruction), not shared with any unrelated
// feature.
//
// **One file, not one-per-note**, matching Shift's own batched-list rationale
// (`ShiftStore.swift`'s header): a captain dragging/editing notes quickly
// should not spam the repo with one commit-worthy file change per note, and
// `ShiftYaml.readListChecked`/`writeList` (the same generic "one file, a
// `key: [ ... ]` document" helpers `ShiftStore` itself uses for
// `tasks/active.yaml`) already do exactly the write/read/GL-01 shape a single
// `notes.yaml` needs.
//
// **`FM_STICKY_BOARD_DIR`** is this store's own narrow override (bypasses git
// entirely, same convention as `FM_DOCS_RUNBOOKS_DIR`/`FM_COMMAND_LIBRARY_DIR`
// - every self-test uses one of these, never the captain's real synced data).
// It ALSO honours `FM_SHIFT_DIR` as a second fallback, deliberately - not
// because this folder lives inside `ShiftGitSync`'s own `personal-tasks/`
// subtree (it does not; it is a sibling, like `GrandLineDocs/runbooks/`), but
// because every existing self-test harness in this app already sets
// `FM_SHIFT_DIR` to keep away from `ShiftGitSync.shared`'s real production
// clone (see `AppShellBodyWidthSelfTest`/`DestinationMountingSelfTest`/
// `DaylightModuleSelfTest`'s own `withScratchEnv` helpers). Honouring that
// same override here means every one of those harnesses automatically keeps
// Sticky Board off the real clone too, with zero per-file edits - the
// opposite of the maintenance burden `DocsRunbookStore`'s narrower,
// single-env-var design created (AGENTS.md documents at least two follow-up
// tasks that had to hunt down and patch every harness individually to add
// `FM_DOCS_RUNBOOKS_DIR`).

import CoreGraphics
import Foundation
import Yaml

// MARK: - Git sync (shares ShiftGitSync's clone/queue - see file header)

final class StickyBoardGitSync {
    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    static let stickyBoardSubpath = "GrandLineDocs/sticky-board"

    let workingTree: URL
    let dataRoot: URL
    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue

    private(set) var status: Status = .synced
    private var statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?

    /// `true` only for `.shared` - see that property's own doc comment. A
    /// standalone instance (every self-test, and any future non-production
    /// use) owns and clones its own working tree instead, so tests never risk
    /// touching `ShiftGitSync.shared`'s real production clone.
    private let sharesProductionWorkingTree: Bool

    init(
        workingTree: URL, remoteURL: String, branch: String = "main",
        debounceInterval: TimeInterval = 3.0, queue: DispatchQueue,
        sharesProductionWorkingTree: Bool = false
    ) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.stickyBoardSubpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.sharesProductionWorkingTree = sharesProductionWorkingTree
    }

    /// Reuses `ShiftGitSync.shared`'s own working tree, remote, and serial
    /// queue - see this file's header for why. `ShiftGitSync.resolveDefaultRemoteURL()`
    /// already honors `FM_SHIFT_REMOTE_URL`, which is what lets a whole test
    /// instance of the app (and this feature's own live verification) point at
    /// a disposable local bare repo instead of the real `manjesh-config`.
    static let shared = StickyBoardGitSync(
        workingTree: ShiftGitSync.shared.workingTree,
        remoteURL: ShiftGitSync.resolveDefaultRemoteURL(),
        queue: ShiftGitSync.shared.sharedQueue,
        sharesProductionWorkingTree: true
    )

    func observeStatus(_ handler: @escaping (Status) -> Void) {
        statusHandlers.append(handler)
        let current = status
        DispatchQueue.main.async { handler(current) }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        let handlers = statusHandlers
        DispatchQueue.main.async { handlers.forEach { $0(newStatus) } }
    }

    /// Production entry point - dispatches the real work onto `queue`
    /// asynchronously, never blocking the caller (`StickyBoardStore.init()`,
    /// called on the main thread). Tests that need to observe the result
    /// synchronously should call `ensureReadyNow()` directly instead (mirrors
    /// `ShiftGitSync`/`DocsRunbookGitSync`'s own start-dispatches-async /
    /// ensureReadyNow-runs-synchronously split).
    func start() {
        queue.async { [weak self] in self?.ensureReadyNow() }
    }

    /// Ensures a working tree exists (delegating to `ShiftGitSync.shared` when
    /// this instance shares its production clone, never re-cloning
    /// independently in that case; cloning its own otherwise - see
    /// `sharesProductionWorkingTree`) and that `dataRoot` exists, then reports
    /// the current dirty/synced state - synchronously, so a caller
    /// (production or test) can rely on `status` reflecting reality the
    /// moment this returns.
    @discardableResult
    func ensureReadyNow() -> Bool {
        let ok = sharesProductionWorkingTree ? ShiftGitSync.shared.ensureWorkingTreeNow() : ensureStandaloneWorkingTreeNow()
        let fm = FileManager.default
        try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let dirty = !uncommittedFiles().isEmpty
        setStatus(dirty ? .localChanges : .synced)
        if dirty { markDirty() }
        return ok
    }

    /// Only reached when `sharesProductionWorkingTree` is `false` (a
    /// standalone instance, e.g. a self-test against a disposable repo) - a
    /// minimal clone-if-needed, since a standalone instance's own repo is
    /// already expected to have the right layout by construction (no
    /// repo-layout migration needed here, unlike `ShiftGitSync`'s own).
    @discardableResult
    private func ensureStandaloneWorkingTreeNow() -> Bool {
        let fm = FileManager.default
        let gitDir = workingTree.appendingPathComponent(".git")
        guard !fm.fileExists(atPath: gitDir.path) else { return true }
        setStatus(.syncing)
        try? fm.createDirectory(at: workingTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clone = runGit(["clone", remoteURL, workingTree.path], cwd: nil, authenticated: true)
        guard clone.status == 0 else {
            try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            setStatus(.failed("Could not clone \(remoteURL): \(clone.stderr.isEmpty ? "unknown error" : clone.stderr)"))
            return false
        }
        return true
    }

    /// Called right after a local YAML write has already completed
    /// synchronously - same debounce shape as
    /// `ShiftGitSync.markDirty()`/`DocsRunbookGitSync.markDirty()`. Rapid
    /// note edits/drags coalesce into one commit rather than one per write.
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

    /// How long the terminate-time flush will hold its caller before giving
    /// up on the git work and letting the app finish quitting.
    ///
    /// Short on purpose. The local commit - the part that preserves the
    /// record - is fast and offline; the slow part is the network push, and
    /// that one is *already* recoverable with no help from here:
    /// `ensureReadyNow()` re-reports a dirty tree on the next launch and
    /// calls `markDirty()` itself, so an abandoned push is picked up then.
    /// Holding the main thread any longer would only trade a bounded, safe
    /// loss for a visible hang on ⌘Q, against a `Subprocess` push bound of
    /// 600s.
    static let terminateFlushBudget: TimeInterval = 3.0

    /// The quit-time flush (audit 2 §4.3).
    ///
    /// Two things this does that calling `commitAndPushNow()` directly did
    /// not. It runs the git work **on `queue`** - the same serial queue every
    /// other invocation in this app uses (`ShiftGitSync.sharedQueue` in
    /// production, shared with Shift's, Docs' and Code Preview's own commits
    /// against the *same* working tree), so a flush can no longer race a
    /// sibling's `git` for `.git/index.lock`. And it **cancels the still-
    /// pending debounced commit first**, which shutdown never did - a
    /// `markDirty()` from the last edit could otherwise fire during or after
    /// this flush and commit the same work twice.
    ///
    /// The cancel happens *inside* the queue block rather than before it, for
    /// two reasons: `pendingCommit` is only ever touched on `queue` (see
    /// `markDirty`), and a serial queue guarantees the pending item is not
    /// running concurrently with us - so if it has not started yet the cancel
    /// takes, and if it already ran there is nothing left to cancel.
    ///
    /// The caller is held for at most `terminateFlushBudget`. Whatever the
    /// bound abandons is safe: the local YAML write already completed
    /// synchronously before this is ever called (`StickyBoardStore.
    /// flushPendingWrite`), so the captain's notes are on disk either way,
    /// and an un-pushed commit is recovered on the next launch.
    @discardableResult
    func flushForTerminationNow() -> Bool {
        // `committed` is written on `queue` and read here, and the bound
        // means the writer can still be running when this returns - so it is
        // lock-guarded rather than relying on the semaphore's ordering alone.
        // GL-28's lesson, and cheap: exactly one write and one read.
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
                sticky board: quit-time git flush still running after \
                \(Self.terminateFlushBudget, privacy: .public)s - letting the app quit; \
                the local notes are already on disk and the next launch re-commits
                """)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    #if FM_SELFTESTS
    /// Whether a debounced commit is still outstanding - audit 2 §4.3's own
    /// case, which has to prove the terminate flush *cancelled* the pending
    /// item rather than merely outran it. Read on `queue`, where
    /// `pendingCommit` is only ever touched.
    var hasPendingCommitForTests: Bool { queue.sync { pendingCommit != nil } }
    #endif

    @discardableResult
    func commitAndPushNow() -> Bool {
        guard FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path) else {
            setStatus(.failed("No local git checkout at \(workingTree.path)"))
            return false
        }
        let dirty = uncommittedFiles()
        guard !dirty.isEmpty else { return pushOnly() }
        setStatus(.syncing)
        let add = runGit(["add", "-A", "--", Self.stickyBoardSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Sticky Board: \(dirty.count) file(s) updated"], cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        // GL-22: the sticky board folder goes to `manjesh-config` too. Same
        // gate, same scoping rule as `ShiftGitSync`/`DocsRunbookGitSync`'s own
        // `pushOnly` - only the real remote is checked, so a self-test against
        // a disposable local bare repo never shells out to `gh`.
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
        let result = runGit(["status", "--short", "--", Self.stickyBoardSubpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Process plumbing

    // GL-15: one shared runner and one copy of the git token injection - see
    // `Subprocess.gitAuthEnvironment`. Bounded, for the same reason
    // `ShiftGitSync`/`DocsRunbookGitSync` are: this class shares that class's
    // working tree and serial queue, so an unbounded fetch here parks both.

    private typealias GitResult = SubprocessResult

    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> GitResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? remoteURL : nil,
                       timeout: 600)
    }
}

// MARK: - Local CRUD store

final class StickyBoardStore {
    private let fm = FileManager.default
    let root: URL

    /// `nil` when `FM_STICKY_BOARD_DIR`/`FM_SHIFT_DIR` overrides `root` - same
    /// convention as `ShiftStore.gitSync`/`DocsRunbookStore.gitSync`.
    let gitSync: StickyBoardGitSync?

    private(set) var notes: [StickyNote] = []

    /// The notes on the board - review #3's UX10.
    ///
    /// `notes` deliberately stays "every note", because that is what the file
    /// holds and what `persist` writes; splitting the stored array would make
    /// archiving a move between two collections and give the writer two places
    /// to get wrong. The board asks for this instead.
    var activeNotes: [StickyNote] { notes.filter { !$0.isArchived } }

    /// The archive drawer's contents, newest-archived first - which is the
    /// order someone looking for "the thing I put away earlier" wants, and the
    /// opposite of the board's own oldest-first stacking order.
    var archivedNotes: [StickyNote] {
        notes.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    private var notesPath: String { root.appendingPathComponent("notes.yaml").path }

    // MARK: Change notification
    //
    // F23 (the widgets) is the first reader outside this store's own
    // controller that needs to know the board changed. `ShiftStore` has had
    // `observe`/`notify()` since its first phase and this is deliberately the
    // same shape - one handler list, fired after a successful write and after
    // a reload - rather than a second mechanism.
    //
    // Fired from `persist()`'s success path and from the end of `reloadAll()`,
    // which between them are every way `notes` changes. A handler must be
    // cheap and must not write back into this store.

    private var changeHandlers: [() -> Void] = []

    func observe(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

    private func notifyChanged() {
        for handler in changeHandlers { handler() }
    }

    // MARK: GL-01 - refuse to overwrite a file this store could not read.
    //
    // A single-file version of `ShiftStore`'s `loadFailurePaths`/
    // `writeListGuarded` pattern (see that file's own header for the full
    // incident this guards against - a hand-edited syntax error silently
    // read as "no notes", then immediately overwritten and pushed as the
    // wipe). One path here rather than a `Set`, since this store owns
    // exactly one file.

    /// `true` once `notesPath`'s last read found real content this store
    /// could not parse. While true, every write is refused and the git-sync
    /// debounce is never armed - nothing local is overwritten and nothing
    /// unreadable is propagated off-machine.
    private(set) var isInFailedLoadState = false

    /// Records read from `notes.yaml` that this build could not decode, kept
    /// verbatim so `persist()` can write them straight back.
    ///
    /// **This is the whole of the full-app audit's finding 4.2.** `note(from:)`
    /// returns nil for a record it cannot make sense of - most realistically a
    /// `color` whose rawValue is a `StickyNoteColor` case a *newer* build
    /// added - and `reloadAll()` used to `compactMap` it away, at which point
    /// the very next `persist()` rewrote the file without it and
    /// `gitSync.markDirty()` committed and pushed the deletion. Whole-file
    /// parse failure was already GL-01-guarded (`isInFailedLoadState`);
    /// per-record failure was not, and the trigger is exactly the cross-
    /// machine version skew this store's git sync exists to serve: a note
    /// written on a newer build is destroyed by any edit made on an older one.
    ///
    /// Carrying the raw `Yaml` through is what makes an unreadable record cost
    /// only its own visibility rather than its existence. The note does not
    /// render on this build - it cannot, nothing here knows what it is - but
    /// it survives every write, and the build that *does* understand it still
    /// finds it. Same principle as `FleetLogStore.Line.opaque`.
    ///
    /// `sortKey` is that record's own `created_at` when it has a readable one,
    /// so a preserved note keeps its position in the file rather than being
    /// shuffled to the end on every rewrite.
    private var unreadableRecords: [(sortKey: Date, raw: Yaml)] = []

    /// How many records the last successful read could not decode. Zero on a
    /// healthy board; a self-test asserts it, and it is worth knowing about.
    var unreadableRecordCount: Int { unreadableRecords.count }

    /// Keys this build writes for a note. Anything else found on a record
    /// this build **could** decode is preserved verbatim - see `passthrough`.
    ///
    /// Adding a field to `StickyNote` means adding its key here in the same
    /// change, or this build will treat its own output as foreign and write
    /// every note's record twice over. `StickyBoardSelfTest
    /// .checkUnknownKeyPassthrough` asserts a round trip through a real
    /// store leaves a note's record with no duplicated keys, which is what
    /// catches that mistake.
    static let knownKeys: Set<String> = [
        "id", "title", "text", "color", "x", "y", "width", "height",
        "rotation", "created_at", "archived_at", "checklist",
    ]

    /// Per-note keys this build did not recognise, kept verbatim and written
    /// straight back out - the *decodable*-record half of the same rule
    /// `unreadableRecords` implements for a record that will not decode at
    /// all.
    ///
    /// **The gap this closes is the one review #3's F6 names as the
    /// checklist variant's prerequisite.** `unreadableRecords` only catches a
    /// record this build cannot make sense of; a record it reads perfectly
    /// well but which carries one extra key from a newer build used to lose
    /// that key on the very next write, because `yaml(_:)` re-serialises from
    /// the decoded struct and the struct has nowhere to put it. That is the
    /// worse of the two failure modes in practice: the note keeps working, so
    /// nothing looks wrong, and the newer build silently finds its own field
    /// gone every time the older one is opened - across a git sync whose
    /// entire purpose is two machines on two builds.
    ///
    /// Rebuilt from disk on every `reloadAll()`. An entry for a note deleted
    /// in this session is deliberately kept until the next reload, so an Undo
    /// (`restoreNote`) restores the whole record rather than a lossy copy of
    /// it; the map is therefore bounded by board size plus this session's own
    /// deletions, which is the same order of magnitude.
    private var passthrough: [String: [(key: Yaml, value: Yaml)]] = [:]

    /// How long a text edit waits before it reaches disk (full-app audit,
    /// findings 3.3/4.6).
    ///
    /// Every `persist()` re-serialises **every** note through
    /// `YamlBeautify.dump` and writes the whole `notes.yaml` synchronously on
    /// the main thread. That used to happen once per *character typed*: only
    /// the git commit was debounced (3s), never the local write, so the cost
    /// was O(board size) at keystroke rate. Position and size were already
    /// drag-**end** only, so text and title were the whole of it.
    ///
    /// 1.5s is the same shape `CodePreviewController` already uses one
    /// destination over - debounce the write, flush on the way out - just
    /// slower, because this write is whole-file where Monaco's is one file.
    /// Anything structural (a note added, deleted, restored, recoloured)
    /// still writes immediately: those are rare, and losing one to a crash
    /// costs a whole note rather than a few characters.
    static let persistDebounce: TimeInterval = 1.5

    private var pendingPersist: DispatchWorkItem?

    /// `nil` when `FM_STICKY_BOARD_DIR` overrides `root` and the notes
    /// themselves are unset (every self-test, plain local-only use).
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_STICKY_BOARD_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sticky-board", isDirectory: true)
            gitSync = nil
        } else {
            let sync = StickyBoardGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reloadAll()
    }

    /// Test seam: an explicitly-rooted, git-free store, mirroring
    /// `IncidentStore(root:)` - so a suite never has to depend on process-wide
    /// environment to stay off the real clone.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reloadAll()
    }

    func reloadAll() {
        // A queued write holds edits that are only in memory; re-reading the
        // file first would silently discard them.
        flushPendingWrite()
        switch ShiftYaml.readListChecked(path: notesPath, key: "notes") {
        case .ok(let items):
            isInFailedLoadState = false
            var decoded: [StickyNote] = []
            var unreadable: [(sortKey: Date, raw: Yaml)] = []
            var extras: [String: [(key: Yaml, value: Yaml)]] = [:]
            for item in items {
                if let note = Self.note(from: item) {
                    decoded.append(note)
                    let unknown = Self.unknownPairs(in: item)
                    if !unknown.isEmpty { extras[note.id] = unknown }
                } else {
                    // Preserved, not dropped - see `unreadableRecords`.
                    unreadable.append((Self.createdAtOrDistantFuture(item), item))
                }
            }
            if !unreadable.isEmpty {
                AppLog.store.info("""
                    Sticky Board: \(unreadable.count, privacy: .public) note record(s) in \
                    \(self.notesPath, privacy: .public) could not be decoded by this build - \
                    preserving them verbatim rather than dropping them on the next write.
                    """)
            }
            unreadableRecords = unreadable
            passthrough = extras
            notes = decoded.sorted { $0.createdAt < $1.createdAt }
        case .missing:
            isInFailedLoadState = false
            notes = []
        case .parseFailed:
            // GL-01: back the file up once (a second consecutive parse
            // failure need not back it up again) and refuse every write
            // until a successful reload clears this - see `persist()`.
            if !isInFailedLoadState {
                StoreLoadFailure.backUp(URL(fileURLWithPath: notesPath), label: "Sticky Board notes")
            }
            isInFailedLoadState = true
            // `notes` is left exactly as it was in memory - a parse failure
            // must never be read as "there are now zero notes".
        }
        notifyChanged()
    }

    // MARK: Writing

    @discardableResult
    func addNote(title: String = "", text: String, color: StickyNoteColor, x: Double, y: Double,
                size: CGSize = StickyBoardMetrics.noteSize,
                rotationDegrees: Double, now: Date = Date()) -> StickyNote {
        let bounded = StickyBoardMetrics.clampSize(size)
        let note = StickyNote(id: UUID().uuidString, title: title, text: text, color: color,
                              x: x, y: y,
                              width: Double(bounded.width), height: Double(bounded.height),
                              rotationDegrees: rotationDegrees, createdAt: now)
        notes.append(note)
        persist()
        return note
    }

    /// Debounced - this is called once per character typed. See
    /// `persistDebounce`.
    func updateText(id: String, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        schedulePersist()
    }

    /// The note's own short label (the reference photo's index-card header).
    /// Debounced, for the same reason `updateText` is - a title is typed a
    /// character at a time too.
    func updateTitle(id: String, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].title = title
        schedulePersist()
    }

    /// Persisted on the resize drag's END only, exactly like `updatePosition`
    /// - see the resize grip's own note in `StickyBoardViews.swift`. Clamped
    /// here as well as in the view so a size can never reach the file outside
    /// the metric bounds, whatever wrote it.
    func updateSize(id: String, width: Double, height: Double) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let bounded = StickyBoardMetrics.clampSize(CGSize(width: width, height: height))
        notes[index].width = Double(bounded.width)
        notes[index].height = Double(bounded.height)
        persist()
    }

    /// Called on every drag update as well as on drop - see
    /// `StickyBoardController`'s own doc comment on why this is fine: writes
    /// are debounced by `StickyBoardGitSync.markDirty()`, and the in-memory
    /// array + local YAML write are cheap regardless of how often they run.
    func updatePosition(id: String, x: Double, y: Double) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].x = x
        notes[index].y = y
        persist()
    }

    /// Removes and returns the note, so a caller can offer an undo
    /// (`Toast.showUndo`, GL-33's rule: an undo must restore the exact value
    /// the caller already had in hand) via `restoreNote(_:)`.
    @discardableResult
    func deleteNote(id: String) -> StickyNote? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = notes.remove(at: index)
        persist()
        return removed
    }

    /// Archive a note, or put it back on the board - review #3's UX10.
    ///
    /// Deliberately not a delete: the finding's complaint is that the board
    /// "is a dead end after ~12 notes", and the answer to a full corkboard is
    /// somewhere to put things, not a bin. Returns the note's new state so a
    /// caller can offer an Undo that restores the value it already had
    /// (GL-33) rather than guessing at it.
    @discardableResult
    func setArchived(id: String, archived: Bool, now: Date = Date()) -> StickyNote? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        // Idempotent: re-archiving an archived note must not move its
        // `archivedAt`, or the drawer's newest-first order would reshuffle on
        // a doubled click.
        guard notes[index].isArchived != archived else { return notes[index] }
        notes[index].archivedAt = archived ? now : nil
        persist()
        return notes[index]
    }

    /// Repaint a note (F6's `Colour \u{25B8}` submenu).
    ///
    /// Structural rather than typed, so it writes immediately like every
    /// other rare, deliberate change - see `persistDebounce`. Returns the
    /// previous colour so the caller can offer a real Undo (GL-33) instead of
    /// re-deriving one.
    @discardableResult
    func updateColor(id: String, color: StickyNoteColor) -> StickyNoteColor? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let previous = notes[index].color
        guard previous != color else { return previous }
        notes[index].color = color
        persist()
        return previous
    }

    // MARK: The checklist variant (F6)

    /// Turn a note into a checklist, edit the checklist it already has, or
    /// (with `nil`) turn it back into a plain text note.
    ///
    /// **This is the one place `text` and `checklist` are kept in step**, and
    /// every other checklist mutator below routes through it. `text` is the
    /// authoritative plain-text rendering whenever a checklist exists - see
    /// `StickyChecklist`'s doc comment for the four things that buys - so a
    /// checklist that wrote itself into `checklist` without re-rendering
    /// `text` would leave `\u{2318}K`, the hub peek and a promoted task all
    /// reading a stale body. Turning a checklist back off leaves `text`
    /// exactly as it was last rendered, which is why the round trip is
    /// lossless and needs no second stored copy.
    @discardableResult
    func setChecklist(id: String, items: [StickyChecklistItem]?) -> StickyNote? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        notes[index].checklist = items
        if let items { notes[index].text = StickyChecklist.text(fromItems: items) }
        persist()
        return notes[index]
    }

    /// Convert this note's existing body into checklist items - the context
    /// menu's "Turn into a Checklist". A no-op on a note that is already one,
    /// so a doubled click cannot re-parse (and so re-id) every row underneath
    /// the captain's cursor.
    @discardableResult
    func convertToChecklist(id: String) -> StickyNote? {
        guard let note = notes.first(where: { $0.id == id }), !note.isChecklist else { return nil }
        return setChecklist(id: id, items: StickyChecklist.items(fromText: note.text))
    }

    /// The inverse. `text` already holds the markdown the captain was looking
    /// at, so this drops the structure and keeps the content.
    @discardableResult
    func convertToText(id: String) -> StickyNote? {
        guard let note = notes.first(where: { $0.id == id }), note.isChecklist else { return nil }
        return setChecklist(id: id, items: nil)
    }

    @discardableResult
    func toggleChecklistItem(noteID: String, itemID: String) -> StickyNote? {
        guard let note = notes.first(where: { $0.id == noteID }), let items = note.checklist else { return nil }
        return setChecklist(id: noteID, items: StickyChecklist.toggling(items, id: itemID))
    }

    /// Debounced, unlike the structural changes above: this one is called
    /// once per character typed into an item's field, exactly like
    /// `updateText`.
    func updateChecklistItemText(noteID: String, itemID: String, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }),
              let items = notes[index].checklist,
              let itemIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        var updated = items
        updated[itemIndex].text = text
        notes[index].checklist = updated
        notes[index].text = StickyChecklist.text(fromItems: updated)
        schedulePersist()
    }

    /// Appends a row and returns it, so the view can focus the field it just
    /// created rather than hunting for it by index.
    @discardableResult
    func addChecklistItem(noteID: String, text: String = "") -> StickyChecklistItem? {
        guard let note = notes.first(where: { $0.id == noteID }), let items = note.checklist else { return nil }
        let item = StickyChecklistItem.fresh(text: text)
        setChecklist(id: noteID, items: items + [item])
        return item
    }

    @discardableResult
    func removeChecklistItem(noteID: String, itemID: String) -> StickyNote? {
        guard let note = notes.first(where: { $0.id == noteID }), let items = note.checklist,
              items.contains(where: { $0.id == itemID }) else { return nil }
        return setChecklist(id: noteID, items: items.filter { $0.id != itemID })
    }

    /// The undo half of `deleteNote` - re-inserts a note that was just
    /// removed, restoring its exact original id/text/color/position/
    /// rotation/created-at. A no-op if a note with that id already exists
    /// (defends against a doubled undo click).
    func restoreNote(_ note: StickyNote) {
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        notes.append(note)
        persist()
    }

    /// Queue a write for `persistDebounce` from now, replacing any already
    /// queued. For the high-frequency callers only (text, title).
    private func schedulePersist() {
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPersist = nil
            self.persist()
        }
        pendingPersist = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDebounce, execute: item)
    }

    /// Write anything the debounce is still holding, now.
    ///
    /// Called on the way out of the destination, when a field gives up focus,
    /// and on app termination. `persist()` always writes the *whole* in-memory
    /// array, so an immediate write for an unrelated reason (a note deleted
    /// while a text edit is pending) already carries the pending edit with it -
    /// which is why every immediate path simply cancels the timer rather than
    /// having to order two writes against each other.
    func flushPendingWrite() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        persist()
    }

    /// Whether a debounced write is still outstanding - for a self-test that
    /// needs to prove the debounce is real rather than that a write happened.
    var hasPendingWrite: Bool { pendingPersist != nil }

    deinit {
        // A store torn down with an edit still queued must not lose it.
        if pendingPersist != nil {
            pendingPersist?.cancel()
            pendingPersist = nil
            persist()
        }
    }

    /// The one write choke point - refuses to write a file this store could
    /// not read (GL-01), and reports a genuine write failure (GL-10) rather
    /// than swallowing it.
    ///
    /// Immediate. A queued debounced write is cancelled first, since this one
    /// writes the same in-memory array and would otherwise fire again for
    /// nothing.
    private func persist() {
        pendingPersist?.cancel()
        pendingPersist = nil
        guard !isInFailedLoadState else {
            AppLog.store.error("""
                Sticky Board: refusing to write \(self.notesPath, privacy: .public) - its last read \
                failed to parse (GL-01). Fix or remove the file, then reload.
                """)
            return
        }
        // Decoded notes and preserved-but-unreadable records are merged back
        // into one `created_at`-ordered list, so a record this build cannot
        // read keeps its place in the file instead of drifting to the end on
        // every single write (which would make `git diff` unreadable for the
        // build that *can* read it).
        var merged: [(sortKey: Date, raw: Yaml)] =
            notes.map { ($0.createdAt, yaml($0)) } + unreadableRecords
        merged.sort { $0.sortKey < $1.sortKey }
        do {
            try ShiftYaml.writeList(path: notesPath, key: "notes", items: merged.map(\.raw))
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "Sticky Board notes", path: notesPath, error: error)
            return
        }
        gitSync?.markDirty()
        notifyChanged()
    }

    // MARK: YAML - reuses `ShiftYamlBridge`'s generic scalar helpers
    // (`LogAnalyzerStore.swift`) rather than a fourth copy of them.

    private func yaml(_ n: StickyNote) -> Yaml {
        var m = YamlOrderedMap()
        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(n.id)
        m[ShiftYamlBridge.key("title")] = ShiftYamlBridge.str(n.title)
        m[ShiftYamlBridge.key("text")] = ShiftYamlBridge.str(n.text)
        m[ShiftYamlBridge.key("color")] = ShiftYamlBridge.str(n.color.rawValue)
        m[ShiftYamlBridge.key("x")] = .double(n.x)
        m[ShiftYamlBridge.key("y")] = .double(n.y)
        m[ShiftYamlBridge.key("width")] = .double(n.width)
        m[ShiftYamlBridge.key("height")] = .double(n.height)
        m[ShiftYamlBridge.key("rotation")] = .double(n.rotationDegrees)
        m[ShiftYamlBridge.key("created_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(n.createdAt))
        // UX10. Written only when set, so an un-archived note's record is
        // byte-identical to what this store has always produced - a key
        // appearing on every note in the captain's git-synced repo would make
        // this change a diff on every line of a file it did not need to touch.
        if let archivedAt = n.archivedAt {
            m[ShiftYamlBridge.key("archived_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(archivedAt))
        }
        // F6's checklist variant, under the same write-only-when-set rule as
        // `archived_at` above: a text note's record stays byte-identical to
        // what this store has always produced, so adding this feature is not
        // a diff on every line of the captain's synced file.
        if let checklist = n.checklist {
            m[ShiftYamlBridge.key("checklist")] = .array(checklist.map { item in
                var im = YamlOrderedMap()
                im[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(item.id)
                im[ShiftYamlBridge.key("text")] = ShiftYamlBridge.str(item.text)
                im[ShiftYamlBridge.key("done")] = .bool(item.isDone)
                return .dictionary(im)
            })
        }
        // Whatever a newer build wrote that this one does not understand,
        // put back exactly as it was found - see `passthrough`. Appended
        // last so this build's own keys keep their established order and the
        // resulting `git diff` stays readable.
        for pair in passthrough[n.id] ?? [] {
            m[pair.key] = pair.value
        }
        return .dictionary(m)
    }

    /// The pairs on a record whose key this build does not write. A
    /// non-string key (legal YAML, never something this store produces) is
    /// preserved too - it is by definition not one of `knownKeys`.
    private static func unknownPairs(in y: Yaml) -> [(key: Yaml, value: Yaml)] {
        guard let dict = y.dictionary else { return [] }
        return dict.pairs.filter { pair in
            guard case .string(let name, _) = pair.key else { return true }
            return !knownKeys.contains(name)
        }
    }

    /// A preserved record's own `created_at`, so it keeps its position in the
    /// file. `.distantFuture` when even that is unreadable - such a record
    /// sorts last, deterministically, rather than jumping around between
    /// writes.
    private static func createdAtOrDistantFuture(_ y: Yaml) -> Date {
        guard let dict = y.dictionary else { return .distantFuture }
        return ShiftYamlBridge.date(dict[ShiftYamlBridge.key("created_at")]) ?? .distantFuture
    }

    private static func note(from y: Yaml) -> StickyNote? {
        guard let dict = y.dictionary,
              let id = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("id")]),
              let colorRaw = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("color")]),
              let color = StickyNoteColor(rawValue: colorRaw) else { return nil }
        let text = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("text")]) ?? ""
        let x = dict[ShiftYamlBridge.key("x")]?.double ?? 0
        let y2 = dict[ShiftYamlBridge.key("y")]?.double ?? 0
        let rotation = dict[ShiftYamlBridge.key("rotation")]?.double ?? 0
        let createdAt = ShiftYamlBridge.date(dict[ShiftYamlBridge.key("created_at")]) ?? Date()
        // `title`/`width`/`height` arrived in
        // `fm/grandline-sticky-code-preview-polish`, after notes had already
        // been written to the captain's own repo. **Every new field needs a
        // real fallback on the way in, never just a Swift-side default** -
        // AGENTS.md records this app losing a whole `hosts.json` to exactly
        // that mistake. This decoder is hand-written (not synthesised
        // `Decodable`, which is where that bug actually lives), so the `??`
        // below is the fallback - but the rule is the same, and
        // `StickyBoardSelfTest.checkLegacyNoteDecode` pins it against a real
        // pre-upgrade file rather than trusting the reading.
        let title = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("title")]) ?? ""
        let size = StickyBoardMetrics.clampSize(CGSize(
            width: dict[ShiftYamlBridge.key("width")]?.double ?? Double(StickyBoardMetrics.noteSize.width),
            height: dict[ShiftYamlBridge.key("height")]?.double ?? Double(StickyBoardMetrics.noteSize.height)))
        // UX10's own new field, under the rule the comment above states: an
        // absent key is "not archived", never a decode failure. A note written
        // by an older build has no `archived_at` and must still load.
        let archivedAt = ShiftYamlBridge.date(dict[ShiftYamlBridge.key("archived_at")])
        // F6, same rule again: an absent `checklist` is a text note, never a
        // decode failure. A present-but-empty one is a checklist the captain
        // emptied, which is a different state - see `StickyNote.checklist`.
        let checklist = checklistItems(dict[ShiftYamlBridge.key("checklist")])
        return StickyNote(id: id, title: title, text: text, color: color, x: x, y: y2,
                          width: Double(size.width), height: Double(size.height),
                          rotationDegrees: rotation, createdAt: createdAt,
                          archivedAt: archivedAt, checklist: checklist)
    }

    /// A stored checklist, or `nil` when the key is absent or holds
    /// something that is not a list. An item with no readable `text` is
    /// dropped rather than rendered as a blank row; an item with no `id`
    /// gets a fresh one, since an id is this build's own handle on the row
    /// and a missing one costs nothing to replace.
    private static func checklistItems(_ y: Yaml?) -> [StickyChecklistItem]? {
        guard let y, let array = y.array else { return nil }
        return array.compactMap { entry in
            guard let dict = entry.dictionary,
                  let text = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("text")]) else { return nil }
            let id = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("id")]) ?? UUID().uuidString
            let done = dict[ShiftYamlBridge.key("done")]?.bool ?? false
            return StickyChecklistItem(id: id, text: text, isDone: done)
        }
    }
}
