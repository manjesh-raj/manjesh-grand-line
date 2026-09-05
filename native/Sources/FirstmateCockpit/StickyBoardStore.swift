// Manjesh Grand Line - native macOS app.
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

    private var notesPath: String { root.appendingPathComponent("notes.yaml").path }

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
        switch ShiftYaml.readListChecked(path: notesPath, key: "notes") {
        case .ok(let items):
            isInFailedLoadState = false
            notes = items.compactMap(Self.note(from:)).sorted { $0.createdAt < $1.createdAt }
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
    }

    // MARK: Writing

    @discardableResult
    func addNote(text: String, color: StickyNoteColor, x: Double, y: Double,
                rotationDegrees: Double, now: Date = Date()) -> StickyNote {
        let note = StickyNote(id: UUID().uuidString, text: text, color: color,
                              x: x, y: y, rotationDegrees: rotationDegrees, createdAt: now)
        notes.append(note)
        persist()
        return note
    }

    func updateText(id: String, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
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

    /// The undo half of `deleteNote` - re-inserts a note that was just
    /// removed, restoring its exact original id/text/color/position/
    /// rotation/created-at. A no-op if a note with that id already exists
    /// (defends against a doubled undo click).
    func restoreNote(_ note: StickyNote) {
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        notes.append(note)
        persist()
    }

    /// The one write choke point - refuses to write a file this store could
    /// not read (GL-01), and reports a genuine write failure (GL-10) rather
    /// than swallowing it.
    private func persist() {
        guard !isInFailedLoadState else {
            AppLog.store.error("""
                Sticky Board: refusing to write \(self.notesPath, privacy: .public) - its last read \
                failed to parse (GL-01). Fix or remove the file, then reload.
                """)
            return
        }
        let sorted = notes.sorted { $0.createdAt < $1.createdAt }
        do {
            try ShiftYaml.writeList(path: notesPath, key: "notes", items: sorted.map(Self.yaml(_:)))
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "Sticky Board notes", path: notesPath, error: error)
            return
        }
        gitSync?.markDirty()
    }

    // MARK: YAML - reuses `ShiftYamlBridge`'s generic scalar helpers
    // (`LogAnalyzerStore.swift`) rather than a fourth copy of them.

    private static func yaml(_ n: StickyNote) -> Yaml {
        var m = YamlOrderedMap()
        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(n.id)
        m[ShiftYamlBridge.key("text")] = ShiftYamlBridge.str(n.text)
        m[ShiftYamlBridge.key("color")] = ShiftYamlBridge.str(n.color.rawValue)
        m[ShiftYamlBridge.key("x")] = .double(n.x)
        m[ShiftYamlBridge.key("y")] = .double(n.y)
        m[ShiftYamlBridge.key("rotation")] = .double(n.rotationDegrees)
        m[ShiftYamlBridge.key("created_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(n.createdAt))
        return .dictionary(m)
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
        return StickyNote(id: id, text: text, color: color, x: x, y: y2, rotationDegrees: rotation, createdAt: createdAt)
    }
}
