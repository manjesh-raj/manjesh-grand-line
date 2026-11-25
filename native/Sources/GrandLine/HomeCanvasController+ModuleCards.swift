// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the remaining module cards: Tasks, the Straw Hat crew, Console, the four Setup sub-pages and every page's own card.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    func fillTasks(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own checklist
        // artwork, replacing the plain `checkmark.circle` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.shift` case, so the card
        // and the floating-bar shortcut/drill header agree.
        content.artwork = TasksIcon.image
        // Exactly the two predicates the Tasks page's own stat tiles use.
        let tasks = sources.shiftStore.activeTasks
        let calendar = Calendar.current
        let today = Date()
        let due = tasks.filter { task in
            guard let date = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return calendar.isDate(date, inSameDayAs: today)
        }
        let overdue = tasks.filter { task in
            guard let date = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return date < calendar.startOfDay(for: today)
        }
        content.subtitle = "today"
        content.chip = overdue.isEmpty
            ? .mute("\(due.count) due")
            : .bad("\(overdue.count) overdue")
        // S06 of the 2026-11-17 UI/UX proposals: the urgent tasks as rows -
        // overdue first, then due today - the shape the Calendar and Notebook
        // cards beside it already use, where a lone "1 task" numeral left
        // most of a row-height card empty. The chip keeps the count.
        let urgent = overdue + due
        guard !urgent.isEmpty else {
            content.body = .note(tasks.isEmpty ? "No active tasks." : "\(tasks.count) active, none due today.",
                                 maxLines: 2)
            return
        }
        let rows = urgent.prefix(HelmModuleCard.maxPeekRows).map { task in
            let late = overdue.contains { $0.id == task.id }
            return HelmModulePeekRow(state: late ? .bad : .warn, text: task.title,
                                     value: late ? StateWord.overdue.label : StateWord.dueToday.label)
        }
        content.setBoundedPeekRows(Array(rows), total: urgent.count)
    }

    /// The Straw Hat Pirates card.
    ///
    /// The crew's own Jolly Roger rather than an SF Symbol, which is the
    /// captain's own ask: this card's job is to be recognisable as *the crew*
    /// among a grid of otherwise-uniform hue tiles. `module.symbol` stays the
    /// fallback if the payload ever stops decoding - see
    /// `HelmGradientTile.configure(artwork:symbol:hue:)`.
    ///
    /// The subtitle is a fixed line, not a status readout - the captain's own
    /// call (`fm/straw-hat-menubar-quick-chat-popover`), replacing the
    /// earlier "Nami \u{00B7} 3 exchanges" derived-from-state text. Luffy's
    /// signature line ("I'm gonna be King of the Pirates!"), always, in
    /// every state - not a rotating pool, and not swapped out while a turn
    /// is in flight either. It reads as the crew's own voice on their own
    /// card rather than as a summary of the conversation.
    ///
    /// The body is still the real activity line: a preview of what was last
    /// said, with no "unread" concept (the captain is the only other
    /// participant, and a reply they have not read is one they asked for
    /// seconds ago). Nothing is invented - with no conversation yet it says
    /// so and names what the crew can be asked for; while thinking, it says
    /// that instead of a stale preview from the previous reply (the one
    /// piece of the removed "thinking\u{2026}" subtitle worth keeping - see
    /// below).
    func fillStrawHat(_ content: inout HelmModuleCard.Content) {
        content.artwork = StrawHatFlag.image
        content.subtitle = "I'm gonna be King of the Pirates!"

        guard let state = strawHatState, state.exchanges > 0 || state.isThinking else {
            // Short on purpose: a module note is one or two lines at a card's
            // real width, so the invitation is the half that has to survive -
            // "every write is yours to confirm" is already on this page's own
            // drill subtitle and on the chat's empty state.
            content.body = .note("Ask for a task, runbook or command.")
            return
        }

        if state.isThinking {
            // The "thinking" signal used to live in the subtitle
            // ("thinking\u{2026}"); with the subtitle now fixed, the body
            // carries it instead - still real, current activity, which is
            // exactly what this line is for.
            content.body = .note("The crew is thinking\u{2026}")
        } else {
            content.body = .note(state.lastLine ?? "The crew is on it.")
        }
    }

    func fillConsole(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own console
        // artwork, replacing the plain `terminal` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.console` case.
        content.artwork = ConsoleIcon.image
        let rows = consoleTabsProvider?() ?? []
        content.subtitle = rows.isEmpty ? "no tabs open" : "\(rows.count) tab\(rows.count == 1 ? "" : "s") open"
        let connected = connectedHostIDs?() ?? []
        if !connected.isEmpty { content.chip = .mute("\(connected.count) host live") }
        if rows.isEmpty {
            content.body = .note("Open a shell, or connect a saved host.")
        } else {
            content.setBoundedPeekRows(rows, total: rows.count)
        }
    }

    // MARK: The four Setup sub-pages
    //
    // Each of these reads the one number its own page owns out of
    // `BackgroundSignalsPoller.lastCounts` - already computed for the
    // Notification Center, and §6.1 is explicit that the canvas takes the last
    // published value and "never a fresh check". Splitting the old aggregate
    // Setup card into four was the captain's call after seeing the hub live.
    //
    // Every one of them shares the same two-state "no number yet" handling
    // (`fillPendingSetupSignal`): the poller's first pass is genuinely in
    // flight, or a pass completed without producing a count, which is a real
    // fault rather than ordinary startup. Neither ever renders a confident
    // zero or an "all current" verdict - GL-14's rule.

    /// The honest loading state shared by all four Setup modules and Vault.
    func fillPendingSetupSignal(_ content: inout HelmModuleCard.Content,
                                        checking: String,
                                        stale: String) {
        Self.applyPendingSetupSignal(&content,
                                     warmingUp: Self.pollerIsStillWarmingUp,
                                     checking: checking,
                                     stale: stale)
    }

    /// The two honest "no number yet" states, as a pure function of which one
    /// it is.
    ///
    /// **Review #3's UI10.** The warming half used to be a
    /// `Checking\u{2026}` chip over a sentence, on all five cards at once -
    /// see `HelmModuleCard.Body`'s `.skeleton` case for why that read as a
    /// wall rather than as five loading cards. The chip and the sentence are
    /// both gone from the body; the sentence survives as the card's tooltip,
    /// so the detail is still a hover away.
    ///
    /// A static taking `warmingUp` rather than reading the poller, so the two
    /// states can be asserted without waiting fifteen minutes for a real pass
    /// (`Audit3UIFixesSelfTest`).
    static func applyPendingSetupSignal(_ content: inout HelmModuleCard.Content,
                                        warmingUp: Bool,
                                        checking: String,
                                        stale: String) {
        guard warmingUp else {
            // A pass finished and produced nothing. That is a real fault, not
            // ordinary startup, and it says so in words - a skeleton here
            // would promise an answer that is not coming.
            content.chip = nil
            content.body = .note(stale)
            return
        }
        content.chip = nil
        content.body = .skeleton()
        content.toolTip = checking
    }

    /// Updates: how many catalog tools need an action - a newer version, a
    /// missing install or a failed check - the count the sidebar's Setup
    /// badge and the bell state. Worded as "updates" only when every one of
    /// them really is an update (`fm/grandline-github-sync-counts`): this
    /// said "13 updates - Ready to install" over thirteen failed checks while
    /// Setup's own Updates card beside it said 0.
    func fillUpdates(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own updates
        // artwork, replacing the plain `steeringwheel` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.updates` case.
        content.artwork = UpdatesIcon.image
        content.subtitle = "tools & packages"
        guard let updates = BackgroundSignalsPoller.shared.lastCounts.toolUpdates else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking every tool for a newer version\u{2026}",
                                   stale: "Tool versions haven't been checked yet this session.")
            return
        }
        guard updates > 0 else {
            content.chip = .ok("Current")
            content.body = .note("Every tool in the catalog is on its latest version.")
            return
        }
        let available = BackgroundSignalsPoller.shared.lastCounts.toolsWithUpdate
        guard let available, available != updates else {
            content.chip = .warn("\(updates) update\(updates == 1 ? "" : "s")")
            content.body = .metric(value: "\(updates)",
                                   unit: updates == 1 ? "update" : "updates",
                                   note: "Ready to install from \(PlaceName.of(.updates)).")
            return
        }
        content.chip = .warn("\(updates) need\(updates == 1 ? "s" : "") attention")
        content.body = .metric(value: "\(updates)",
                               unit: updates == 1 ? "tool" : "tools",
                               note: available == 0
                                   ? "Missing, or could not be checked. See \(PlaceName.of(.updates))."
                                   : "\(available) with an update, the rest missing or not checked.")
    }

    /// Bootstrap: how many of the five setup steps have drifted. This is the
    /// progress body the aggregate Setup card used to carry, and it belongs
    /// here because `SetupStepKind` *is* Bootstrap's own stepper.
    func fillBootstrap(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "machine setup"
        guard let drift = BackgroundSignalsPoller.shared.lastCounts.setupDrift else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking the setup steps\u{2026} this card fills itself in when the first pass lands.",
                                   stale: "Setup status hasn't been checked yet this session.")
            return
        }
        let total = SetupStepKind.shown.count
        let done = max(0, total - drift)
        content.chip = drift == 0 ? .ok("Current") : .warn("\(drift) drifted")
        content.body = .progress(value: done, total: total,
                                 note: drift == 0
                                    ? "Every setup step matches."
                                    : "\(drift) step\(drift == 1 ? "" : "s") drifted.")
    }

    /// Automation: what a one-click "Run Automation" would actually do.
    ///
    /// Deliberately the same published `setupDrift` Bootstrap reads - that page
    /// is the sequencer over the very same `SetupStepChecks` predicates, so a
    /// second number would be a second opinion about one fact. What differs is
    /// the question each card answers: Bootstrap's is "does my machine match?",
    /// this one's is "is there anything for a run to do?".
    func fillAutomation(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own automation
        // artwork, replacing the plain `bolt.fill` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.automation` case.
        content.artwork = AutomationIcon.image
        content.subtitle = "one-click setup"
        guard let drift = BackgroundSignalsPoller.shared.lastCounts.setupDrift else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking what a full run would need to do\u{2026}",
                                   stale: "Setup status hasn't been checked yet this session.")
            return
        }
        let total = SetupStepKind.shown.count
        guard drift > 0 else {
            content.chip = .ok("Nothing to run")
            content.body = .note("All \(total) steps are already satisfied - a full run would skip every one.")
            return
        }
        content.chip = .warn("\(drift) to run")
        content.body = .note("A full run would work through \(drift) drifted step\(drift == 1 ? "" : "s") in order, stopping at the first failure.")
    }

    /// GitHub Sync: how many of the captain's forks upstream is ahead of -
    /// `SetupSummary.ForksFigure`, the same figure and words Setup's own
    /// GitHub sync card states, so the two cannot disagree.
    ///
    /// `fm/grandline-github-sync-counts`: this used to say "In sync - All 8
    /// forks match their upstream" both for a diverged fork and for a sweep
    /// where every check failed.
    func fillGitHubSync(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own GitHub Sync
        // artwork, replacing the plain `arrow.2.squarepath` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.githubSync` case.
        content.artwork = GithubSyncIcon.image
        content.subtitle = "forks"
        let figure = SetupSummary.ForksFigure(BackgroundSignalsPoller.shared.lastCounts)
        let label = figure.label ?? ""
        switch figure {
        case .unread:
            fillPendingSetupSignal(&content,
                                   checking: "Checking each fork against its upstream\u{2026}",
                                   stale: "Fork drift hasn't been checked yet this session.")
        case .toSync(let n, let diverged):
            content.chip = diverged > 0 ? .bad(label) : .warn(label)
            let total = GitHubSyncCatalog.repos.count
            let note: String
            if diverged == 0 {
                note = "Behind upstream, of \(total) tracked."
            } else if diverged == n {
                note = "Diverged from upstream, of \(total) tracked."
            } else {
                note = "Behind upstream, \(diverged) diverged, of \(total) tracked."
            }
            content.body = .metric(value: "\(n)", unit: n == 1 ? "fork" : "forks", note: note)
        case .couldNotCheck:
            content.chip = .bad(label)
            content.body = .note("None of the forks could be checked against upstream.")
        case .partlyRead(let checked, let total):
            content.chip = .warn(label)
            content.body = .note("\(total - checked) of \(total) forks could not be checked.")
        case .inSync(let total):
            content.chip = .ok(label)
            content.body = .note("All \(total) forks match their upstream.")
        }
    }

    func fillSchedules(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own schedules
        // artwork, replacing the plain `calendar` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.schedules` case.
        content.artwork = SchedulesIcon.image
        let schedules = sources.scheduleStore.schedules
        content.subtitle = "unattended"
        guard !schedules.isEmpty else {
            // L3: the old copy ("Nothing scheduled. Add one to have it run on
            // its own.") ran past the two-line note cap at a narrow column and
            // truncated mid-word - the same class as B9's Health note. Short
            // enough to fit, and the card's title already says what "one" is.
            content.body = .note("Nothing scheduled yet. Add one here.")
            return
        }
        let failed = schedules.filter { $0.lastRun?.verdict == .failed }
        content.chip = failed.isEmpty ? .ok("Clean") : .warn("\(failed.count) failed")
        let rows = schedules.prefix(HelmModuleCard.maxPeekRows).map { schedule -> HelmModulePeekRow in
            let state: HelmModuleRowState
            switch schedule.lastRun?.verdict {
            case .some(.failed): state = .bad
            case .some: state = .ok
            case .none: state = .idle
            }
            return HelmModulePeekRow(state: schedule.isEnabled ? state : .idle,
                                     text: schedule.action.title,
                                     value: schedule.isEnabled ? schedule.cadence.displayString : "paused")
        }
        content.setBoundedPeekRows(Array(rows), total: schedules.count)
    }

    func fillLogAnalyzer(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own log-analyzer
        // artwork, replacing the plain `text.magnifyingglass` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.logAnalyzer` case.
        content.artwork = LogAnalyzerIcon.image
        // Memoised inside the store (GL-35) - this is not a fresh disk walk
        // on every canvas render.
        let history = sources.logAnalyzerStore.history()
        content.subtitle = history.first.map { "last: \($0.sourceKind.displayName)" } ?? "nothing saved"
        guard let latest = history.first else {
            content.body = .note("Paste output or capture a terminal block to start an investigation.")
            return
        }
        content.body = .metric(value: "\(history.count)",
                               unit: history.count == 1 ? "saved" : "saved",
                               note: "Latest: \(latest.title)")
    }

    /// `fm/grandline-k8s-cluster-tail`. Reads the same `connectedHostIDs`
    /// closure the Hosts module already uses - `HostSessionRegistry`'s own
    /// live set, in memory, one hop away - and nothing else. The canvas constructs no store and fires no fetch
    /// (`DaylightModuleSelfTest.checkCanvasConstructsNoStores` is a source
    /// guard on exactly that), and this page's own data needs a feed tab the
    /// canvas has no business creating.
    func fillKubernetes(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own kubernetes
        // artwork, replacing the plain `cube.transparent` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.kubernetes` case.
        content.artwork = KubernetesIcon.image
        let live = connectedHostIDs?().count ?? 0
        content.subtitle = live == 0 ? "no live session" : (live == 1 ? "1 live session" : "\(live) live sessions")
        guard live > 0 else {
            content.body = .note("Cluster browsing and log tailing run inside a bastion session you're already logged into. Connect a host first.")
            return
        }
        content.body = .note("Browse pods, deployments and events read-only, or tail several pods at once - through a session you've already authenticated.")
    }

    /// Automic Vault's hardening panel, back at this app's `.vault`
    /// destination by the captain's own later correction
    /// (`fm/swap-vault-poneglyph-naming-in-grand-lin-1f` - see
    /// `VaultController.swift`'s header for the full history). The number is
    /// unchanged either way - the last snapshot `BackgroundSignalsPoller`
    /// took, never a fresh `av` shell-out (§6.1) - because what it counts did
    /// not change, only where the page lives and what it is called.
    func fillVault(_ content: inout HelmModuleCard.Content) {
        let counts = BackgroundSignalsPoller.shared.lastCounts
        content.subtitle = "names only"
        guard let secrets = counts.vaultSecrets else {
            // `fm/grandline-github-sync-counts`: the attention count comes
            // from the poller's `av doctor` read, which never needs the
            // secrets count (`av list`, the Vault page's alone). It used to be
            // hidden behind this branch, so the card said "hasn't been
            // checked" while the bell said "2 security tools need attention".
            if let attention = counts.vaultAttention {
                if attention > 0 { content.chip = .warn("\(attention) need\(attention == 1 ? "s" : "") a look") }
                content.body = .note("Open \(PlaceName.of(.vault)) to count the hardened secrets.")
                return
            }
            // The same two honest loading states as the four Setup modules, for
            // the same reason.
            fillPendingSetupSignal(&content,
                                   checking: "Checking Automic Vault\u{2026} this card fills itself in when the first pass lands.",
                                   stale: "Automic Vault hasn't been checked yet this session.")
            return
        }
        if let attention = counts.vaultAttention, attention > 0 {
            content.chip = .warn("\(attention) need\(attention == 1 ? "s" : "") a look")
        }
        content.body = .metric(value: "\(secrets)",
                               unit: secrets == 1 ? "secret" : "secrets",
                               note: "Hardened in Automic Vault's Keychain. Values never leave it.")
    }

    /// `fm/implement-grand-line-secrets-vault-poneg-ad`: the captain's own
    /// credential vault, named Poneglyph (`fm/swap-vault-poneglyph-naming-in-
    /// grand-lin-1f` gave `.vault`/Stores back to Automic Vault's hardening
    /// panel above). It is its own standalone destination now rather than a
    /// Setup tab (`fm/poneglyph-own-destination-and-strawhat-toolbar-
    /// shortcut`) - this card still just opens `RailDestination.poneglyph`,
    /// unaffected by which slot that destination shows.
    ///
    /// It reads injected state and shells out to nothing - §6.1's rule, and
    /// here it is also a security property: a canvas card must not decrypt
    /// anything, and while the vault is locked there is genuinely nothing to
    /// count.
    func fillPoneglyph(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own poneglyph
        // tablet artwork, replacing the plain `doc.text.image` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.poneglyph` case.
        content.artwork = PoneglyphIcon.image
        guard let vault = credentialVaultState?() else {
            content.subtitle = "encrypted credentials"
            content.body = .note("Open \(PlaceName.of(.poneglyph)) to unlock it.")
            return
        }
        switch vault.state {
        case .absent:
            content.subtitle = "not set up yet"
            content.chip = .warn("Set up")
            content.body = .note("Store your tokens and passwords here, encrypted, and get them back on any machine.")
        case .unreadable:
            content.subtitle = "unavailable"
            content.chip = .bad("Unreadable")
            content.body = .note("The vault file could not be read. Nothing has been overwritten - open \(PlaceName.of(.poneglyph)) for details.")
        case .present:
            content.subtitle = "encrypted credentials"
            guard vault.isUnlocked, let count = vault.count else {
                content.chip = .mute("Locked")
                content.body = .note("Unlock with your master password to reach your credentials.")
                return
            }
            content.chip = .ok("Unlocked")
            content.body = .metric(value: "\(count)",
                                   unit: count == 1 ? "credential" : "credentials",
                                   note: "Reveal or copy any of them in one click.")
        }
    }

    /// `fm/grandline-docs-split-runbooks-postmortems` narrowed this card to
    /// the Playbook alone - Runbooks and Postmortems are `fillRunbooks`/
    /// `fillPostmortems` below now, each with its own module card. `DocsStore`
    /// is a plain static enum (no store to inject), so this reads exactly
    /// what `DocsController.drillHeaderSubtitle`'s own Playbook branch reads -
    /// the real sync state, never a fabricated "offline copy" claim.
    func fillDocs(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own docs
        // artwork, replacing the plain `book.closed` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.docs` case.
        content.artwork = DocsAppIcon.image
        content.subtitle = "DevOps Playbook"
        if DocsStore.isSynced {
            content.chip = .ok("Synced")
            content.body = .note("Browsable offline - the captain's playbook, kept locally.")
        } else {
            content.chip = .warn("Not synced")
            content.body = .note("Sync it once from \(PlaceName.of(.docs)) to browse it here, fully offline afterward.")
        }
    }

    /// F1's notebook card: the two most recently touched pages, and how many
    /// there are.
    ///
    /// GL-14: an empty notebook says so in its own words rather than showing
    /// "0 pages", and the card never claims a sync state it has not read.
    func fillNotebook(_ content: inout HelmModuleCard.Content) {
        let pages = sources.notebookStore.listPages()
        content.subtitle = "linked markdown pages"
        guard !pages.isEmpty else {
            content.body = .note("No pages yet. Start with today's note - everything you write "
                                 + "lands in your own config repo as markdown.")
            return
        }
        content.chip = .ok(pages.count == 1 ? "1 page" : "\(pages.count) pages")
        let rows = pages
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(2)
            .map { page in
                HelmModulePeekRow(state: .idle,
                                  text: page.title,
                                  value: page.isDailyNote ? "daily note" : page.folder)
            }
        content.setBoundedPeekRows(Array(rows), total: pages.count, limit: 2)
    }

    /// F4's reading list card: what is still waiting, and the two most
    /// recently saved.
    ///
    /// GL-14 twice over: an empty list says so in its own words rather than
    /// showing "0 unread", and a link whose title has not been fetched yet
    /// shows its host rather than a blank row pretending to be a headline.
    func fillReadingList(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "links saved to read"
        // PERF-01: the store reads its file off the main thread at launch.
        // Until that lands this card states the gap (GL-14) rather than
        // either reading the file here, before the first frame, or calling
        // an unread list empty. `storeDidLoad()` re-renders it.
        guard sources.readingListStore.isLoaded else {
            content.body = .note("Reading your saved links\u{2026}")
            return
        }
        let links = sources.readingListStore.links
        guard !links.isEmpty else {
            content.body = .note("Nothing saved yet. Paste a URL here, or press \u{2318}6 in the "
                                 + "\u{2325}Space capture panel, and it lands here as a card.")
            return
        }
        let unread = links.filter { !$0.isRead }
        content.chip = unread.isEmpty
            ? .ok("all read")
            : .warn(unread.count == 1 ? "1 unread" : "\(unread.count) unread")
        // Unread first, newest first - the grid's own order, so the card and
        // the page agree about what is at the top of the pile.
        let rows = links
            .sorted(by: ReadingListQuery.order)
            .prefix(2)
            .map { link in
                HelmModulePeekRow(state: link.isRead ? .idle : .warn,
                                  text: link.displayTitle,
                                  value: link.host)
            }
        content.setBoundedPeekRows(Array(rows), total: links.count, limit: 2)
    }

    /// The runbook peek rows this card used to show under `.docs` before the
    /// split above - moved verbatim, since Runbooks is now its own module
    /// with its own destination.
    func fillRunbooks(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own runbooks
        // artwork, replacing the plain `list.bullet.rectangle` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.runbooks` case.
        content.artwork = RunbooksIcon.image
        let runbooks = sources.docsRunbookStore.listRunbooks()
        content.subtitle = "step-by-step procedures"
        guard !runbooks.isEmpty else {
            // R2-UX-01 (c): what a runbook is, before who can write one.
            content.body = .note("No runbooks yet. A runbook is a checklist of steps you can follow again - write one, or start from an example.")
            return
        }
        let rows = runbooks.prefix(2).map { runbook in
            HelmModulePeekRow(state: .idle,
                              text: runbook.title,
                              value: DocsRunbookMetadata.runbookSubtitle(runbook) ?? "")
        }
        content.setBoundedPeekRows(Array(rows), total: runbooks.count, limit: 2)
    }

    /// The Postmortems sibling of `fillRunbooks` above - same shape, reading
    /// `listPostmortems()` instead.
    func fillPostmortems(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own postmortems
        // artwork, replacing the plain `doc.text.magnifyingglass` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.postmortems` case.
        content.artwork = PostmortemsIcon.image
        let postmortems = sources.docsRunbookStore.listPostmortems()
        content.subtitle = "incident write-ups"
        guard !postmortems.isEmpty else {
            content.body = .note("No postmortems yet. A postmortem writes down what went wrong, why, and what changes next time.")
            return
        }
        let rows = postmortems.prefix(2).map { postmortem in
            HelmModulePeekRow(state: .idle,
                              text: postmortem.title,
                              value: DocsRunbookMetadata.postmortemSubtitle(postmortem) ?? "")
        }
        content.setBoundedPeekRows(Array(rows), total: postmortems.count, limit: 2)
    }

    func fillDictation(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "hold Right \u{2325}"
        let dictationStatus = pushedDictationStatus ?? DictationPermissions.currentStatus()
        switch dictationStatus {
        case .ready: content.chip = .ok("Ready")
        case .recording, .transcribing, .cleaningUp: content.chip = .mute(dictationStatus.title)
        case .didNotCatchThat: content.chip = .warn(dictationStatus.title)
        default: content.chip = .warn("Needs access")
        }
        content.body = .note(dictationStatus.detail(shortcutDisplay: AppSettings.shared.dictationShortcut.displayString))
    }

    func fillTools(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own tools
        // artwork, replacing the plain `wrench.and.screwdriver` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.tools` case.
        content.artwork = ToolsAppIcon.image
        content.subtitle = "\(ToolKind.allCases.count) utilities"
        content.body = .note(ToolKind.allCases.prefix(5).map { $0.shortName }.joined(separator: " \u{00B7} ") + " and more")
    }

    /// Static, like Tools' and Settings' cards (§6.1's table says "static" for
    /// both, and this is the same kind of card): a whiteboard has no count the
    /// canvas could read without reaching into a live web view, and this card
    /// must never do that - the whole point of the destination being lazy is
    /// that the canvas can be on screen with no canvas process running.
    func fillWhiteboard(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own whiteboard
        // artwork, replacing the plain `scribble.variable` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.whiteboard` case.
        content.artwork = WhiteboardAppIcon.image
        content.subtitle = "Excalidraw, offline"
        content.body = .note("Sketch by hand, or describe a diagram and have Claude draw it.")
    }

    /// Static, like Whiteboard's card right above and for the exact same
    /// reason: a live note count would mean constructing a `StickyBoardStore`
    /// from the canvas, which `checkCanvasConstructsNoStores` exists to
    /// forbid - the canvas never fires a fetch, and a store construction here
    /// is one, not just a read.
    /// R5-UX-07: what the calendar has next - the open tasks and follow-ups
    /// dated from now to two weeks out, from the entries the calendar itself
    /// draws (`HomeNextUpCard`). Overdue work is the Tasks card's.
    func fillCalendar(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "next up"
        // GL-14: a task list that would not read is not an empty calendar.
        guard !sources.shiftStore.isInFailedLoadState else {
            content.chip = .warn("Can't read")
            content.body = .note("The task list could not be read, so nothing upcoming can be shown.")
            return
        }
        let rows = HomeNextUpCard.rows(tasks: sources.shiftStore.activeTasks, followUps: sources.shiftStore.followUps)
        guard !rows.isEmpty else {
            content.chip = .mute("clear")
            content.body = .note("Nothing dated in the next two weeks. Give a task a due date, or "
                                 + "double-click a day on \(PlaceName.of(.calendar)) to add one.")
            return
        }
        content.chip = .mute(rows.count == 1 ? "1 coming up" : "\(rows.count) coming up")
        content.setBoundedPeekRows(rows.prefix(HelmModuleCard.maxPeekRows).map { row in
            HelmModulePeekRow(state: .idle, text: row.isFollowUp ? "Follow up: \(row.title)" : row.title,
                              value: row.when)
        }, total: rows.count)
    }

    /// R5-UX-07: the focus timer - the session running now, or today's
    /// focused minutes (`HomeFocusCard`).
    func fillFocusCard(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "deep work"
        let state = HomeFocusCard.state(session: sources.focusTimer?.session,
                                        focusedSecondsToday: sources.shiftStore.focusSecondsToday())
        switch state {
        case .running:
            content.chip = .ok("Focusing")
            content.body = .note(HomeFocusCard.note(for: state))
        case .paused:
            content.chip = .warn("Paused")
            content.body = .note(HomeFocusCard.note(for: state))
        case .idle(let minutes):
            content.chip = .mute(minutes == 0 ? "not started" : "today")
            content.body = .metric(value: "\(minutes)", unit: "min", note: HomeFocusCard.note(for: state))
        }
    }

    func fillStickyBoard(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own sticky-note
        // artwork, replacing the plain `note.text` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.stickyBoard` case.
        content.artwork = StickyNotesIcon.image
        content.subtitle = "quick notes"
        // UX5: "give each module card a genuinely useful peek (Tasks: due
        // today; Console: last command; Sticky: newest note) rather than a
        // static summary." Tasks and Console already had theirs; this card was
        // one of the static ones the finding is about - the same sentence on
        // every visit whether the board held nothing or forty notes.
        //
        // Newest first, which is the opposite of the store's own order
        // (`notes` is sorted oldest-first, because that is the board's
        // stacking order) - a peek of three answers "what was I just
        // thinking", not "what did I think first".
        // `activeNotes`, not every note: UX10 gave the board an archive, and a
        // hub peek that counted archived notes would report a board fuller
        // than the one the captain sees.
        // PERF-01: the same gap the reading list card states, for the same
        // reason - see `fillReadingList`.
        guard sources.stickyBoardStore.isLoaded else {
            content.body = .note("Reading your notes\u{2026}")
            return
        }
        let newest = sources.stickyBoardStore.activeNotes.sorted { $0.createdAt > $1.createdAt }
        guard !newest.isEmpty else {
            content.body = .note("Jot down a thought on a colored sticky note, anywhere on the board.")
            return
        }
        content.chip = .mute(newest.count == 1 ? "1 note" : "\(newest.count) notes")
        content.setBoundedPeekRows(newest.prefix(HelmModuleCard.maxPeekRows).map { note in
            HelmModulePeekRow(state: .idle,
                              // The same title-or-first-line fallback ⌘K's own
                              // sticky rows use, so one note reads the same way
                              // wherever it is listed.
                              text: UnifiedSearchStickyNoteProvider.displayTitle(for: note),
                              // The colour is the one thing a captain
                              // actually sorts these by on the board itself.
                              value: note.color.rawValue.capitalized)
        }, total: newest.count)
    }

    /// `names()` rather than `list()`: this needs "how many, and what are they
    /// called", and a snippet's content can be large - reading every one of
    /// them on every return to the hub would be a real cost for a subtitle.
    func fillCodePreview(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own code-preview
        // artwork, replacing the plain `chevron.left.forwardslash.chevron.right`
        // glyph - matches `RailDestination.drillHeaderArtwork`'s
        // `.codePreview` case.
        content.artwork = CodePreviewIcon.image
        let names = sources.codePreviewStore.names()
        content.subtitle = "Monaco, offline"
        guard !names.isEmpty else {
            content.body = .note("Paste code here to read it with real syntax highlighting.")
            return
        }
        content.chip = .mute(names.count == 1 ? "1 snippet" : "\(names.count) snippets")
        content.setBoundedPeekRows(names.prefix(HelmModuleCard.maxPeekRows).map {
            HelmModulePeekRow(state: .idle,
                              text: $0,
                              value: CodePreviewLanguage.forFilename($0).displayName)
        }, total: names.count)
    }

    /// Reads the store's already-loaded `commands` array and its favourites -
    /// both in-memory field reads on a store the shell already owns, so this
    /// costs nothing per canvas render. The peek rows are the captain's own
    /// recently-used commands, which is the one thing about this library that
    /// changes between visits.
    func fillCommandLibrary(_ content: inout HelmModuleCard.Content) {
        let total = commandLibrarySources.commands.count
        content.subtitle = "saved commands"
        guard total > 0 else {
            content.body = .note("Your DevOps command library - searchable, parameterised, one click from a terminal.")
            return
        }
        content.chip = .mute("\(total)")
        let recent = commandLibrarySources.recentlyUsedCommands(limit: HelmModuleCard.maxPeekRows)
        guard !recent.isEmpty else {
            content.body = .metric(value: "\(total)",
                                   unit: total == 1 ? "command" : "commands",
                                   note: "Nothing run yet - open the library to find one.")
            return
        }
        content.setBoundedPeekRows(recent.map {
            HelmModulePeekRow(state: .idle, text: $0.name, value: $0.category)
        }, total: total)
    }

    /// Spelled out rather than reaching through `sources` inline, purely so
    /// the store's role in this one card is obvious at its use site.
    var commandLibrarySources: CommandLibraryStore { sources.commandLibraryStore }

    func fillSettings(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own settings
        // artwork, replacing the plain `gearshape` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.settings` case.
        content.artwork = SettingsAppIcon.image
        content.subtitle = "this machine"
        content.body = .note("Connection \u{00B7} Appearance \u{00B7} Terminal \u{00B7} Security \u{00B7} Backup")
    }

    /// Whether the background-signals poller has yet completed a pass.
    ///
    /// Read from the poller rather than tracked here: `lastCompletedPassAt` is
    /// its own already-published state, so this cannot drift out of step with
    /// it and adds nothing new to observe.
    static var pollerIsStillWarmingUp: Bool {
        BackgroundSignalsPoller.shared.lastCompletedPassAt == nil
    }
}
