// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates, the rendering half.
//
// Separate from `StrawHatSelfTest` on purpose: that one is pure logic and
// runs in CI's blocking job, this one mounts a real `StrawHatController` in a
// real `NSWindow` and drives real `NSButton` target/action clicks, so it
// belongs in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list with its
// window-backed peers. `FleetReplyLayoutSelfTest` is the sibling this copies.
//
// `fm/polish-straw-hat-overview-card-and-voice-c8d3` re-pointed this suite:
// the chat was a tab on `FleetController` for phases 1-3 and is its own
// destination now, so what used to be "switch to the Crew tab and measure"
// is "mount the page". The one case that still mounts a `FleetController` is
// M3.3's quick-ask card, which stays on the fleet dashboard by design.
//
// This app cannot be launched from a worktree to look at the page - every
// build shares one bundle identity, so a launched copy can disturb the
// captain's own running instance (see the README) - which makes a real
// off-screen mount the only way to check any of this geometry at all.
//
// Nothing here reaches the captain's real data: `FM_SHIFT_DIR` is redirected
// to a scratch directory before the controller is built (constructing one
// builds a `ShiftStore`, whose default root is the real git-synced clone),
// and every `claude` is a disposable shell script.
//
// Run: `FM_RUN_STRAW_HAT_VIEW_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only - see `Phase3PolishSelfTest`.
#if FM_SELFTESTS

import AppKit

enum StrawHatViewSelfTest {

    static func run() -> Bool {
        var ok = true

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-view-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The gate starts locked (the app does); the page's own chat refuses
        // every turn until it is open. Restored on the way out - this is
        // process-wide state.
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        _ = NSApplication.shared
        checkOwnCardAndDestination(&ok)
        checkChatFillsThePage(&ok)
        checkChatIsNotBuiltUntilMounted(&ok)
        checkCanvasCardSummary(&ok)
        checkTurnRoundTrip(&ok)
        checkMarkdownRenders(&ok)
        checkNewConversation(&ok)
        checkFailureIsShown(&ok)
        checkMultiSectionReply(&ok)
        checkAcceptanceScenario(&ok)
        checkSalvageRendersButNeverExecutes(&ok)
        checkToolNarrationRendersNeutralNote(&ok)
        checkContributingGlow(&ok)
        checkUnwiredCardFailsVisibly(&ok)
        checkHandoffRendersAsALink(&ok)
        checkHandoffWritesNothing(&ok)
        checkQuickAskCard(&ok)
        checkThemeSweep(&ok)

        print(ok ? "StrawHatViewSelfTest: all checks passed" : "StrawHatViewSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }

    // MARK: Harness

    private struct Mounted {
        let controller: StrawHatController
        let window: NSWindow
    }

    /// A real `StrawHatController` in a real off-screen window.
    private static func mount(width: CGFloat = 1100, height: CGFloat = 800,
                              shiftStore: ShiftStore? = nil,
                              stickyStore: StickyBoardStore? = nil,
                              commandLibraryStore: CommandLibraryStore? = nil,
                              scheduleStore: ScheduleStore? = nil) -> Mounted {
        // `shiftStore` is passed only by the cases that then assert what a
        // confirmed proposal wrote - everything else takes a fresh one, which
        // resolves through this suite's own scratch `FM_SHIFT_DIR`.
        // Phase 2.5's command-library root: a disposable empty directory,
        // because this suite drives the chat/proposal surface rather than the
        // crew's tools. `StrawHatMCPSelfTest` is where a real, populated set
        // of roots is exercised end to end.
        // Phase 3's three write stores are passed only by the cases that then
        // assert what a confirmed proposal wrote - a `nil` one is the real
        // "this page has no such store" path, which must fail visibly.
        let controller = StrawHatController(shiftStore: shiftStore ?? ShiftStore(),
                                            commandLibraryRoot: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("fm-straw-hat-view-commands", isDirectory: true),
                                            commandLibraryStore: commandLibraryStore,
                                            stickyStore: stickyStore,
                                            scheduleStore: scheduleStore)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
        controller.view.layoutSubtreeIfNeeded()
        return Mounted(controller: controller, window: window)
    }

    /// The page *is* the crew now, so this only settles layout - there is no
    /// tab to select and no height to derive. Kept as a named helper rather
    /// than inlined so the diff that removed the tab is legible, and because
    /// every case wants the same two lines.
    private static func showCrew(_ m: Mounted) {
        m.controller.view.layoutSubtreeIfNeeded()
        m.controller.debugChat.layoutSubtreeIfNeeded()
    }

    // MARK: Cases

    /// The captain's own placement correction, asserted as the tables it
    /// actually lives in.
    ///
    /// Phases 1-3 put this chat on a third tab inside `FleetController`, and
    /// this case used to assert exactly that - plus that no rail destination
    /// existed, with a comment saying a future task adding one "should have to
    /// change this line deliberately rather than by accident". This is that
    /// deliberate change: `fm/polish-straw-hat-overview-card-and-voice-c8d3`
    /// is the captain asking for its own Overview card instead, so the
    /// assertions are **inverted** rather than deleted - they had become a
    /// record of the old behaviour, the same shape audit #2 §4.5 found in
    /// `SessionRestoreSelfTest` and §1 found in
    /// `checkSettingsTwoColumnLayout`.
    ///
    /// What is asserted, and why each half matters: the card exists on
    /// Overview (the ask), it opens *its own* destination rather than Fleet's
    /// (the substance of the ask - a card that opened Overview would look
    /// right and change nothing), and Fleet's own tab strip no longer offers
    /// it (a duplicate entry point would be its own confusion).
    private static func checkOwnCardAndDestination(_ ok: inout Bool) {
        check(DaylightModule.allCases.contains(.strawHat),
              "there is a Straw Hat Pirates module - the captain asked for its own card", &ok)
        check(DaylightModule.strawHat.appearsOnOverview,
              "...and it renders on the Overview canvas", &ok)
        check(DaylightModule.strawHat.isVisible(in: .overview),
              "...which is what the canvas filter actually reads", &ok)
        check(DaylightModule.strawHat.space == nil,
              "...and nowhere else - it has no space of its own, like the briefing and Fleet", &ok)
        check(DaylightModule.strawHat.opens == .strawHat,
              "the card opens its own page, not Fleet's - got \(DaylightModule.strawHat.opens.rawValue)", &ok)
        check(DaylightModule.strawHat.title == "Straw Hat Pirates",
              "the card is named for the crew, got \(DaylightModule.strawHat.title)", &ok)

        // The page it opens is a real, registered body slot of its own.
        check(RailDestination.strawHat.slot == .strawHat,
              "the destination has its own body slot rather than sharing one", &ok)
        check(RailDestination.strawHat.bodyTitle == "Straw Hat Pirates",
              "...titled for the crew, got \(RailDestination.strawHat.bodyTitle)", &ok)

        // Fleet is back to the two tabs F6 gave it. Asserted against the real
        // strip, not against the enum, so a tab left in the UI would fail.
        let fleet = FleetController(shiftStore: ShiftStore())
        let fleetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        fleetWindow.contentViewController = fleet
        fleet.view.layoutSubtreeIfNeeded()
        check(fleet.debugTabIDs == ["overview", "log"],
              "Fleet's own page is back to Overview/Log - got \(fleet.debugTabIDs)", &ok)
        check(findLabel(in: fleet.view, text: "Crew") == nil,
              "...with no leftover Crew pill in its tab strip", &ok)

        // The card's own tile: the captain asked for the crew's Jolly Roger
        // on it, so this drives the *real* canvas and reads the real tile.
        // `hasTile` would pass for the SF Symbol fallback, which is why the
        // assertion is on the artwork path specifically.
        // Every store below resolves through the scratch overrides
        // `main.swift`'s own `#if FM_SELFTESTS` block sets for any `FM_RUN_*`
        // process (`FM_SHIFT_DIR`, `FM_HOSTS_FILE`, `FM_SCHEDULES_FILE`,
        // `FM_DOCS_RUNBOOKS_DIR`, `FM_CODE_PREVIEW_DIR`), so this reaches
        // none of the captain's real data. Driving the *real* canvas rather
        // than building a card by hand is the point: it is what proves the
        // module actually renders there.
        let canvas = HomeCanvasController(sources: .init(
            shiftStore: ShiftStore(),
            hostStore: HostStore(),
            scheduleStore: ScheduleStore(),
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: CodePreviewStore()))
        let canvasWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        canvasWindow.contentViewController = canvas
        canvas.view.layoutSubtreeIfNeeded()
        canvas.debugRenderNow()
        canvas.view.layoutSubtreeIfNeeded()
        let crewCard = canvas.moduleCardsForTests.first { $0.anatomyForTests.title == "Straw Hat Pirates" }
        guard let crewCard else {
            check(false, "the Overview canvas must render a Straw Hat Pirates card, got "
                    + "\(canvas.moduleCardsForTests.map { $0.anatomyForTests.title })", &ok)
            return
        }
        let anatomy = crewCard.anatomyForTests
        check(anatomy.tileHasArtwork,
              "the card's tile carries the Jolly Roger artwork, not an SF Symbol glyph", &ok)
        check(anatomy.isCardActivatable, "...and the card opens its page on a click", &ok)
        // With no conversation yet it must say so rather than fabricating a
        // summary of one (GL-14's rule, one more card).
        check(anatomy.noteTexts.contains(where: { $0.contains("Ask for a task") }),
              "a fresh card invites a question instead of inventing a summary, got \(anatomy.noteTexts)", &ok)
    }

    /// The chat has to fill the page, or it renders as a small box in an
    /// otherwise-empty page - the exact defect the audit found on Log
    /// Analyzer's own work area.
    ///
    /// Much simpler than it was: the chat used to derive its own height from
    /// `FleetController`'s scroll viewport so the two scrollers did not fight
    /// over the wheel, and on its own page there is no outer scroller to
    /// fight - the chat is pinned to the page's edges. So what is asserted is
    /// the pinning, at two window sizes, which is what that derivation was
    /// approximating.
    private static func checkChatFillsThePage(_ ok: inout Bool) {
        for (label, size) in [("a tall window", CGSize(width: 1100, height: 800)),
                              ("a short window", CGSize(width: 900, height: 420))] {
            let m = mount(width: size.width, height: size.height)
            showCrew(m)
            let chat = m.controller.debugChat
            let page = m.controller.view.bounds

            check(chat.frame.height > page.height * 0.75,
                  "\(label): the chat fills the page's height, got \(chat.frame) in \(page)", &ok)
            check(chat.frame.width > page.width * 0.85,
                  "\(label): ...and its width, got \(chat.frame) in \(page)", &ok)
            // Inside the page, not overflowing it - a destination wider than
            // its own page is how one caps the whole window (gotcha (13)).
            check(chat.frame.maxX <= page.maxX + 0.5 && chat.frame.maxY <= page.maxY + 0.5,
                  "\(label): the chat stays inside the page, got \(chat.frame) in \(page)", &ok)
        }

        let m = mount(width: 1100, height: 800)
        showCrew(m)
        let chat = m.controller.debugChat

        // The empty state is what a captain sees before their first message -
        // a blank content area would read as broken. It has to *fill* the
        // transcript area (so its own content centres in it) rather than sit
        // as a card at the top of a tall blank space, which is exactly how it
        // rendered before a real off-screen render caught it.
        check(!chat.debugEmptyStateHidden, "an empty thread shows the empty state", &ok)
        check(chat.debugEmptyStateFrame.height > chat.frame.height * 0.5,
              "the empty state fills the transcript area (so it centres) - got \(chat.debugEmptyStateFrame.height) of \(chat.frame.height)", &ok)

        // This view is a bordered card; its content must be inset from that
        // border rather than flush against it (also a real-render finding).
        check(chat.debugTranscriptLeadingInset > 4,
              "the transcript is inset from the card border, got \(chat.debugTranscriptLeadingInset)", &ok)
        check(chat.debugComposerLeadingInset > 4,
              "the composer is inset from the card border, got \(chat.debugComposerLeadingInset)", &ok)
        check(chat.debugMessageCount == 0, "...and holds no messages", &ok)
        check(!chat.debugSendEnabled, "Send is disabled with nothing typed", &ok)
        chat.debugType("hello")
        check(chat.debugSendEnabled, "Send enables once there is real text", &ok)
    }

    /// A lazily mounted destination must not build its view at launch.
    ///
    /// `StrawHatController` is constructed in `AppShellController.init` on
    /// every launch, and its chat is a `lazy var` for exactly this reason - a
    /// stored view property would build the whole transcript and composer for
    /// a page most sessions never open, which is the cost GL-37's laziness
    /// exists to remove. Read off the lazy storage rather than the property,
    /// because touching the property is what builds it.
    private static func checkChatIsNotBuiltUntilMounted(_ ok: inout Bool) {
        let controller = StrawHatController(shiftStore: ShiftStore(),
                                            commandLibraryRoot: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("fm-straw-hat-lazy", isDirectory: true))
        check(!controller.debugChatWasBuilt,
              "constructing the controller must not build its chat - this destination is lazily mounted", &ok)
        // The subtitle is what the shell asks an unmounted controller for, so
        // it has to be answerable without a view.
        check(controller.drillHeaderSubtitle?.contains("aboard") == true,
              "...and its drill subtitle answers without one, got \(String(describing: controller.drillHeaderSubtitle))", &ok)
        check(!controller.debugChatWasBuilt, "...still without building it", &ok)
    }

    /// What the Overview card says about the conversation.
    ///
    /// The card reads `canvasState`, which is plain data updated by the turn
    /// cycle - never read off the chat view, because the canvas renders at
    /// launch before this page has ever been mounted. So the assertions are
    /// about that state moving with the transcript, and about the preview
    /// extractor reducing a markdown reply to one honest line.
    private static func checkCanvasCardSummary(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        check(m.controller.canvasState.exchanges == 0,
              "a fresh page reports no exchanges - the card then says so rather than inventing a summary", &ok)
        check(m.controller.canvasState.lastLine == nil, "...and has no preview line", &ok)

        // One line, no embedded newline: a `\n` inside a JSON string needs
        // double-escaping through Swift's own literal, and getting that wrong
        // silently produces invalid JSON - i.e. rung 3, attributed to Luffy,
        // which is what this fixture would then be testing instead. The
        // markdown reduction is covered against the extractor directly below.
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"nami","text":"Two tasks are due today."}]}
        """)
        check(m.controller.canvasState.exchanges == 1,
              "a reply counts as one exchange, got \(m.controller.canvasState.exchanges)", &ok)
        check(m.controller.canvasState.lastSpeakers == [.nami],
              "...credited to who actually spoke, got \(m.controller.canvasState.lastSpeakers.map(\.rawValue))", &ok)
        check(m.controller.canvasState.lastLine == "Two tasks are due today.",
              "...with the first line as the card's preview, got \(String(describing: m.controller.canvasState.lastLine))", &ok)

        // An unattributed reply (the parser's rung 2) must credit nobody -
        // naming a crew member who did not speak is the plausible-but-wrong
        // the whole ladder exists to avoid.
        m.controller.newConversationTapped()
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"sanji","text":"Dinner is ready."}]}
        """)
        check(m.controller.canvasState.lastSpeakers.isEmpty,
              "an unaboard speaker credits nobody on the card, got \(m.controller.canvasState.lastSpeakers.map(\.rawValue))", &ok)

        // "New conversation" resets the card too, or it would keep showing a
        // thread the captain has just discarded.
        m.controller.newConversationTapped()
        check(m.controller.canvasState.exchanges == 0 && m.controller.canvasState.lastLine == nil,
              "a new conversation resets the card's summary", &ok)

        // The preview extractor: one line out of markdown, with the leading
        // noise stripped, and nothing at all out of a reply that is only a
        // fenced block.
        check(StrawHatController.debugPreviewLine(of: "# Heading\nbody") == "Heading",
              "a heading's marker is stripped, got \(String(describing: StrawHatController.debugPreviewLine(of: "# Heading\nbody")))", &ok)
        check(StrawHatController.debugPreviewLine(of: "\n\n- `kubectl get pods`") == "kubectl get pods",
              "leading blanks, a bullet and backticks are all stripped", &ok)
        check(StrawHatController.debugPreviewLine(of: "```\ncode\n") == "code",
              "a fence line is skipped rather than shown as the preview", &ok)
        check(StrawHatController.debugPreviewLine(of: "   ") == nil,
              "an empty reply has no preview rather than a blank one", &ok)
    }

    /// One real turn, end to end: type, click the real Send button, and watch
    /// the transcript go captain -> status -> reply.
    private static func checkTurnRoundTrip(_ ok: inout Bool) {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-view-argv-\(UUID().uuidString).log")
        let script = writeFakeClaude(reply: "Aye - let's start with the login bug.",
                                     argvLog: log, sessionID: "view-sess-1")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat

        check(!m.controller.debugNewButton.isEnabled,
              "\"New conversation\" is pointless on an empty thread", &ok)

        chat.debugType("what should I do first?")
        // The real click path: target/action, exactly as a mouse would.
        chat.debugSendButton.performClick(nil)

        check(chat.debugComposerText.isEmpty, "sending clears the composer", &ok)
        check(chat.debugEmptyStateHidden, "the empty state goes once there is a message", &ok)
        check(!chat.debugInputEnabled, "input is disabled while a turn is in flight", &ok)
        check(m.controller.debugTurnInFlight, "...and the controller knows a turn is running", &ok)
        // The status line is chrome, shown while `claude` runs.
        check(chat.debugMessageTexts().contains { $0.contains("thinking") },
              "a status line shows while the turn runs, got \(chat.debugMessageTexts())", &ok)

        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }

        let texts = chat.debugMessageTexts()
        check(texts.contains("what should I do first?"), "the captain's message stays in the transcript, got \(texts)", &ok)
        check(texts.contains("Aye - let's start with the login bug."), "the reply is rendered, got \(texts)", &ok)
        check(!texts.contains { $0.contains("thinking") },
              "the status line is replaced by the reply, not left above it, got \(texts)", &ok)
        check(chat.debugCrewSpeakers() == ["Luffy"],
              "the reply is attributed to Luffy, got \(chat.debugCrewSpeakers())", &ok)

        // The attribution has to read as one phrase. `.fill` distribution
        // stretches whichever view hugs least, and without a trailing spacer
        // that is the role label - which a real render showed pinned to the
        // far right of the card, ~1000pt from the name it belongs to.
        //
        // Measured as "neither label was stretched beyond its own text", NOT
        // as the gap between them: with `.fill` the *name* can be the view
        // that absorbs the slack, in which case the gap stays 0 while the
        // role text is still pushed a thousand points to the right. Checking
        // the gap was this suite's own first attempt and it passed against
        // the exact pre-fix code.
        m.controller.view.layoutSubtreeIfNeeded()
        if let block = chat.debugLastBlockView,
           let name = findLabel(in: block, text: "Luffy"),
           // From the roster, never a literal: Luffy's role read "Crew" in
           // phase 1, "Orchestrator" in phase 2, and a richer multi-segment
           // phrase ("General Assistant / Conversation") after the captain's
           // reference-image ask - a hardcoded word here fails for a reason
           // that has nothing to do with layout. The explicit `maxLength`
           // (default 30, calibrated against the old one-word roles) is what
           // the richer phrase needs - `findLabel`'s own header names this
           // exact situation as the reason that parameter exists.
           let role = findLabel(in: block, textContaining: StrawHatMember.luffy.role, maxLength: 60) {
            let nameSlack = name.frame.width - name.intrinsicContentSize.width
            let roleSlack = role.frame.width - role.intrinsicContentSize.width
            check(nameSlack < 20,
                  "the name label is not stretched by the row's slack - \(nameSlack)pt over its own text", &ok)
            check(roleSlack < 20,
                  "the role label is not stretched by the row's slack - \(roleSlack)pt over its own text", &ok)
            // ...and the attribution as a whole stays on the left of the card
            // rather than spanning it.
            let roleMaxX = block.convert(role.bounds, from: role).maxX
            check(roleMaxX < block.frame.width * 0.5,
                  "the attribution stays on the left of the card - role ends at \(roleMaxX) of \(block.frame.width)", &ok)
        } else {
            check(false, "could not find the reply block's name/role labels", &ok)
        }
        check(chat.debugInputEnabled, "input is re-enabled once the turn lands", &ok)
        check(m.controller.debugNewButton.isEnabled,
              "\"New conversation\" becomes available once there is a real exchange", &ok)

        // A second turn from the same page really resumes - the multi-turn
        // property, observed through the whole UI path rather than the
        // runner alone.
        chat.debugType("and after that?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        let argv = readArgv(log)
        let printable = printableArgv(log)
        check(argv.contains("--resume"),
              "the page's second turn resumes the conversation, got \(printable)", &ok)
        check(argv.contains("view-sess-1"), "...with the first turn's own session id, got \(printable)", &ok)
    }

    /// The reply is parsed as markdown, not rendered as one flat label - the
    /// whole reason `SRELeadMarkdown` is reused rather than reimplemented.
    private static func checkMarkdownRenders(_ ok: inout Bool) {
        let reply = """
        Here's the shape:

        - check `kubectl get pods`
        - then the **rollout** status

        ```
        kubectl rollout status deploy/api
        ```
        """
        let script = writeFakeClaude(reply: reply, argvLog: nil, sessionID: "md-1")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat
        chat.debugType("how do I check a rollout?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        m.controller.view.layoutSubtreeIfNeeded()

        // Asserted through the shared parser the view actually calls, so this
        // cannot pass while the view has quietly stopped using it.
        let blocks = SRELeadMarkdown.parse(reply)
        var sawList = false
        var sawCode = false
        for block in blocks {
            if case .bulletList = block { sawList = true }
            if case .codeBlock = block { sawCode = true }
        }
        check(sawList, "the reply's bullet list is parsed as a list", &ok)
        check(sawCode, "the reply's fenced block is parsed as code", &ok)

        // ...and the rendered block really has geometry, so a parse that
        // produced views nobody laid out would still fail here.
        let rendered = chat.subviews.first.map { deepestHeight(of: $0) } ?? 0
        check(rendered > 0, "the rendered transcript has real height", &ok)
        check(chat.debugCrewSpeakers() == ["Luffy"], "the markdown reply is still attributed", &ok)
    }

    private static func checkNewConversation(_ ok: inout Bool) {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-view-new-\(UUID().uuidString).log")
        let script = writeFakeClaude(reply: "Sure.", argvLog: log, sessionID: "new-sess")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat
        chat.debugType("first thread")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        check(chat.debugMessageCount >= 2, "a turn leaves the captain's message and the reply", &ok)

        m.controller.debugNewButton.performClick(nil)
        m.controller.view.layoutSubtreeIfNeeded()
        check(chat.debugMessageCount == 0, "\"New conversation\" clears the transcript", &ok)
        check(!chat.debugEmptyStateHidden, "...and brings the empty state back", &ok)
        check(!m.controller.debugNewButton.isEnabled, "...and disables itself again", &ok)

        // The next turn genuinely starts a new session rather than resuming
        // a thread the captain just discarded.
        chat.debugType("second thread")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        check(!readArgv(log).contains("--resume"),
              "the turn after \"New conversation\" starts fresh, got \(printableArgv(log))", &ok)
    }

    /// A failed turn has to be visible and recoverable - never a dead
    /// composer and never a silent no-op.
    private static func checkFailureIsShown(_ ok: inout Bool) {
        StrawHatCrew.claudePathOverrideForTests = "/nonexistent/claude-\(UUID().uuidString)"
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat
        chat.debugType("are you there?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }

        check(chat.debugCrewSpeakers().isEmpty, "a failed turn renders no crew reply", &ok)
        check(chat.debugMessageTexts().count >= 2, "the failure is rendered, got \(chat.debugMessageTexts())", &ok)
        check(chat.debugInputEnabled, "the composer is usable again after a failure", &ok)
        check(!chat.debugMessageTexts().contains { $0.contains("thinking") },
              "the status line is cleared on failure too", &ok)
    }

    /// Every full-window surface must force its own appearance, or system-
    /// semantic colours resolve against the OS's light/dark rather than the
    /// Helm theme. This page already did; the check is here because the Crew
    /// tab is new content inside it and a chat pane is mostly text.
    private static func checkThemeSweep(_ ok: inout Bool) {
        let saved = ThemeManager.shared.theme
        // `setTheme` writes through to the real `UserDefaults`, so the
        // captain's own selection is put back - a suite that leaves it
        // changed poisons every later suite in the same run (see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`).
        defer { ThemeManager.shared.setTheme(saved) }

        let script = writeFakeClaude(reply: "Aye.", argvLog: nil, sessionID: "theme-1")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat
        chat.debugType("hello")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }

        for id in ["daylight", "dusk", "helm-light", "helm-dark", "gruvbox-light"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else { continue }
            ThemeManager.shared.setTheme(theme)
            m.controller.view.layoutSubtreeIfNeeded()

            let expected: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
            let resolved = m.controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            check(resolved == expected,
                  "\(id): the page's appearance should be \(expected.rawValue), was \(resolved?.rawValue ?? "nil")", &ok)

            // A theme change rebuilds every transcript block from `messages`
            // (styling is a pure function of them) - so the transcript has to
            // survive it rather than being cleared.
            check(chat.debugCrewSpeakers() == ["Luffy"],
                  "\(id): the transcript survives a theme change, got \(chat.debugCrewSpeakers())", &ok)
            check(chat.debugMessageTexts().contains("Aye."),
                  "\(id): ...including the reply text", &ok)
            check(chat.frame.height > 200, "\(id): the chat still has real height", &ok)
        }
    }

    // MARK: Phase 2 - several voices in one reply

    /// The plan's own worked example, driven all the way through: one fake
    /// `claude` reply becomes two attributed blocks and two confirm cards.
    private static func checkMultiSectionReply(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat

        let envelope = """
        ```json
        { "sections": [
            { "speaker": "nami",
              "text": "I heard a task and a follow-up in there - drafted both:",
              "proposals": [
                { "kind": "add_task", "title": "Fix the login issue", "due": "2026-09-09" },
                { "kind": "add_follow_up", "title": "Ask Rahul about the Cognito config" } ] },
            { "speaker": "luffy",
              "text": "Both drafted - confirm to add.",
              "followup": "Want Robin to check for a Cognito runbook first?" }
        ] }
        ```
        """
        let script = writeFakeClaude(reply: envelope, argvLog: nil, sessionID: "sess-multi")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        // Through the real composer, so the whole turn cycle runs.
        chat.debugType("I need to fix the login issue tomorrow and ask Rahul about the Cognito configuration")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        guard !m.controller.debugTurnInFlight else {
            check(false, "the turn never completed - transcript is \(chat.debugMessageTexts())", &ok)
            return
        }

        // One captain message + two crew blocks. The status line is gone.
        check(chat.debugCrewSpeakers() == ["Nami", "Luffy"],
              "one reply renders as two attributed blocks, got \(chat.debugCrewSpeakers())", &ok)
        check(chat.debugMessageTexts().contains(where: { $0.contains("drafted both") }),
              "Nami's own words render", &ok)
        check(chat.debugMessageTexts().contains(where: { $0.contains("confirm to add") }),
              "and so do Luffy's", &ok)

        // M2.4: the strip lights exactly the two who spoke, and nobody else.
        let strip = chat.debugCrewStrip
        check(strip.debugLitMembers == [.nami, .luffy],
              "the strip lights exactly the crew who replied, got \(strip.debugLitMembers.map(\.rawValue).sorted())", &ok)
        check(strip.debugCaption.contains("Nami") && strip.debugCaption.contains("Luffy"),
              "...and names them, got \(strip.debugCaption)", &ok)
        for member in [StrawHatMember.chopper, .robin] {
            check(strip.debugTile(member)?.debugIsLit == false,
                  "\(member.displayName) did not speak and must stay dim", &ok)
        }

        // M2.2: two confirm cards, in the reply's own order, neither confirmed.
        let cards = chat.debugConfirmCards()
        check(cards.count == 2, "two proposals means two confirm cards, got \(cards.count)", &ok)
        check(cards.first?.debugProposal.kind == .addTask, "the task's card first", &ok)
        check(cards.last?.debugProposal.kind == .addFollowUp, "then the follow-up's", &ok)
        check(cards.allSatisfy { !$0.debugIsConfirmed },
              "a rendered card is not a confirmed one - nothing writes until a press", &ok)
        check(cards.allSatisfy { !$0.debugConfirmButtonHidden },
              "and each still offers its button", &ok)

        // The card's own three columns. Two successive attempts to express
        // "the text column takes the slack" through hugging priorities were
        // measured wrong on a real render (the action column resolved to 871pt
        // of a 998pt card, wrapping a one-line title over three lines and
        // truncating the detail beside a wide empty gap) - so this asserts the
        // resolved geometry rather than the priorities that were supposed to
        // produce it.
        m.controller.view.layoutSubtreeIfNeeded()
        for card in cards {
            let title = card.debugTitleLabel
            let slack = title.frame.width - title.intrinsicContentSize.width
            check(slack >= -0.5,
                  "a proposal title has room for its own text - short by \(-slack)pt [\(card.debugFrames)]", &ok)
            // ...and the action column is sized by its own control rather than
            // absorbing the row.
            check(card.debugActionColumnWidth < card.frame.width * 0.35,
                  "the action column hugs its button - \(card.debugActionColumnWidth)pt of \(card.frame.width)", &ok)
        }
    }

    /// The acceptance criterion, end to end: one message, two clicks, a task
    /// and a follow-up really in Shift.
    private static func checkAcceptanceScenario(_ ok: inout Bool) {
        // This case's own store, so what it writes is its own and a leftover
        // from an earlier case cannot make it pass.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-accept-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = ShiftStore()
        let m = mount(shiftStore: store)
        showCrew(m)
        let chat = m.controller.debugChat

        let envelope = """
        {"sections":[
          {"speaker":"nami","text":"Drafted both:","proposals":[
            {"kind":"add_task","title":"Fix the login issue","due":"tomorrow"},
            {"kind":"add_follow_up","title":"Ask Rahul about the Cognito configuration"}]},
          {"speaker":"luffy","text":"Confirm to add."}]}
        """
        let script = writeFakeClaude(reply: envelope, argvLog: nil, sessionID: "sess-accept")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        chat.debugType("I need to fix the login issue tomorrow and ask Rahul about the Cognito configuration")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugTurnInFlight }
        guard !m.controller.debugTurnInFlight else {
            check(false, "the acceptance turn never completed", &ok)
            return
        }

        // Nothing has been written yet - the cards are rendered, not pressed.
        check(store.activeTasks.isEmpty && store.followUps.isEmpty,
              "rendering the cards must write nothing at all", &ok)

        let cards = chat.debugConfirmCards()
        guard cards.count == 2 else {
            check(false, "expected two cards to press, got \(cards.count)", &ok)
            return
        }

        // Two real presses, through the real button's own target/action.
        for card in cards { card.debugConfirmButton.performClick(nil) }

        check(store.activeTasks.contains(where: { $0.title == "Fix the login issue" }),
              "the task landed in Shift, got \(store.activeTasks.map(\.title))", &ok)
        check(store.followUps.contains(where: { $0.title.contains("Rahul") }),
              "the follow-up landed in Shift, got \(store.followUps.map(\.title))", &ok)
        check(cards.allSatisfy { $0.debugIsConfirmed },
              "both cards show their confirmed state", &ok)
        check(cards.allSatisfy { $0.debugConfirmButtonHidden },
              "and the button is gone, so a second press cannot double-write", &ok)
        check(cards.first?.debugDoneText.contains("Added to Tasks") == true,
              "the confirmed card names where the record went, got \(cards.first?.debugDoneText ?? "")", &ok)
        // ...and it is not truncated. The action column used to be pinned to
        // the *button's* width on both edges, so the longer confirmed label
        // rendered as "\u{2713} Adde\u{2026}" - caught in a real off-screen
        // render, invisible to every other assertion here (the string is
        // correct; only its frame was too small).
        m.controller.view.layoutSubtreeIfNeeded()
        if let done = cards.first?.debugDoneLabel {
            let slack = done.frame.width - done.intrinsicContentSize.width
            check(slack >= -0.5,
                  "the confirmed label has room for its own text - short by \(-slack)pt [\(cards.first!.debugFrames)]", &ok)
        } else {
            check(false, "could not reach the confirmed label", &ok)
        }
        // The detail line still says what the record is, rather than being
        // overwritten with the toast's own wording (which threw away the due
        // date the card was showing).
        check(cards.first?.debugDetailText.contains("Tomorrow") == true,
              "a confirmed card keeps its detail, got \(cards.first?.debugDetailText ?? "")", &ok)

        // A second press on an already-confirmed card writes nothing more -
        // guarded as well as hidden, since a keyboard activation could reach it.
        let tasksAfter = store.activeTasks.count
        cards.first?.debugConfirmButton.performClick(nil)
        check(store.activeTasks.count == tasksAfter,
              "a re-press must not write a second copy, went \(tasksAfter) -> \(store.activeTasks.count)", &ok)

        // It really reached disk, not just the in-memory array.
        check(ShiftStore().activeTasks.contains(where: { $0.title == "Fix the login issue" }),
              "a confirmed task survives a fresh store", &ok)
    }

    /// Rung 2 and rung 3, through the real render path - neither is reachable
    /// from a well-behaved fake `claude`, so both are driven directly.
    private static func checkSalvageRendersButNeverExecutes(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-salvage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = ShiftStore()
        let m = mount(shiftStore: store)
        showCrew(m)
        let chat = m.controller.debugChat

        // Rung 2: a voice that is not aboard, carrying a proposal.
        //
        // **Brook**, who the plan gives no code at all - phase 2's fixture
        // used Zoro, who is aboard as of phase 3, so this was re-pointed at a
        // voice that is genuinely still absent rather than left asserting the
        // old roster (the same shape audit #2 section 4.5 found in
        // `SessionRestoreSelfTest`: an assertion that had quietly become a
        // record of the old behaviour).
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"brook","text":"I'd restart the pod.",
          "proposals":[{"kind":"run_kubectl","title":"rollout restart"}]}]}
        """)
        check(chat.debugCrewSpeakers() == ["-"],
              "an unaboard voice renders with no attribution, got \(chat.debugCrewSpeakers())", &ok)
        check(chat.debugMessageTexts().contains("I'd restart the pod."),
              "...but its text still renders - the reply is never dropped", &ok)
        check(chat.debugConfirmCards().isEmpty,
              "and it offers no card at all, got \(chat.debugConfirmCards().count)", &ok)
        // The refusal is stated rather than silent.
        guard let block = chat.debugLastBlockView,
              findLabel(in: block, textContaining: "couldn't be offered", maxLength: 300) != nil else {
            check(false, "a refused proposal must be stated in the block, not silently dropped", &ok)
            return
        }
        // The strip lights nobody: crediting a voice that is not aboard is
        // exactly the plausible-but-wrong this feature must never do.
        check(chat.debugCrewStrip.debugLitMembers.isEmpty,
              "an unattributed reply lights nobody, got \(chat.debugCrewStrip.debugLitMembers.map(\.rawValue))", &ok)

        // Rung 3: prose with a fenced block that is not an envelope. The
        // direction that matters - this must not be shredded into a fragment.
        chat.clearMessages()
        m.controller.debugRenderReply("""
        Your config needs a `logging` block:

        ```json
        { "level": "debug", "sections": 4 }
        ```

        Drop that in and restart.
        """)
        check(chat.debugCrewSpeakers() == ["Luffy"],
              "rung 3 renders as one Luffy block, got \(chat.debugCrewSpeakers())", &ok)
        let shown = chat.debugMessageTexts().joined()
        check(shown.contains("Drop that in and restart."),
              "the prose after the block survives - losing it would be silent data loss", &ok)
        check(shown.contains("\"level\": \"debug\""), "and so does the code the captain asked for", &ok)
        check(store.activeTasks.isEmpty && store.followUps.isEmpty,
              "neither rung wrote anything", &ok)
    }

    /// `fm/straw-hat-voice-order-composer-polish-8dd2`: the one case rung 3
    /// deliberately does NOT render as an ordinary Luffy message - a whole
    /// reply that reads as leaked tool-use narration
    /// (`StrawHatEnvelope.isLikelyToolNarration`), the captain's screenshot's
    /// exact fixture. Attributing an internal-reasoning fragment to a
    /// character speaking in character is precisely the immersion break this
    /// feature exists to avoid, so `StrawHatController.renderReply` renders a
    /// plain, unattributed note instead - still something (the ladder's own
    /// "the reply is never dropped" invariant), never Luffy's own words.
    ///
    /// The parser-level suppression (leading/trailing prose stitched around a
    /// real envelope) is pure logic and covered in `StrawHatSelfTest.
    /// checkToolNarrationSuppression` - this is the one half of the fix that
    /// needs a real rendered transcript to prove.
    private static func checkToolNarrationRendersNeutralNote(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat

        m.controller.debugRenderReply(
            "Context already says tasks_due_soon: 0, no need for a tool call.")

        check(chat.debugCrewSpeakers() == ["-"],
              "a leaked-narration reply must not be credited to Luffy, got \(chat.debugCrewSpeakers())", &ok)
        let shown = chat.debugMessageTexts().joined()
        check(!shown.contains("no need for a tool call"),
              "the raw leaked sentence must not reach the transcript verbatim, got: \(shown)", &ok)
        check(shown.contains("didn't come through cleanly"),
              "...a plain, honest note is shown instead - the reply is never dropped, got: \(shown)", &ok)
        check(m.controller.canvasState.lastSpeakers.isEmpty,
              "the Overview card credits nobody either, got \(m.controller.canvasState.lastSpeakers.map(\.rawValue))", &ok)

        // An ordinary rung-3 reply with none of the two narration signals
        // still renders normally, in Luffy's own voice - the fix must not
        // have widened into "every unparseable reply is suspect".
        m.controller.newConversationTapped()
        m.controller.debugRenderReply("Loguetown and Water Seven. Want the rest?")
        check(chat.debugCrewSpeakers() == ["Luffy"],
              "an ordinary prose reply still renders as Luffy, got \(chat.debugCrewSpeakers())", &ok)
    }

    /// M2.4's glow, and its Reduce Motion gate.
    private static func checkContributingGlow(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat
        let strip = chat.debugCrewStrip

        // Before anything is said: everyone aboard, nobody lit.
        check(strip.debugLitMembers.isEmpty, "an empty thread lights nobody", &ok)
        check(strip.debugCaption.contains("\(StrawHatMember.allCases.count) crew aboard"),
              "...and the strip says who is aboard, got \(strip.debugCaption)", &ok)

        // Portraits, not the fallback glyphs - M2.4's actual ask.
        for member in StrawHatMember.allCases {
            check(strip.debugTile(member)?.debugUsesPortrait == true,
                  "\(member.displayName)'s strip tile renders a portrait, not the fallback glyph", &ok)
        }

        // While a turn is in flight nobody is lit: the app does not know yet
        // who will answer, and lighting a guess is what this must never do.
        chat.append(.captain("anything broken?"))
        chat.append(.status("The crew is thinking\u{2026}"))
        check(strip.debugLitMembers.isEmpty,
              "a turn in flight lights nobody, got \(strip.debugLitMembers.map(\.rawValue))", &ok)

        chat.removeTrailingStatus()
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"chopper","text":"Schedules are failing."}]}
        """)
        check(strip.debugLitMembers == [.chopper],
              "the reply's own speaker lights, got \(strip.debugLitMembers.map(\.rawValue))", &ok)

        // The pulse is the motion half, and Reduce Motion gets the end state
        // instantly - never the same motion slower. A gate that is read and
        // then ignored is invisible from every other angle, which is why this
        // reads the animation off the layer.
        let wasReduced = HelmMotion.reducedOverrideForTests
        defer { HelmMotion.reducedOverrideForTests = wasReduced }

        HelmMotion.reducedOverrideForTests = false
        chat.applyTheme(ThemeManager.shared.theme)
        check(strip.debugTile(.chopper)?.debugIsPulsing == true,
              "a lit tile pulses with Reduce Motion off", &ok)

        HelmMotion.reducedOverrideForTests = true
        chat.applyTheme(ThemeManager.shared.theme)
        check(strip.debugTile(.chopper)?.debugIsPulsing == false,
              "Reduce Motion removes the pulse", &ok)
        check(strip.debugTile(.chopper)?.debugIsLit == true,
              "...but keeps the lit end state - the app's own rule", &ok)

        // A theme rebuild replays every message, so the strip has to land back
        // on the same state rather than clearing.
        check(strip.debugLitMembers == [.chopper],
              "a theme rebuild preserves who contributed, got \(strip.debugLitMembers.map(\.rawValue))", &ok)

        // A new conversation clears it.
        m.controller.newConversationTapped()
        check(strip.debugLitMembers.isEmpty, "a new conversation lights nobody again", &ok)
    }

    /// A rendered card holds no store; a press without a wired handler must
    /// report a real failure rather than silently doing nothing.
    private static func checkUnwiredCardFailsVisibly(_ ok: inout Bool) {
        let chat = StrawHatChatView()
        chat.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        chat.append(.crew(StrawHatSection(
            speaker: .nami, rawSpeaker: "nami", text: "Drafted:",
            proposals: [StrawHatProposal(kind: .addTask, title: "Orphaned")],
            droppedProposalCount: 0, followup: nil)))
        guard let card = chat.debugConfirmCards().first else {
            check(false, "a bare chat view still renders its card", &ok)
            return
        }
        card.debugConfirmButton.performClick(nil)
        check(!card.debugIsConfirmed, "an unwired press must not claim success", &ok)
        check(card.debugDetailText.lowercased().contains("isn't connected"),
              "...and says why, got \(card.debugDetailText)", &ok)
    }

    // MARK: Utilities

    // MARK: Phase 3 (M3.2) - the two handoffs render as links, not cards

    /// A navigation proposal must render as a link row and **never** as a
    /// confirm card, and the row must not stretch its own button.
    ///
    /// The card/link choice is the visible half of the write/handoff split:
    /// a confirm button in front of something that writes nothing would
    /// teach the captain that a confirm press sometimes means "this changes
    /// nothing", which is what makes every *other* confirm press worth less.
    private static func checkHandoffRendersAsALink(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        let chat = m.controller.debugChat

        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"zoro","text":"That needs a live session.","proposals":[
          {"kind":"open_sre_lead","host":"prod-bastion"},
          {"kind":"open_destination","destination":"logAnalyzer","notes":"paste the trace"}]}]}
        """)

        let rows = chat.debugHandoffRows()
        check(rows.count == 2, "both handoffs render as link rows, got \(rows.count)", &ok)
        check(chat.debugConfirmCards().isEmpty,
              "a handoff must never render as a confirm card, got \(chat.debugConfirmCards().count)", &ok)
        guard rows.count == 2 else { return }

        // Derived titles, so a link always says where it goes.
        check(rows[0].debugTitle.contains("prod-bastion"),
              "the SRE Lead link names the host, got \(rows[0].debugTitle)", &ok)
        check(rows[1].debugTitle.contains("Log Analyzer"),
              "the destination link names the page, got \(rows[1].debugTitle)", &ok)

        // The button keeps its own width. Two views with no intrinsic content
        // size in one row is the exact shape this codebase has measured wrong
        // three separate times (`ToolRowLayout`, `StrawHatConfirmCard`, the
        // Hosts list's Connect button at ~900pt) - so this is measured, not
        // reasoned about.
        m.controller.view.layoutSubtreeIfNeeded()
        for row in rows {
            check(row.debugButton.frame.width > 0,
                  "a handoff button must have a real width - \(row.debugFrames)", &ok)
            check(row.debugButton.frame.width < row.frame.width - 20,
                  "a handoff link must not stretch to the block's full width - \(row.debugFrames)", &ok)
        }

        // And a section that carries both a write and a handoff renders one
        // of each, in order - the split is per proposal, not per section.
        m.controller.newConversationTapped()
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"zoro","text":"Both:","proposals":[
          {"kind":"save_command_draft","title":"Tail it","command":"kubectl logs -f deploy/api"},
          {"kind":"open_destination","destination":"console"}]}]}
        """)
        check(chat.debugConfirmCards().count == 1 && chat.debugHandoffRows().count == 1,
              "one section can carry a card and a link at once, got \(chat.debugConfirmCards().count) cards / \(chat.debugHandoffRows().count) links", &ok)
    }

    /// Clicking a handoff must reach `onHandoff` and write nothing.
    ///
    /// Driven through the row's real button target/action, so a row that lost
    /// its wiring fails this rather than passing - and the write assertion is
    /// what makes "a link runs on a single click" defensible: if a handoff
    /// could reach a store, running it without a confirm card would be a
    /// model-triggered unconfirmed write.
    private static func checkHandoffWritesNothing(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-handoff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = ShiftStore()
        let m = mount(shiftStore: store)
        showCrew(m)
        let chat = m.controller.debugChat

        var destinations: [RailDestination] = []
        var hints: [String?] = []
        var sreHints: [String?] = []
        m.controller.onOpenDestination = { dest, hint in
            destinations.append(dest)
            hints.append(hint)
        }
        m.controller.onOpenSRELead = { hint in
            sreHints.append(hint)
            return nil
        }

        let tasksBefore = store.activeTasks.count
        let followUpsBefore = store.followUps.count

        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"usopp","text":"Draw it?","proposals":[
          {"kind":"open_destination","destination":"whiteboard","notes":"three boxes and an arrow"}]}]}
        """)
        guard let row = chat.debugHandoffRows().first else {
            check(false, "the handoff row must render before it can be clicked", &ok)
            return
        }
        // The real target/action, not `onActivate` directly.
        row.debugButton.performClick(nil)
        check(destinations == [.whiteboard],
              "clicking a destination link reaches the page it names, got \(destinations.map(\.rawValue))", &ok)
        check(hints == ["three boxes and an arrow"],
              "...carrying what the crew was talking about, got \(String(describing: hints))", &ok)
        check(row.debugNote.isEmpty,
              "a handoff that worked says nothing in place - the app moved, got \(row.debugNote)", &ok)

        // The SRE Lead half, through the same path.
        m.controller.newConversationTapped()
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"zoro","text":"Needs a session.","proposals":[
          {"kind":"open_sre_lead","host":"prod-bastion"}]}]}
        """)
        chat.debugHandoffRows().first?.debugButton.performClick(nil)
        check(sreHints == ["prod-bastion"],
              "clicking the SRE Lead link passes the host the captain named, got \(String(describing: sreHints))", &ok)

        // Nothing was written by either.
        check(store.activeTasks.count == tasksBefore && store.followUps.count == followUpsBefore,
              "a handoff must write nothing - that is what lets it run with no confirm card", &ok)

        // A refusal is shown in place rather than looking like it worked.
        m.controller.onOpenSRELead = { _ in "You don't have a live host session right now." }
        m.controller.newConversationTapped()
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"zoro","text":"x","proposals":[{"kind":"open_sre_lead"}]}]}
        """)
        guard let refusing = chat.debugHandoffRows().first else {
            check(false, "the refusing handoff row must render", &ok)
            return
        }
        refusing.debugButton.performClick(nil)
        check(refusing.debugNote.contains("live host session"),
              "a handoff that could not be followed says why, got \(refusing.debugNote)", &ok)
    }

    // MARK: Phase 3 (M3.3) - "Ask your crew" on the dashboard

    /// The quick-ask card stays on the **fleet dashboard**, and one press
    /// starts a new conversation on the crew's own page with the captain's
    /// message already sent.
    ///
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` split this across
    /// two controllers - the card is `FleetController`'s, the chat is
    /// `StrawHatController`'s - so this case wires the hop exactly as
    /// `AppShellController` does (`overview.onAskCrew` -> `show(.strawHat)` +
    /// `startNewConversation(with:)`) and asserts the real handoff rather
    /// than a tab switch.
    ///
    /// It deliberately survived that task even though the "Crew" tab did not,
    /// and the distinction is the point: the tab was a second place to *find
    /// the chat*, which is confusing; this is a compose-and-go field that
    /// lands on the one chat page, which is exactly the affordance a canvas
    /// card cannot be. Every assertion is about placement and routing.
    private static func checkQuickAskCard(_ ok: inout Bool) {
        let fleet = FleetController(shiftStore: ShiftStore())
        let fleetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        fleetWindow.contentViewController = fleet
        fleet.view.layoutSubtreeIfNeeded()

        guard let card = fleet.debugCrewQuickAsk else {
            check(false, "M3.3's quick-ask card must exist on the fleet dashboard", &ok)
            return
        }
        // The Overview tab is Fleet's default, so the card is on screen with
        // no navigation at all - which is the point.
        check(!card.isHidden && card.frame.width > 0,
              "...and be visible on the dashboard with no navigation, got \(card.frame)", &ok)
        check(card.isDescendant(of: fleet.view), "the card is part of the fleet page", &ok)

        // Nothing to send yet.
        check(!card.debugAskEnabled, "Ask starts disabled - there is nothing to ask", &ok)
        card.debugType("what needs my attention?")
        check(card.debugAskEnabled, "typing enables Ask", &ok)
        card.debugType("   ")
        check(!card.debugAskEnabled, "whitespace alone does not", &ok)

        // The row's own geometry: the field takes the slack, the button keeps
        // its width. Measured for the same reason the handoff row's is.
        card.debugType("a real question")
        fleet.view.layoutSubtreeIfNeeded()
        check(card.debugField.frame.width > card.debugAskButton.frame.width * 2,
              "the field takes the row's slack, not the button - \(card.debugFrames)", &ok)
        check(card.debugAskButton.frame.width > 0,
              "...and the button still has a real width - \(card.debugFrames)", &ok)

        // ---- the press: navigate, reset, send ----
        //
        // A fake `claude` so the turn is real end to end rather than stopping
        // at "a runner was built".
        let script = writeFakeClaude(reply: """
        {"sections":[{"speaker":"luffy","text":"Two things need you."}]}
        """, argvLog: nil, sessionID: nil)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        let m = mount()
        showCrew(m)

        // Seed a conversation on the crew page first, so "starts a NEW
        // conversation" is a real assertion rather than one about an already
        // empty thread.
        m.controller.debugRenderReply("""
        {"sections":[{"speaker":"nami","text":"an older turn nobody can see from the dashboard"}]}
        """)
        check(m.controller.debugChat.debugMessageCount > 0, "the seeded turn is there", &ok)

        // The shell's own wiring, verbatim.
        var navigated: [RailDestination] = []
        fleet.onAskCrew = { text in
            navigated.append(.strawHat)
            m.controller.startNewConversation(with: text)
        }

        card.debugType("what needs my attention?")
        card.debugPressAsk()

        check(navigated == [.strawHat],
              "pressing Ask navigates to the crew's own page - the reply is not visible on the dashboard, got \(navigated.map(\.rawValue))", &ok)
        check(card.debugText.isEmpty,
              "and clears the field, so it does not read as an unsent draft", &ok)

        let deadline = Date().addingTimeInterval(20)
        while m.controller.debugTurnInFlight && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let texts = m.controller.debugChat.debugMessageTexts()
        check(texts.contains("what needs my attention?"),
              "the captain's own message is in the transcript, got \(texts)", &ok)
        check(texts.contains("Two things need you."),
              "...and so is the reply, got \(texts)", &ok)
        // M3.3's "into a NEW conversation": the seeded turn is gone.
        check(!texts.contains(where: { $0.contains("older turn") }),
              "a quick ask starts a new conversation - the old thread must be cleared, got \(texts)", &ok)
    }

    private static func findLabel(in view: NSView, text: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        for sub in view.subviews { if let hit = findLabel(in: sub, text: text) { return hit } }
        return nil
    }

    private static func findLabel(in view: NSView, textContaining needle: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue.contains(needle),
           field.stringValue.count < 30 { return field }
        for sub in view.subviews { if let hit = findLabel(in: sub, textContaining: needle) { return hit } }
        return nil
    }

    /// The 30-character cap on the variant above exists so a search for a
    /// short word does not match a whole wrapped paragraph; a caller looking
    /// for a phrase *inside* a long note has to say so.
    private static func findLabel(in view: NSView, textContaining needle: String,
                                  maxLength: Int) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue.contains(needle),
           field.stringValue.count < maxLength { return field }
        for sub in view.subviews {
            if let hit = findLabel(in: sub, textContaining: needle, maxLength: maxLength) { return hit }
        }
        return nil
    }

    private static func deepestHeight(of view: NSView) -> CGFloat {
        max(view.frame.height, view.subviews.map { deepestHeight(of: $0) }.max() ?? 0)
    }

    /// Pumps the main run loop, never a semaphore: `ClaudeOneShot` completes
    /// via `DispatchQueue.main.async` and this suite runs before
    /// `NSApplication.run()`, so blocking would deadlock on the very block
    /// being waited for.
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func readArgv(_ log: URL) -> [String] {
        guard let raw = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        var parts = raw.components(separatedBy: "\0")
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// The same argv with the ~2.5KB persona collapsed to a marker. A failure
    /// message that dumps the whole persona buries the one thing it is trying
    /// to say - found the first time an injected regression was verified here.
    private static func printableArgv(_ log: URL) -> [String] {
        readArgv(log).map { $0 == StrawHatCrew.persona ? "<persona>" : $0 }
    }

    private static func writeFakeClaude(reply: String, argvLog: URL?, sessionID: String?) -> URL {
        var obj: [String: Any] = ["result": reply, "is_error": false]
        if let sessionID { obj["session_id"] = sessionID }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        let escaped = payload.replacingOccurrences(of: "'", with: "'\\''")
        var body = ""
        if let argvLog { body += "printf '%s\\0' \"$@\" > \"\(argvLog.path)\"\n" }
        body += "printf '%s\\n' '\(escaped)'\nexit 0\n"

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-strawhat-view-\(UUID().uuidString).sh")
        try? "#!/bin/sh\n\(body)".write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

#endif
