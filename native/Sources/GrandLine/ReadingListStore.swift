// Grand Line - native macOS app.
//
// F4's storage. One batched YAML file - `GrandLineDocs/reading-list/links.yaml`
// - inside the SAME local clone of `manjesh-config` that `ShiftGitSync`
// already manages, plus a `reading-list/icons/` folder of one small PNG per
// host.
//
// **`ReadingListGitSync` mirrors `StickyBoardGitSync` deliberately and
// exactly**: it shares `ShiftGitSync.shared`'s `workingTree` and serial
// `sharedQueue` so every store's `git` invocations serialise against one
// working tree instead of racing on `.git/index.lock` (AGENTS.md's "Stores,
// subprocesses and secrets"), and it relies on
// `ShiftGitSync.shared.ensureWorkingTreeNow()` for the clone/pull mechanics
// rather than reimplementing them. What it owns is a debounced commit+push
// scoped to its own subtree, which is a new sibling of `personal-tasks/`,
// `runbooks/`, `sticky-board/` and `notebook/` - not nested inside any of
// them.
//
// **One file, not one per link**, for `ShiftStore`'s own reason: marking six
// articles read in a row should be one commit-worthy change, not six.
//
// **`FM_READING_LIST_DIR`** is this store's narrow override, and it honours
// **`FM_SHIFT_DIR`** as a second fallback for the reason
// `StickyBoardStore.init` spells out at length: every existing self-test
// harness in this app already sets `FM_SHIFT_DIR` to stay off the captain's
// real clone, so honouring it here keeps this store off it too with no
// per-harness edit. `main.swift`'s `#if FM_SELFTESTS` block sets both.
//
// ## GL-01, in both of its halves
//
// A file this store could not parse is backed up once and then **never
// written** until a successful reload clears the flag - a parse failure must
// never read as "there are now zero saved links" and then be committed as the
// wipe. And a *record* this build cannot decode is carried through verbatim
// rather than dropped, which is the full-app audit's finding 4.2 applied
// before it can happen again here: a link saved by a newer build must survive
// every write an older one makes, because the whole point of the git sync is
// that two machines run different builds.

import Foundation
import Yaml

// MARK: - Git sync (shares ShiftGitSync's clone and queue - see file header)

final class ReadingListGitSync {
    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    static let subpath = "GrandLineDocs/reading-list"

    let workingTree: URL
    let dataRoot: URL
    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue

    private(set) var status: Status = .synced
    private var statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?

    /// `true` only for `.shared`. A standalone instance clones its own tree,
    /// so a suite can never reach `ShiftGitSync.shared`'s production clone.
    private let sharesProductionWorkingTree: Bool

    init(workingTree: URL, remoteURL: String, branch: String = "main",
         debounceInterval: TimeInterval = 3.0, queue: DispatchQueue,
         sharesProductionWorkingTree: Bool = false) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.subpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.sharesProductionWorkingTree = sharesProductionWorkingTree
    }

    static let shared = ReadingListGitSync(
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

    /// Production entry point. Dispatches onto `queue` rather than blocking
    /// `ReadingListStore.init()`, which runs on the main thread at launch -
    /// GL-12: nothing synchronous and slow before the window exists.
    func start() {
        queue.async { [weak self] in self?.ensureReadyNow() }
    }

    @discardableResult
    func ensureReadyNow() -> Bool {
        let ok = sharesProductionWorkingTree
            ? ShiftGitSync.shared.ensureWorkingTreeNow()
            : ensureStandaloneWorkingTreeNow()
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
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
            try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            setStatus(.failed("Could not clone \(remoteURL): \(clone.stderr.isEmpty ? "unknown error" : clone.stderr)"))
            return false
        }
        return true
    }

    /// Called right after a local write has already completed synchronously.
    /// Rapid edits - marking three articles read - coalesce into one commit.
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

    /// How long the quit-time flush holds the main thread. Short, for
    /// `StickyBoardGitSync.terminateFlushBudget`'s own reason: the local write
    /// already landed, and an abandoned push is picked up by the next launch's
    /// `ensureReadyNow()`.
    static let terminateFlushBudget: TimeInterval = 3.0

    @discardableResult
    func flushForTerminationNow() -> Bool {
        let lock = NSLock()
        var committed = false
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else { done.signal(); return }
            // Cancelled *inside* the queue block: `pendingCommit` is only ever
            // touched on `queue`, and a serial queue guarantees the pending
            // item is not running concurrently with this one.
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
                reading list: quit-time git flush still running after \
                \(Self.terminateFlushBudget, privacy: .public)s - letting the app quit; \
                the links are already on disk and the next launch re-commits
                """)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    #if FM_SELFTESTS
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
        let add = runGit(["add", "-A", "--", Self.subpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Reading list: \(dirty.count) file(s) updated"],
                            cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        // GL-22: only the real remote is gated, so a suite pushing to a
        // disposable local bare repo never shells out to `gh`.
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
        let result = runGit(["status", "--short", "--", Self.subpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // GL-15: one shared runner and one copy of the git token injection.
    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> SubprocessResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? remoteURL : nil,
                       timeout: 600)
    }
}

// MARK: - The store

final class ReadingListStore {

    private let fm = FileManager.default
    let root: URL

    /// `nil` when an `FM_*` override replaced `root` - the same convention
    /// `ShiftStore.gitSync` / `StickyBoardStore.gitSync` use.
    let gitSync: ReadingListGitSync?

    private(set) var links: [ReadingLink] = []

    private var linksPath: String { root.appendingPathComponent("links.yaml").path }
    private var iconsRoot: URL { root.appendingPathComponent("icons", isDirectory: true) }

    /// GL-01's first half: `true` once the last read found real content this
    /// store could not parse. Every write is refused while it holds.
    private(set) var isInFailedLoadState = false

    /// GL-01's second half, and the full-app audit's finding 4.2: records this
    /// build could not decode, kept verbatim so `persist()` writes them
    /// straight back. A link saved by a newer build must survive an older
    /// build's edits - that is the cross-machine skew the git sync exists to
    /// serve, and dropping it would destroy data rather than only hide it.
    private var unreadableRecords: [(sortKey: Date, raw: Yaml)] = []

    var unreadableRecordCount: Int { unreadableRecords.count }

    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_READING_LIST_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("reading-list", isDirectory: true)
            gitSync = nil
        } else {
            let sync = ReadingListGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reloadAll()
    }

    /// Test seam: an explicitly-rooted, git-free store, so a suite never has
    /// to depend on process-wide environment to stay off the real clone.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reloadAll()
    }

    // MARK: Reading

    func reloadAll() {
        switch ShiftYaml.readListChecked(path: linksPath, key: "links") {
        case .ok(let items):
            isInFailedLoadState = false
            var decoded: [ReadingLink] = []
            var unreadable: [(sortKey: Date, raw: Yaml)] = []
            for item in items {
                if let link = Self.link(from: item) {
                    decoded.append(link)
                } else {
                    unreadable.append((Self.addedAtOrDistantFuture(item), item))
                }
            }
            if !unreadable.isEmpty {
                AppLog.store.info("""
                    Reading list: \(unreadable.count, privacy: .public) record(s) in \
                    \(self.linksPath, privacy: .public) could not be decoded by this build - \
                    preserving them verbatim rather than dropping them on the next write.
                    """)
            }
            unreadableRecords = unreadable
            links = decoded.sorted { $0.addedAt < $1.addedAt }
        case .missing:
            isInFailedLoadState = false
            links = []
        case .parseFailed:
            if !isInFailedLoadState {
                StoreLoadFailure.backUp(URL(fileURLWithPath: linksPath), label: "Reading list")
            }
            isInFailedLoadState = true
            // `links` is left exactly as it was: a parse failure must never be
            // read as "there are now zero saved links".
        }
    }

    func link(id: String) -> ReadingLink? { links.first { $0.id == id } }

    // MARK: Writing

    /// What one `add` did - the caller needs to tell the captain, and "already
    /// saved" is a different sentence from "saved".
    enum AddOutcome: Equatable {
        case added(ReadingLink)
        /// The same URL was already on the list. Carries the existing link so
        /// the page can scroll to it rather than silently doing nothing.
        case duplicate(ReadingLink)
        case rejected(String)
    }

    /// Save one captured string.
    ///
    /// Normalisation happens **here**, once, so the card, the duplicate check
    /// and the file all hold the same string - `CaptureRouter.snippetName`'s
    /// own note records what happens when a panel shows one thing and a store
    /// writes another.
    @discardableResult
    func add(_ raw: String, tags: [String] = [], now: Date = Date()) -> AddOutcome {
        guard !isInFailedLoadState else {
            return .rejected("The reading list file could not be read, so nothing new can be saved to it.")
        }
        guard let url = ReadingListURL.detect(raw) else {
            return .rejected("That does not look like a web link.")
        }
        if let existing = ReadingListQuery.existing(url, in: links) {
            return .duplicate(existing)
        }
        let link = ReadingLink(id: UUID().uuidString,
                               url: url,
                               tags: ReadingListTags.normaliseList(tags),
                               addedAt: now)
        links.append(link)
        persist()
        return .added(link)
    }

    /// Record what `LinkPresentation` said. The icon is written to its own
    /// per-host file rather than into the YAML - see
    /// `ReadingListMetadata.swift`'s header.
    func applyMetadata(id: String, _ metadata: ReadingListMetadata) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].title = metadata.title
        // A page's own description is only overwritten when the fetch
        // actually produced one: a retry that comes back thinner must not
        // erase what an earlier, better fetch found.
        if !metadata.summary.isEmpty { links[index].summary = metadata.summary }
        links[index].metadataState = .resolved
        if let png = metadata.iconPNG { writeIcon(png, forHost: links[index].host) }
        persist()
    }

    func applyMetadataFailure(id: String, reason: String) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].metadataState = .failed(reason)
        persist()
    }

    /// Put a link back in the queue for a metadata fetch - the card's Retry.
    func markMetadataPending(id: String) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].metadataState = .pending
        persist()
    }

    /// Returns the link's new state so a caller can offer an Undo that
    /// restores the value it already had in hand (GL-33) rather than guessing
    /// at it.
    @discardableResult
    func setRead(id: String, read: Bool, now: Date = Date()) -> ReadingLink? {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return nil }
        // Idempotent: re-marking a read link read must not move `readAt`, or
        // the Read slice's newest-first order would reshuffle on a doubled
        // click.
        guard links[index].isRead != read else { return links[index] }
        links[index].readAt = read ? now : nil
        persist()
        return links[index]
    }

    @discardableResult
    func setTags(id: String, tags: [String]) -> ReadingLink? {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return nil }
        links[index].tags = ReadingListTags.normaliseList(tags)
        persist()
        return links[index]
    }

    @discardableResult
    func setAISummary(id: String, summary: String) -> ReadingLink? {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return nil }
        links[index].aiSummary = summary
        persist()
        return links[index]
    }

    /// Removes and returns the link, so a caller can offer an Undo via
    /// `restore(_:)` - GL-33's rule again.
    @discardableResult
    func delete(id: String) -> ReadingLink? {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = links.remove(at: index)
        persist()
        // The icon file is deliberately **not** removed: it is keyed by host,
        // and another saved link may well share it. A stale icon for a host
        // with no links costs a few kilobytes and is reused the next time
        // something from that site is saved.
        return removed
    }

    /// The undo half of `delete`. A no-op when a link with that id is already
    /// back, which defends against a doubled Undo click.
    func restore(_ link: ReadingLink) {
        guard !links.contains(where: { $0.id == link.id }) else { return }
        links.append(link)
        persist()
    }

    // MARK: Icons

    /// The cached icon for a host, or `nil` - which is ordinary, and means the
    /// card draws its monogram tile instead.
    func iconPNG(forHost host: String) -> Data? {
        guard let name = ReadingListIconCache.filename(forHost: host) else { return nil }
        return try? Data(contentsOf: iconsRoot.appendingPathComponent(name))
    }

    private func writeIcon(_ png: Data, forHost host: String) {
        guard let name = ReadingListIconCache.filename(forHost: host) else { return }
        do {
            try fm.createDirectory(at: iconsRoot, withIntermediateDirectories: true)
            // GL-30: through `AtomicWrite`, like every other store write here.
            // Not `sensitive:` - a favicon is a public asset.
            try AtomicWrite.data(png, to: iconsRoot.appendingPathComponent(name))
        } catch {
            // GL-10 says no silent `try?` on a persistence write; it does not
            // say a cosmetic cache failure should interrupt the captain. The
            // log is the report, and the card falls back to its monogram.
            AppLog.store.error("""
                Reading list: could not cache the icon for \(host, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: Persisting

    /// The one write choke point. Refuses to write a file this store could not
    /// read (GL-01), reports a genuine write failure rather than swallowing it
    /// (GL-10), and arms the git debounce afterwards.
    private func persist() {
        guard !isInFailedLoadState else {
            AppLog.store.error("""
                Reading list: refusing to write \(self.linksPath, privacy: .public) - its last read \
                failed to parse (GL-01). Fix or remove the file, then reload.
                """)
            return
        }
        // Decoded links and preserved-but-unreadable records merge back into
        // one `added_at`-ordered list, so a record this build cannot read
        // keeps its place in the file rather than drifting to the end on every
        // write (which would make `git diff` unreadable for the build that
        // *can* read it).
        var merged: [(sortKey: Date, raw: Yaml)] =
            links.map { ($0.addedAt, Self.yaml($0)) } + unreadableRecords
        merged.sort { $0.sortKey < $1.sortKey }
        do {
            try ShiftYaml.writeList(path: linksPath, key: "links", items: merged.map(\.raw))
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "Reading list", path: linksPath, error: error)
            return
        }
        gitSync?.markDirty()
    }

    // MARK: YAML - reuses `ShiftYamlBridge`'s scalar helpers

    private static func yaml(_ link: ReadingLink) -> Yaml {
        var m = YamlOrderedMap()
        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(link.id)
        m[ShiftYamlBridge.key("url")] = ShiftYamlBridge.str(link.url)
        m[ShiftYamlBridge.key("title")] = ShiftYamlBridge.str(link.title)
        m[ShiftYamlBridge.key("summary")] = ShiftYamlBridge.str(link.summary)
        m[ShiftYamlBridge.key("ai_summary")] = ShiftYamlBridge.str(link.aiSummary)
        m[ShiftYamlBridge.key("tags")] = .array(link.tags.map { ShiftYamlBridge.str($0) })
        m[ShiftYamlBridge.key("added_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(link.addedAt))
        m[ShiftYamlBridge.key("metadata_state")] = ShiftYamlBridge.str(link.metadataState.rawValue)
        // Written only when set, so an ordinary unread link's record carries
        // no key claiming a failure or a read date it does not have - and a
        // whole-file rewrite does not touch lines it had no reason to.
        if let reason = link.metadataState.failureReason {
            m[ShiftYamlBridge.key("metadata_error")] = ShiftYamlBridge.str(reason)
        }
        if let readAt = link.readAt {
            m[ShiftYamlBridge.key("read_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(readAt))
        }
        return .dictionary(m)
    }

    private static func addedAtOrDistantFuture(_ y: Yaml) -> Date {
        guard let dict = y.dictionary else { return .distantFuture }
        return ShiftYamlBridge.date(dict[ShiftYamlBridge.key("added_at")]) ?? .distantFuture
    }

    /// The hand-written decoder. **Every field needs a real fallback on the
    /// way in, never only a Swift-side default** - GL-01, and AGENTS.md
    /// records this app losing a whole `hosts.json` to exactly that mistake.
    /// Only `id` and `url` are required, because a record without either is
    /// not a link at all; everything else has a stated default, so a file
    /// written by an older build still loads.
    private static func link(from y: Yaml) -> ReadingLink? {
        guard let dict = y.dictionary,
              let id = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("id")]),
              let url = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("url")]),
              !id.isEmpty, !url.isEmpty else { return nil }
        let title = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("title")]) ?? ""
        let summary = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("summary")]) ?? ""
        let aiSummary = ShiftYamlBridge.string(dict[ShiftYamlBridge.key("ai_summary")]) ?? ""
        let tags = ReadingListTags.normaliseList(
            (dict[ShiftYamlBridge.key("tags")]?.array ?? []).compactMap { ShiftYamlBridge.string($0) })
        let addedAt = ShiftYamlBridge.date(dict[ShiftYamlBridge.key("added_at")]) ?? Date()
        let readAt = ShiftYamlBridge.date(dict[ShiftYamlBridge.key("read_at")])
        let state = Self.metadataState(
            raw: ShiftYamlBridge.string(dict[ShiftYamlBridge.key("metadata_state")]),
            reason: ShiftYamlBridge.string(dict[ShiftYamlBridge.key("metadata_error")]))
        return ReadingLink(id: id, url: url, title: title, summary: summary, aiSummary: aiSummary,
                           tags: tags, addedAt: addedAt, readAt: readAt, metadataState: state)
    }

    /// An unknown or absent state reads as `.pending`, never as `.resolved`.
    ///
    /// The direction matters: `.pending` costs one metadata fetch, and
    /// `.resolved` would make the card present an empty title as a fetched
    /// one, which is the GL-14 failure this feature's whole three-valued state
    /// exists to avoid.
    private static func metadataState(raw: String?, reason: String?) -> ReadingLinkMetadataState {
        switch raw {
        case "resolved": return .resolved
        case "failed": return .failed(reason ?? "That page could not be read.")
        default: return .pending
        }
    }
}
