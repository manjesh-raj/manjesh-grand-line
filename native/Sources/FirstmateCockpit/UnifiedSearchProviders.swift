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
    case host
    case command
    case task
    case followUp
    case project
    case runbook
    case postmortem
    case action

    var groupTitle: String {
        switch self {
        case .host: return "Hosts"
        case .command: return "Commands"
        case .task, .followUp, .project: return "Tasks & follow-ups"
        case .runbook: return "Runbooks"
        case .postmortem: return "Postmortems"
        case .action: return "Actions"
        }
    }

    /// Section order in the palette. Hosts first (the mockup's own order, and
    /// the most common verb for an SRE), actions last since they are always
    /// present and never the thing being hunted for.
    static let groupOrder = ["Hosts", "Commands", "Tasks & follow-ups", "Runbooks", "Postmortems", "Actions"]

    var symbol: String {
        switch self {
        case .host: return "server.rack"
        case .command: return "terminal"
        case .task: return "checkmark.circle"
        case .followUp: return "bell"
        case .project: return "folder"
        case .runbook: return "doc.text"
        case .postmortem: return "doc.badge.clock"
        case .action: return "bolt.fill"
        }
    }

    /// Matches the mockup's per-section hues: blue hosts, magenta commands,
    /// amber tasks, green runbooks, accent actions. Semantic `HelmTint`
    /// cases, never literal hexes, so all 12 palettes resolve their own.
    var tint: HelmTint {
        switch self {
        case .host: return .info
        case .command: return .violet
        case .task, .followUp, .project: return .warn
        case .runbook, .postmortem: return .good
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
    let activate: () -> Void

    init(kind: UnifiedSearchKind, id: String, title: String, meta: String,
         actionHint: String? = nil, activate: @escaping () -> Void) {
        self.kind = kind
        self.id = id
        self.title = title
        self.meta = meta
        self.actionHint = actionHint
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

// MARK: - Hosts

/// Saved SSH hosts, matched on label/address/username/group/tags - every
/// field a captain would plausibly type. Connecting goes through the caller's
/// `onConnect`, wired to `AppDelegate.connectToHost` - the one place a saved
/// host is actually connected to, shared with the Hosts list's own Connect
/// and the rail's per-host icons.
struct UnifiedSearchHostProvider: UnifiedSearchProvider {
    let store: HostStore
    let onConnect: (Host) -> Void

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
        return store.hosts.filter { Self.matches($0, query: trimmed) }.map { host in
            UnifiedSearchItem(
                kind: .host,
                id: host.id.uuidString,
                title: host.label,
                meta: Self.meta(for: host),
                actionHint: "Connect \u{21B5}",
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

    static func runbookMeta(_ runbook: DocsRunbook) -> String {
        let steps = DocsRunbookMetadata.stepCount(in: runbook.content)
        var bits = ["Runbook"]
        if let category = DocsRunbookMetadata.category(in: runbook.content) { bits.append(category) }
        if steps > 0 { bits.append("\(steps) step\(steps == 1 ? "" : "s")") }
        return bits.joined(separator: " \u{00B7} ")
    }

    func items(query: String) -> [UnifiedSearchItem] {
        DocsKnowledgeSearch.search(query: query, store: store).map { result in
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
        let run: () -> Void
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
            // F7: the general "message first mate" channel, reachable from
            // the palette as well as Overview's header - the review names
            // both entry points. It opens the same composer, and its Send
            // goes through the Herdr tab, never `fm-send.sh` (there is no
            // task id to address here).
            Action(title: "Message First Mate", meta: "Fleet",
                   keywords: ["reply", "answer", "crew", "firstmate", "chat", "send"],
                   run: { [weak shell] in shell?.messageFirstMateFromMenu() }),
            Action(title: "Find in Terminal", meta: "Console", keywords: ["search", "grep"],
                   run: { [weak shell] in shell?.activateConsoleFind() }),
            Action(title: "Settings", meta: "App", keywords: ["preferences", "config"],
                   run: { [weak shell] in shell?.selectSettings() }),
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
                activate: action.run
            )
        }
    }
}
