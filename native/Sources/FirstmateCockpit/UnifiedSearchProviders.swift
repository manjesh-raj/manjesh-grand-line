// Manjesh Grand Line - native macOS app.
//
// F5 (`fm/grandline-feature-f5-command-palette-expansion`) - the provider
// layer that turns `⌘K` from a runbook/postmortem search into the app's verb
// surface, per the production review's own F5 entry (section 25 of
// `data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`)
// and the captain-approved mockup in that review's `lavish-plan.html`.
//
// The review's framing, followed literally: "extend `UnifiedSearchIndex` with
// providers per store (all data is already in memory or cheaply readable);
// action items dispatch through existing `AppShellController` methods" and
// "a provider protocol on the existing palette". So:
//
//   * `UnifiedSearchProvider` is the seam. A provider owns *matching* against
//     its own store and *nothing else* - every item it yields carries an
//     `activate` closure the provider was constructed with, so the palette
//     never learns a store's internals and never re-implements an action.
//   * Every `activate` closure is wired (in `main.swift`) to the same real
//     method the corresponding page's own click already calls: a saved host
//     goes through `AppDelegate.connectToHost`, a task through
//     `AppShellController.openShiftTask`, a runbook through
//     `openDocsRunbook`, a command through the Command Library's own
//     Send-to-terminal path *including its risk gate*. There is exactly one
//     implementation of each action in this app; the palette is a faster way
//     to reach it, never a second copy of it and never a way around a
//     confirmation.
//   * Matching itself is never re-implemented either: the command provider
//     calls `DevOpsCommand.matches(query:)` (the Command Library's own
//     shipped matcher) and the docs provider calls `DocsKnowledgeSearch.search`
//     (the Docs page's own). Only hosts needed a matcher written here, since
//     `Host` had none.
//
// **Absorbing ⌘⇧P.** `ShiftSearch.swift` was a second, near-identical palette
// over Shift's own tasks/follow-ups/projects. Its UI is deleted; its matcher
// lives on as `UnifiedSearchShiftProvider` below, which searches exactly what
// it searched (active tasks, every follow-up, every project, case-insensitive
// title substring) so the captain loses no search capability - plus the due
// status the mockup shows. ⌘⇧P is now unbound.
//
// **Empty query.** Content providers return nothing for an empty query (the
// pre-F5 `⌘K` behaviour, inherited from `DocsKnowledgeSearch`). The actions
// provider is the one exception and lists every destination/verb, so an
// empty `⌘K` opens as a browsable verb list - which is the whole point of
// "⌘K as the app's verb surface", and strictly more than the nothing it
// showed before. Browsing *all* tasks with an empty query (⌘⇧P's old
// behaviour) is deliberately not carried over: with hosts, 70+ seeded
// commands, tasks and 15 destinations all in one list it would be a wall of
// noise, and the Tasks page already lists them.

import AppKit

// MARK: - Item model

/// What a palette row *is*. Drives its group header, glyph and tint.
///
/// `groupTitle` is what the palette groups and orders by - not the kind
/// itself - so task/follow-up/project collapse into one "Tasks &
/// follow-ups" section exactly like the mockup shows, without the palette
/// needing to know why.
enum UnifiedSearchKind {
    /// A live SSH session (`fm/grandline-session-switcher`, item 4). Its own
    /// kind rather than a flag on `.host` because it groups separately, sorts
    /// first, and dispatches a different action - switching into a session
    /// that already exists, never opening a connection.
    case session
    case host
    case command
    case task
    case followUp
    case project
    case runbook
    case postmortem
    /// F1's notebook page. Its own kind rather than a third `runbook`-family
    /// member because it groups separately, carries a different meta line
    /// (a folder and a backlink count, not a step count) and dispatches to a
    /// different destination.
    case notebookPage
    /// F4's saved link. Its own kind for the same reasons `.notebookPage` is:
    /// it groups separately, its meta line is a host plus a read state, and it
    /// dispatches into the reading list's own reader.
    case savedLink
    case stickyNote
    case snippet
    case action

    var groupTitle: String {
        switch self {
        case .session: return "Active sessions"
        case .host: return "Hosts"
        case .command: return "Commands"
        case .task, .followUp, .project: return "Tasks & follow-ups"
        case .runbook: return "Runbooks"
        case .postmortem: return "Postmortems"
        case .notebookPage: return "Notebook"
        case .savedLink: return "Reading list"
        case .stickyNote: return "Sticky notes"
        case .snippet: return "Snippets"
        case .action: return "Actions"
        }
    }

    /// Section order in the palette. Hosts first (the mockup's own order, and
    /// the most common verb for an SRE), actions last since they are always
    /// present and never the thing being hunted for.
    /// Active sessions are pinned first: with a live session open, "take me
    /// back into it" is more likely than anything else a query could mean, and
    /// landing on a host's *detail* page when the captain meant its live shell
    /// is exactly the confusion the session switcher exists to remove.
    static let groupOrder = ["Active sessions", "Hosts", "Commands", "Tasks & follow-ups",
                             "Runbooks", "Postmortems", "Notebook", "Reading list", "Sticky notes",
                             "Snippets", "Actions"]

    var symbol: String {
        switch self {
        case .session: return "bolt.horizontal.circle.fill"
        case .host: return "server.rack"
        case .command: return "terminal"
        case .task: return "checkmark.circle"
        case .followUp: return "bell"
        case .project: return "folder"
        case .runbook: return "doc.text"
        case .postmortem: return "doc.badge.clock"
        case .notebookPage: return "book.and.wrench"
        case .savedLink: return "bookmark.fill"
        case .stickyNote: return "note.text"
        case .snippet: return "chevron.left.forwardslash.chevron.right"
        case .action: return "bolt.fill"
        }
    }

    /// Matches the mockup's per-section hues: blue hosts, magenta commands,
    /// amber tasks, green runbooks, accent actions. Semantic `HelmTint`
    /// cases, never literal hexes, so all 12 palettes resolve their own.
    var tint: HelmTint {
        switch self {
        // A live session reads as healthy/running, the same `.good` the Hosts
        // row's own "Connected" chip uses - one hue for one fact.
        case .session: return .good
        case .host: return .info
        case .command: return .violet
        case .task, .followUp, .project: return .warn
        case .runbook, .postmortem: return .good
        // The "reading material" blue this app gives Docs, Runbooks and the
        // Notebook destination itself - `.info` is that hue's semantic name
        // here, so all twelve palettes resolve their own.
        case .notebookPage: return .info
        // F4's own hue: `.good` is what `HelmDomainHue.green` maps to, and
        // green is the hue the reviewed mockup draws the reading list in.
        case .savedLink: return .good
        // Both are scratch surfaces the captain writes into, not signals -
        // `.neutral` says exactly that, and is the same call Dictation's
        // history rows make for the same reason.
        case .stickyNote, .snippet: return .neutral
        case .action: return .accent
        }
    }
}

/// One palette row.
///
/// `activate` is the whole point of the provider seam: the provider that
/// produced this item already closed over the real action, so
/// `UnifiedSearchController` picks a row by calling this and knows nothing
/// about hosts, commands, tasks or navigation.
struct UnifiedSearchItem {
    let kind: UnifiedSearchKind
    /// Stable enough to identify the row in a self-test; not used for dedup
    /// (two providers never produce the same kind).
    let id: String
    let title: String
    /// The muted second line - "tag: PROD", "Kubernetes · Send to…",
    /// "Due tomorrow", "Runbook · 4 steps", "Destination".
    let meta: String
    /// The trailing chip, e.g. "Connect ↵". `nil` for a row whose meta line
    /// already says what Return does.
    let actionHint: String?
    /// H1: this row's *own* identity, where it has one - "destinations use
    /// their real artwork/hue, commands use their category tint, hosts their
    /// accent". `nil` falls back to `kind.symbol`/`kind.tint`, which is right
    /// for a row whose identity genuinely is its kind (a task, a note).
    ///
    /// Three shapes because the three sources are genuinely different: a
    /// destination owns a raster app icon, a command owns a semantic
    /// `HelmTint` through its category, and a saved host owns a literal hex
    /// the captain picked. Collapsing them would mean discarding one of the
    /// three - which is the same distinction `HelmAccentRow.Content.tintHex`
    /// already draws against `domainHue`.
    let icon: Icon?
    let activate: () -> Void

    enum Icon {
        /// A destination: its own artwork when it has any, its own domain hue.
        case destination(RailDestination)
        /// A semantic tint, with an optional symbol override.
        case tinted(HelmTint, symbol: String? = nil)
        /// A literal hue the captain chose - a saved host's `accentHex`.
        case literal(hex: String, symbol: String)
    }

    init(kind: UnifiedSearchKind, id: String, title: String, meta: String,
         actionHint: String? = nil, icon: Icon? = nil, activate: @escaping () -> Void) {
        self.kind = kind
        self.id = id
        self.title = title
        self.meta = meta
        self.actionHint = actionHint
        self.icon = icon
        self.activate = activate
    }
}

/// A rendered section: a header plus the rows that survived the per-group cap.
struct UnifiedSearchGroup {
    let title: String
    let items: [UnifiedSearchItem]
    /// How many further matches this group had beyond the cap. Rendered as an
    /// explicit "N more…" line rather than silently dropped - AGENTS.md's own
    /// "no silent caps" rule.
    let overflow: Int
}

// MARK: - The seam

/// One searchable domain. A provider is constructed with its store *and* the
/// real actions its items should dispatch to, so `items(query:)` is the only
/// thing the index ever needs from it.
protocol UnifiedSearchProvider {
    func items(query: String) -> [UnifiedSearchItem]
}

// MARK: - Live sessions

/// The live SSH sessions, pinned above the Hosts group
/// (`fm/grandline-session-switcher`, item 4).
///
/// Reads `HostSessionRegistry` - the app's one notion of liveness, the same one
/// the session strip and the Hosts rows read - and dispatches
/// `AppShellController.switchToSession`, which reveals an already-built console
/// page and needs no `ssh` argv at all. That is the whole point of the group:
/// ⌘K, "prod", Return lands *in* the live session instead of reconnecting.
///
/// **Two deliberate departures from the other content providers**, both stated
/// because they are exceptions to conventions AGENTS.md records:
///
///   * It answers an **empty query**, unlike every provider except
///     `UnifiedSearchActionProvider`. The set is bounded by however many
///     sessions are actually open (a handful, never a wall of noise like the
///     70+ seeded commands), and a captain who opens ⌘K with two live sessions
///     should see them without typing.
///   * It matches on the *host's* fields, via `UnifiedSearchHostProvider.
///     matches`, rather than re-implementing a matcher for the session's label
///     alone - so typing an address or a tag finds the live session too.
struct UnifiedSearchSessionProvider: UnifiedSearchProvider {
    let registry: HostSessionRegistry
    let store: HostStore
    let onSwitch: (UUID) -> Void

    func items(query: String) -> [UnifiedSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return registry.sessions.compactMap { session in
            // A session whose host was deleted out from under it still matches
            // on its own label - the registry carries that, so a stale id
            // never silently drops the row the captain can see on the strip.
            let host = store.host(id: session.hostID)
            if !trimmed.isEmpty {
                let hostMatches = host.map { UnifiedSearchHostProvider.matches($0, query: trimmed) } ?? false
                guard hostMatches || session.label.lowercased().contains(trimmed.lowercased()) else { return nil }
            }
            let meta = host.map { UnifiedSearchHostProvider.meta(for: $0) } ?? "Live session"
            return UnifiedSearchItem(
                kind: .session,
                id: session.hostID.uuidString,
                title: session.label,
                // Audit 2 §4.6: the kicker follows the real state too - a
                // restored page is still worth listing here (switching to it
                // is what connects it) but must not be labelled LIVE.
                meta: "\(session.isConnected ? "LIVE" : "RESTORED") \u{00B7} "
                    + "\(session.stateText) \u{00B7} \(meta)",
                actionHint: "Switch \u{21B5}",
                // The same host's own accent, so a live session and its host
                // row read as the same machine.
                icon: host.map { .literal(hex: $0.accentHex, symbol: $0.iconSymbol) },
                activate: { onSwitch(session.hostID) }
            )
        }
    }
}

// MARK: - Hosts

/// Saved SSH hosts, matched on label/address/username/group/tags - every
/// field a captain would plausibly type. Connecting goes through the caller's
/// `onConnect`, wired to `AppDelegate.connectToHost` - the one place a saved
/// host is actually connected to, shared with the Hosts list's own Connect
/// and the rail's per-host icons.
struct UnifiedSearchHostProvider: UnifiedSearchProvider {
    let store: HostStore
    let onConnect: (Host) -> Void
    /// `fm/grandline-session-switcher`: a host with a live session is rendered
    /// by `UnifiedSearchSessionProvider` in the pinned "Active sessions" group
    /// above, so it is skipped here rather than appearing twice - once as
    /// "Switch" and once as "Connect", which is precisely the ambiguity the
    /// switcher removes. Defaults to "nothing is live", which is the exact
    /// pre-switcher behaviour.
    var isLive: (UUID) -> Bool = { _ in false }

    /// `Host` has no matcher of its own (unlike `DevOpsCommand.matches`), so
    /// this is the one written here. Same plain case-insensitive substring
    /// shape as every other search in this app.
    static func matches(_ host: Host, query: String) -> Bool {
        let q = query.lowercased()
        if q.isEmpty { return true }
        if host.label.lowercased().contains(q) { return true }
        if host.address.lowercased().contains(q) { return true }
        if host.username.lowercased().contains(q) { return true }
        if let group = host.group, group.lowercased().contains(q) { return true }
        if host.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        return false
    }

    /// The mockup's "tag: PROD" line, falling back to the host's real
    /// destination when it carries no tag or group - never a fabricated
    /// label.
    static func meta(for host: Host) -> String {
        if let tag = host.tags.first, !tag.isEmpty { return "tag: \(tag)" }
        if let group = host.group, !group.isEmpty { return group }
        let user = host.username.isEmpty ? "" : "\(host.username)@"
        return "\(user)\(host.address)"
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return store.hosts
            .filter { !isLive($0.id) && Self.matches($0, query: trimmed) }
            .map { host in
            UnifiedSearchItem(
                kind: .host,
                id: host.id.uuidString,
                title: host.label,
                meta: Self.meta(for: host),
                actionHint: "Connect \u{21B5}",
                // H1: "hosts their accent" - a colour the captain picked, so a
                // literal hue rather than a semantic tint.
                icon: .literal(hex: host.accentHex, symbol: host.iconSymbol),
                activate: { onConnect(host) }
            )
        }
    }
}

// MARK: - Command library

/// The DevOps Command Library (GL-23's one shared store - never a second
/// cached copy, which is exactly why F5 depends on that fix for correct
/// results).
///
/// **Two actions, chosen per command rather than offered as a choice**, since
/// the mockup shows one action per row:
///
///   * A command whose template resolves with no captain input (every
///     `{{token}}` has a default) is **sent to the terminal** through
///     `onSend`, which routes to the same
///     `ConsoleController.sendCommandLibraryTextToActiveTab` the Command
///     Library's own "Send to Terminal" button uses - *after* the same
///     `CommandRiskConfirmation` gate that button goes through. There is no
///     path from a risky command to a terminal that skips that alert,
///     whichever surface reached it.
///   * A command with an unfilled parameter is **opened in the library**
///     (`onOpen` -> `AppShellController.openCommandLibraryCommand`) so the
///     captain can fill the fields in. Sending `kubectl get pods -n
///     {{namespace}}` verbatim would be worse than useless, and inventing a
///     value would be a lie - so the palette takes them to the real form.
///
/// "Readiness" is asked of the real generator (`generatedCommand(values: [:])`
/// leaving no `{{` behind) rather than re-derived from the parameter list, so
/// it cannot drift from what the detail pane actually renders.
struct UnifiedSearchCommandProvider: UnifiedSearchProvider {
    let store: CommandLibraryStore
    /// Called with the command and its fully-resolved text. The *caller* runs
    /// the risk gate and the send, so this provider holds no action logic.
    let onSend: (DevOpsCommand, String) -> Void
    let onOpen: (String) -> Void

    static func isReadyToRunWithoutInput(_ command: DevOpsCommand) -> Bool {
        !command.generatedCommand(values: [:]).contains("{{")
    }

    static func meta(for command: DevOpsCommand) -> String {
        let category = command.category.isEmpty
            ? ""
            : CommandLibraryCategory.info(for: command.category).displayName
        let verb = isReadyToRunWithoutInput(command) ? "Send to terminal" : "Fill in and send\u{2026}"
        return category.isEmpty ? verb : "\(category) \u{00B7} \(verb)"
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // The Command Library's own shipped matcher (name/description/
        // category/subcategory/tags/command text/parameter names), not a
        // second one written here.
        return store.commands.filter { $0.matches(query: trimmed) }.map { command in
            let ready = Self.isReadyToRunWithoutInput(command)
            return UnifiedSearchItem(
                kind: .command,
                id: command.id,
                title: command.name,
                meta: Self.meta(for: command),
                actionHint: ready ? "Send \u{21B5}" : "Open \u{21B5}",
                // H1: "commands use their category tint" - the same mapping the
                // Command Library's own category list uses, not a second one.
                icon: {
                    let info = CommandLibraryCategory.info(for: command.category)
                    return .tinted(info.tint, symbol: info.symbol)
                }(),
                activate: {
                    if ready {
                        onSend(command, command.generatedCommand(values: [:]))
                    } else {
                        onOpen(command.id)
                    }
                }
            )
        }
    }
}

// MARK: - Tasks, follow-ups, projects (absorbs ⌘⇧P)

/// Exactly what `ShiftSearchIndex.search` searched before F5 deleted its
/// palette: active tasks (a completed task isn't editable through
/// `ShiftController.openTask`'s sheet), every follow-up pending or done, and
/// every project, matched on title/name substring. The only addition is the
/// due status the mockup's task row shows, formatted with the app's own
/// `ShiftDateFormatting.friendly` ("Today"/"Tomorrow"/"Aug 12") rather than a
/// second date formatter.
struct UnifiedSearchShiftProvider: UnifiedSearchProvider {
    let store: ShiftStore
    let onOpenTask: (String) -> Void
    let onOpenFollowUp: (String) -> Void
    let onOpenProject: (String) -> Void

    /// "Due tomorrow" / "Overdue - Aug 12" / the project name / "Task".
    static func taskMeta(_ task: ShiftTask, projectName: String?) -> String {
        var bits: [String] = []
        if let due = task.dueDate {
            let friendly = ShiftDateFormatting.friendly(due)
            let overdue = ShiftDateFormatting.date(from: due)
                .map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false
            bits.append(overdue ? "Overdue \u{00B7} \(friendly)" : "Due \(friendly.lowercased())")
        }
        bits.append(projectName ?? "Task")
        return bits.joined(separator: " \u{00B7} ")
    }

    /// `followUpAt` is genuinely optional (a follow-up with no date yet), so
    /// the meta line says just what it knows rather than inventing a date.
    static func followUpMeta(_ followUp: ShiftFollowUp) -> String {
        var bits = ["Follow-up"]
        if let at = followUp.followUpAt, !at.isEmpty {
            bits.append(ShiftDateFormatting.friendly(at, time: followUp.followUpTime))
        }
        if followUp.status == .done { bits.append("Done") }
        return bits.joined(separator: " \u{00B7} ")
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        var out: [UnifiedSearchItem] = []
        for task in store.activeTasks where task.title.lowercased().contains(needle) {
            let projectName = task.projectID.flatMap { pid in
                store.projects.first(where: { $0.id == pid })?.name
            }
            out.append(UnifiedSearchItem(
                kind: .task,
                id: task.id,
                title: task.title,
                meta: Self.taskMeta(task, projectName: projectName),
                actionHint: "Open \u{21B5}",
                activate: { onOpenTask(task.id) }
            ))
        }
        for followUp in store.followUps where followUp.title.lowercased().contains(needle) {
            out.append(UnifiedSearchItem(
                kind: .followUp,
                id: followUp.id,
                title: followUp.title,
                meta: Self.followUpMeta(followUp),
                actionHint: "Open \u{21B5}",
                activate: { onOpenFollowUp(followUp.id) }
            ))
        }
        for project in store.projects where project.name.lowercased().contains(needle) {
            out.append(UnifiedSearchItem(
                kind: .project,
                id: project.id,
                title: project.name,
                meta: "Project \u{00B7} \(project.status.displayName)",
                actionHint: "Open \u{21B5}",
                activate: { onOpenProject(project.id) }
            ))
        }
        return out
    }
}

// MARK: - Runbooks and postmortems (the pre-F5 palette, unchanged)

/// The one provider that existed before F5, just moved behind the protocol.
/// Still `DocsKnowledgeSearch.search` verbatim - the same real search the Docs
/// page's own Search used - with the mockup's "Runbook · 4 steps" meta layered
/// on from `DocsRunbookMetadata` (the same derivation the Docs cards already
/// show, so a card and a palette row can never disagree).
struct UnifiedSearchDocsProvider: UnifiedSearchProvider {
    let store: DocsRunbookStore
    let onOpenRunbook: (String) -> Void
    let onOpenPostmortem: (String) -> Void

    /// The corpus, held briefly so a burst of keystrokes reads the library
    /// once rather than once per character.
    ///
    /// This provider used to call `DocsKnowledgeSearch.search(query:store:)`
    /// on every keystroke, which re-enumerates both directories and reads the
    /// whole content of every markdown file - synchronous, on main, uncached.
    /// A short TTL rather than a session cache: the palette's owner
    /// (`AppDelegate.unifiedSearch`) is app-lifetime, so "for this session"
    /// would mean "until relaunch", and a runbook saved while the app is open
    /// has to turn up. Two seconds covers typing and is under the time it
    /// takes to switch to Runbooks, add one, and come back.
    private final class Corpus {
        static let ttl: TimeInterval = 2
        var loadedAt = Date.distantPast
        var runbooks: [DocsRunbook] = []
        var postmortems: [DocsRunbook] = []
    }

    private static let corpus = Corpus()

    private func loadedCorpus() -> (runbooks: [DocsRunbook], postmortems: [DocsRunbook]) {
        let corpus = Self.corpus
        if Date().timeIntervalSince(corpus.loadedAt) >= Corpus.ttl {
            corpus.runbooks = store.listRunbooks()
            corpus.postmortems = store.listPostmortems()
            corpus.loadedAt = Date()
        }
        return (corpus.runbooks, corpus.postmortems)
    }

    static func runbookMeta(_ runbook: DocsRunbook) -> String {
        let steps = DocsRunbookMetadata.stepCount(in: runbook.content)
        var bits = ["Runbook"]
        if let category = DocsRunbookMetadata.category(in: runbook.content) { bits.append(category) }
        if steps > 0 { bits.append("\(steps) step\(steps == 1 ? "" : "s")") }
        return bits.joined(separator: " \u{00B7} ")
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let corpus = loadedCorpus()
        return DocsKnowledgeSearch.search(query: query,
                                          runbooks: corpus.runbooks,
                                          postmortems: corpus.postmortems).map { result in
            switch result.scope {
            case .runbook:
                return UnifiedSearchItem(
                    kind: .runbook,
                    id: result.runbook.id,
                    title: result.runbook.title,
                    meta: Self.runbookMeta(result.runbook),
                    actionHint: "Open \u{21B5}",
                    activate: { onOpenRunbook(result.runbook.id) }
                )
            case .postmortem:
                let rootCause = DocsRunbookMetadata.rootCause(in: result.runbook.content)
                return UnifiedSearchItem(
                    kind: .postmortem,
                    id: result.runbook.id,
                    title: result.runbook.title,
                    meta: rootCause.map { "Root cause: \($0)" } ?? result.snippet,
                    actionHint: "Open \u{21B5}",
                    activate: { onOpenPostmortem(result.runbook.id) }
                )
            }
        }
    }
}

// MARK: - Sticky notes and code snippets

/// The Sticky Board's notes (audit §6.5b).
///
/// The board is a freeform canvas with no list view, so a note that scrolled
/// out of sight is genuinely hard to find again - which is what makes ⌘K worth
/// more here than on a page that already lists its records.
///
/// Matching is a plain case-insensitive substring over title and body, the
/// same shape `UnifiedSearchHostProvider` uses. Deliberately not a fuzzy
/// matcher: nothing else in this palette is one, and one domain scoring
/// differently from its neighbours reads as a bug.
struct UnifiedSearchStickyNoteProvider: UnifiedSearchProvider {
    let store: StickyBoardStore
    let onOpen: (String) -> Void

    /// A note's title is optional by design (the view renders a placeholder),
    /// so the row falls back to the body - a title-only row would render blank
    /// for exactly the notes a captain jots fastest.
    static func displayTitle(for note: StickyNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let firstLine = note.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        return (firstLine?.isEmpty == false ? firstLine! : "Untitled note")
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty query returns nothing, like every content provider except
        // sessions and actions - a board of notes would be a wall of noise.
        guard !needle.isEmpty else { return [] }
        return store.notes.filter {
            $0.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
        }.map { note in
            UnifiedSearchItem(
                kind: .stickyNote,
                id: note.id,
                title: Self.displayTitle(for: note),
                meta: "Sticky note",
                actionHint: "Open \u{21B5}",
                activate: { onOpen(note.id) }
            )
        }
    }
}

/// Code Preview's saved snippets (audit §6.6b).
///
/// A snippet's filename is its identity (see `CodePreviewStore`'s header), so
/// that is both what the row shows and what the action carries.
///
/// Reads through the same short-TTL corpus idea as the docs provider, and for
/// the same measured reason: `list()` enumerates the directory and reads every
/// file's contents, which on a per-keystroke path is real synchronous work on
/// the main thread.
struct UnifiedSearchSnippetProvider: UnifiedSearchProvider {
    let store: CodePreviewStore
    let onOpen: (String) -> Void

    private final class Corpus {
        static let ttl: TimeInterval = 2
        var loadedAt = Date.distantPast
        var snippets: [CodePreviewSnippet] = []
    }

    private static let corpus = Corpus()

    private func loadedSnippets() -> [CodePreviewSnippet] {
        let corpus = Self.corpus
        if Date().timeIntervalSince(corpus.loadedAt) >= Corpus.ttl {
            corpus.snippets = store.list()
            corpus.loadedAt = Date()
        }
        return corpus.snippets
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return loadedSnippets().filter {
            $0.id.lowercased().contains(needle) || $0.content.lowercased().contains(needle)
        }.map { snippet in
            UnifiedSearchItem(
                kind: .snippet,
                id: snippet.id,
                title: snippet.id,
                meta: snippet.language.displayName,
                actionHint: "Open \u{21B5}",
                activate: { onOpen(snippet.id) }
            )
        }
    }
}

// MARK: - App actions and destinations

/// The verb half of "⌘K as the app's verb surface": every fixed destination
/// as "Switch to X", plus the handful of app verbs that already exist as
/// `AppShellController` menu actions. Nothing here is new behaviour - each
/// entry dispatches the exact method its own menu item does, which is the
/// review's own instruction ("action items dispatch through existing
/// `AppShellController` methods").
///
/// This is the one provider that answers an empty query, so opening `⌘K` and
/// typing nothing shows what the app can do. Matching is over the visible
/// title plus a small set of keyword aliases, so "settings" finds "Switch to
/// Settings" and "connect" finds "Quick Connect" without the captain having
/// to guess the exact wording.
struct UnifiedSearchActionProvider: UnifiedSearchProvider {
    /// One entry: what it says, what it does, and the extra words that should
    /// find it.
    struct Action {
        let title: String
        let meta: String
        let keywords: [String]
        /// H1: a destination row wears that destination's own identity - its
        /// artwork and hue - rather than the one teal square every action row
        /// used to share.
        var icon: UnifiedSearchItem.Icon?
        let run: () -> Void
        init(title: String, meta: String, keywords: [String],
             icon: UnifiedSearchItem.Icon? = nil, run: @escaping () -> Void) {
            self.title = title
            self.meta = meta
            self.keywords = keywords
            self.icon = icon
            self.run = run
        }
    }

    let actions: [Action]

    /// Builds the real list. Every closure here is a call into a method that
    /// already backs a menu item.
    ///
    /// The shell is captured weakly, matching `main.swift`'s own `[weak self]`
    /// discipline - the app delegate owns both this palette and the shell, so
    /// a strong capture here would be a retain cycle waiting for the day one
    /// of them is no longer app-lifetime.
    static func standard(shell: AppShellController) -> UnifiedSearchActionProvider {
        var actions: [Action] = RailDestination.allCases.map { destination in
            Action(
                title: "Switch to \(destination.title)",
                meta: "Destination",
                keywords: [destination.title],
                icon: .destination(destination),
                run: { [weak shell] in shell?.show(destination) }
            )
        }
        actions.append(contentsOf: [
            Action(title: "New Task\u{2026}", meta: "Tasks", keywords: ["add", "create", "todo"],
                   run: { [weak shell] in shell?.newShiftTaskFromMenu() }),
            Action(title: "New Follow-up\u{2026}", meta: "Tasks", keywords: ["add", "create", "remind"],
                   run: { [weak shell] in shell?.newShiftFollowUpFromMenu() }),
            Action(title: "New Project\u{2026}", meta: "Tasks", keywords: ["add", "create"],
                   run: { [weak shell] in shell?.newShiftProjectFromMenu() }),
            Action(title: "Weekly Review", meta: "Tasks", keywords: ["week", "summary"],
                   run: { [weak shell] in shell?.showShiftWeeklyReview() }),
            Action(title: "New Host\u{2026}", meta: "Hosts", keywords: ["add", "create", "ssh", "server"],
                   run: { [weak shell] in shell?.newHostFromMenu() }),
            Action(title: "Quick Connect", meta: "Hosts", keywords: ["ssh", "ad-hoc"],
                   run: { [weak shell] in shell?.revealHostsQuickConnect() }),
            Action(title: "Manage SSH Keys", meta: "Hosts", keywords: ["key", "keychain"],
                   run: { [weak shell] in shell?.selectKeys() }),
            Action(title: "New SSH Key\u{2026}", meta: "Hosts", keywords: ["add", "create", "keygen"],
                   run: { [weak shell] in shell?.newKeyFromMenu() }),
            Action(title: "Manage Snippets", meta: "Hosts", keywords: ["snippet"],
                   run: { [weak shell] in shell?.selectSnippets() }),
            Action(title: "New Snippet\u{2026}", meta: "Hosts", keywords: ["add", "create"],
                   run: { [weak shell] in shell?.newSnippetFromMenu() }),
            Action(title: "Open Log Analyzer", meta: "Log Analyzer", keywords: ["logs", "investigate"],
                   run: { [weak shell] in shell?.showLogAnalyzer() }),
            Action(title: "Analyze Clipboard", meta: "Log Analyzer", keywords: ["logs", "paste"],
                   run: { [weak shell] in shell?.analyzeClipboardInLogAnalyzer() }),
            Action(title: "Find in Terminal", meta: "Console", keywords: ["search", "grep"],
                   run: { [weak shell] in shell?.activateConsoleFind() }),
            Action(title: "Settings", meta: "App", keywords: ["preferences", "config"],
                   run: { [weak shell] in shell?.selectSettings() }),
            // Review #3's UX1: "the 14 ⌘K verbs have no 'New sticky note',
            // 'New code snippet', 'Ask the crew' or 'Lock Poneglyph'". Each
            // dispatches the same `AppShellController` method its File-menu
            // sibling does, per this provider's own rule - nothing here is new
            // behaviour.
            Action(title: "New Sticky Note", meta: "Sticky Board", keywords: ["add", "create", "note", "sticky"],
                   run: { [weak shell] in shell?.newStickyNoteFromMenu() }),
            Action(title: "New Code Snippet", meta: "Code Preview", keywords: ["add", "create", "code", "paste"],
                   run: { [weak shell] in shell?.newCodeSnippetFromMenu() }),
            Action(title: "New Credential\u{2026}", meta: "Poneglyph", keywords: ["add", "create", "password", "secret", "vault"],
                   run: { [weak shell] in shell?.newCredentialFromMenu() }),
            Action(title: "New Schedule\u{2026}", meta: "Schedules", keywords: ["add", "create", "cron", "recurring"],
                   run: { [weak shell] in shell?.newScheduleFromMenu() }),
            Action(title: "Ask the Crew", meta: "Straw Hat Pirates", keywords: ["ai", "chat", "luffy", "crew", "ask"],
                   icon: .destination(.strawHat),
                   run: { [weak shell] in shell?.show(.strawHat) }),
            Action(title: "Lock Poneglyph", meta: "Poneglyph", keywords: ["vault", "secure", "lock", "credential"],
                   run: { [weak shell] in shell?.lockPoneglyph() }),
            Action(title: "All Destinations\u{2026}", meta: "App", keywords: ["map", "pages", "everything", "navigate"],
                   run: { [weak shell] in shell?.onShowAllDestinations?() }),
        ])
        return UnifiedSearchActionProvider(actions: actions)
    }

    static func matches(_ action: Action, query: String) -> Bool {
        let q = query.lowercased()
        if q.isEmpty { return true }
        if action.title.lowercased().contains(q) { return true }
        if action.meta.lowercased().contains(q) { return true }
        return action.keywords.contains { $0.lowercased().contains(q) }
    }

    func items(query: String) -> [UnifiedSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return actions.filter { Self.matches($0, query: trimmed) }.enumerated().map { index, action in
            UnifiedSearchItem(
                kind: .action,
                id: "action:\(index):\(action.title)",
                title: action.title,
                meta: action.meta,
                actionHint: nil,
                icon: action.icon,
                activate: action.run
            )
        }
    }
}

// MARK: - Notebook pages

/// F1's notebook, in ⌘K.
///
/// The report's own F1 entry names this as one of the things the feature
/// inherits "for free" by living in `GrandLineDocs/` - and it very nearly is:
/// this provider is `UnifiedSearchDocsProvider` with one store and one
/// destination changed, including its short-TTL corpus cache, which is there
/// for the same measured reason (the palette re-reads on every keystroke
/// otherwise, synchronously, on main).
///
/// The meta line is deliberately *not* a snippet of the match. A notebook page
/// is found by name far more often than by content, and where it is found by
/// content the excerpt is what the row shows; where it is found by title, the
/// folder is the more useful second line, because two pages called "Notes" in
/// two folders is a thing a notebook grows.
struct UnifiedSearchNotebookProvider: UnifiedSearchProvider {
    let store: NotebookStore
    let onOpen: (String) -> Void

    private final class Corpus {
        static let ttl: TimeInterval = 2
        var loadedAt = Date.distantPast
        var pages: [NotebookPage] = []
    }

    private static let corpus = Corpus()

    private func loadedPages() -> [NotebookPage] {
        let corpus = Self.corpus
        if Date().timeIntervalSince(corpus.loadedAt) >= Corpus.ttl {
            corpus.pages = store.listPages()
            corpus.loadedAt = Date()
        }
        return corpus.pages
    }

    /// How much of a content match the row quotes.
    static let snippetContext = 60

    func items(query: String) -> [UnifiedSearchItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return loadedPages().compactMap { page -> UnifiedSearchItem? in
            let meta: String
            if page.title.range(of: q, options: .caseInsensitive) != nil {
                meta = page.folder.isEmpty
                    ? "Notebook page"
                    : "Notebook \u{00B7} \(NotebookStore.humanise(lastComponentOf: page.folder))"
            } else if let range = page.content.range(of: q, options: .caseInsensitive) {
                meta = Self.excerpt(around: range, in: page.content)
            } else {
                return nil
            }
            return UnifiedSearchItem(
                kind: .notebookPage,
                id: page.id,
                title: page.title,
                meta: meta,
                actionHint: "Open \u{21B5}",
                activate: { onOpen(page.id) })
        }
    }

    private static func excerpt(around range: Range<String.Index>, in content: String) -> String {
        let start = content.index(range.lowerBound, offsetBy: -snippetContext, limitedBy: content.startIndex)
            ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: snippetContext, limitedBy: content.endIndex)
            ?? content.endIndex
        var text = String(content[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != content.startIndex { text = "\u{2026}" + text }
        if end != content.endIndex { text += "\u{2026}" }
        return text
    }
}

// MARK: - Reading list (F4)

/// ⌘K over the saved links.
///
/// Reads the **live** `ReadingListStore` instance the page and the canvas card
/// share (GL-23) - this store caches its decoded array and writes back to it,
/// so a second reader would serve stale rows and become a second source of
/// truth. The short-lived corpus cache below is `UnifiedSearchNotebookProvider`'s
/// shape and for its reason: a palette keystroke must not re-read and re-parse
/// a YAML file.
struct UnifiedSearchReadingListProvider: UnifiedSearchProvider {
    let store: ReadingListStore
    let onOpen: (String) -> Void

    func items(query: String) -> [UnifiedSearchItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return store.links.compactMap { link -> UnifiedSearchItem? in
            // Every field the card shows is searchable, and the *URL* is in
            // there deliberately: half of finding a saved link again is
            // remembering the site rather than the headline.
            let haystacks = [link.displayTitle, link.url, link.summary, link.aiSummary]
                + link.tags
            guard haystacks.contains(where: { $0.range(of: q, options: .caseInsensitive) != nil }) else {
                return nil
            }
            // GL-14 in a search row: an unread link and one whose title has not
            // been fetched yet read differently, rather than both showing a
            // bare host.
            var meta = link.host.isEmpty ? "saved link" : link.host
            meta += link.isRead ? " \u{00B7} read" : " \u{00B7} unread"
            if link.metadataState == .pending { meta += " \u{00B7} title still loading" }
            if !link.tags.isEmpty { meta += " \u{00B7} " + link.tags.joined(separator: ", ") }
            return UnifiedSearchItem(
                kind: .savedLink,
                id: link.id,
                title: link.displayTitle,
                meta: meta,
                actionHint: "Read \u{21B5}",
                activate: { onOpen(link.id) })
        }
    }
}
