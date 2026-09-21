// Manjesh Grand Line - native macOS app.
//
// The Notebook destination's persistence (F1 of full review #3 §8).
//
// ## The layout
//
// Plain markdown files in a tree under `GrandLineDocs/notebook/`, in the SAME
// local clone of `manjesh-config` that `ShiftGitSync` already manages:
//
//     GrandLineDocs/notebook/
//         scratch.md
//         daily/
//             2026-09-21.md
//         migrations/
//             raas-cutover.md
//             node-drain.md
//
// That is the whole schema. There is **no index file and no metadata
// sidecar**, for the reasons `CodePreviewStore`'s header already records and
// which apply here word for word: the filename is the identity, the body is
// the page byte for byte, and no shared file means no shared conflict. What is
// different from Code Preview is that this store is a *tree* rather than a
// flat folder - a notebook without folders is a list, and the report's own F1
// entry asks for "pages in a tree".
//
// **A page's id is its path relative to the root, without `.md`** -
// `migrations/raas-cutover`, `daily/2026-09-21`, `scratch`. That is stable
// across a title edit (the `# Heading` inside the file changes, the file does
// not), which is what makes `[[wiki-links]]` and the backlink index worth
// building at all: a link that broke every time somebody fixed a typo in a
// heading would be worse than no link.
//
// ## Why this is not a fourth copy of `DocsRunbookStore`
//
// It is a *fifth* instance of the same git-sync shape (`ShiftGitSync`,
// `DocsRunbookGitSync`, `CredentialVaultSync`, `CodePreviewGitSync`, this),
// and the duplication is the same deliberate call `CodePreviewStore`'s header
// makes: the shape is shared, the surface is not. Each of them owns a
// different subtree, a different commit message, a different dirty-file
// predicate and a different `FM_*` override, and a base class parameterised on
// all four would be a type whose every method took a "which store am I"
// argument. What they genuinely share - the working tree, the serial queue,
// the clone/pull mechanics, the `ConfigRepoPrivacy` gate and the one
// `Subprocess.git` runner - is shared, and that is the part that would
// actually hurt if it diverged.
//
// ## Sync
//
// `NotebookGitSync` shares `ShiftGitSync.shared`'s `workingTree` and serial
// `queue` (GL-02/GL-15, and AGENTS.md's "Git-backed stores share one working
// tree and one serial queue"), so this store's git invocations serialise
// against the same tree instead of racing on `.git/index.lock`. It owns only a
// debounced commit+push scoped to `GrandLineDocs/notebook`.
//
// There is no Save button anywhere in this feature: an edit reaches disk when
// the editor's own 500ms debounce fires, and reaches GitHub `debounceInterval`
// after that - exactly Code Preview's contract, because it is literally the
// same Monaco page underneath.

import Foundation

// MARK: - A single page

struct NotebookPage: Identifiable, Equatable {
    /// The path relative to the notebook root, without `.md` - the on-disk
    /// identity, stable across a title edit. See the file header.
    let id: String
    /// The first `# Heading`, or the humanised final path component.
    var title: String
    var content: String
    var modifiedAt: Date

    /// The folder this page sits in, `""` for a top-level page.
    var folder: String {
        guard let slash = id.lastIndex(of: "/") else { return "" }
        return String(id[id.startIndex..<slash])
    }

    /// The final path component, without `.md`.
    var slug: String {
        guard let slash = id.lastIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// Is this one of the dated pages the "Today's note" button writes?
    var isDailyNote: Bool { folder == NotebookStore.dailyFolder }

    /// Words in the body, for the page inspector. Whitespace-separated runs,
    /// which is what every word count in every editor means - deliberately
    /// not a markdown-aware count, since the captain is looking at the same
    /// text the editor shows.
    var wordCount: Int {
        content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

// MARK: - Git sync (shares ShiftGitSync's clone/queue - see file header)

final class NotebookGitSync {
    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    /// A folder of this feature's own, a sibling of Shift's `personal-tasks/`,
    /// the Docs runbooks and the code snippets - never shared with any of
    /// them. Changing this string orphans every page already pushed, so it is
    /// deliberately one constant used by both the store and the git scoping.
    static let notebookSubpath = "GrandLineDocs/notebook"

    let workingTree: URL
    let dataRoot: URL
    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue

    private(set) var status: Status = .synced
    private var statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?

    /// `true` only for `.shared`. A standalone instance (every self-test, and
    /// any future non-production use) owns and clones its own working tree, so
    /// a test can never touch `ShiftGitSync.shared`'s real production clone.
    private let sharesProductionWorkingTree: Bool

    init(
        workingTree: URL, remoteURL: String, branch: String = "main",
        debounceInterval: TimeInterval = 3.0, queue: DispatchQueue,
        sharesProductionWorkingTree: Bool = false
    ) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.notebookSubpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.sharesProductionWorkingTree = sharesProductionWorkingTree
    }

    /// Reuses `ShiftGitSync.shared`'s own working tree, remote and serial
    /// queue - see this file's header. `ShiftGitSync.resolveDefaultRemoteURL()`
    /// already honours `FM_SHIFT_REMOTE_URL`, which is what lets a whole test
    /// instance of the app point at a disposable local bare repo instead of
    /// the real `manjesh-config`.
    static let shared = NotebookGitSync(
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

    /// GL-04/GL-12: dispatches the real work onto `queue` asynchronously,
    /// never blocking the caller (`NotebookStore.init()`, on the main thread
    /// during a destination's first mount).
    func start() {
        queue.async { [weak self] in self?.ensureReadyNow() }
    }

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

    /// Called right after a local markdown write has already completed
    /// synchronously - same debounce shape as `ShiftGitSync.markDirty()`.
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

    /// How long the quit path may wait for a commit already in flight.
    static let terminateFlushBudget: TimeInterval = 2.0

    /// §4.3's shape, applied to this store: the terminate-time flush
    /// dispatches **onto** the shared queue (so it cannot race whatever is
    /// already running there), cancels the pending debounce *inside* the queue
    /// block, and is bounded so a wedged git never blocks ⌘Q.
    @discardableResult
    func flushForTerminationNow() -> Bool {
        var committed = false
        let lock = NSLock()
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
                notebook: quit-time git flush still running after \
                \(Self.terminateFlushBudget, privacy: .public)s - letting the app quit; \
                the pages are already on disk and the next launch re-commits
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
        let add = runGit(["add", "-A", "--", Self.notebookSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Notebook: \(dirty.count) page(s) updated"],
                            cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        // GL-22: notebook pages go to `manjesh-config` too, and a notebook is
        // the least predictable payload in this repo - it is whatever the
        // captain wrote down. Same gate and the same scoping rule as
        // `ShiftGitSync.pushOnly`: only the real remote is checked, so a
        // self-test against a disposable local bare repo never shells out to
        // `gh`.
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
        let result = runGit(["status", "--short", "--", Self.notebookSubpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Process plumbing

    // GL-15: one shared runner and one copy of the git token injection - see
    // `Subprocess.gitAuthEnvironment`. Bounded, for the same reason
    // `DocsRunbookGitSync` is: this class shares `ShiftGitSync`'s working tree
    // and serial queue, so an unbounded fetch here parks both.
    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> SubprocessResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? remoteURL : nil,
                       timeout: 600)
    }
}

// MARK: - Local CRUD store

final class NotebookStore {

    private let fm = FileManager.default
    let root: URL
    /// `nil` when an env override bypasses git sync - the same convention as
    /// `ShiftStore.gitSync` / `DocsRunbookStore.gitSync` / `CodePreviewStore.gitSync`.
    let gitSync: NotebookGitSync?

    /// The folder "Today's note" writes into. One constant, because the
    /// sidebar's Daily-notes section, the button, and `NotebookPage.isDailyNote`
    /// all have to agree about which pages are dated.
    static let dailyFolder = "daily"

    /// How deep the tree is walked. A notebook is a notebook, not a
    /// filesystem browser - and GL-35 forbids an unbounded scan on a path a
    /// page hits on every appearance. Four levels is deeper than any real
    /// outline and shallow enough that a stray `node_modules` somebody dropped
    /// in the config repo cannot cost a visible pause.
    static let maxDepth = 4

    /// GL-35: the cap on how many pages are ever read into memory at once. A
    /// notebook that genuinely grew past this is reported honestly (see
    /// `listPages(overflow:)`), never silently truncated.
    static let maxPages = 2000

    /// Root resolution mirrors `CodePreviewStore`'s and `DocsRunbookStore`'s,
    /// **including honouring `FM_SHIFT_DIR`** - which AGENTS.md records as the
    /// hermeticity hole `DocsRunbookStore` shipped with: a store living inside
    /// `ShiftGitSync`'s working tree that ignored the root override would let a
    /// self-test setting only `FM_SHIFT_DIR` still write into the captain's
    /// real clone. `main.swift`'s `#if FM_SELFTESTS` block sets
    /// `FM_NOTEBOOK_DIR` as well, so this is the belt to that brace.
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_NOTEBOOK_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("notebook", isDirectory: true)
            gitSync = nil
        } else {
            let sync = NotebookGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
            // Deliberately no eager `createDirectory` on this branch, for the
            // reason `DocsRunbookStore.init` states: `ensureReadyNow()` makes
            // the directory itself, *after* the clone-into-temp-and-swap has
            // landed.
            return
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Test seam: an explicitly-rooted, git-free store, so a suite never has
    /// to depend on process-wide environment to stay off the real clone. Same
    /// shape as `CodePreviewStore.init(root:)`.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// Every page in the tree, sorted by id so the sidebar's order is stable
    /// and folder-grouped.
    ///
    /// `localizedStandardCompare` rather than a plain `<` so `note-2` sorts
    /// before `note-10`, which is the one place a lexicographic sort reads as
    /// a bug.
    func listPages() -> [NotebookPage] { listPages(overflow: nil) }

    /// The same read, reporting how many pages were past `maxPages`.
    ///
    /// GL-35's cap with GL-14's honesty: a caller that wants to *say* "showing
    /// 2000 of 2143" can, and the one that does not still gets a bounded list.
    func listPages(overflow: UnsafeMutablePointer<Int>?) -> [NotebookPage] {
        var found: [URL] = []
        var skipped = 0
        collectMarkdown(in: root, depth: 0, into: &found, skipped: &skipped)
        overflow?.pointee = skipped
        return found
            .compactMap(page(at:))
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// One page, or `nil` when no file backs that id.
    func page(id: String) -> NotebookPage? {
        guard let url = fileURL(for: id) else { return nil }
        return page(at: url)
    }

    func exists(id: String) -> Bool {
        guard let url = fileURL(for: id) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    /// Every folder that holds at least one page, sorted. Derived from the
    /// pages rather than from a directory listing, so an empty folder left
    /// behind by a delete does not appear as a section with nothing in it.
    func folders(in pages: [NotebookPage]) -> [String] {
        Array(Set(pages.map(\.folder).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func page(at url: URL) -> NotebookPage? {
        // A page is text by definition. A file that is not valid UTF-8 is
        // something else that landed in this folder, and rendering it as
        // mojibake would be worse than skipping it.
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        guard let id = Self.identifier(of: url, under: root) else { return nil }
        return NotebookPage(id: id,
                            title: Self.titleFromContent(content, fallback: Self.humanise(lastComponentOf: id)),
                            content: content,
                            modifiedAt: modified)
    }

    private func collectMarkdown(in dir: URL, depth: Int, into found: inout [URL], skipped: inout Int) {
        guard depth <= Self.maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            // GL-21: "the directory could not be enumerated" is not "the
            // directory is empty". Nothing here overwrites anything, so the
            // cost is only a missing subtree - but it is logged rather than
            // swallowed, because a notebook that silently lost a folder is
            // exactly the kind of thing a captain would not think to report.
            AppLog.lifecycle.error("notebook: could not enumerate \(dir.lastPathComponent, privacy: .public)")
            return
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                collectMarkdown(in: entry, depth: depth + 1, into: &found, skipped: &skipped)
            } else if entry.pathExtension.lowercased() == "md" {
                if found.count >= Self.maxPages { skipped += 1; continue }
                found.append(entry)
            }
        }
    }

    // MARK: Writing

    /// Creates a page, disambiguating its slug against what is already there.
    /// Returns the page as written, so a caller never has to re-read to learn
    /// the id it actually got.
    @discardableResult
    func createPage(title: String, folder: String = "", content: String? = nil) -> NotebookPage {
        let base = Self.slugify(title)
        var slug = base
        var n = 2
        while exists(id: Self.join(folder: folder, slug: slug)) {
            slug = "\(base)-\(n)"
            n += 1
        }
        let id = Self.join(folder: folder, slug: slug)
        let body = content ?? "# \(title)\n\n"
        write(id: id, content: body, what: "notebook page \"\(title)\"")
        return NotebookPage(id: id,
                            title: Self.titleFromContent(body, fallback: Self.humanise(lastComponentOf: id)),
                            content: body,
                            modifiedAt: Date())
    }

    /// Overwrites a page's body. The id never moves, so this is the whole of
    /// what the editor's debounce has to do.
    func updatePage(id: String, content: String) {
        write(id: id, content: content, what: "notebook page \"\(id)\"")
    }

    func deletePage(id: String) {
        guard let url = fileURL(for: id) else { return }
        try? fm.removeItem(at: url)
        gitSync?.markDirty()
    }

    /// Moves a page to a new id (a rename, or a move between folders).
    ///
    /// Returns the id it actually landed on, which is `to` disambiguated
    /// against anything already there - never silently clobbering an existing
    /// page, which for a store whose files are the captain's own writing would
    /// be the worst failure this class could have.
    @discardableResult
    func renamePage(id: String, to newID: String) -> String? {
        guard let from = fileURL(for: id), fm.fileExists(atPath: from.path) else { return nil }
        let folder = newID.contains("/") ? String(newID[newID.startIndex..<newID.lastIndex(of: "/")!]) : ""
        let base = newID.contains("/") ? String(newID[newID.index(after: newID.lastIndex(of: "/")!)...]) : newID
        var slug = base
        var n = 2
        var target = Self.join(folder: folder, slug: slug)
        while target != id, exists(id: target) {
            slug = "\(base)-\(n)"
            n += 1
            target = Self.join(folder: folder, slug: slug)
        }
        guard target != id, let to = fileURL(for: target) else { return id }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            PersistenceFailureReporter.report(what: "renaming notebook page \"\(id)\"", path: to.path, error: error)
            return nil
        }
        gitSync?.markDirty()
        return target
    }

    /// GL-10: no silent `try?` on a persistence write. `try` at the write,
    /// `report` at the store. `AtomicWrite` creates intermediate directories,
    /// which is what lets a page be created straight into a folder that does
    /// not exist yet.
    private func write(id: String, content: String, what: String) {
        guard let url = fileURL(for: id) else {
            AppLog.lifecycle.error("notebook: refused a write to an unsafe page id")
            return
        }
        do {
            try AtomicWrite.text(content, to: url)
            PersistenceFailureReporter.reportSuccess()
            gitSync?.markDirty()
        } catch {
            PersistenceFailureReporter.report(what: what, path: url.path, error: error)
        }
    }

    // MARK: Daily notes

    /// Today's dated page, creating it if this is the first time it has been
    /// asked for today.
    ///
    /// The id is `daily/<yyyy-MM-dd>`, which is the same ISO day string
    /// `ShiftStore`, `LogAnalyzerStore`, `MorningBriefingData` and
    /// `StrawHatEnvelope` all already use for a dated key in this app - so a
    /// captain grepping their config repo for a date finds the day's tasks and
    /// the day's note with one pattern. The *heading* inside the file is the
    /// localised long form, because that is what a human reads at the top of a
    /// page; the *filename* is ISO, because that is what sorts.
    @discardableResult
    func openDailyNote(for date: Date = Date()) -> NotebookPage {
        let id = Self.dailyNoteID(for: date)
        if let existing = page(id: id) { return existing }
        let body = "# \(Self.dailyHeadingFormatter.string(from: date))\n\n"
        write(id: id, content: body, what: "today's note")
        return NotebookPage(id: id,
                            title: Self.dailyHeadingFormatter.string(from: date),
                            content: body,
                            modifiedAt: Date())
    }

    static func dailyNoteID(for date: Date) -> String {
        "\(dailyFolder)/\(isoDayFormatter.string(from: date))"
    }

    /// GL-P3's lesson: `DateFormatter` construction is measurably expensive
    /// and these are read on every render of the sidebar.
    static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Monday, 21 September 2026" in the captain's own locale -
    /// `setLocalizedDateFormatFromTemplate`, never a hardcoded order, which is
    /// the convention `ShiftStore.monthDayFormatter` already sets here.
    static let dailyHeadingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        return f
    }()

    // MARK: Identity helpers

    /// The file behind a page id, or `nil` when the id would escape the root.
    ///
    /// **This is a real check, not a formality.** A page id reaches this
    /// function from a `[[wiki-link]]` inside a markdown file, and a markdown
    /// file is something a git pull can deliver from another machine - so
    /// `[[../../.ssh/authorized_keys]]` is a path this app would otherwise
    /// resolve and write to. Same posture as GL-08's argv rule: the file the
    /// captain did not type is the delivery vector.
    func fileURL(for id: String) -> URL? {
        guard Self.isSafeIdentifier(id) else { return nil }
        return root.appendingPathComponent("\(id).md")
    }

    /// An id is a `/`-separated run of non-empty components, none of which is
    /// `.` or `..`, with no leading slash and no backslashes.
    static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\\"), !id.contains("\0") else { return false }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= maxDepth + 1 else { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { return false }
            if part.hasPrefix(".") { return false }
        }
        return true
    }

    /// The id of a file on disk, relative to `root`. `nil` for anything that
    /// is not genuinely under it.
    static func identifier(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        var relative = String(filePath.dropFirst(rootPath.count + 1))
        guard relative.hasSuffix(".md") else { return nil }
        relative.removeLast(3)
        return relative.isEmpty ? nil : relative
    }

    static func join(folder: String, slug: String) -> String {
        folder.isEmpty ? slug : "\(folder)/\(slug)"
    }

    /// The first non-empty line's `# Heading` text, or `fallback`. Identical
    /// in shape to `DocsRunbookStore.titleFromContent` - deliberately so, since
    /// both read the same convention out of the same kind of file.
    static func titleFromContent(_ content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# ") {
                let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
            }
            break
        }
        return fallback
    }

    static func slugify(_ title: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// `raas-cutover` -> `Raas cutover`. Only ever a *fallback* title, for a
    /// file with no `# Heading` - a page the captain titled keeps their words.
    static func humanise(lastComponentOf id: String) -> String {
        let slug = id.contains("/") ? String(id[id.index(after: id.lastIndex(of: "/")!)...]) : id
        let words = slug.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return slug }
        return String(first).uppercased() + words.dropFirst()
    }
}
