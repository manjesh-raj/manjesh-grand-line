// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates phase 1, the rendering half.
//
// Separate from `StrawHatSelfTest` on purpose: that one is pure logic and
// runs in CI's blocking job, this one mounts a real `FleetController` in a
// real `NSWindow` and drives real `NSButton` target/action clicks, so it
// belongs in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list with its
// window-backed peers. `FleetReplyLayoutSelfTest` is the sibling this copies.
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
        checkTabExists(&ok)
        checkChatFillsTheTab(&ok)
        checkTurnRoundTrip(&ok)
        checkMarkdownRenders(&ok)
        checkNewConversation(&ok)
        checkFailureIsShown(&ok)
        checkMultiSectionReply(&ok)
        checkAcceptanceScenario(&ok)
        checkSalvageRendersButNeverExecutes(&ok)
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
        let controller: FleetController
        let window: NSWindow
    }

    /// A real `FleetController` in a real off-screen window, switched to the
    /// Crew tab through the same method a real pill click reaches.
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
        let controller = FleetController(shiftStore: shiftStore ?? ShiftStore(),
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

    private static func showCrew(_ m: Mounted) {
        m.controller.debugSelectTab("crew")
        m.controller.view.layoutSubtreeIfNeeded()
        // `updateCrewChatHeight` runs from `viewDidLayout`, which a manual
        // `layoutSubtreeIfNeeded` on a never-displayed window does not always
        // drive - so ask for it directly too. Idempotent (epsilon-guarded).
        m.controller.updateCrewChatHeight()
        m.controller.view.layoutSubtreeIfNeeded()
    }

    // MARK: Cases

    private static func checkTabExists(_ ok: inout Bool) {
        let m = mount()
        check(m.controller.debugTabIDs == ["overview", "log", "crew"],
              "Overview offers exactly Overview/Log/Crew, got \(m.controller.debugTabIDs)", &ok)
        // The captain's placement call: inside Overview, NOT a new rail
        // destination. A future task adding one should have to change this
        // line deliberately rather than by accident.
        check(!RailDestination.allCases.contains { $0.title.lowercased().contains("straw") },
              "phase 1 must not add a rail destination - the captain put this inside Overview", &ok)

        check(m.controller.debugActiveTabID == "overview", "Overview is still the default tab", &ok)
        check(m.controller.debugCrewTabHidden, "the Crew tab's content starts hidden", &ok)

        showCrew(m)
        check(!m.controller.debugCrewTabHidden, "selecting Crew shows its content", &ok)
        check(m.controller.debugActiveTabID == "crew", "...and it becomes the active tab", &ok)

        m.controller.debugSelectTab("overview")
        m.controller.view.layoutSubtreeIfNeeded()
        check(m.controller.debugCrewTabHidden, "switching away hides it again", &ok)
    }

    /// The Crew tab's chat has to fill the viewport, or it renders as a small
    /// box inside an otherwise-empty page and scrolls inside a scroll view -
    /// the exact defect the audit found on Log Analyzer's own work area.
    private static func checkChatFillsTheTab(_ ok: inout Bool) {
        let m = mount(width: 1100, height: 800)
        showCrew(m)

        let chat = m.controller.debugCrewChat
        check(chat.frame.width > 700,
              "the chat fills the page's content column, got width \(chat.frame.width)", &ok)
        check(chat.frame.height > 500,
              "the chat fills the remaining viewport height, got \(chat.frame.height)", &ok)
        check(m.controller.debugCrewChatHeight >= FleetController.crewChatMinHeight,
              "the derived height never drops below the floor", &ok)

        // A short window degrades to the floor rather than to something
        // unusable or negative.
        let short = mount(width: 900, height: 420)
        showCrew(short)
        check(short.controller.debugCrewChatHeight >= FleetController.crewChatMinHeight,
              "a short window clamps to the minimum height, got \(short.controller.debugCrewChatHeight)", &ok)

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
        let chat = m.controller.debugCrewChat

        check(!m.controller.debugCrewNewButton.isEnabled,
              "\"New conversation\" is pointless on an empty thread", &ok)

        chat.debugType("what should I do first?")
        // The real click path: target/action, exactly as a mouse would.
        chat.debugSendButton.performClick(nil)

        check(chat.debugComposerText.isEmpty, "sending clears the composer", &ok)
        check(chat.debugEmptyStateHidden, "the empty state goes once there is a message", &ok)
        check(!chat.debugInputEnabled, "input is disabled while a turn is in flight", &ok)
        check(m.controller.debugCrewTurnInFlight, "...and the controller knows a turn is running", &ok)
        // The status line is chrome, shown while `claude` runs.
        check(chat.debugMessageTexts().contains { $0.contains("thinking") },
              "a status line shows while the turn runs, got \(chat.debugMessageTexts())", &ok)

        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }

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
           // phase 1 and "Orchestrator" in phase 2, and a hardcoded word
           // here fails for a reason that has nothing to do with layout.
           let role = findLabel(in: block, textContaining: StrawHatMember.luffy.role) {
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
        check(m.controller.debugCrewNewButton.isEnabled,
              "\"New conversation\" becomes available once there is a real exchange", &ok)

        // A second turn from the same page really resumes - the multi-turn
        // property, observed through the whole UI path rather than the
        // runner alone.
        chat.debugType("and after that?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
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
        let chat = m.controller.debugCrewChat
        chat.debugType("how do I check a rollout?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
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
        let chat = m.controller.debugCrewChat
        chat.debugType("first thread")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
        check(chat.debugMessageCount >= 2, "a turn leaves the captain's message and the reply", &ok)

        m.controller.debugCrewNewButton.performClick(nil)
        m.controller.view.layoutSubtreeIfNeeded()
        check(chat.debugMessageCount == 0, "\"New conversation\" clears the transcript", &ok)
        check(!chat.debugEmptyStateHidden, "...and brings the empty state back", &ok)
        check(!m.controller.debugCrewNewButton.isEnabled, "...and disables itself again", &ok)

        // The next turn genuinely starts a new session rather than resuming
        // a thread the captain just discarded.
        chat.debugType("second thread")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
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
        let chat = m.controller.debugCrewChat
        chat.debugType("are you there?")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }

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
        let chat = m.controller.debugCrewChat
        chat.debugType("hello")
        chat.debugSendButton.performClick(nil)
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }

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
        let chat = m.controller.debugCrewChat

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
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
        guard !m.controller.debugCrewTurnInFlight else {
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
        let chat = m.controller.debugCrewChat

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
        waitUntil(timeout: 20) { !m.controller.debugCrewTurnInFlight }
        guard !m.controller.debugCrewTurnInFlight else {
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
        let chat = m.controller.debugCrewChat

        // Rung 2: a voice that is not aboard, carrying a proposal.
        //
        // **Brook**, who the plan gives no code at all - phase 2's fixture
        // used Zoro, who is aboard as of phase 3, so this was re-pointed at a
        // voice that is genuinely still absent rather than left asserting the
        // old roster (the same shape audit #2 section 4.5 found in
        // `SessionRestoreSelfTest`: an assertion that had quietly become a
        // record of the old behaviour).
        m.controller.debugRenderCrewReply("""
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
        m.controller.debugRenderCrewReply("""
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

    /// M2.4's glow, and its Reduce Motion gate.
    private static func checkContributingGlow(_ ok: inout Bool) {
        let m = mount()
        showCrew(m)
        let chat = m.controller.debugCrewChat
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
        m.controller.debugRenderCrewReply("""
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
        m.controller.newCrewConversationTapped()
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
        let chat = m.controller.debugCrewChat

        m.controller.debugRenderCrewReply("""
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
        m.controller.newCrewConversationTapped()
        m.controller.debugRenderCrewReply("""
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
        let chat = m.controller.debugCrewChat

        var destinations: [RailDestination] = []
        var hints: [String?] = []
        var sreHints: [String?] = []
        m.controller.onOpenCrewDestination = { dest, hint in
            destinations.append(dest)
            hints.append(hint)
        }
        m.controller.onOpenSRELead = { hint in
            sreHints.append(hint)
            return nil
        }

        let tasksBefore = store.activeTasks.count
        let followUpsBefore = store.followUps.count

        m.controller.debugRenderCrewReply("""
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
        m.controller.newCrewConversationTapped()
        m.controller.debugRenderCrewReply("""
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
        m.controller.newCrewConversationTapped()
        m.controller.debugRenderCrewReply("""
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

    /// The quick-ask card is on the **Overview** tab, and one press starts a
    /// new conversation on the Crew tab with the captain's message already
    /// sent.
    ///
    /// Every assertion here is about the *placement and the routing*, because
    /// that is the whole milestone: the field is one tab away from where the
    /// friction was, and the message has to arrive in a conversation the
    /// captain can then see.
    private static func checkQuickAskCard(_ ok: inout Bool) {
        let m = mount()
        // Overview is the default tab, so the card is on screen with no tab
        // switch at all - which is the point.
        m.controller.view.layoutSubtreeIfNeeded()
        guard let card = m.controller.debugCrewQuickAsk else {
            check(false, "M3.3's quick-ask card must exist on the Overview tab", &ok)
            return
        }
        check(!card.isHidden && card.frame.width > 0,
              "...and be visible on the dashboard without switching tabs, got \(card.frame)", &ok)
        // Not on the Crew tab, which already has the full composer - a second
        // one there would be the duplication M3.3 is not.
        check(card.isDescendant(of: m.controller.view),
              "the card is part of this page", &ok)
        check(!card.isDescendant(of: m.controller.debugCrewChat),
              "the quick-ask card must not be inside the chat pane it is an alternative to", &ok)

        // Nothing to send yet.
        check(!card.debugAskEnabled, "Ask starts disabled - there is nothing to ask", &ok)
        card.debugType("what needs my attention?")
        check(card.debugAskEnabled, "typing enables Ask", &ok)
        card.debugType("   ")
        check(!card.debugAskEnabled, "whitespace alone does not", &ok)

        // The row's own geometry: the field takes the slack, the button keeps
        // its width. Measured for the same reason the handoff row's is.
        card.debugType("a real question")
        m.controller.view.layoutSubtreeIfNeeded()
        check(card.debugField.frame.width > card.debugAskButton.frame.width * 2,
              "the field takes the row's slack, not the button - \(card.debugFrames)", &ok)
        check(card.debugAskButton.frame.width > 0,
              "...and the button still has a real width - \(card.debugFrames)", &ok)

        // ---- the press: switch, reset, send ----
        //
        // A fake `claude` so the turn is real end to end rather than stopping
        // at "a runner was built".
        let script = writeFakeClaude(reply: """
        {"sections":[{"speaker":"luffy","text":"Two things need you."}]}
        """, argvLog: nil, sessionID: nil)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        // Seed a conversation on the Crew tab first, so "starts a NEW
        // conversation" is a real assertion rather than one about an already
        // empty thread.
        showCrew(m)
        m.controller.debugRenderCrewReply("""
        {"sections":[{"speaker":"nami","text":"an older turn nobody can see from Overview"}]}
        """)
        check(m.controller.debugCrewChat.debugMessageCount > 0, "the seeded turn is there", &ok)
        m.controller.debugSelectTab("overview")

        card.debugType("what needs my attention?")
        card.debugPressAsk()

        check(m.controller.debugCrewTabHidden == false,
              "pressing Ask takes the captain to the Crew tab - the reply is not visible on Overview", &ok)
        check(card.debugText.isEmpty,
              "and clears the field, so it does not read as an unsent draft", &ok)

        let deadline = Date().addingTimeInterval(20)
        while m.controller.debugCrewTurnInFlight && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let texts = m.controller.debugCrewChat.debugMessageTexts()
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
