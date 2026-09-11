// Manjesh Grand Line - native macOS app.
//
// The Straw Hat Pirates crew chat, as its own destination.
//
// ## Why this is a page and not a tab any more
//
// Phases 1-3 shipped this as a third tab ("Crew") inside `FleetController`,
// Overview's own detail page - the captain's phase-1 placement call, in his
// words: "This will be inside overview section." He then used it and
// corrected himself (`fm/polish-straw-hat-overview-card-and-voice-c8d3`): he
// expected the crew to be **its own card on Overview, like the Console
// card**, and instead found it nested inside Fleet's page beside that page's
// unrelated Overview and Log tabs.
//
// That reaction is worth recording, because the tangle was real and not just
// a matter of taste. Overview's "Fleet" card reports Grand Line's own
// *dispatched crewmates* - the `working`/`needs_decision` tasks firstmate
// runs, whose ids look like `implement-straw-hat-pirates-...`. The Straw Hat
// Pirates are an AI persona chat. Two entirely different things called "crew"
// had ended up on one page by an accident of naming.
//
// So: `DaylightModule.strawHat` is its own Overview card (with the crew's own
// Jolly Roger on it - `StrawHatFlag`), it opens `RailDestination.strawHat`,
// and this controller is that page. Fleet's tab strip is back to
// Overview/Log.
//
// **This is a relocation, not a rewrite.** The turn cycle, the three-rung
// parser, the proposal executor, the confirm cards, the handoffs and the
// quick-ask entry point are the same code doing the same things; what changed
// is which controller owns them. Two things did genuinely go away, both
// because they only ever existed to make a chat work *inside a scrolling
// page*:
//
//   - `updateCrewChatHeight()` and `crewChatMinHeight`. The chat used to
//     derive its own height from the enclosing scroll view's viewport so the
//     outer scroller had nothing to scroll and the two did not fight over the
//     wheel. This page has no scroll view - the chat is pinned to its edges
//     and owns its own scrolling, which is what that derivation was
//     approximating.
//   - The in-page title and subtitle. Daylight §6.4: a page never repeats its
//     own destination name, a rule Review, Docs and Health were each
//     corrected for. `HelmDrillHeader` above shows "Straw Hat Pirates" and
//     this page's live subtitle; "New conversation" is hoisted into its
//     action cluster via `DaylightDrillActions`.
//
// What still does not live here: the persona (`StrawHatCrew`), the `claude`
// plumbing (`StrawHatRunner`), the reply parsing (`StrawHatEnvelope`), the
// writes (`StrawHatProposalExecutor`) and the rendering
// (`StrawHatChatView`).
//
// ## `fm/straw-hat-menubar-quick-chat-popover`
//
// Two additions, both deliberately thin wrappers around what this file
// already owns rather than a second implementation of either:
//
//  - `send(_ text:completion:)` grew an optional completion so the menu-bar
//    popover (`StrawHatMenuBarController`, owned by `AppDelegate`) can run a
//    turn through this controller's own runner and transcript - see that
//    method's own doc comment for why the popover's question is never a
//    second, disconnected conversation.
//  - `rosterButton`/`rosterTapped()` open `StrawHatRosterController`, a
//    static "who does what" reference built from `StrawHatMember`'s own
//    fixed table - not a live view, and holds no store.

import AppKit

/// The crew chat page.
final class StrawHatController: NSViewController, DaylightDrillActions {

    // MARK: Stores
    //
    // Every one of these is injected rather than constructed here, for the
    // reason `StrawHatContextSnapshot.capture` also takes its stores as
    // parameters: a file that builds its own would duplicate that store's
    // root precedence (several env branches apiece, which drift) and could
    // reach the captain's real git-synced clone from a self-test.

    /// The shared `ShiftStore` - the context snapshot's task half, and where a
    /// confirmed task/follow-up lands. Deliberately *the shared instance*: a
    /// second `ShiftStore()` would cache and write against the same files
    /// (AGENTS.md's `CommandLibraryStore` lesson).
    private let shiftStore: ShiftStore

    /// The command library's folder, for the crew's read-only
    /// `command_search` tool.
    ///
    /// A root URL rather than the store itself, and the two coexist on
    /// purpose: the *tool* only needs somewhere to read, while a saved
    /// command draft needs the shared store below. Constructing a second
    /// `CommandLibraryStore` here just to get a `.root` would be the mistake
    /// GL-24 fixed.
    private let commandLibraryRoot: URL

    /// The three phase-3 write stores.
    ///
    /// Each is the shared instance `AppShellController` owns, and that is
    /// mandatory rather than tidy (GL-23's lesson, applied three times over) -
    /// all three cache their records in memory as well as writing them:
    ///
    ///  - `CommandLibraryStore` is the instance GL-24 made shared after two
    ///    caching copies diverged in-session and raced each other's
    ///    `recent.yaml`. Phase 2.5 only needed its `.root`; a crew-saved
    ///    command needs the store, and it has to be that one.
    ///  - `StickyBoardStore` debounces its writes 1.5s and holds its notes in
    ///    memory, so a second instance's next flush would overwrite whatever
    ///    the board's own page had just written. That store is already
    ///    `internal` on `StickyBoardController` for exactly this reason
    ///    (audit section 6.5b did the same for the command palette).
    ///  - `ScheduleStore` likewise caches, and its rows drive a live runner.
    ///
    /// All three are optional so this page still builds in a context that has
    /// none of them - a confirmed proposal then fails with a real message
    /// rather than silently doing nothing, exactly as a missing
    /// `DocsRunbookStore` already does.
    private let commandLibraryStore: CommandLibraryStore?
    private let stickyStore: StickyBoardStore?
    private let scheduleStore: ScheduleStore?

    init(shiftStore: ShiftStore,
         commandLibraryRoot: URL,
         commandLibraryStore: CommandLibraryStore? = nil,
         stickyStore: StickyBoardStore? = nil,
         scheduleStore: ScheduleStore? = nil) {
        self.shiftStore = shiftStore
        self.commandLibraryRoot = commandLibraryRoot
        self.commandLibraryStore = commandLibraryStore
        self.stickyStore = stickyStore
        self.scheduleStore = scheduleStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// This page's own `DocsRunbookStore`, for Robin's half of the context
    /// snapshot and for a confirmed runbook draft.
    ///
    /// A per-page instance rather than a shared one, which is the established
    /// convention for *this* store specifically: it is uncached (every call
    /// re-reads its folder), so two instances cannot diverge the way two
    /// `CommandLibraryStore`s once did - and `RunbooksController`,
    /// `PostmortemsController`, `LogAnalyzerController` and
    /// `CommandLibraryPageView` each already hold their own.
    ///
    /// Built lazily so a captain who never opens this page never pays for it,
    /// and so the store's own `init` (which can reach `ShiftGitSync` when no
    /// override is set) is not run at app launch. `FM_SHIFT_DIR` and
    /// `FM_DOCS_RUNBOOKS_DIR` both redirect it, and `main.swift`'s self-test
    /// block sets both.
    private lazy var docsStore = DocsRunbookStore()

    // MARK: Views
    //
    // `lazy` rather than a stored `let`, because this destination is *lazily
    // mounted* (`DestinationRegistry`): the controller is constructed at
    // launch but its view is not built until the captain first opens the
    // page, and a stored view property would build the whole transcript and
    // composer at launch for a page most sessions never visit. Nothing on the
    // canvas-facing path (`canvasState`) touches either of these.

    private lazy var chat: StrawHatChatView = {
        let chat = StrawHatChatView()
        chat.onSubmit = { [weak self] text in self?.send(text) }
        // The single path from a proposal to a store. Set once here so there
        // is one wiring to audit rather than one per rendered card.
        chat.onConfirmProposal = { [weak self] proposal, choices in
            guard let self else {
                return .failed(message: "This page went away before that could be saved.")
            }
            return self.confirmProposal(proposal, choices: choices)
        }
        // M3.2's other half, and deliberately its own closure rather than a
        // second branch inside `onConfirmProposal`: a handoff writes nothing,
        // and sharing one closure would let a self-test asserting that pass
        // with the two paths crossed.
        chat.onHandoff = { [weak self] handoff in
            guard let self else { return "This page went away." }
            return self.followHandoff(handoff)
        }
        chat.onMessagesChanged = { [weak self] in
            guard let self else { return }
            self.refreshNewButtonState()
            self.publishCanvasState()
        }
        return chat
    }()

    private lazy var newButton: HelmButton = {
        let button = HelmButton(title: "New conversation", variant: .quiet, symbol: "plus.bubble")
        button.target = self
        button.action = #selector(newConversationTapped)
        button.isEnabled = false
        button.toolTip = "Start a new conversation - the crew forgets what was said before"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    /// `fm/straw-hat-menubar-quick-chat-popover`: "who does what" - a static
    /// tree/org-chart reference (`StrawHatRosterController`), not a live
    /// status view. `point.3.connected.trianglepath.dotted` is reused rather
    /// than guessed at: it already resolves in this app (GitHub Sync's
    /// "Repos" card, Kubernetes' session card header) and reads well for "a
    /// group of connected nodes".
    private lazy var rosterButton: HelmButton = HelmPageToolbar.iconButton(
        symbol: "point.3.connected.trianglepath.dotted",
        tooltip: "Crew roster - who does what",
        target: self, action: #selector(rosterTapped))

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    // MARK: Turn state

    /// Built on the first send, not at `loadView` - resolving `claude` and
    /// writing an MCP config is work for a page whose captain may only be
    /// reading the transcript.
    private var runner: StrawHatRunner?
    private var turnInFlight = false

    /// Every proposal this page has already resolved, keyed by
    /// `StrawHatProposal.id`. See `confirmProposal` for what this is for.
    ///
    /// Cleared by "New conversation" along with the transcript itself - a
    /// thread the captain has thrown away has no proposals left to dedup
    /// against, and the ids are gone with it either way.
    private var resolvedProposals: [UUID: ResolvedProposal] = [:]

    /// A recorded terminal outcome, without the `undo` closure `.written`
    /// carries - see `record(_:for:)`.
    private enum ResolvedProposal {
        case written(message: String)
        case openedForReview(message: String)

        var outcome: StrawHatProposalOutcome {
            switch self {
            case .written(let message): return .written(message: message, undo: nil)
            case .openedForReview(let message): return .openedForReview(message: message)
            }
        }
    }

    // MARK: Forwarded closures
    //
    // Each of these is navigation or state this page does not own. The
    // forward-don't-own convention every out-of-page surface in this app
    // follows - `AppShellController` wires them.

    /// M3.2: where an `open_destination` handoff goes, and the hint it
    /// carries. This page knows nothing about the whiteboard's composer or
    /// about which destination has an entry point worth landing on.
    var onOpenDestination: ((RailDestination, String?) -> Void)?

    /// M3.2: `open_sre_lead`. Returns a message when the handoff could not be
    /// followed (no live session on that host, or no host matched what the
    /// captain called it) and `nil` when the app moved.
    ///
    /// The *app* resolves which host, never the crew - the crew cannot see
    /// hosts at all. See `AppShellController.openSRELeadForCrew`.
    var onOpenSRELead: ((String?) -> String?)?

    /// Set by `AppShellController` - "re-read my subtitle". The drill header
    /// is the shell's; this page only says when its numbers moved.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Set by `AppShellController` - "my card's summary changed". The Overview
    /// card reads `canvasState` when it renders; this is what tells it a
    /// render is worth doing.
    var onCanvasStateChanged: (() -> Void)?

    // MARK: The Overview card's summary

    private(set) var canvasState = StrawHatCanvasState()

    // MARK: Drill header (Daylight §6.4)

    /// Counted off the same conversation the transcript renders, so the
    /// header and the page can never disagree, and nothing new is read to
    /// produce it.
    var drillHeaderSubtitle: String? {
        let aboard = "\(StrawHatMember.allCases.count) aboard"
        if canvasState.isThinking { return "\(aboard) \u{00B7} thinking\u{2026}" }
        guard canvasState.exchanges > 0 else {
            return "\(aboard) \u{00B7} every write is yours to confirm"
        }
        let noun = canvasState.exchanges == 1 ? "1 exchange" : "\(canvasState.exchanges) exchanges"
        return "\(aboard) \u{00B7} \(noun) \u{00B7} every write is yours to confirm"
    }

    /// §6.4's action cluster: this page's own actions, hoisted out of a page
    /// header that no longer exists. Caller-owned, so the enabled state this
    /// controller manages on `newButton` keeps working. The roster button
    /// carries no state of its own - it always opens the same static
    /// reference sheet.
    var drillHeaderActions: [NSView] { [newButton, rosterButton] }

    // MARK: Building

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 720))
        root.wantsLayer = true
        view = root

        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.wantsLayer = true
        chat.layer?.cornerRadius = HelmMetrics.rCard
        chat.layer?.masksToBounds = true
        chat.layer?.borderWidth = 1
        root.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            chat.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            chat.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            chat.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s4),
        ])

        // Registered *after* the view tree exists, then fired once by hand.
        // `ThemeManager.observe` fires synchronously at registration, and this
        // codebase has shipped that trap four times (see `HelmFormSheet`'s
        // header) - a closure registered before `chat` was in the tree would
        // theme nothing.
        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
        applyTheme(ThemeManager.shared.theme)
        refreshProjects()
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A project created on the Tasks page since this page was last open
        // has to be pickable here, and appearing is the only moment it can
        // have happened - this page is showing for every other moment.
        refreshProjects()
        chat.focusComposer()
    }

    /// Hands the chat the captain's current projects, for a task card's own
    /// inline picker.
    ///
    /// Reads the shared `ShiftStore`'s own in-memory list rather than forcing
    /// a reload: it is the same instance the Tasks page writes through, so a
    /// project created there is already here, and a disk read on every appear
    /// would buy nothing. `setProjects` is a no-op when the list has not
    /// changed, so this costs nothing on a repeat visit either.
    private func refreshProjects() {
        chat.setProjects(shiftStore.projects)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // AGENTS.md gotcha (8) plus the "half-themed page" class this app
        // shipped three times: a full-size destination must force its own
        // appearance, or everything AppKit resolves semantically inside it
        // (scrollers, the shared field editor, focus rings) follows the OS's
        // light/dark rather than the Helm theme.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        chat.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        chat.applyTheme(theme)
        // `newButton` is a `HelmButton` and themes itself - never set
        // `contentTintColor`/`attributedTitle` on one, `restyle()` owns them.
    }

    // MARK: Assembled inputs

    /// Every store a confirmed proposal can reach, in the one shape
    /// `StrawHatProposalExecutor` takes (phase 3, M3.1).
    private var stores: StrawHatProposalExecutor.Stores {
        StrawHatProposalExecutor.Stores(shift: shiftStore,
                                        docs: docsStore,
                                        sticky: stickyStore,
                                        commands: commandLibraryStore,
                                        schedules: scheduleStore)
    }

    /// The three store roots phase 2.5's read-only tools are pointed at
    /// (`StrawHatTools.swift`).
    ///
    /// Built here rather than inside `StrawHatCrew.setUpTools` for the same
    /// reason the stores above are injected: going through the real stores
    /// means a self-test's `FM_SHIFT_DIR` reaches the tools with no extra
    /// wiring, because these stores already resolved it.
    private var storeRoots: StrawHatStoreRoots {
        StrawHatStoreRoots(shift: shiftStore.root,
                           docs: docsStore.root,
                           commands: commandLibraryRoot)
    }

    // MARK: The turn cycle

    @objc func newConversationTapped() {
        runner?.reset()
        turnInFlight = false
        resolvedProposals.removeAll()
        chat.clearMessages()
        chat.setInputEnabled(true)
        canvasState = StrawHatCanvasState()
        newButton.isEnabled = false
        publishCanvasState()
        chat.focusComposer()
    }

    /// "Who does what" - opens the static crew roster reference
    /// (`StrawHatRosterController`). A plain sheet, not a store-backed
    /// controller: it reads nothing but `StrawHatMember`'s own fixed table,
    /// so a fresh instance per press is cheap and there is nothing to keep
    /// in sync.
    @objc func rosterTapped() {
        let roster = StrawHatRosterController()
        presentAsSheet(roster)
        #if FM_SELFTESTS
        debugLastRoutedRoster = roster
        #endif
    }

    /// M3.3's entry point: one message from somewhere else in the app, into a
    /// **new** conversation.
    ///
    /// Used by Overview's "Ask your crew" card. A message appended to a thread
    /// the captain cannot see would be answered in a context they are not
    /// looking at, which is why this resets first - exactly as the page's own
    /// "New conversation" button does.
    ///
    /// A turn already in flight belongs to a conversation the captain may be
    /// about to look at; resetting it out from under them would drop a reply
    /// mid-flight, so that case does not reset anything.
    ///
    /// **It does not silently do nothing either** - the review's L7. It used
    /// to `return` on that guard, so the captain typed into Overview's
    /// quick-ask card, pressed Ask, landed on this page, and found their
    /// message simply gone with nothing said about it - the worst of the three
    /// possible outcomes, because it looks exactly like a dropped keystroke.
    /// Now the transcript says what happened and the message is handed back
    /// into the composer, so recovery is one press of Send once the running
    /// turn resolves. `send(_:)`'s own in-flight branch already reported this
    /// through its `completion` for the menu-bar popover; this is the same
    /// courtesy for the one caller that has no completion to report to.
    func startNewConversation(with text: String) {
        guard !turnInFlight else {
            chat.append(.status("The crew is still answering something else, so this wasn\u{2019}t sent yet \u{2014} it\u{2019}s waiting in the box below."))
            chat.setComposerText(text)
            _ = chat.focusComposer()
            return
        }
        newConversationTapped()
        send(text)
    }

    /// One turn: the captain's message, a status line while `claude` runs,
    /// then the reply's sections in its place.
    ///
    /// The composer is disabled for the whole turn - `StrawHatRunner` is not
    /// built for concurrent `ask` calls and says so, the same contract
    /// `SRELeadChatView` enforces for SRE Lead.
    ///
    /// `completion` is the menu-bar popover's own hook
    /// (`fm/straw-hat-menubar-quick-chat-popover`) - it fires exactly once,
    /// after the turn resolves, with the same sections `renderReply` just
    /// appended to this controller's **own real transcript** on success (or
    /// the failure message otherwise). This is deliberately not a second
    /// turn cycle: the popover's question lands in the SAME conversation
    /// `send(_:)` always has, so a proposal it surfaces can be confirmed
    /// later on the real page with a working card - not re-asked from
    /// scratch. `nil` for the composer's own call, which has nowhere else to
    /// report to.
    ///
    /// A turn already in flight (from either surface - the popover and the
    /// composer share this one runner) reports a real failure through
    /// `completion` rather than silently doing nothing, since a popover
    /// press with no visible effect reads as broken.
    func send(_ text: String, completion: ((Result<[StrawHatSection], StrawHatError>) -> Void)? = nil) {
        guard !turnInFlight else {
            completion?(.failure(StrawHatError(message: "The crew is already answering something else - try again in a moment.")))
            return
        }

        chat.append(.captain(text))

        // Phase 2.5: the runner sets its own tool session up from these roots
        // once, on first use, and tears it down with itself. A captain who
        // never opens this page never writes an MCP config at all.
        if runner == nil { runner = StrawHatRunner(storeRoots: storeRoots) }
        guard let runner else {
            // Not a crash and not a silent no-op: the one thing this feature
            // needs that the app cannot install for the captain.
            let message = "I can't find the `claude` command on this Mac. Install Claude Code and sign in, then try again \u{2014} Grand Line uses your own CLI login, so there's no API key to set up."
            chat.append(.error(message))
            completion?(.failure(StrawHatError(message: message)))
            return
        }

        turnInFlight = true
        chat.setInputEnabled(false)
        newButton.isEnabled = false
        chat.append(.status("The crew is thinking\u{2026}"))
        canvasState.isThinking = true
        publishCanvasState()

        // M2.3: captured here, fresh, once per turn - not inside the runner
        // (which owns `claude` and should not reach into stores) and not
        // cached (a snapshot from three turns ago would tell the crew a task
        // is due that the captain has since completed).
        let context = StrawHatContextSnapshot.capture(shift: shiftStore, docs: docsStore)

        runner.ask(text, context: context) { [weak self] result in
            guard let self else { return }
            self.turnInFlight = false
            self.canvasState.isThinking = false
            self.chat.removeTrailingStatus()
            switch result {
            case .success(let reply):
                let sections = self.renderReply(reply)
                completion?(.success(sections))
            case .failure(let error):
                AppLog.ai.error("straw hat: turn failed: \(error.message, privacy: .public)")
                self.chat.append(.error(error.message))
                completion?(.failure(error))
            }
            self.chat.setInputEnabled(true)
            self.refreshNewButtonState()
            self.publishCanvasState()
        }
    }

    /// M2.1's three rungs, at their one call site.
    ///
    /// The rungs themselves are `StrawHatEnvelope.parse`'s; all this does is
    /// append what came back. Note there is **no** failure branch: the parser
    /// cannot fail, by design - rung 3 renders the reply as a crew block,
    /// which is exactly phase 1's behaviour. That is what makes a model that
    /// stops emitting the envelope a cosmetic regression rather than a chat
    /// that silently stops answering.
    ///
    /// One exception, inside rung 3: a whole reply that reads as leaked
    /// tool-use narration (`StrawHatEnvelope.isLikelyToolNarration`'s own
    /// header - the captain's screenshot is its fixture) is never put in
    /// Luffy's own voice. Attributing an internal-reasoning fragment to a
    /// character speaking in character is the exact immersion break this
    /// feature exists to avoid, so it renders as a plain, unattributed note
    /// instead - honest about what happened, and still something rather than
    /// nothing (the ladder's own "the reply is never dropped" invariant).
    ///
    /// Returns exactly the sections this call appended to `chat`, in order -
    /// `send(_:completion:)`'s own hook for the menu-bar popover, so a
    /// second surface can build a compact summary from the same parse rather
    /// than re-deriving it.
    @discardableResult
    private func renderReply(_ reply: String) -> [StrawHatSection] {
        var spoke: [StrawHatMember] = []
        var preview: String?
        var rendered: [StrawHatSection] = []
        switch StrawHatEnvelope.parse(reply) {
        case .envelope(let sections):
            for section in sections {
                chat.append(.crew(section))
                rendered.append(section)
                if let speaker = section.speaker, !spoke.contains(speaker) { spoke.append(speaker) }
                if preview == nil { preview = Self.previewLine(of: section.text) }
            }
        case .plain(let text):
            if StrawHatEnvelope.isLikelyToolNarration(text) {
                AppLog.ai.info("straw hat: the whole reply looked like leaked tool-use narration - showing a status note instead of crediting it to Luffy")
                let note = StrawHatSection(speaker: nil, rawSpeaker: "",
                                           text: "That reply didn't come through cleanly - try asking again.",
                                           proposals: [], droppedProposalCount: 0, followup: nil)
                chat.append(.crew(note))
                rendered = [note]
            } else {
                let section = StrawHatSection.text(StrawHatCrew.speaker, text)
                chat.append(.crew(section))
                rendered = [section]
                spoke = [StrawHatCrew.speaker]
                preview = Self.previewLine(of: text)
            }
        }
        canvasState.exchanges += 1
        canvasState.lastSpeakers = spoke
        // Only overwritten when this reply actually had a line worth showing -
        // an all-proposals section with empty text should leave the card's
        // previous preview alone rather than blanking it.
        if let preview { canvasState.lastLine = preview }
        return rendered
    }

    /// The Overview card's one-line preview of a reply.
    ///
    /// A section's text is markdown and may be several lines with bullets and
    /// fenced code in it; the card has room for one line. Taking the first
    /// non-empty line is a summary rather than a truncation of the whole
    /// block, and the leading markdown noise is stripped so a reply that
    /// happens to start with a bullet does not read as one on the card.
    private static func previewLine(of markdown: String) -> String? {
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }
            while let first = line.first, "-*#>".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "`", with: "")
            guard !line.isEmpty else { continue }
            return line
        }
        return nil
    }

    /// M2.2: the captain pressed a confirm card's button.
    ///
    /// A kind that has an existing "New X" editor to review through
    /// (`StrawHatProposalKind.opensEditor`) never reaches
    /// `StrawHatProposalExecutor.execute` at all - `openEditorForReview` owns
    /// it end to end, including its own write once the captain saves. The
    /// three remaining write kinds - `.addTask` among them again, see that
    /// executor's header - take the direct path and write on this press.
    /// Wired to the chat view once, in `chat`'s own initializer - so there is
    /// exactly one path from a proposal to a store, and it starts at a real
    /// button press.
    ///
    /// - Parameter choices: what the captain picked on the card before
    ///   pressing it (today: which project a task lands in). Handed through
    ///   rather than read back off the card, so the write can never depend on
    ///   a view that a theme change may already have rebuilt.
    func confirmProposal(_ proposal: StrawHatProposal,
                         choices: StrawHatConfirmChoices = .init()) -> StrawHatProposalOutcome {
        // One proposal, one write. This is the *write* half of the fix for a
        // real HIGH-severity defect (`StrawHatProposal.id`'s own note has the
        // mechanism): the transcript is rebuilt from its data on any theme or
        // chrome-font-scale change, so a card whose confirmed state lived only
        // on the view came back armed and a second press wrote a second
        // identical record to the captain's stores.
        //
        // `StrawHatChatView.proposalResolutions` re-renders an already-resolved
        // card in its done state, which is what the captain sees; this is the
        // guarantee that holds even if it does not - a keyboard activation
        // racing a rebuild, or any future renderer. The stored outcome is
        // replayed verbatim so the card lands in the same state it would have,
        // and deliberately *without* a second toast or a second `execute`.
        if let already = resolvedProposals[proposal.id] {
            AppLog.ai.info("straw hat: ignoring a repeat confirm of an already-resolved proposal")
            return already.outcome
        }
        guard !proposal.kind.opensEditor else {
            return record(openEditorForReview(proposal), for: proposal)
        }
        let outcome = StrawHatProposalExecutor.execute(proposal, stores: stores, choices: choices)
        switch outcome {
        case .written(let message, let undo):
            // GL-33 / the house convention: a toast for a transient
            // confirmation, and `showUndo` only where the undo genuinely
            // restores. Every kind that reaches here in production now has a
            // real one - `.addTask` included, since `ShiftStore.deleteTask`
            // exists (see `StrawHatProposalExecutor`'s header) - but the
            // branch stays, because `undo` is the executor's decision to make
            // per kind and a future one may honestly have none. The card's own
            // confirmed state names where the record went either way.
            if let undo {
                Toast.showUndo(in: view, message: message, onUndo: undo)
            } else {
                Toast.show(in: view, message: message)
            }
        case .failed(let message):
            AppLog.ai.error("straw hat: a confirmed proposal failed: \(message, privacy: .public)")
            Toast.show(in: view, message: message)
        case .openedForReview:
            // Unreachable: `execute` never returns this case - the guard above
            // already diverted every kind that could.
            break
        }
        return record(outcome, for: proposal)
    }

    /// Remember a *terminal* outcome against the proposal's own id, so a
    /// repeat confirm replays it instead of re-executing.
    ///
    /// `.failed` is deliberately not recorded: nothing was written, so a retry
    /// is exactly what should happen next (and the card keeps its button for
    /// that reason).
    private func record(_ outcome: StrawHatProposalOutcome,
                        for proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        switch outcome {
        case .written(let message, _):
            // The `undo` closure is deliberately dropped rather than stored: a
            // replay shows no toast, so nothing would ever call it, and keeping
            // it alive would hold a closure that removes a record the captain
            // may have edited since.
            resolvedProposals[proposal.id] = .written(message: message)
        case .openedForReview(let message):
            resolvedProposals[proposal.id] = .openedForReview(message: message)
        case .failed:
            break
        }
        return outcome
    }

    // MARK: Editor-routed confirmation
    //
    // `fm/straw-hat-task-proposal-full-editor`. Each of these opens the same
    // "New X" sheet the app's own hand-created-record flows use, pre-filled
    // from the proposal, and wires that sheet's own Save to the real store
    // write - so the captain reviews/adjusts every field that sheet exposes
    // (linked task, category, parameters, cadence, ...) before anything lands
    // anywhere. See `StrawHatProposalExecutor.swift`'s header for why this
    // deliberately never calls `execute` for these three kinds - and why
    // `.addTask`, which used to be a fourth, no longer routes here at all.

    /// One dispatch point for the three editor-routed kinds - kept separate
    /// from `confirmProposal` so the "does this kind open an editor at all"
    /// question and "which editor, with which fields" are two different
    /// switches, each exhaustive on its own.
    private func openEditorForReview(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        switch proposal.kind {
        case .addFollowUp:
            return openFollowUpEditor(proposal)
        case .saveCommandDraft:
            return openCommandEditor(proposal)
        case .createScheduleDraft:
            return openScheduleEditor(proposal)
        case .addTask, .createRunbookDraft, .addSticky, .openSRELead, .openDestination:
            // Unreachable - `opensEditor` is false for all five, so
            // `confirmProposal`'s guard never sends them here. Kept explicit
            // rather than folded into `default:` so adding a kind is a
            // compile error in both switches.
            return .failed(message: "Nothing was written.")
        }
    }

    /// Nami's `add_follow_up`. `.addTask` used to sit here too, in the same
    /// shape; `fm/grandline-strawhat-task-direct-create` removed it, and
    /// `StrawHatProposalExecutor`'s header has the captain's own reasoning.
    ///
    /// The crew's `notes` land in this sheet's own visible field rather than
    /// in a model property with no UI behind it - the same "silently set, never
    /// shown" complaint the routing exists to avoid.
    private func openFollowUpEditor(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        let due = proposal.resolvedDue()
        let editor = ShiftFollowUpEditorController(
            followUp: nil, tasks: shiftStore.activeTasks, projects: shiftStore.projects,
            prefillTitle: proposal.title, prefillNotes: proposal.notes,
            prefillFollowUpAt: due?.date, prefillFollowUpTime: due?.time)
        editor.onSave = { [weak self] followUp in
            guard let self else { return }
            self.shiftStore.addFollowUp(followUp)
            Toast.show(in: self.view, message: "Added \u{201C}\(followUp.title)\u{201D} to Follow-ups")
        }
        presentAsSheet(editor)
        #if FM_SELFTESTS
        debugLastRoutedEditor = editor
        #endif
        return .openedForReview(message: proposal.kind.openedForReviewLabel)
    }

    /// Zoro's `save_command_draft`. Audit #2 section 5.3's gate stays in
    /// front of the editor, unchanged: the captain still has to read the
    /// model's own shell text and vouch for it (`confirmAIAuthored`) before
    /// anything - including a form to edit it in - opens at all. Only once
    /// they proceed does the pre-filled Command editor appear, where they set
    /// category/description/tags/parameters/risk themselves; the stored risk
    /// is therefore the captain's own choice at Save time, never the
    /// heuristic guess alone (which only seeds the field).
    ///
    /// `"Crew Drafts"`, the folder the old direct write used, is not one of
    /// `CommandLibraryCategory.all`'s thirteen real, pickable categories, so
    /// it could never be *shown* as selected in this editor's own category
    /// card - a category the captain cannot see they are saving into is not
    /// review. "General DevOps" is the closest real starting point instead,
    /// same as any other unsorted new command; the captain can pick any
    /// category they like before saving.
    private func openCommandEditor(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        guard let commandLibraryStore else {
            return .failed(message: "I couldn't reach your command library, so there was nowhere to save that.")
        }
        guard let command = proposal.command, !command.isEmpty else {
            return .failed(message: "That draft had no command in it, so there was nothing to save.")
        }
        var outcome = StrawHatProposalOutcome.failed(
            message: "Not saved - you can ask again if you want it after all.")
        CommandRiskConfirmation.confirmAIAuthored(command: command, source: "The crew", intent: .saveTemplate) { [weak self] in
            guard let self else { return }
            let generalCategory = CommandLibraryCategory.all.first { $0.id == "general" }?.id
                ?? CommandLibraryCategory.all[0].id
            let prefill = DevOpsCommand(
                id: UUID().uuidString, name: proposal.title,
                description: proposal.notes ?? "Drafted by the crew - not yet vouched for.",
                category: generalCategory, subcategory: nil,
                commandTemplate: command, parameters: [], tags: ["crew-draft"],
                risk: CommandRiskConfirmation.heuristicRisk(of: command))
            let editor = CommandEditorController(editingID: nil, prefill: prefill, config: commandLibraryStore.config)
            editor.onSave = { [weak self] name, description, category, subcategory, template, parameters, tags, risk in
                guard let self else { return }
                let saved = commandLibraryStore.createCommand(
                    name: name, description: description, category: category, subcategory: subcategory,
                    commandTemplate: template, parameters: parameters, tags: tags, risk: risk)
                Toast.showUndo(in: self.view,
                               message: "Saved \u{201C}\(saved.name)\u{201D} to DevOps Commands as \(saved.risk.displayName)") {
                    commandLibraryStore.deleteCommand(id: saved.id)
                }
            }
            self.presentAsSheet(editor)
            #if FM_SELFTESTS
            self.debugLastRoutedEditor = editor
            #endif
            outcome = .openedForReview(message: proposal.kind.openedForReviewLabel)
        }
        return outcome
    }

    /// Franky's `create_schedule_draft`: opens the real Schedule editor
    /// pre-filled with the drafted action and cadence - the captain can
    /// change either, or the notify setting, before Save creates it.
    private func openScheduleEditor(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        guard let scheduleStore else {
            return .failed(message: "I couldn't reach your schedules, so there was nowhere to save that.")
        }
        guard let action = proposal.scheduleAction, let cadence = proposal.scheduleCadence else {
            return .failed(message: "That draft was missing its action or its cadence, so there was nothing to save.")
        }
        let prefill = AutomationSchedule(action: action, cadence: cadence, notifyOn: .changeOnly)
        let editor = ScheduleEditorController(schedule: nil, prefill: prefill)
        editor.onSave = { [weak self] schedule in
            guard let self else { return }
            scheduleStore.add(schedule)
            Toast.showUndo(in: self.view,
                           message: "Added \u{201C}\(schedule.action.pickerTitle)\u{201D} \u{00B7} \(schedule.cadence.displayString)") {
                scheduleStore.delete(id: schedule.id)
            }
        }
        presentAsSheet(editor)
        #if FM_SELFTESTS
        debugLastRoutedEditor = editor
        #endif
        return .openedForReview(message: proposal.kind.openedForReviewLabel)
    }

    // MARK: M3.2 - the two navigation handoffs

    /// The captain clicked a handoff link row.
    ///
    /// Returns a message only when the handoff could **not** be followed;
    /// `nil` means the app has already moved and there is nothing left to say
    /// (the row is not on screen any more either).
    ///
    /// Neither branch writes anything, which is what makes running on a single
    /// click rather than behind a confirm card defensible.
    func followHandoff(_ handoff: StrawHatHandoff) -> String? {
        switch handoff {
        case .destination(let dest, let hint):
            guard let open = onOpenDestination else {
                return "I couldn't reach that page from here."
            }
            AppLog.ai.info("straw hat: captain followed a handoff to \(dest.rawValue, privacy: .public)")
            open(dest, hint)
            return nil

        case .sreLead(let hint):
            guard let open = onOpenSRELead else {
                return "I couldn't reach SRE Lead from here."
            }
            // The app resolves which host, never the crew - see
            // `AppShellController.openSRELeadForCrew`. A refusal comes back as
            // real text so the row can say why rather than looking broken.
            return open(hint)
        }
    }

    // MARK: Lifecycle

    /// GL-13: a turn in flight when the app quits would keep its `claude`
    /// process running and render into a pane nobody is looking at.
    func shutdown() {
        runner?.cancel()
        turnInFlight = false
    }

    // MARK: Plumbing

    private func refreshNewButtonState() {
        newButton.isEnabled = chat.hasRealExchange && !turnInFlight
    }

    /// Tells the drill header and the Overview card that this conversation
    /// moved. Both read state this method does not compute - it only says
    /// "look again".
    private func publishCanvasState() {
        onDrillSubtitleChanged?()
        onCanvasStateChanged?()
    }

    #if FM_SELFTESTS
    var debugChat: StrawHatChatView { chat }
    var debugNewButton: HelmButton { newButton }
    var debugRosterButton: HelmButton { rosterButton }
    var debugTurnInFlight: Bool { turnInFlight }
    /// The roster sheet most recently built by `rosterTapped()`, whether or
    /// not `presentAsSheet` actually showed it on screen - the same
    /// "no self-test in this codebase relies on a genuine sheet presentation
    /// working headlessly" convention `debugLastRoutedEditor` already
    /// documents.
    var debugLastRoutedRoster: StrawHatRosterController?
    /// Whether the chat view has been built at all. The point of a lazily
    /// mounted destination is that a captain who never opens this page pays
    /// nothing for it, and a stored view property would silently undo that.
    var debugChatWasBuilt: Bool { chatWasBuiltForTests }
    /// Renders a raw reply through the real three-rung path, so a suite can
    /// drive rung 2 and rung 3 without a fake `claude` able to produce them.
    func debugRenderReply(_ reply: String) { renderReply(reply) }
    /// Confirms a proposal through the real executor + toast path.
    func debugConfirmProposal(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        confirmProposal(proposal)
    }
    /// The store roots this page would point the crew's tools at, so a suite
    /// can assert the MCP config really reaches its scratch directories.
    var debugStoreRoots: StrawHatStoreRoots { storeRoots }
    var debugStores: StrawHatProposalExecutor.Stores { stores }
    /// Follows a handoff through the real resolution path, so a suite can
    /// assert what a click does without synthesizing a mouse event on a row.
    func debugFollowHandoff(_ handoff: StrawHatHandoff) -> String? {
        followHandoff(handoff)
    }
    var debugRunner: StrawHatRunner? { runner }
    var debugContext: StrawHatContextSnapshot {
        StrawHatContextSnapshot.capture(shift: shiftStore, docs: docsStore)
    }
    /// The one-line preview the Overview card shows, through the real
    /// extractor - so a suite can assert what a markdown reply reduces to
    /// without rendering a card.
    static func debugPreviewLine(of markdown: String) -> String? { previewLine(of: markdown) }
    /// The editor most recently built by `openEditorForReview`, whether or
    /// not `presentAsSheet` actually managed to show it on screen - no
    /// self-test in this codebase relies on a genuine sheet presentation
    /// working headlessly (see `DaylightChromeSelfTest`'s own convention of
    /// mounting an editor controller standalone instead), so a suite drives
    /// this instance's own fields/save button directly, the same way.
    var debugLastRoutedEditor: NSViewController?
    #endif
}

/// What the Overview card says about the crew conversation.
///
/// Plain data, and deliberately **not read off the chat view**: the canvas
/// renders at launch, before the crew page has ever been mounted, and reading
/// a view property there would build the whole transcript for a card that
/// only wants one line of text. It is also what keeps the spirit of
/// `DaylightModuleSelfTest.checkCanvasConstructsNoStores` intact - the canvas
/// renders already-computed state and computes nothing itself.
///
/// A top-level type rather than one nested on the controller, matching
/// `DictationStatus`: `HomeCanvasController` takes it in a pushed
/// `applyStrawHat(_:)` and should not have to name a view controller to do
/// so.
struct StrawHatCanvasState {
    /// Completed captain-to-crew exchanges in the current conversation.
    var exchanges = 0
    /// Who spoke in the most recent reply, in the order they spoke.
    var lastSpeakers: [StrawHatMember] = []
    /// The first line of the most recent crew reply, for the card's preview.
    /// `nil` before the first reply.
    var lastLine: String?
    /// A turn is mid-flight. The card says so rather than showing a stale
    /// preview as though it were current.
    var isThinking = false
}

#if FM_SELFTESTS
extension StrawHatController {
    /// Reads the `lazy var`'s backing storage without triggering it - the only
    /// way to assert "this was not built" rather than "this is built now",
    /// since touching `chat` itself is what builds it.
    fileprivate var chatWasBuiltForTests: Bool {
        Mirror(reflecting: self).children.contains { child in
            child.label == "$__lazy_storage_$_chat" && !isNilOptional(child.value)
        }
    }
}

private func isNilOptional(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return false }
    return mirror.children.isEmpty
}
#endif
