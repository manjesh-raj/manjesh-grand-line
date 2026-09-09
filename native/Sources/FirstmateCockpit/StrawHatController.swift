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
        chat.onConfirmProposal = { [weak self] proposal in
            guard let self else {
                return .failed(message: "This page went away before that could be saved.")
            }
            return self.confirmProposal(proposal)
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

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    // MARK: Turn state

    /// Built on the first send, not at `loadView` - resolving `claude` and
    /// writing an MCP config is work for a page whose captain may only be
    /// reading the transcript.
    private var runner: StrawHatRunner?
    private var turnInFlight = false

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

    /// §6.4's action cluster: this page's one action, hoisted out of a page
    /// header that no longer exists. Caller-owned, so the enabled state this
    /// controller manages on it keeps working.
    var drillHeaderActions: [NSView] { [newButton] }

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
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        chat.focusComposer()
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
        chat.clearMessages()
        chat.setInputEnabled(true)
        canvasState = StrawHatCanvasState()
        newButton.isEnabled = false
        publishCanvasState()
        chat.focusComposer()
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
    /// mid-flight, so that case is left alone and only the navigation happens
    /// (the caller has already switched to this page by the time this runs).
    func startNewConversation(with text: String) {
        guard !turnInFlight else { return }
        newConversationTapped()
        send(text)
    }

    /// One turn: the captain's message, a status line while `claude` runs,
    /// then the reply's sections in its place.
    ///
    /// The composer is disabled for the whole turn - `StrawHatRunner` is not
    /// built for concurrent `ask` calls and says so, the same contract
    /// `SRELeadChatView` enforces for SRE Lead.
    func send(_ text: String) {
        guard !turnInFlight else { return }

        chat.append(.captain(text))

        // Phase 2.5: the runner sets its own tool session up from these roots
        // once, on first use, and tears it down with itself. A captain who
        // never opens this page never writes an MCP config at all.
        if runner == nil { runner = StrawHatRunner(storeRoots: storeRoots) }
        guard let runner else {
            // Not a crash and not a silent no-op: the one thing this feature
            // needs that the app cannot install for the captain.
            chat.append(.error("I can't find the `claude` command on this Mac. Install Claude Code and sign in, then try again \u{2014} Grand Line uses your own CLI login, so there's no API key to set up."))
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
                self.renderReply(reply)
            case .failure(let error):
                AppLog.ai.error("straw hat: turn failed: \(error.message, privacy: .public)")
                self.chat.append(.error(error.message))
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
    /// cannot fail, by design - rung 3 renders the reply verbatim as one Luffy
    /// block, which is exactly phase 1's behaviour. That is what makes a model
    /// that stops emitting the envelope a cosmetic regression rather than a
    /// chat that silently stops answering.
    private func renderReply(_ reply: String) {
        var spoke: [StrawHatMember] = []
        var preview: String?
        switch StrawHatEnvelope.parse(reply) {
        case .envelope(let sections):
            for section in sections {
                chat.append(.crew(section))
                if let speaker = section.speaker, !spoke.contains(speaker) { spoke.append(speaker) }
                if preview == nil { preview = Self.previewLine(of: section.text) }
            }
        case .plain(let text):
            chat.append(.crew(.text(StrawHatCrew.speaker, text)))
            spoke = [StrawHatCrew.speaker]
            preview = Self.previewLine(of: text)
        }
        canvasState.exchanges += 1
        canvasState.lastSpeakers = spoke
        // Only overwritten when this reply actually had a line worth showing -
        // an all-proposals section with empty text should leave the card's
        // previous preview alone rather than blanking it.
        if let preview { canvasState.lastLine = preview }
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
    /// The write itself is `StrawHatProposalExecutor`'s; this owns only the
    /// stores it hands over and the feedback afterwards. Wired to the chat
    /// view once, in `chat`'s own initializer - so there is exactly one path
    /// from a proposal to a store, and it starts at a real button press.
    func confirmProposal(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        let outcome = StrawHatProposalExecutor.execute(proposal, stores: stores)
        switch outcome {
        case .written(let message, let undo):
            // GL-33 / the house convention: a toast for a transient
            // confirmation, and `showUndo` only where the undo genuinely
            // restores. Two kinds have no undo, and
            // `StrawHatProposalExecutor`'s header records why (`ShiftStore`
            // has no delete for a task or a follow-up, so an "Undo" there
            // could only pretend). The card's own confirmed state names where
            // the record went either way.
            if let undo {
                Toast.showUndo(in: view, message: message, onUndo: undo)
            } else {
                Toast.show(in: view, message: message)
            }
        case .failed(let message):
            AppLog.ai.error("straw hat: a confirmed proposal failed: \(message, privacy: .public)")
            Toast.show(in: view, message: message)
        }
        return outcome
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
    var debugTurnInFlight: Bool { turnInFlight }
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
