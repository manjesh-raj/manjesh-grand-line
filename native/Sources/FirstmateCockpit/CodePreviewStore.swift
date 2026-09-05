// Manjesh Grand Line - native macOS app.
//
// The Code Preview destination's persistence: every open snippet, in the
// captain's own `manjesh-config` repo, synced automatically.
//
// ## The layout, and why the filename carries everything
//
// One file per snippet in a folder of this feature's own:
//
//     GrandLineDocs/code-snippets/
//         HostRow.swift
//         values.yaml
//         deploy.sh
//         notes.txt
//
// That is the whole schema. There is **no index file and no metadata sidecar**,
// and both omissions are decisions rather than shortcuts:
//
//   - **The filename is the tab name**, verbatim. The reviewed mockup's tabs
//     read "HostRow.swift" / "config.yaml", which are filenames; making them
//     literally be filenames means a captain browsing the repo on GitHub sees
//     exactly the tabs they have open, with the names they gave them.
//   - **The extension is the language**, the same way every editor on earth
//     decides it. Picking a different language in the picker renames the file,
//     which is a real, visible, self-explanatory side effect rather than
//     hidden state - and it is precisely what VS Code does.
//   - **The body is the code, byte for byte.** A YAML or JSON wrapper would
//     make every snippet one escaped line in `git diff`
//     (`YamlBeautify.dump` escapes `\n` rather than emitting a block scalar),
//     which for a feature whose entire content is code would make the git
//     history worthless. This is the one store in this app whose payload is
//     *already* a file format, so it is stored as one.
//   - **No shared file means no shared conflict.** Two machines editing two
//     different snippets touch two different files and merge cleanly. An
//     `index.yaml` holding the tab order would be edited by every change on
//     both machines, i.e. a conflict magnet for metadata nobody misses.
//
// The cost, stated because it is real: **tab order is filename order.** With no
// index there is nowhere to keep a captain-chosen order, so renaming a tab can
// move it. Sorted, stable and predictable was judged the better trade against a
// shared file that conflicts, or an order prefix baked into every filename.
//
// ## Sync
//
// `CodePreviewGitSync` is `DocsRunbookGitSync` with one subpath changed, and
// that is the point: it shares `ShiftGitSync.shared`'s working tree and its
// serial git queue rather than cloning a second copy of `manjesh-config`, so
// the two stores' git invocations serialize against one working tree instead of
// racing on `.git/index.lock`. It owns only a debounced commit+push scoped to
// `GrandLineDocs/code-snippets`; the clone/pull/repo-layout-migration mechanics
// stay in `ShiftGitSync.shared.ensureWorkingTreeNow()`.
//
// There is no Save button anywhere in this feature. An edit reaches disk when
// the page's own 500ms debounce fires, and reaches GitHub `debounceInterval`
// after that.

import Foundation

// MARK: - A single snippet

struct CodePreviewSnippet: Identifiable, Equatable {
    /// The filename, extension included - and therefore also the tab label and
    /// the on-disk identity. See the file header for why these are one thing.
    let id: String
    var content: String
    var modifiedAt: Date

    var language: CodePreviewLanguage { CodePreviewLanguage.forFilename(id) }

    /// The name without its extension - what a rename dialog should start
    /// from, and what a language change keeps.
    var baseName: String {
        let base = (id as NSString).deletingPathExtension
        return base.isEmpty ? id : base
    }

}

// MARK: - Git sync (shares ShiftGitSync's clone/queue - see file header)

final class CodePreviewGitSync {
    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    /// A folder of this feature's own, a sibling of Shift's `personal-tasks/`
    /// and the Docs runbooks - never shared with either. Changing this string
    /// orphans every snippet already pushed, so it is deliberately one
    /// constant used by both the store and the git scoping.
    static let snippetsSubpath = "GrandLineDocs/code-snippets"

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
    /// any future non-production use) owns and clones its own working tree
    /// instead, so a test can never touch `ShiftGitSync.shared`'s real
    /// production clone.
    private let sharesProductionWorkingTree: Bool

    init(
        workingTree: URL, remoteURL: String, branch: String = "main",
        debounceInterval: TimeInterval = 3.0, queue: DispatchQueue,
        sharesProductionWorkingTree: Bool = false
    ) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.snippetsSubpath, isDirectory: true)
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
    static let shared = CodePreviewGitSync(
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

    /// Production entry point - dispatches onto `queue` asynchronously, never
    /// blocking the caller (`CodePreviewStore.init()`, on the main thread).
    /// Tests that need to observe the result synchronously call
    /// `ensureReadyNow()` directly, mirroring `ShiftGitSync`'s own
    /// `start()`/`ensureWorkingTreeNow()` split.
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

    /// Only reached when `sharesProductionWorkingTree` is `false` - a
    /// standalone instance against a disposable repo, whose layout is right by
    /// construction (no repo-layout migration needed, unlike `ShiftGitSync`'s).
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

    /// Called right after a local write has already completed synchronously -
    /// the same debounce shape as `ShiftGitSync.markDirty()`, so a burst of
    /// edits is one commit rather than one per keystroke.
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
        let add = runGit(["add", "-A", "--", Self.snippetsSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Code snippets: \(dirty.count) file(s) updated"],
                            cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        // GL-22: code snippets go to `manjesh-config` too, and a snippet is
        // whatever the captain pasted - which may well be a config file. Same
        // gate and the same scoping rule as `ShiftGitSync.pushOnly`: only the
        // real remote is checked, so a self-test against a disposable local
        // bare repo never shells out to `gh`.
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
        let result = runGit(["status", "--short", "--", Self.snippetsSubpath], cwd: workingTree, authenticated: false)
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

final class CodePreviewStore {

    private let fm = FileManager.default
    let root: URL
    /// `nil` when an env override bypasses git sync - the same convention as
    /// `ShiftStore.gitSync` / `DocsRunbookStore.gitSync`.
    let gitSync: CodePreviewGitSync?

    /// Root resolution mirrors `LogAnalyzerStore`'s and `IncidentStore`'s,
    /// **including honouring `FM_SHIFT_DIR`**: a store living inside
    /// `ShiftGitSync`'s working tree that ignored it would let a self-test
    /// which sets only `FM_SHIFT_DIR` (the established way to keep away from
    /// the captain's real synced clone) still write into production. That was
    /// a real bug in `CommandLibraryStore` once; see AGENTS.md.
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_CODE_PREVIEW_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("code-snippets", isDirectory: true)
            gitSync = nil
        } else {
            let sync = CodePreviewGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Test seam: an explicitly-rooted, git-free store, so a suite never has to
    /// depend on process-wide environment to stay off the real clone. Same
    /// shape as `IncidentStore.init(root:)`.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// Every snippet, in tab order - which is filename order (see the file
    /// header's note on the cost of having no index).
    ///
    /// `localizedStandardCompare` rather than a plain `<` so `snippet-2` sorts
    /// before `snippet-10` instead of after it, which is the one place a plain
    /// lexicographic sort reads as a bug.
    func list() -> [CodePreviewSnippet] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .compactMap { url -> CodePreviewSnippet? in
                // A snippet is text by definition. A file that is not valid
                // UTF-8 is something else that landed in this folder, and
                // showing it as mojibake would be worse than skipping it.
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                return CodePreviewSnippet(id: url.lastPathComponent, content: content, modifiedAt: modified)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Just the filenames, in the same order `list()` returns them, without
    /// reading a single file's contents.
    ///
    /// The canvas module needs "how many, and what are they called", and a
    /// snippet's content can be large - `list()` would `String(contentsOf:)`
    /// every one of them on every return to the hub.
    func names() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Writing

    /// Creates a snippet, disambiguating its filename if one is already taken.
    @discardableResult
    func create(name: String, content: String) -> CodePreviewSnippet {
        let unique = availableName(basedOn: Self.sanitize(name))
        write(name: unique, content: content)
        return CodePreviewSnippet(id: unique, content: content, modifiedAt: Date())
    }

    /// The name a brand-new, unnamed snippet gets: `snippet-1.txt`,
    /// `snippet-2.txt`, … - the first number not already in use.
    ///
    /// Two things it has to get right, both of which it got wrong first:
    ///
    ///   - **The stem is what is taken, not the filename.** A snippet's
    ///     extension changes the moment its language is detected, so once
    ///     `snippet-1.txt` has become `snippet-1.swift` a full-filename check
    ///     hands out `snippet-1.txt` again - and the moment *that* one is
    ///     detected as Swift it collides and lands on `snippet-1-2.swift`.
    ///   - **`avoiding` covers tabs that are open but not yet on disk.** A new
    ///     tab is deliberately not written until it has content (see
    ///     `CodePreviewController`), so a disk-only check would hand two empty
    ///     tabs the same name and the first one to be typed into would take
    ///     the other's file.
    func nextUntitledName(extension ext: String = CodePreviewLanguage.plainText.canonicalExtension,
                          avoiding: Set<String> = []) -> String {
        let stems = Set((names() + avoiding).map { ($0 as NSString).deletingPathExtension })
        var n = 1
        while stems.contains("snippet-\(n)") { n += 1 }
        return "snippet-\(n).\(ext)"
    }

    func save(name: String, content: String) {
        write(name: name, content: content)
    }

    /// Renames a snippet, i.e. moves its file. Returns the name it actually
    /// landed on, which differs from `to` when that name was taken.
    ///
    /// A rename is how *both* a tab rename and a language change are expressed
    /// (see the file header), so this is the one path either takes.
    @discardableResult
    func rename(from: String, to: String) -> String {
        let target = Self.sanitize(to)
        guard target != from else { return from }
        let unique = availableName(basedOn: target)
        let src = root.appendingPathComponent(from)
        let dst = root.appendingPathComponent(unique)
        do {
            try fm.moveItem(at: src, to: dst)
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "code snippet \"\(from)\"", path: dst.path, error: error)
            return from
        }
        gitSync?.markDirty()
        return unique
    }

    /// GL-10: never a bare `try?`, for the same reason `write(name:content:)`
    /// below spells out - and it matters more here than for a write. A delete
    /// this store swallowed leaves a snippet the panel has already closed
    /// still on disk, so it comes back on the next launch *and* stays synced
    /// to GitHub, with nothing anywhere saying the delete failed. "The file is
    /// already gone" is the one failure that genuinely is success, so it is
    /// the one case that reports nothing (a `markDirty` on it is harmless and
    /// keeps a stale committed copy from lingering).
    func delete(name: String) {
        let url = root.appendingPathComponent(name)
        do {
            try fm.removeItem(at: url)
            PersistenceFailureReporter.reportSuccess()
        } catch CocoaError.fileNoSuchFile {
            // Nothing to remove - the caller's intent is already satisfied.
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileNoSuchFile.rawValue {
            // Same case, reported through the bridged `NSError` shape.
        } catch {
            PersistenceFailureReporter.report(what: "code snippet \"\(name)\"", path: url.path, error: error)
            return
        }
        gitSync?.markDirty()
    }

    /// GL-10: never a bare `try?`. A snippet the panel showed as saved that
    /// simply does not exist is the exact failure this reporter was built for,
    /// and it matters more here than most - there is no Save button to press
    /// again, so a silent failure is silent forever.
    private func write(name: String, content: String) {
        let url = root.appendingPathComponent(name)
        do {
            try AtomicWrite.text(content, to: url)
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "code snippet \"\(name)\"", path: url.path, error: error)
            return
        }
        gitSync?.markDirty()
    }

    /// `name` if free, else `name-2`, `name-3`, … with the suffix inserted
    /// before the extension so the language survives disambiguation.
    private func availableName(basedOn name: String) -> String {
        guard fm.fileExists(atPath: root.appendingPathComponent(name).path) else { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !fm.fileExists(atPath: root.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    // MARK: Names

    /// Makes a captain-typed tab name safe to be a filename, without being
    /// precious about it: this is a name they will see again, so the goal is
    /// "the same name, minus what a filesystem cannot hold", not a slug.
    ///
    /// `/` and `:` are the two macOS genuinely cannot store (`:` is the
    /// classic HFS path separator and still shows up as `/` in Finder), a
    /// leading `.` would hide the file, and `..` would escape the folder.
    /// Everything else - spaces, unicode, capitals - is kept.
    ///
    /// **A leading `-` is stripped too, and that is not cosmetic.** Turning
    /// `/` into `-` means `../../escape.txt` arrives here as `..-..-escape.txt`,
    /// which after the dot strip would start with a dash - and a filename
    /// beginning with a dash is read as a *flag* by most command-line tools,
    /// `git` very much included. This store's whole point is that these files
    /// are committed and pushed, so a name `git add` would misread is a real
    /// problem rather than an ugly one.
    static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = cleaned.first, first == "." || first == "-" { cleaned.removeFirst() }
        // A filename this app writes has to survive a `git add`, and one long
        // enough to trip a filesystem limit would fail the write rather than
        // the sanitise, which is a much less legible failure.
        if cleaned.count > maxNameLength {
            let ns = cleaned as NSString
            let ext = ns.pathExtension
            let base = String(ns.deletingPathExtension.prefix(maxNameLength - ext.count - 1))
            cleaned = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return cleaned.isEmpty ? "snippet.txt" : cleaned
    }

    /// Comfortably under every filesystem's own 255-*byte* limit even for a
    /// name made entirely of 4-byte characters.
    static let maxNameLength = 60
}
