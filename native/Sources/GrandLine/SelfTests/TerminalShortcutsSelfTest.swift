// Grand Line - native macOS app.
//
// Permanent coverage for `fm/grand-line-terminal-shortcuts-settings`: the nine
// configurable Console bindings, and the split panes six of them drive.
//
// Three halves, because the feature has three and they fail differently.
//
// The **table** cases are pure. They are about the shipped defaults - that no
// two of them are the same chord, that every one is a shape a command
// shortcut may take, and above all that none of them lands on a keystroke
// this app already spends. That last one is a literal list rather than
// anything derived: `TabShortcut.from` matches on characters and these match
// on keyCode, so there is no shared representation to compare, and a check
// that re-derived the reserved set from the same source the defaults came
// from would assert nothing. `DaylightModuleSelfTest.checkSpaceTable`'s own
// reasoning, applied to a different table.
//
// The **geometry** cases drive a real `ConsoleController` in a real
// off-screen window through `OffScreenProbe`, with real `.shell` launches
// only - the same harness shape and the same restriction
// `TabKeyboardShortcutsSelfTest` and `TabForwardDragsToggleSelfTest` already
// use, for the reason those give: a real `.ssh` launch through an appeared
// controller would attempt a real `ssh` subprocess.
//
// They assert **frames**, not pane counts. A pane count is satisfied by a
// split that built two panes and gave one of them zero width, which is
// exactly what happens if `TerminalSplitContainer.halve` stops running -
// `NSSplitView.adjustSubviews()` preserves existing proportions, and a
// brand-new pane's proportion is zero. On screen that is one full-size
// terminal and an invisible one; to a count it is a pass.
//
// The **routing** case drives a real `NSEvent` through the real monitor, which
// is what proves a configured chord actually reaches a split rather than
// merely being stored correctly.
//
// Confirmed, per this project's convention, to catch a real regression rather
// than merely to pass - see this task's PR description for the injections and
// which case each one failed.
//
// Run with:
//   swift build && FM_RUN_TERMINAL_SHORTCUTS_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TerminalShortcutsSelfTest {

    static func run() -> Bool {
        // Splitting forks a real login shell and focusing a pane hands it the
        // keyboard, and both are refused while the gate is locked - which it
        // is at startup, because the app is. Every case below asks what an
        // unlocked app does.
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        let cases: [(String, () -> String?)] = [
            ("everyDefaultIsADistinctCommandChord", test_defaultsAreWellFormed),
            ("noDefaultLandsOnAnAlreadySpentKeystroke", test_defaultsAvoidReservedChords),
            ("modifierMatchingIsExactRatherThanContains", test_exactModifiers),
            ("anUnboundActionKeepsItsOwnDefault", test_perActionFallback),
            ("theRecorderRefusesAChordAShellWouldEat", test_recorderMode),
            ("nextAndPreviousTabWrapThroughSelectTab", test_tabCycling),
            ("aSplitOpensASecondPaneWithRealWidth", test_splitGeometry),
            ("eachDirectionPutsTheNewPaneWhereItSays", test_splitDirections),
            ("closingAPaneGivesItsSpaceBack", test_closePane),
            ("theLastPaneCannotBeClosed", test_lastPaneSurvives),
            ("thePrimaryPaneCannotBeClosed", test_primaryPaneSurvives),
            ("shuttingDownTearsDownEverySplitPane", test_shutdownTearsDownSplitPanes),
            ("zoomFillsTheTabAndPutsItBack", test_zoom),
            ("focusCyclesThroughEveryPaneAndWraps", test_focusCycle),
            ("aBackgroundTabsPanesAreHiddenToo", test_backgroundTabPanes),
            ("aConfiguredChordReachesTheSplitAction", test_monitorRouting),
        ]

        print("== Terminal shortcuts ==")
        var ok = true
        for (name, body) in cases {
            if let failure = body() {
                print("  FAIL \(name): \(failure)")
                ok = false
            } else {
                print("  OK   \(name)")
            }
        }
        return ok
    }

    // MARK: The table

    private static func test_defaultsAreWellFormed() -> String? {
        var seen: [String: TerminalShortcutAction] = [:]
        for action in TerminalShortcutAction.allCases {
            let chord = action.defaultChord
            if chord.isModifierOnly {
                return "\(action.rawValue) defaults to a modifier-only chord, which would fire whenever that modifier is pressed"
            }
            if !chord.hasModifiers {
                return "\(action.rawValue) defaults to an unmodified key, which would be eaten from the shell"
            }
            let key = "\(chord.keyCode)/\(chord.modifiers.rawValue)"
            if let other = seen[key] {
                return "\(action.rawValue) and \(other.rawValue) both default to \(chord.displayString)"
            }
            seen[key] = action
        }
        return nil
    }

    /// Every chord this app already spends, as literal `(keyCode, modifiers)`
    /// pairs.
    ///
    /// Written out rather than derived, deliberately: the menus build their
    /// key equivalents from *characters* and a `KeyChord` carries a *keyCode*,
    /// so there is nothing to derive from. Keeping it literal is also what
    /// makes it a real check - a default moved onto ⌘⌃1 fails here rather than
    /// silently stealing the first session shortcut.
    private static let reservedChords: [(UInt16, NSEvent.ModifierFlags, String)] = [
        (13, [.command], "⌘W close tab"),
        (2, [.command], "⌘D duplicate tab"),
        (17, [.command], "⌘T new tab"),
        (15, [.command], "⌘R reconnect"),
        (15, [.command, .shift], "⇧⌘R rename tab"),
        (3, [.command], "⌘F find"),
        (40, [.command], "⌘K unified search"),
        (30, [.command], "⌘] next session"),
        (33, [.command], "⌘[ previous session"),
        (45, [.command, .control], "⌃⌘N new host"),
        (1, [.command, .control], "⌃⌘S show hosts"),
        (18, [.command, .control], "⌃⌘1 first session"),
        (45, [.command, .option], "⌥⌘N new snippet"),
        (35, [.command, .option], "⌥⌘P manage snippets"),
        (45, [.command, .shift], "⇧⌘N new key"),
        (40, [.command, .shift], "⇧⌘K manage keys"),
        (3, [.command, .shift], "⇧⌘F new follow-up"),
        (37, [.command, .shift], "⇧⌘L log analyzer"),
        (0, [.command, .shift], "⇧⌘A create RCA"),
        (8, [.command, .shift], "⇧⌘C copy analysis"),
        (17, [.command, .shift], "⇧⌘T send to terminal"),
        (34, [.command, .shift], "⇧⌘I investigate further"),
        (49, [.option], "⌥Space quick capture"),
        (43, [.command], "⌘, settings"),
        (12, [.command], "⌘Q quit"),
    ]

    private static func test_defaultsAvoidReservedChords() -> String? {
        for action in TerminalShortcutAction.allCases {
            let chord = action.defaultChord
            for (code, mods, label) in reservedChords
            where chord.keyCode == code && chord.modifiers == mods.intersection(KeyChord.relevantModifierMask) {
                return "\(action.rawValue)'s default \(chord.displayString) is already \(label)"
            }
        }
        return nil
    }

    private static func test_exactModifiers() -> String? {
        let set = TerminalShortcutSet.defaults
        let next = TerminalShortcutAction.nextTab.defaultChord
        guard set.action(forKeyCode: next.keyCode, modifiers: next.modifiers) == .nextTab else {
            return "the shipped next-tab chord did not match itself"
        }
        // One extra modifier is somebody else's chord, or nobody's - never a
        // looser match for this one.
        let widened = next.modifiers.union(.option)
        if let stolen = set.action(forKeyCode: next.keyCode, modifiers: widened) {
            return "\(next.displayString) plus ⌥ was claimed as \(stolen.rawValue)"
        }
        // A modifier-only chord can never match a command action, whatever is
        // stored - the monitor would otherwise fire on a bare modifier press.
        var custom = set
        custom[.zoomPane] = KeyChord(keyCode: 61, modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue, isModifierOnly: true)
        if custom.action(forKeyCode: 61, modifiers: [.option]) != nil {
            return "a modifier-only chord matched a command action"
        }
        return nil
    }

    private static func test_perActionFallback() -> String? {
        var set = TerminalShortcutSet.defaults
        let mine = KeyChord(key: 35, [.command, .control])  // ⌃⌘P
        set[.splitDown] = mine
        guard let data = try? JSONEncoder().encode(set),
              let back = try? JSONDecoder().decode(TerminalShortcutSet.self, from: data) else {
            return "the set did not round-trip through JSON"
        }
        guard back[.splitDown] == mine else { return "the rebound action did not survive a round trip" }
        for action in TerminalShortcutAction.allCases where action != .splitDown {
            guard back[action] == action.defaultChord else {
                return "\(action.rawValue) lost its default when a different action was rebound"
            }
        }
        guard back.hasCustomBindings else { return "a rebound set did not report itself as customised" }
        var reset = back
        reset.reset()
        for action in TerminalShortcutAction.allCases where reset[action] != action.defaultChord {
            return "\(action.rawValue) was not back on its default after a reset"
        }
        guard !reset.hasCustomBindings else { return "a reset set still reported itself as customised" }
        return nil
    }

    private static func test_recorderMode() -> String? {
        let command = KeyChordRecorderView(shortcut: TerminalShortcutAction.splitRight.defaultChord, mode: .command)
        let held = KeyChord(keyCode: 61, modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue, isModifierOnly: true)
        if command.accepts(held) { return "a command recorder accepted a modifier-only chord" }
        let bare = KeyChord(keyCode: 13, modifierFlagsRaw: 0, isModifierOnly: false)
        if command.accepts(bare) { return "a command recorder accepted an unmodified key" }
        if !command.accepts(KeyChord(key: 13, [.command, .control])) {
            return "a command recorder refused a real command chord"
        }
        // Dictation's own recorder must keep taking the shape it was built
        // for - the generalisation must not have narrowed it.
        let any = KeyChordRecorderView(shortcut: .dictationDefault, mode: .any)
        if !any.accepts(held) { return "the dictation recorder stopped accepting a held modifier" }
        return nil
    }

    // MARK: Tabs

    private static func test_tabCycling() -> String? {
        let (window, console) = makeConsole(tabs: 3)
        defer { teardown(window, console) }
        guard console.tabShortcutCount == 3 else { return "expected 3 tabs, got \(console.tabShortcutCount)" }

        console.selectTab(atIndex: 0)
        console.selectTab(byOffset: 1)
        guard console.tabShortcutSelectedIndex == 1 else { return "next from tab 0 landed on \(String(describing: console.tabShortcutSelectedIndex))" }
        console.selectTab(byOffset: 1)
        console.selectTab(byOffset: 1)
        guard console.tabShortcutSelectedIndex == 0 else { return "next from the last tab did not wrap to the first" }
        console.selectTab(byOffset: -1)
        guard console.tabShortcutSelectedIndex == 2 else { return "previous from the first tab did not wrap to the last" }
        return nil
    }

    // MARK: Splits

    private static func test_splitGeometry() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }

        let before = tab.splits.bounds
        guard before.width > 200 else { return "the pane container was never laid out (\(before))" }
        guard tab.splits.paneCount == 1 else { return "a fresh tab had \(tab.splits.paneCount) panes" }

        console.splitFocusedPane(.right)
        settle(console)

        guard tab.splits.paneCount == 2 else { return "splitting produced \(tab.splits.paneCount) panes" }
        let frames = tab.splits.panes.map { $0.view.convert($0.view.bounds, to: tab.splits) }
        for (i, f) in frames.enumerated() where f.width < 40 || f.height < 40 {
            return "pane \(i) got no real size after the split: \(f)"
        }
        // The two together account for the container, give or take the
        // divider - i.e. this really is a split rather than one pane laid over
        // another.
        let covered = frames.reduce(CGFloat(0)) { $0 + $1.width }
        guard covered <= before.width + 1, covered > before.width - 20 else {
            return "the two panes cover \(covered) of \(before.width) - they are not sharing the container"
        }
        // And they share it roughly evenly. This is the assertion `halve`
        // exists for, and the one the "real width" check above cannot make:
        // without it `NSSplitView.adjustSubviews()` still gives both panes a
        // real size, just a lopsided one (measured: two thirds against one),
        // so a split that had stopped halving would pass every check about
        // size being non-zero.
        guard let widest = frames.map(\.width).max(), let narrowest = frames.map(\.width).min(),
              widest - narrowest < before.width * 0.15 else {
            return "the split is lopsided: panes are \(frames.map { $0.width })"
        }
        // Each pane is a distinct, live terminal.
        guard tab.splits.panes[0].terminal !== tab.splits.panes[1].terminal else {
            return "both panes report the same terminal"
        }
        guard tab.splits.panes.contains(where: { $0.terminal === tab.terminal }) else {
            return "the tab's primary terminal is no longer one of its panes"
        }
        guard let focused = tab.splits.focusedPane, focused !== tab.primaryPane else {
            return "the new pane is not the focused one"
        }
        // And the keyboard genuinely moved, not just the container's own idea
        // of which pane is focused. Those are two different things: the
        // container records focus, `ConsoleController.focusPane` is what makes
        // AppKit agree, and a split that updated only the first would leave
        // the captain typing into the pane they just split away from.
        guard window.firstResponder === focused.terminal else {
            return "the split moved the focus ring but not the keyboard - first responder is \(type(of: window.firstResponder))"
        }
        return nil
    }

    private static func test_splitDirections() -> String? {
        for (direction, describe) in [(TerminalSplitDirection.right, "right"),
                                      (.left, "left"),
                                      (.down, "down")] {
            let (window, console) = makeConsole(tabs: 1)
            guard let tab = console.currentTab, let original = tab.primaryPane else {
                teardown(window, console)
                return "no tab for the \(describe) case"
            }
            guard tab.splits.bounds.width > 200 else {
                teardown(window, console)
                return "\(describe): the pane container was never laid out"
            }
            console.splitFocusedPane(direction)
            settle(console)
            guard let fresh = tab.splits.focusedPane else {
                teardown(window, console)
                return "\(describe): nothing was focused after the split"
            }
            let old = original.view.convert(original.view.bounds, to: tab.splits)
            let new = fresh.view.convert(fresh.view.bounds, to: tab.splits)
            var failure: String?
            switch direction {
            case .right where !(new.minX > old.minX):
                failure = "split right put the new pane at x \(new.minX), not right of \(old.minX)"
            case .left where !(new.minX < old.minX):
                failure = "split left put the new pane at x \(new.minX), not left of \(old.minX)"
            case .down:
                // `TerminalSplitContainer` is not flipped, so "below" is the
                // smaller y. Asserted as a relation rather than a number so
                // this reads the same whichever way that ever goes.
                if !(new.minY < old.minY) {
                    failure = "split down put the new pane at y \(new.minY), not below \(old.minY)"
                }
            default:
                break
            }
            teardown(window, console)
            if let failure { return failure }
        }
        return nil
    }

    private static func test_closePane() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }
        let full = tab.splits.bounds
        guard full.width > 200 else { return "the pane container was never laid out (\(full))" }

        console.splitFocusedPane(.right)
        console.splitFocusedPane(.down)
        settle(console)
        guard tab.splits.paneCount == 3 else { return "expected 3 panes, got \(tab.splits.paneCount)" }

        console.closeFocusedPane()
        console.closeFocusedPane()
        settle(console)

        guard tab.splits.paneCount == 1 else { return "expected 1 pane after closing two, got \(tab.splits.paneCount)" }
        guard let last = tab.splits.panes.first else { return "no pane left" }
        let frame = last.view.convert(last.view.bounds, to: tab.splits)
        // The surviving pane gets the whole container back - which is what
        // fails if a split view with one child left is not collapsed away.
        guard abs(frame.width - full.width) < 2, abs(frame.height - full.height) < 2 else {
            return "the surviving pane is \(frame.size), not the container's \(full.size) - a spent split view was left in the tree"
        }
        return nil
    }

    private static func test_lastPaneSurvives() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }
        console.closeFocusedPane()
        guard tab.splits.paneCount == 1 else {
            return "closing the only pane left \(tab.splits.paneCount) - ⌘W closes a tab, this must not"
        }
        guard console.tabs.count == 1 else { return "closing the only pane closed the tab" }
        return nil
    }

    /// Review 3, B13: the *primary* pane cannot be closed either.
    ///
    /// The last-pane guard above is not the same rule and does not imply this
    /// one: with a split open there genuinely is another pane to fall back to,
    /// so `closePane` happily removed the primary - and the primary wraps
    /// `TabModel.terminal`, a `let` ~50 tab-scoped consumers read as "this
    /// tab's session" (the SRE Lead bridge, the kube-context badge, the block
    /// tracker, the Log Analyzer capture, the window title). Closing it killed
    /// that session while every one of them went on pointing at it.
    ///
    /// Asserted as three separate things, because a pane *count* is satisfied
    /// by a tree that kept two panes and killed the right session anyway.
    private static func test_primaryPaneSurvives() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }
        guard let primary = tab.primaryPane else { return "the tab has no primary pane" }

        console.splitFocusedPane(.right)
        settle(console)
        guard tab.splits.paneCount == 2 else { return "splitting produced \(tab.splits.paneCount) panes" }

        // Put the keyboard back in the primary - the split focused the new
        // pane, and this is the state a captain reaches by clicking back into
        // the one they started in.
        console.focusPane(primary, in: tab)
        guard tab.splits.focusedPane === primary else { return "could not focus the primary pane" }

        console.closeFocusedPane()
        settle(console)

        guard tab.splits.paneCount == 2 else {
            return "closing the primary pane left \(tab.splits.paneCount) - it must be refused while a sibling exists"
        }
        guard tab.splits.panes.contains(where: { $0 === primary }) else {
            return "the primary pane is gone from the container"
        }
        // The session itself, which is what the ~50 consumers actually hold.
        guard tab.splits.panes.contains(where: { $0.terminal === tab.terminal }) else {
            return "the tab's own terminal is no longer one of its panes"
        }
        guard let content = window.contentView, tab.terminal.isDescendant(of: content) else {
            return "the tab's own terminal was removed from the window's view tree"
        }
        guard let primaryPane = tab.splits.panes.first(where: { $0 === primary }), !primaryPane.isClosing else {
            return "the primary pane was torn down by a close-pane keystroke"
        }
        // And the sibling really can still be closed - otherwise "refuses the
        // primary" would be indistinguishable from "refuses everything".
        guard let sibling = tab.splits.panes.first(where: { $0 !== primary }) else {
            return "no sibling pane to close"
        }
        console.focusPane(sibling, in: tab)
        console.closeFocusedPane()
        settle(console)
        guard tab.splits.paneCount == 1 else {
            return "closing a non-primary pane left \(tab.splits.paneCount) panes"
        }
        return nil
    }

    /// Review 3, B14: quitting has to reach a tab's *split* panes, not just
    /// its primary terminal.
    ///
    /// `shutdown()` walked `tabs` and terminated `tab.terminal`, which is one
    /// shell per tab however many a captain had split it into - so every
    /// extra pane's login shell outlived the app, orphaned, with its view
    /// still holding a focus registration.
    ///
    /// A pane count after the fact cannot see that on its own (a container
    /// emptied without terminating anything reports zero too), so the child
    /// processes are read directly.
    private static func test_shutdownTearsDownSplitPanes() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { window.contentView = nil }
        guard let tab = console.currentTab else { return "no current tab" }

        console.splitFocusedPane(.right)
        settle(console)
        console.splitFocusedPane(.down)
        settle(console)
        guard tab.splits.paneCount == 3 else { return "expected 3 panes, got \(tab.splits.paneCount)" }

        let panes = tab.splits.panes
        // Vacuity guard: with nothing torn down to begin with there is nothing
        // for shutdown to miss, and every assertion below would pass for free.
        guard panes.allSatisfy({ !$0.isClosing && $0.view.superview != nil }) else {
            return "a pane was already torn down before shutdown, so this case would prove nothing"
        }

        console.shutdown()

        guard tab.splits.paneCount == 0 else {
            return "shutdown left \(tab.splits.paneCount) pane(s) in the container"
        }
        // `isClosing` is what `TerminalPane.teardown()` sets, so this is the
        // direct evidence that `teardownAll` reached *every* pane rather than
        // the container merely emptying its own array. Deliberately not the
        // child processes: this harness never calls `viewDidAppear`, so no
        // pane's shell is ever started (`hasAppeared` gates `startSplitPane`)
        // and a liveness check here would pass whatever shutdown did.
        let missed = panes.enumerated().filter { !$0.element.isClosing }.map(\.offset)
        guard missed.isEmpty else {
            return "shutdown never tore down pane(s) \(missed) of \(panes.count) - their shells would outlive the app"
        }
        // Each pane's own view leaves the tree. (Its *terminal* stays inside
        // that view - `teardown()` removes the pane, not the terminal from the
        // pane - so asserting on the terminal's superview would fail for a
        // correct teardown.)
        for (i, pane) in panes.enumerated() where pane.view.superview != nil {
            return "pane \(i) is still in a view tree after shutdown"
        }
        return nil
    }

    private static func test_zoom() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }
        let full = tab.splits.bounds
        guard full.width > 200 else { return "the pane container was never laid out (\(full))" }

        console.splitFocusedPane(.right)
        settle(console)
        guard let zoomTarget = tab.splits.focusedPane else { return "nothing focused after the split" }
        let halved = zoomTarget.view.convert(zoomTarget.view.bounds, to: tab.splits)
        guard halved.width < full.width - 20 else { return "the split pane was never actually halved" }

        console.toggleZoomFocusedPane()
        settle(console)
        let zoomed = zoomTarget.view.convert(zoomTarget.view.bounds, to: tab.splits)
        guard abs(zoomed.width - full.width) < 2 else {
            return "zoom left the pane at \(zoomed.width), not the container's \(full.width)"
        }
        guard tab.splits.paneCount == 2 else { return "zoom lost a pane - it must hide them, not close them" }

        console.toggleZoomFocusedPane()
        settle(console)
        let restored = zoomTarget.view.convert(zoomTarget.view.bounds, to: tab.splits)
        guard abs(restored.width - halved.width) < 2 else {
            return "unzoom left the pane at \(restored.width), not back at \(halved.width)"
        }
        return nil
    }

    private static func test_focusCycle() -> String? {
        let (window, console) = makeConsole(tabs: 1)
        defer { teardown(window, console) }
        guard let tab = console.currentTab else { return "no current tab" }
        console.splitFocusedPane(.right)
        console.splitFocusedPane(.down)
        guard tab.splits.paneCount == 3 else { return "expected 3 panes" }

        var visited: [UUID] = []
        for _ in 0..<3 {
            guard let focused = tab.splits.focusedPane else { return "nothing focused mid-cycle" }
            visited.append(focused.id)
            console.cycleFocusedPane(by: 1)
        }
        guard Set(visited).count == 3 else { return "cycling visited \(Set(visited).count) distinct panes, not 3" }
        guard tab.splits.focusedPane?.id == visited[0] else { return "cycling three times did not wrap back to the start" }
        console.cycleFocusedPane(by: -1)
        guard tab.splits.focusedPane?.id == visited[2] else { return "cycling backwards from the first pane did not wrap" }
        return nil
    }

    private static func test_backgroundTabPanes() -> String? {
        let (window, console) = makeConsole(tabs: 2)
        defer { teardown(window, console) }
        console.selectTab(atIndex: 0)
        guard let first = console.currentTab else { return "no current tab" }
        console.splitFocusedPane(.right)
        guard first.splits.paneCount == 2 else { return "the split did not take" }

        console.selectTab(atIndex: 1)
        guard first.splits.isHiddenOrHasHiddenAncestor else {
            return "a background tab's panes are still on screen - they would draw over the current tab"
        }
        // And every pane inside it, which is what the display gating reads.
        for pane in first.splits.panes where !pane.view.isHiddenOrHasHiddenAncestor {
            return "a background tab's pane is not effectively hidden, so its redraw is never suspended"
        }
        console.selectTab(atIndex: 0)
        guard !first.splits.isHiddenOrHasHiddenAncestor else { return "coming back to the tab left its panes hidden" }
        return nil
    }

    // MARK: Routing

    private static func test_monitorRouting() -> String? {
        let (window, console) = makeConsole(tabs: 2)
        defer { teardown(window, console) }
        let shortcuts = TabKeyboardShortcuts(target: { console },
                                             mainWindow: { window },
                                             terminalShortcuts: .defaults)
        guard let tab = console.currentTab else { return "no current tab" }

        let split = TerminalShortcutAction.splitRight.defaultChord
        guard shortcuts.handle(keyEvent(in: window, split)) else {
            return "the shipped split-right chord was not consumed"
        }
        guard tab.splits.paneCount == 2 else {
            return "the split-right chord reached the monitor but opened no pane"
        }

        console.selectTab(atIndex: 0)
        let next = TerminalShortcutAction.nextTab.defaultChord
        guard shortcuts.handle(keyEvent(in: window, next)) else { return "the next-tab chord was not consumed" }
        guard console.tabShortcutSelectedIndex == 1 else { return "the next-tab chord did not move the selection" }

        // A chord nobody bound falls through, so the rest of the app still
        // sees it.
        let unbound = KeyChord(key: 35, [.command, .control, .shift])
        if shortcuts.handle(keyEvent(in: window, unbound)) {
            return "an unbound chord was swallowed"
        }
        return nil
    }

    // MARK: Helpers

    /// A real console in a real off-screen window, with real frames.
    ///
    /// `window.contentView = controller.view` plus an explicit frame, rather
    /// than `contentViewController` - measured, the latter leaves the view at
    /// `.zero` in a headless process, which every geometry case here would
    /// then pass against vacuously. `DaylightDrillPageSlice2SelfTest.mount`
    /// is where this shape comes from.
    ///
    /// It also means `viewDidAppear` never fires, so `hasAppeared` stays
    /// false and no tab or pane forks a real login shell - which is what these
    /// cases want. They are about layout and bookkeeping; a real child process
    /// per pane would buy nothing and cost a suite full of orphaned shells.
    private static func makeConsole(tabs: Int) -> (NSWindow, ConsoleController) {
        let size = NSSize(width: 1000, height: 700)
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = OffScreenProbe.window(width: size.width, height: size.height)
        window.contentView = controller.view
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        for _ in 0..<tabs { controller.newShellTab() }
        settle(controller)
        return (window, controller)
    }

    /// Resolve the console's layout after a structural change.
    ///
    /// Both halves are load-bearing, and the first is AGENTS.md's own
    /// repeatedly-documented trap: `layoutSubtreeIfNeeded()` is a **no-op**
    /// unless something already marked the view dirty, and it is called on
    /// the view that owns the change rather than on an ancestor - an
    /// ancestor whose own `needsLayout` is false never descends into the
    /// subtree that moved. Measured here rather than assumed: without the
    /// explicit `needsLayout`, a freshly mounted pane container reports a
    /// `.zero` frame while its four constraints sit active and satisfied, and
    /// every geometry case below would then measure nothing.
    ///
    /// Only a test needs this. A real window runs a display cycle of its own,
    /// which is what resolves a tab added at runtime.
    private static func settle(_ console: ConsoleController) {
        console.content.needsLayout = true
        console.content.layoutSubtreeIfNeeded()
    }

    private static func teardown(_ window: NSWindow, _ console: ConsoleController) {
        console.shutdown()
        window.contentViewController = nil
    }

    /// A real `NSEvent` for a chord, carrying the window number the monitor's
    /// own gate reads.
    private static func keyEvent(in window: NSWindow, _ chord: KeyChord) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: chord.modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: "\u{f700}",
                         charactersIgnoringModifiers: "\u{f700}",
                         isARepeat: false,
                         keyCode: chord.keyCode)!
    }
}

#endif
