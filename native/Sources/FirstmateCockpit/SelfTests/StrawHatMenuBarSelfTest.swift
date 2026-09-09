// Manjesh Grand Line - native macOS app.
//
// Coverage for `fm/straw-hat-menubar-quick-chat-popover`'s two new UI
// surfaces: the crew's menu-bar quick-chat popover
// (`StrawHatMenuBarController`/`StrawHatMenuBarPopoverController`) and the
// static crew roster reference sheet (`StrawHatRosterController`).
//
// Mounts real views and drives real button target/action clicks, so this
// belongs in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list with its
// window-backed peers (`StrawHatViewSelfTest` is the sibling this copies the
// harness conventions from). Separate from that file rather than folded into
// it, because this one's subject is a status-bar popover and a standalone
// sheet - genuinely different mounting concerns from a full-page destination.
//
// ## What this deliberately does NOT do
//
// `NSPopover.show(relativeTo:of:preferredEdge:)` raises
// `NSInvalidArgumentException` ("view has no window") when its anchor view
// has none - `StrawHatHandoffSelfTest`'s own documented finding for the
// identical AppKit call, one popover over. A headless self-test process never
// calls `NSApp.run()`, so a real `NSStatusItem`'s button cannot be trusted to
// have a window in every environment this runs in. So this suite never calls
// the unlocked click-to-open path - it drives `StrawHatMenuBarPopoverController`
// (the popover's *content*) directly, which needs no `.show()` at all, and
// only exercises `StrawHatMenuBarController.debugIconClicked()` from the
// LOCKED state, where `iconClicked()` returns before ever reaching `.show()`
// regardless of whether a real button exists. The actual security property -
// "the popover may not open while locked" - is proven both ways: through that
// safe click path, and directly against `AppLockGate.shared.allows(
// .strawHatMenuBarPopover)`, which is the same boolean `iconClicked()` reads.
//
// Nothing here reaches the captain's real data or the real menu bar for more
// than the length of this process.
//
// Run: `FM_RUN_STRAW_HAT_MENUBAR_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only - see `Phase3PolishSelfTest`.
#if FM_SELFTESTS

import AppKit

enum StrawHatMenuBarSelfTest {

    static func run() -> Bool {
        var ok = true

        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        _ = NSApplication.shared

        checkLockGate(&ok)
        checkIdleState(&ok)
        checkTypingEnablesAsk(&ok)
        checkAskFlowSuccess(&ok)
        checkAskFlowFailure(&ok)
        checkAskFlowUnattributedReply(&ok)
        checkMultiSectionSummaryAndProposalNote(&ok)
        checkPopoverNeverOffersAConfirmControl(&ok)
        checkPortraitOnlyForAKnownSpeaker(&ok)
        checkThinkingDisablesInputAndSubmit(&ok)
        checkThemeApplies(&ok)
        checkControllerWiring(&ok)
        checkIconResizedWithoutMutatingSharedAsset(&ok)
        checkIconClickedRefusesWhileLocked(&ok)

        checkRosterSheetContent(&ok)
        checkRosterCloseIsSafeWithNoPresenter(&ok)
        checkRosterOpensFromTheRealPage(&ok)

        print(ok ? "StrawHatMenuBarSelfTest: all checks passed" : "StrawHatMenuBarSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }

    // MARK: Harness - the popover content, standalone

    /// A real `StrawHatMenuBarPopoverController`, view loaded, with no
    /// `NSStatusItem`/`NSPopover` involved at all - see this file's header.
    private static func mountContent() -> StrawHatMenuBarPopoverController {
        let content = StrawHatMenuBarPopoverController()
        _ = content.view // forces loadView(), exactly as embedding it would
        content.view.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: Cases - the lock gate

    /// The security property `StrawHatMenuBarController.iconClicked()` reads,
    /// asserted directly (this is the case whose regression would look like a
    /// previous reply still on screen after the lock engaged).
    private static func checkLockGate(_ ok: inout Bool) {
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }

        AppLockGate.shared.setLocked(false)
        check(AppLockGate.shared.allows(.strawHatMenuBarPopover),
              "the popover may open while the app is unlocked", &ok)

        AppLockGate.shared.setLocked(true)
        check(!AppLockGate.shared.allows(.strawHatMenuBarPopover),
              "the popover must refuse to open while locked (GL-09)", &ok)
    }

    // MARK: Cases - the popover content

    private static func checkIdleState(_ ok: inout Bool) {
        let content = mountContent()
        check(content.debugHintVisible, "a fresh popover shows the idle hint", &ok)
        check(!content.debugThinkingVisible, "...not the thinking row", &ok)
        check(!content.debugReplyVisible, "...not the reply area", &ok)
        check(!content.debugErrorVisible, "...not the error label", &ok)
        check(!content.debugAskEnabled, "Ask starts disabled with nothing typed", &ok)
        check(content.debugField.isEnabled, "the field itself is usable while idle", &ok)
    }

    private static func checkTypingEnablesAsk(_ ok: inout Bool) {
        let content = mountContent()
        content.debugType("what's due today?")
        check(content.debugAskEnabled, "typing real text enables Ask", &ok)
        content.debugType("   ")
        check(!content.debugAskEnabled, "whitespace alone does not", &ok)
        content.debugType("")
        check(!content.debugAskEnabled, "...and neither does clearing it", &ok)
    }

    /// One full round trip through the real submit path: type, click the
    /// real Ask button, and land on the reply state with the crew's own
    /// portrait + name, exactly as the real chat page attributes a reply.
    private static func checkAskFlowSuccess(_ ok: inout Bool) {
        let content = mountContent()
        var asked: [String] = []
        content.onAsk = { text, completion in
            asked.append(text)
            let section = StrawHatSection(speaker: .nami, rawSpeaker: "nami",
                                          text: "Two tasks are due today.",
                                          proposals: [], droppedProposalCount: 0, followup: nil)
            completion(.success([section]))
        }

        content.debugType("what's on my plate?")
        // Through the real button's own target/action, exactly as a mouse
        // click would reach it.
        content.debugPressAsk()

        check(asked == ["what's on my plate?"],
              "the real Ask button reaches onAsk with the typed text, got \(asked)", &ok)
        check(content.debugStateDescription == "reply",
              "a successful ask lands on the reply state, got \(content.debugStateDescription)", &ok)
        check(content.debugReplyVisible && !content.debugHintVisible && !content.debugThinkingVisible
                && !content.debugErrorVisible,
              "...and only the reply area is showing", &ok)
        check(content.debugReplyName == "Nami",
              "the reply is attributed to who actually spoke, got \(content.debugReplyName)", &ok)
        check(content.debugReplyText == "Two tasks are due today.",
              "...with the reply's own text, got \(content.debugReplyText)", &ok)
        check(content.debugReplyPortraitVisible,
              "a known speaker renders a portrait, matching the real chat's attribution", &ok)
        check(!content.debugReplyMoreVisible, "one section means no \"+N more\" note", &ok)
        check(!content.debugProposalNoteVisible, "no proposals means no proposal note", &ok)
        check(content.debugField.isEnabled && content.debugField.stringValue.isEmpty,
              "the field is cleared and usable again after the turn lands", &ok)
    }

    private static func checkAskFlowFailure(_ ok: inout Bool) {
        let content = mountContent()
        content.onAsk = { _, completion in
            completion(.failure(StrawHatError(message: "The crew is already answering something else - try again in a moment.")))
        }
        content.debugType("are you there?")
        content.debugPressAsk()

        check(content.debugStateDescription == "failed",
              "a refused/failed ask renders the failed state, got \(content.debugStateDescription)", &ok)
        check(content.debugErrorVisible && !content.debugReplyVisible,
              "...showing only the error label", &ok)
        check(content.debugErrorText.contains("already answering"),
              "the real failure message is shown verbatim, got \(content.debugErrorText)", &ok)
        check(content.debugField.isEnabled, "the field is usable again after a failure", &ok)
    }

    /// Rung 2, through this popover: a voice not on the roster still renders
    /// its text - the reply is never dropped - but is credited to nobody,
    /// never silently attributed to whichever member happened to be asked.
    private static func checkAskFlowUnattributedReply(_ ok: inout Bool) {
        let content = mountContent()
        content.onAsk = { _, completion in
            let section = StrawHatSection(speaker: nil, rawSpeaker: "sanji",
                                          text: "Dinner is ready.",
                                          proposals: [], droppedProposalCount: 0, followup: nil)
            completion(.success([section]))
        }
        content.debugType("anything for dinner?")
        content.debugPressAsk()

        check(content.debugReplyName == "The crew",
              "an unaboard speaker is credited to no one member, got \(content.debugReplyName)", &ok)
        check(content.debugReplyText == "Dinner is ready.",
              "...but the text still renders, got \(content.debugReplyText)", &ok)
        check(!content.debugReplyPortraitVisible,
              "and no portrait is shown for a voice that is not on the roster", &ok)
    }

    /// Only the first section with a speaker is shown, plus a compact "+N
    /// more" note - and every proposal across the WHOLE reply is summarised,
    /// not just the ones on the section actually shown.
    private static func checkMultiSectionSummaryAndProposalNote(_ ok: inout Bool) {
        let content = mountContent()
        content.onAsk = { _, completion in
            let nami = StrawHatSection(speaker: .nami, rawSpeaker: "nami",
                                       text: "I drafted two things:",
                                       proposals: [StrawHatProposal(kind: .addTask, title: "Fix the login issue"),
                                                   StrawHatProposal(kind: .addFollowUp, title: "Ask Rahul")],
                                       droppedProposalCount: 0, followup: nil)
            let luffy = StrawHatSection(speaker: .luffy, rawSpeaker: "luffy",
                                        text: "Confirm to add.",
                                        proposals: [], droppedProposalCount: 0, followup: nil)
            completion(.success([nami, luffy]))
        }
        content.debugType("what needs doing?")
        content.debugPressAsk()

        check(content.debugReplyName == "Nami",
              "the first section with a speaker is the one shown, got \(content.debugReplyName)", &ok)
        check(content.debugReplyMoreVisible, "a two-section reply notes there is more", &ok)
        check(content.debugReplyMoreText.contains("1"),
              "...counting the section not shown, got \(content.debugReplyMoreText)", &ok)

        check(content.debugProposalNoteVisible, "two proposals means the note shows", &ok)
        check(content.debugProposalNoteText.contains("2 drafts"),
              "the note counts every proposal in the WHOLE reply, not just the shown section, got \(content.debugProposalNoteText)", &ok)
        check(content.debugProposalNoteText.lowercased().contains("nothing is written yet"),
              "...and states nothing has been written, got \(content.debugProposalNoteText)", &ok)
        check(content.debugProposalNoteText.lowercased().contains("confirm on the full page"),
              "...pointing at the real page as the way to act on it, got \(content.debugProposalNoteText)", &ok)
    }

    /// The task's own hard requirement, made structural rather than left to
    /// the note text alone: this popover offers no confirm control anywhere,
    /// under any state - so there is no button here that could ever write a
    /// proposal without the captain opening the real page first.
    private static func checkPopoverNeverOffersAConfirmControl(_ ok: inout Bool) {
        let content = mountContent()
        content.onAsk = { _, completion in
            let section = StrawHatSection(speaker: .zoro, rawSpeaker: "zoro",
                                          text: "Drafted a command.",
                                          proposals: [StrawHatProposal(kind: .saveCommandDraft, title: "Tail it",
                                                                       command: "kubectl logs -f deploy/api")],
                                          droppedProposalCount: 0, followup: nil)
            completion(.success([section]))
        }
        content.debugType("tail the api logs")
        content.debugPressAsk()
        content.view.layoutSubtreeIfNeeded()

        let buttons = allButtons(in: content.view)
        // Exactly the two controls this popover ever built: Ask and "Open
        // Straw Hat Pirates". A confirm button appearing here - however it
        // got there - would show up as a third.
        check(buttons.count == 2,
              "the popover offers exactly Ask and Open Full Chat, no matter the state - found \(buttons.count) buttons", &ok)
        check(buttons.contains(where: { $0 === content.debugAskButton }),
              "Ask itself is one of them", &ok)
        check(buttons.contains(where: { $0 === content.debugOpenFullChatButton }),
              "and Open Full Chat is the other", &ok)
    }

    private static func checkPortraitOnlyForAKnownSpeaker(_ ok: inout Bool) {
        let content = mountContent()
        content.onAsk = { _, completion in
            let section = StrawHatSection(speaker: .robin, rawSpeaker: "robin",
                                          text: "The runbook's already there.",
                                          proposals: [], droppedProposalCount: 0, followup: nil)
            completion(.success([section]))
        }
        content.debugType("is there a runbook?")
        content.debugPressAsk()
        check(content.debugReplyPortraitVisible, "Robin's portrait renders", &ok)
        check(content.debugReplyName == "Robin", "attributed to Robin, got \(content.debugReplyName)", &ok)
    }

    /// While a turn is in flight, both the field and the button are
    /// disabled, and a second submit (a stray Return, a double-click) must
    /// not fire a second `onAsk`.
    private static func checkThinkingDisablesInputAndSubmit(_ ok: inout Bool) {
        let content = mountContent()
        var askCount = 0
        var pendingCompletion: ((Result<[StrawHatSection], StrawHatError>) -> Void)?
        content.onAsk = { _, completion in
            askCount += 1
            pendingCompletion = completion // never call it - stay "thinking"
        }
        content.debugType("hold on")
        content.debugPressAsk()

        check(content.debugStateDescription == "thinking",
              "the popover enters the thinking state once onAsk is called, got \(content.debugStateDescription)", &ok)
        check(content.debugThinkingVisible && !content.debugHintVisible
                && !content.debugReplyVisible && !content.debugErrorVisible,
              "...showing only the thinking row", &ok)
        check(!content.debugField.isEnabled, "the field is disabled while a turn is in flight", &ok)
        check(!content.debugAskEnabled, "and so is Ask", &ok)

        // A stray press while disabled must not reach onAsk a second time.
        content.debugPressAsk()
        check(askCount == 1, "a second press while thinking must not fire a second ask, got \(askCount) calls", &ok)

        // Resolve the pending turn so nothing leaks into a later case.
        pendingCompletion?(.success([StrawHatSection(speaker: .luffy, rawSpeaker: "luffy", text: "done",
                                                     proposals: [], droppedProposalCount: 0, followup: nil)]))
        check(content.debugStateDescription == "reply", "the pending turn still lands once resolved", &ok)
    }

    /// Every full-window/popover surface must force its own appearance - the
    /// half-themed class this app has shipped three times before. Applied
    /// directly (`content.applyTheme(_:)`), never through
    /// `ThemeManager.shared.setTheme`, which writes through to the real
    /// `UserDefaults` and would poison every later suite in the same run if
    /// left unrestored (`AppShellBodyWidthSelfTest.withScratchEnv`'s own
    /// documented hazard).
    private static func checkThemeApplies(_ ok: inout Bool) {
        let content = mountContent()
        for id in ["daylight", "helm-light", "helm-dark", "gruvbox-light"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else { continue }
            content.applyTheme(theme)
            let expected = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            let resolved = content.view.layer?.backgroundColor
            check(resolved == expected,
                  "\(id): the popover's own background follows the theme it was given", &ok)
        }
    }

    // MARK: Cases - the controller (icon + popover wiring)

    /// The forwarding wiring `StrawHatMenuBarController.init` sets up -
    /// `content.onAsk`/`content.onOpenFullChat` calling back into the
    /// controller's own public `onAsk`/`onOpenFullChat` - invoked directly
    /// rather than through a real click, so no `.show()` is ever reached.
    private static func checkControllerWiring(_ ok: inout Bool) {
        let menuBar = StrawHatMenuBarController()
        check(menuBar.debugPopover.contentViewController === menuBar.debugContent,
              "the controller's popover holds its own content controller", &ok)

        var forwardedAsk: String?
        var forwardedResult: Result<[StrawHatSection], StrawHatError>?
        menuBar.onAsk = { text, completion in
            forwardedAsk = text
            completion(.success([StrawHatSection(speaker: .luffy, rawSpeaker: "luffy", text: "aye",
                                                 proposals: [], droppedProposalCount: 0, followup: nil)]))
        }
        // Simulating what the content's own Ask button reaches internally -
        // `content.onAsk` itself, the closure `init` assigned.
        menuBar.debugContent.onAsk?("a question") { result in forwardedResult = result }
        check(forwardedAsk == "a question",
              "the controller's onAsk is reached from the content's own closure, got \(String(describing: forwardedAsk))", &ok)
        check({ if case .success = forwardedResult { return true }; return false }(),
              "...and the completion round-trips back out", &ok)

        var openedFullChat = false
        menuBar.onOpenFullChat = { openedFullChat = true }
        menuBar.debugContent.onOpenFullChat?()
        check(openedFullChat, "the controller's onOpenFullChat is reached from the content's own closure", &ok)
        // `performClose` on a popover that was never shown is a documented
        // no-op, unlike `.show()` - safe to let run as part of this wiring.
    }

    /// `StrawHatFlag.image` is a cached singleton shared with the Overview
    /// card's own tile - resizing it in place for the status item would
    /// silently rescale it everywhere else that reads the cache. The whole
    /// reason `statusItemIcon()` copies first.
    private static func checkIconResizedWithoutMutatingSharedAsset(_ ok: inout Bool) {
        guard let before = StrawHatFlag.image?.size else {
            check(false, "the Jolly Roger must decode before this check means anything", &ok)
            return
        }
        check(before.width == StrawHatFlag.side && before.height == StrawHatFlag.side,
              "the shared asset starts at its real size, got \(before)", &ok)

        _ = StrawHatMenuBarController() // builds the status item icon in init

        let after = StrawHatFlag.image?.size
        check(after?.width == StrawHatFlag.side && after?.height == StrawHatFlag.side,
              "building the status-item icon must not mutate the shared asset's own size, was \(before), now \(String(describing: after))", &ok)
    }

    /// Only ever driven from the locked state - see this file's header for
    /// why the unlocked branch is never exercised here.
    private static func checkIconClickedRefusesWhileLocked(_ ok: inout Bool) {
        let menuBar = StrawHatMenuBarController()
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }

        AppLockGate.shared.setLocked(true)
        menuBar.debugIconClicked()
        check(!menuBar.debugPopover.isShown,
              "the popover must not be showing after a click while locked", &ok)

        if !menuBar.debugHasStatusButton {
            print("  NOTE: this process has no real status-item button - the click path's own "
                + "\"guard let button\" line returns before ever reaching AppLockGate here, so "
                + "this case's own assertion holds either way but does not, on its own, prove the "
                + "gate fired. checkLockGate() above proves the gate itself directly.")
        }
    }

    // MARK: Cases - the roster sheet

    /// The captain's own hard requirements: a real portrait per card (not a
    /// placeholder), and `member.role` reused verbatim - never invented copy.
    private static func checkRosterSheetContent(_ ok: inout Bool) {
        let roster = StrawHatRosterController()
        _ = roster.view
        roster.view.layoutSubtreeIfNeeded()

        check(roster.debugTitle == "Crew Roster", "the sheet is titled for what it is, got \(roster.debugTitle)", &ok)
        check(roster.debugSubtitle.contains("Luffy"),
              "the subtitle states the shape of the tree, got \(roster.debugSubtitle)", &ok)

        let cards = roster.debugCards
        check(cards.count == StrawHatMember.allCases.count,
              "every crew member has a card, got \(cards.count) of \(StrawHatMember.allCases.count)", &ok)
        check(cards.first?.member == .luffy, "Luffy is the root card, got \(String(describing: cards.first?.member))", &ok)
        for (member, name, role) in cards {
            check(name == member.displayName,
                  "\(member.rawValue)'s card names them, got \(name)", &ok)
            check(role == member.role,
                  "\(member.rawValue)'s card reuses StrawHatMember.role verbatim, got \(role) vs \(member.role)", &ok)
        }

        // A tree needs real connectors: a trunk (Luffy -> the bus), a bus
        // (spanning the row), and one drop per branch card - the six
        // non-Luffy members.
        let branchCount = StrawHatMember.allCases.count - 1
        check(roster.debugConnectorCount == branchCount + 2,
              "trunk + bus + one drop per branch, got \(roster.debugConnectorCount) for \(branchCount) branches", &ok)

        // Real geometry, not zero-sized placeholders - a laid-out card has to
        // actually occupy space for the "at-a-glance diagram" ask to hold.
        let anyPortrait = findImageView(in: roster.view)
        check(anyPortrait?.frame.width ?? 0 > 0,
              "a card's portrait has real width once laid out", &ok)
    }

    /// `dismiss(_:)` raises rather than no-opping when nothing presented the
    /// controller (AGENTS.md gotcha 6) - a bare `StrawHatRosterController()`
    /// with no `presentAsSheet` behind it is exactly that state, and Close
    /// has to survive it.
    private static func checkRosterCloseIsSafeWithNoPresenter(_ ok: inout Bool) {
        let roster = StrawHatRosterController()
        _ = roster.view
        roster.debugCloseClicked()
        check(roster.debugCloseRequests == 1, "the close path itself still runs", &ok)
        // No crash reaching this line is the actual assertion.
    }

    /// The real page's own entry point: the roster button is on the drill
    /// header's action cluster, and pressing it opens a real
    /// `StrawHatRosterController` carrying the same content the standalone
    /// case above checks.
    private static func checkRosterOpensFromTheRealPage(_ ok: inout Bool) {
        let controller = StrawHatController(shiftStore: ShiftStore(),
                                            commandLibraryRoot: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("fm-straw-hat-menubar-roster", isDirectory: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        check(controller.drillHeaderActions.contains(where: { $0 === controller.debugRosterButton }),
              "the roster button is part of the page's own drill header actions", &ok)
        check(controller.debugLastRoutedRoster == nil, "nothing has been opened yet", &ok)

        // Through the real button's own target/action.
        controller.debugRosterButton.performClick(nil)

        guard let roster = controller.debugLastRoutedRoster else {
            check(false, "pressing the roster button must route to a real StrawHatRosterController", &ok)
            return
        }
        _ = roster.view
        check(roster.debugCards.count == StrawHatMember.allCases.count,
              "the sheet opened from the real page carries the full roster too", &ok)
    }

    // MARK: Utilities

    private static func allButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found.append(contentsOf: allButtons(in: sub)) }
        return found
    }

    private static func findImageView(in view: NSView) -> NSImageView? {
        if let iv = view as? NSImageView { return iv }
        for sub in view.subviews { if let hit = findImageView(in: sub) { return hit } }
        return nil
    }
}

#endif
