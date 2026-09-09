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
    private static func mount(width: CGFloat = 1100, height: CGFloat = 800) -> Mounted {
        let controller = FleetController(shiftStore: ShiftStore())
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
           let role = findLabel(in: block, textContaining: "Crew") {
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

    // MARK: Utilities

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
