// Grand Line - native macOS app.
//
// F-04 of full review 4: find anything from Spotlight.
//
// Tasks and follow-ups, Notebook pages, saved links, sticky notes and
// runbooks are written to the system's Core Spotlight index, so they show up
// in Spotlight from anywhere on the Mac. Pressing Return opens Grand Line on
// that item through the same navigator calls ⌘K uses.
//
// **What is never indexed.** Nothing from the vault, Automic Vault or the
// clipboard history is ever handed to this file: `SpotlightIndex.entries`
// takes the five stores above and nothing else, and a source guard in the
// self-test holds that line.
//
// **While the app is locked** (the captain's product call, recommended
// option): Spotlight keeps the items but shows titles only. On lock the index
// is rewritten with every description, keyword and preview stripped, and on
// unlock the full entries go back. The other choice in Settings, "Nothing",
// removes every item on lock and adds them back on unlock. Opening a result
// while locked shows the lock screen with what is waiting to open, and opens
// it after the unlock (GL-09: `AppLockedSurface.spotlightResult`).
//
// **When it is rebuilt.** On launch, when the app goes to the background
// (which is when someone reaches for Spotlight), on every lock change, and
// every five minutes while the app is active. Not on every keystroke in a
// store: Spotlight only needs to be right by the time someone searches.

import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Entries

struct SpotlightEntry: Equatable {

    enum Kind: String, CaseIterable {
        case task, followUp, note, link, sticky, runbook

        /// The domain each kind is indexed under, so Settings can remove one
        /// kind without touching the rest.
        var domain: String { "com.manjesh.grandline.\(rawValue)" }

        var displayName: String {
            switch self {
            case .task: return "Task"
            case .followUp: return "Follow-up"
            case .note: return "Note"
            case .link: return "Reading list"
            case .sticky: return "Sticky note"
            case .runbook: return "Runbook"
            }
        }
    }

    var kind: Kind
    /// The record's own id in its store.
    var recordID: String
    var title: String
    /// The preview line Spotlight shows under the title. Stripped while
    /// locked.
    var detail: String
    var keywords: [String]

    /// `task:<id>`: the Spotlight unique identifier, and what an open parses.
    var identifier: String { "\(kind.rawValue):\(recordID)" }

    /// This entry as it may be shown while the app is locked: the title, and
    /// nothing a preview could show.
    var titleOnly: SpotlightEntry {
        SpotlightEntry(kind: kind, recordID: recordID, title: title, detail: "", keywords: [])
    }

    static func parse(identifier: String) -> (kind: Kind, recordID: String)? {
        guard let colon = identifier.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(identifier[..<colon])) else { return nil }
        let id = String(identifier[identifier.index(after: colon)...])
        return id.isEmpty ? nil : (kind, id)
    }
}

/// What may be in the index, built from the five stores and nothing else.
enum SpotlightIndex {

    struct Sources {
        var tasks: [ShiftTask] = []
        var followUps: [ShiftFollowUp] = []
        var projects: [ShiftProject] = []
        var pages: [NotebookPage] = []
        var links: [ReadingLink] = []
        var stickies: [StickyNote] = []
        var runbooks: [DocsRunbook] = []
    }

    static let previewLength = 220

    static func entries(from sources: Sources, enabled: Set<SpotlightEntry.Kind>) -> [SpotlightEntry] {
        var out: [SpotlightEntry] = []
        let projectNames = Dictionary(sources.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        if enabled.contains(.task) {
            for task in sources.tasks where task.status != .completed && task.status != .cancelled {
                var lines: [String] = []
                if let project = task.projectID.flatMap({ projectNames[$0] }) { lines.append(project) }
                if let due = task.dueDate { lines.append("Due \(due)") }
                if task.priority == .high { lines.append("High priority") }
                if !task.subtasks.isEmpty {
                    lines.append("Checklist \(task.subtasks.filter(\.done).count) of \(task.subtasks.count) done")
                }
                let notes = [task.description, task.notes ?? ""].first { !$0.isEmpty } ?? ""
                if !notes.isEmpty { lines.append(preview(notes)) }
                out.append(SpotlightEntry(kind: .task, recordID: task.id, title: task.title,
                                          detail: lines.joined(separator: " \u{00B7} "), keywords: task.tags))
            }
        }
        if enabled.contains(.followUp) {
            for followUp in sources.followUps where followUp.status != .done {
                out.append(SpotlightEntry(kind: .followUp, recordID: followUp.id, title: followUp.title,
                                          detail: preview(followUp.notes ?? ""), keywords: []))
            }
        }
        if enabled.contains(.note) {
            for page in sources.pages {
                let folder = page.folder.isEmpty ? "" : NotebookStore.humanise(lastComponentOf: page.folder) + " \u{203A} "
                out.append(SpotlightEntry(kind: .note, recordID: page.id, title: folder + page.title,
                                          detail: preview(page.content), keywords: []))
            }
        }
        if enabled.contains(.link) {
            for link in sources.links {
                let detail = [link.host, link.summary].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                out.append(SpotlightEntry(kind: .link, recordID: link.id, title: link.displayTitle,
                                          detail: preview(detail), keywords: link.tags + [link.host]))
            }
        }
        if enabled.contains(.sticky) {
            for note in sources.stickies {
                out.append(SpotlightEntry(kind: .sticky, recordID: note.id,
                                          title: UnifiedSearchStickyNoteProvider.displayTitle(for: note),
                                          detail: preview(note.text), keywords: []))
            }
        }
        if enabled.contains(.runbook) {
            for runbook in sources.runbooks {
                out.append(SpotlightEntry(kind: .runbook, recordID: runbook.id, title: runbook.title,
                                          detail: preview(runbook.content), keywords: []))
            }
        }
        return out.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One line, bounded, no Markdown fences.
    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "```", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > previewLength ? String(flat.prefix(previewLength - 1)) + "\u{2026}" : flat
    }

    /// What the index holds for `entries` under the current lock state and
    /// the "while locked" choice: everything, titles only, or nothing.
    static func visible(_ entries: [SpotlightEntry], locked: Bool, lockedMode: LockedMode) -> [SpotlightEntry] {
        guard locked else { return entries }
        switch lockedMode {
        case .titlesOnly: return entries.map(\.titleOnly)
        case .nothing: return []
        }
    }

    enum LockedMode: String, CaseIterable {
        case titlesOnly
        case nothing

        var title: String { self == .titlesOnly ? "Titles only" : "Nothing" }
    }
}

// MARK: - Where it is written

/// The index the entries go to. The real one is Core Spotlight; a self-test
/// passes a recorder.
protocol SpotlightSink: AnyObject {
    func replace(with entries: [SpotlightEntry], completion: @escaping () -> Void)
    func removeAll(completion: @escaping () -> Void)
}

final class CoreSpotlightSink: SpotlightSink {

    private let index = CSSearchableIndex.default()

    func replace(with entries: [SpotlightEntry], completion: @escaping () -> Void) {
        let items = entries.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = entry.title
            attributes.displayName = entry.title
            if !entry.detail.isEmpty { attributes.contentDescription = entry.detail }
            attributes.keywords = entry.keywords.isEmpty ? nil : entry.keywords
            attributes.kind = "Grand Line \u{00B7} \(entry.kind.displayName)"
            let item = CSSearchableItem(uniqueIdentifier: entry.identifier, domainIdentifier: entry.kind.domain,
                                        attributeSet: attributes)
            // Never older than a day: the next rebuild replaces it anyway.
            item.expirationDate = Date().addingTimeInterval(7 * 86_400)
            return item
        }
        // Delete first, so an item removed from a store goes from Spotlight too.
        index.deleteSearchableItems(withDomainIdentifiers: SpotlightEntry.Kind.allCases.map(\.domain)) { [index] _ in
            guard !items.isEmpty else { DispatchQueue.main.async(execute: completion); return }
            index.indexSearchableItems(items) { error in
                if let error { AppLog.ui.error("spotlight: indexing failed - \(error.localizedDescription, privacy: .public)") }
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func removeAll(completion: @escaping () -> Void) {
        index.deleteSearchableItems(withDomainIdentifiers: SpotlightEntry.Kind.allCases.map(\.domain)) { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }
}

// MARK: - The indexer

final class SpotlightIndexer {

    let sink: SpotlightSink
    /// Reads the stores. On main for the in-memory ones; `onDisk` (Notebook
    /// pages, runbooks) is read off main.
    var inMemory: () -> SpotlightIndex.Sources
    var onDisk: () -> (pages: [NotebookPage], runbooks: [DocsRunbook])
    var isLocked: () -> Bool = { AppLockGate.shared.isLocked }
    /// Opens a parsed result. Wired to the navigator.
    var open: ((SpotlightEntry.Kind, String) -> Void)?
    /// Shows what is waiting to open on the lock screen.
    var showPendingOnLock: ((String) -> Void)?

    private(set) var lastEntries: [SpotlightEntry] = []
    private(set) var lastWrittenCount = 0
    private(set) var lastUpdatedAt: Date?
    private(set) var pendingOpen: String?
    private var timer: Timer?
    private var generation = 0
    private var observers: [() -> Void] = []

    init(sink: SpotlightSink = CoreSpotlightSink(),
         inMemory: @escaping () -> SpotlightIndex.Sources,
         onDisk: @escaping () -> (pages: [NotebookPage], runbooks: [DocsRunbook])) {
        self.sink = sink
        self.inMemory = inMemory
        self.onDisk = onDisk
    }

    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    static var enabledKinds: Set<SpotlightEntry.Kind> {
        Set(SpotlightEntry.Kind.allCases).subtracting(AppSettings.shared.spotlightDisabledKinds)
    }

    /// Arms the rebuilds. A suite or a tour never writes the real index.
    func start() {
        guard !ProcessMode.current.isIsolated, timer == nil else { return }
        AppLockGate.shared.observe { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.rebuild() }
        let tick = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            guard NSApp.isActive else { return }
            self?.rebuild()
        }
        tick.tolerance = 60
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.rebuild() }
    }

    /// Reads the stores and rewrites the index. Turned off, it empties it.
    func rebuild(completion: (() -> Void)? = nil) {
        generation += 1
        let mine = generation
        guard AppSettings.shared.spotlightEnabled else {
            sink.removeAll { [weak self] in self?.finish(entries: [], written: 0, completion: completion) }
            return
        }
        var sources = inMemory()
        let read = onDisk
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disk = read()
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { completion?(); return }
                sources.pages = disk.pages
                sources.runbooks = disk.runbooks
                let entries = SpotlightIndex.entries(from: sources, enabled: Self.enabledKinds)
                let visible = SpotlightIndex.visible(entries, locked: self.isLocked(),
                                                     lockedMode: AppSettings.shared.spotlightLockedMode)
                let write: (@escaping () -> Void) -> Void = visible.isEmpty
                    ? { done in self.sink.removeAll(completion: done) }
                    : { done in self.sink.replace(with: visible, completion: done) }
                write { self.finish(entries: entries, written: visible.count, completion: completion) }
            }
        }
    }

    private func finish(entries: [SpotlightEntry], written: Int, completion: (() -> Void)?) {
        lastEntries = entries
        lastWrittenCount = written
        lastUpdatedAt = Date()
        observers.forEach { $0() }
        completion?()
    }

    /// "Remove all from Spotlight": empties the index now. The setting stays
    /// as it is, so the next rebuild puts it back unless Spotlight is off.
    func removeAll(completion: (() -> Void)? = nil) {
        generation += 1
        sink.removeAll { [weak self] in self?.finish(entries: self?.lastEntries ?? [], written: 0, completion: completion) }
    }

    func count(of kind: SpotlightEntry.Kind) -> Int { lastEntries.filter { $0.kind == kind }.count }

    // MARK: Opening a result

    /// The activity Spotlight hands the app when a result is chosen. While
    /// locked it waits for the unlock (GL-09) and says on the lock screen
    /// what will open.
    @discardableResult
    func handle(identifier: String) -> Bool {
        guard let (kind, id) = SpotlightEntry.parse(identifier: identifier) else { return false }
        guard AppLockGate.shared.allows(.spotlightResult) else {
            pendingOpen = identifier
            let title = lastEntries.first { $0.identifier == identifier }?.title ?? "this \(kind.displayName.lowercased())"
            showPendingOnLock?("Unlock to open \u{201C}\(title)\u{201D}. Spotlight showed the title only.")
            return true
        }
        open?(kind, id)
        return true
    }

    /// Called on unlock: opens what Spotlight asked for while locked.
    func openPendingIfUnlocked() {
        guard let pending = pendingOpen, AppLockGate.shared.allows(.spotlightResult) else { return }
        pendingOpen = nil
        handle(identifier: pending)
    }
}
