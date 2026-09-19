// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_NAVIGATION_COHERENCE_TESTS` - review #3's UX1-UX4.
//
// Four findings, one mechanism each, and this suite asserts the mechanism
// rather than the wording:
//
//   * **UX1** - "nothing shows the whole set at once". The assertion is
//     *completeness*: `AllDestinationsOverlayController.groups()` lists every
//     `RailDestination` exactly once. That is the only property of that
//     overlay a future change can silently break - adding a case and
//     forgetting the grid would produce a map that is quietly wrong, which is
//     strictly worse than no map.
//   * **UX2** - the row is capped at six visible with the remainder in an
//     overflow menu, and pin/unpin/reorder round-trip through
//     `QuickAccessConfiguration` including its encoding.
//   * **UX3** - the menu bar carries Go, Window and Help, and no longer
//     carries top-level Keys or Snippets menus, while every shortcut those two
//     menus owned is still bound somewhere in the tree.
//   * **UX4** - `ContextualNewAction` routes ⌘N per destination, and exactly
//     one item in the whole menu tree carries ⌘N (the H3 trap: a duplicate
//     chord makes one of the two items permanently dead, silently).
//
// Pure logic and `NSMenu`/`NSMenuItem` construction - no window, no view
// hierarchy - so this is **not** in `NEEDS_SESSION`. AGENTS.md's rule: the test
// is what the suite asserts, never what it imports.
//
// GL-27: debug builds only.
#if FM_SELFTESTS

import AppKit

enum NavigationCoherenceSelfTest {
    static func run() -> Bool {
        var ok = true
        ok = checkEveryDestinationIsOnTheMap() && ok
        ok = checkQuickAccessCapAndOrder() && ok
        ok = checkQuickAccessRoundTrips() && ok
        ok = checkContextualNewRouting() && ok
        ok = checkMenuBarShape() && ok
        ok = checkShortcutCatalog() && ok
        ok = checkFirstRunOnboarding() && ok
        return ok
    }

    // MARK: UX1

    /// The map is complete and lists nothing twice.
    ///
    /// **Discriminating power first** (AGENTS.md: "a check that cannot fail is
    /// worse than no check"): the grid is asserted non-trivial - more than one
    /// group, and more destinations than any single group holds - before the
    /// completeness claim, so a `groups()` that regressed to returning one
    /// catch-all bucket fails here rather than passing the count check.
    private static func checkEveryDestinationIsOnTheMap() -> Bool {
        var ok = true
        let groups = AllDestinationsOverlayController.groups()
        check(groups.count > 1, "UX1: the map collapsed to \(groups.count) group(s) - it is meant to be grouped by space", &ok)

        let listed = groups.flatMap(\.destinations)
        if let biggest = groups.map(\.destinations.count).max() {
            check(listed.count > biggest,
                  "UX1: every destination landed in one group - the grouping is not discriminating", &ok)
        }

        let all = Set(RailDestination.allCases)
        let listedSet = Set(listed)
        let missing = all.subtracting(listedSet).map(\.rawValue).sorted()
        check(missing.isEmpty, "UX1: the all-destinations map is missing \(missing) - a destination nobody can find", &ok)
        check(listed.count == listedSet.count,
              "UX1: the map lists \(listed.count - listedSet.count) destination(s) twice", &ok)
        return ok
    }

    // MARK: UX2

    private static func checkQuickAccessCapAndOrder() -> Bool {
        var ok = true
        // The default is the seven that shipped, so the cap genuinely bites on
        // a captain who has never touched this - which is the case UX2 is
        // about. Asserted rather than assumed: if the default ever shrinks to
        // six, every check below still passes while covering nothing.
        let shipped = QuickAccessConfiguration()
        check(shipped.pinned.count > QuickAccessConfiguration.visibleLimit,
              "UX2: the default row (\(shipped.pinned.count)) no longer exceeds the cap (\(QuickAccessConfiguration.visibleLimit)) - this suite's overflow checks are vacuous", &ok)
        check(shipped.visible.count == QuickAccessConfiguration.visibleLimit,
              "UX2: \(shipped.visible.count) icons visible, expected the cap of \(QuickAccessConfiguration.visibleLimit)", &ok)
        check(shipped.overflow.count == shipped.pinned.count - QuickAccessConfiguration.visibleLimit,
              "UX2: the overflow tail is \(shipped.overflow.count), expected \(shipped.pinned.count - QuickAccessConfiguration.visibleLimit)", &ok)
        check(shipped.visible + shipped.overflow == shipped.pinned,
              "UX2: visible + overflow is not the pinned row - a destination is being dropped rather than overflowed", &ok)

        // Six or fewer: no overflow at all, so the button disappears rather
        // than opening an empty menu.
        let small = QuickAccessConfiguration(pinned: [.console, .hosts, .shift])
        check(small.overflow.isEmpty, "UX2: a three-icon row produced an overflow tail", &ok)
        check(small.visible.count == 3, "UX2: a three-icon row drew \(small.visible.count) icons", &ok)
        return ok
    }

    private static func checkQuickAccessRoundTrips() -> Bool {
        var ok = true
        let base = QuickAccessConfiguration(pinned: [.console, .hosts, .shift])

        let pinned = base.toggling(.whiteboard)
        check(pinned.contains(.whiteboard), "UX1: pinning a destination did not add it", &ok)
        check(pinned.pinned.last == .whiteboard,
              "UX1: a new pin did not append - it displaced an icon the captain already reads at a fixed position", &ok)
        check(pinned.pinned.prefix(3) == base.pinned.prefix(3),
              "UX1: pinning moved the icons that were already there", &ok)

        let unpinned = pinned.toggling(.whiteboard)
        check(unpinned == base, "UX1: pin-then-unpin did not return the original row", &ok)

        // Unpinning the last one leaves an empty row and does NOT silently
        // restore the seven defaults - "I want no shortcuts" is a real
        // preference. The store's fallback-to-default is for an *absent* value.
        let emptied = QuickAccessConfiguration(pinned: [])
        check(emptied.pinned.isEmpty, "UX1: an explicitly empty row was refilled with the defaults", &ok)

        // Reorder: move the third icon to the front.
        let moved = base.moving(from: 2, to: 0)
        check(moved.pinned == [.shift, .console, .hosts],
              "UX2: reorder produced \(moved.pinned.map(\.rawValue)), expected shift/console/hosts", &ok)
        check(base.moving(from: 99, to: 0) == base, "UX2: an out-of-range drag changed the row", &ok)
        check(base.moving(from: 1, to: 1) == base, "UX2: a no-op drag changed the row", &ok)

        // A duplicate cannot survive construction - two squares for one
        // destination is a row whose active highlight is undefined.
        let duped = QuickAccessConfiguration(pinned: [.console, .hosts, .console])
        check(duped.pinned == [.console, .hosts], "UX2: a duplicate pin survived - got \(duped.pinned.map(\.rawValue))", &ok)

        // The encoding round-trips, which is what makes the choice survive a
        // relaunch at all.
        guard let data = try? JSONEncoder().encode(pinned),
              let decoded = try? JSONDecoder().decode(QuickAccessConfiguration.self, from: data) else {
            fail("UX1: the pinned row does not round-trip through JSON", &ok)
            return ok
        }
        check(decoded == pinned, "UX1: the decoded row is \(decoded.pinned.map(\.rawValue)), expected \(pinned.pinned.map(\.rawValue))", &ok)

        // GL-01: a file this build cannot fully read decodes to something
        // usable rather than making the whole value undecodable.
        let unknown = #"{"pinned":["console","nosuchdestination","hosts"]}"#.data(using: .utf8)!
        if let salvaged = try? JSONDecoder().decode(QuickAccessConfiguration.self, from: unknown) {
            check(salvaged.pinned == [.console, .hosts],
                  "UX1: an unknown destination was not dropped cleanly - got \(salvaged.pinned.map(\.rawValue))", &ok)
        } else {
            fail("UX1: a row naming one unknown destination failed to decode at all (GL-01)", &ok)
        }
        return ok
    }

    // MARK: UX4

    private static func checkContextualNewRouting() -> Bool {
        var ok = true
        let expected: [(RailDestination, ContextualNewAction)] = [
            (.shift, .task),
            (.hosts, .host),
            (.stickyBoard, .stickyNote),
            (.codePreview, .codeSnippet),
            (.poneglyph, .credential),
            (.schedules, .schedule),
            (.commandLibrary, .command),
            (.runbooks, .runbook),
            // The fallback: a page that owns nothing creatable still gets a
            // working ⌘N rather than a dead one.
            (.settings, .task),
            (.console, .task),
            (.homeCanvas, .task),
        ]
        for (destination, want) in expected {
            let got = ContextualNewAction.forDestination(destination)
            check(got == want,
                  "UX4: \u{2318}N on \(destination.rawValue) resolves to \(got.rawValue), expected \(want.rawValue)", &ok)
        }
        // The one destination with three verbs behind one page.
        check(ContextualNewAction.forDestination(.hosts, hostsTab: .keys) == .sshKey,
              "UX4: \u{2318}N on the Hosts page's Keys tab does not make a key", &ok)
        check(ContextualNewAction.forDestination(.hosts, hostsTab: .snippets) == .snippet,
              "UX4: \u{2318}N on the Hosts page's Snippets tab does not make a snippet", &ok)

        // Every action names a page that really owns it, and every title reads
        // as a creation verb - the title is part of the contract, since the
        // menu item is what tells the captain which thing ⌘N means here.
        for action in ContextualNewAction.allCases {
            check(action.menuTitle.hasPrefix("New "),
                  "UX4: \(action.rawValue)'s menu title is \"\(action.menuTitle)\" - it must read as a creation verb", &ok)
            check(ContextualNewAction.forDestination(action.owningDestination,
                                                    hostsTab: hostsTab(for: action)) == action,
                  "UX4: \(action.rawValue) claims to be owned by \(action.owningDestination.rawValue), which routes elsewhere", &ok)
        }
        return ok
    }

    /// The Hosts page is the one destination whose ⌘N depends on a sub-tab, so
    /// the round-trip above has to hand back the tab each of its three verbs
    /// belongs to.
    private static func hostsTab(for action: ContextualNewAction) -> HostsTab? {
        switch action {
        case .sshKey: return .keys
        case .snippet: return .snippets
        case .host: return .hosts
        default: return nil
        }
    }

    // MARK: UX3

    /// Build the app's real menu bar and assert its shape.
    ///
    /// `AppDelegate.buildMenu()` assigns `NSApp.mainMenu`, and constructing an
    /// `AppDelegate` here would mount the whole app - so this suite builds the
    /// menu the same way the app does and reads `NSApp.mainMenu` back. That is
    /// the real tree, not a reconstruction of it, which is the only version of
    /// this check worth having.
    private static func checkMenuBarShape() -> Bool {
        var ok = true
        guard let menu = buildRealMenuBar() else {
            fail("UX3: could not build the app's menu bar - every menu-shape check below is vacuous", &ok)
            return ok
        }
        let titles = menu.items.compactMap { $0.submenu?.title }

        for wanted in ["File", "Go", "Window", "Help"] {
            check(titles.contains(wanted), "UX3: there is no \(wanted) menu - menu bar is \(titles)", &ok)
        }
        // UX3's own complaint: "Keys and Snippets are two-item top-level menus
        // for tabs of the Hosts page".
        for gone in ["Keys", "Snippets"] {
            check(!titles.contains(gone),
                  "UX3: \(gone) is still a top-level menu - it belongs under Hosts", &ok)
        }

        // Folding them must not have cost a shortcut. Assert the four chords
        // are still bound *somewhere*, which is what actually matters to a
        // captain's fingers.
        let bound = allBindings(menu)
        for (chord, label) in [("\u{21e7}\u{2318}N", "New SSH Key"), ("\u{21e7}\u{2318}K", "Manage SSH Keys"),
                               ("\u{2325}\u{2318}N", "New Snippet"), ("\u{2325}\u{2318}P", "Manage Snippets")] {
            check(bound.contains(where: { $0.chord == chord }),
                  "UX3: \(chord) (\(label)) was lost when Keys/Snippets folded under Hosts", &ok)
        }

        // UX4's ⌘1-⌘5.
        for index in 1...5 {
            check(bound.contains(where: { $0.chord == "\u{2318}\(index)" }),
                  "UX4: \u{2318}\(index) is not bound - the five spaces were meant to take \u{2318}1-\u{2318}5", &ok)
        }

        // The H3 trap, generalised: **no chord may be declared twice**. AppKit
        // resolves one to the first enabled match in menu order and this app
        // implements no `validateMenuItem`, so a duplicate silently makes one
        // of the two items permanently dead. This is the check that would have
        // caught H3 before a captain did.
        var seen: [String: String] = [:]
        for binding in bound {
            if let first = seen[binding.chord] {
                fail("UX3/UX4: \(binding.chord) is declared twice - \"\(first)\" and \"\(binding.title)\". "
                     + "AppKit resolves it to the first enabled match, so one of them is dead.", &ok)
            } else {
                seen[binding.chord] = binding.title
            }
        }

        // UX4's headline: exactly one ⌘N, and it is the contextual item.
        let commandN = bound.filter { $0.chord == "\u{2318}N" }
        check(commandN.count == 1, "UX4: \(commandN.count) items claim \u{2318}N - \(commandN.map(\.title))", &ok)
        return ok
    }

    private static func checkShortcutCatalog() -> Bool {
        var ok = true
        // Rendering: the canonical ⌃⌥⇧⌘ order, and the glyph for a key whose
        // literal character is unprintable.
        check(KeyboardShortcutCatalog.keycaps(keyEquivalent: "n", modifiers: [.command, .shift])
                == ["\u{21e7}", "\u{2318}", "N"],
              "UX3: \u{21e7}\u{2318}N did not render in macOS's own modifier order", &ok)
        check(KeyboardShortcutCatalog.keycaps(keyEquivalent: " ", modifiers: [.option]).last == "Space",
              "UX3: a space key equivalent did not render as \"Space\"", &ok)
        check(KeyboardShortcutCatalog.keycaps(keyEquivalent: "", modifiers: [.command]).isEmpty,
              "UX3: an item with no key equivalent produced a chord", &ok)

        guard let menu = buildRealMenuBar() else {
            fail("UX3: could not build the menu bar - the catalog checks below are vacuous", &ok)
            return ok
        }
        let sections = KeyboardShortcutCatalog.sections(from: menu)
        check(!sections.isEmpty, "UX3: the shortcuts sheet would print nothing", &ok)
        check(sections.allSatisfy { !$0.entries.isEmpty },
              "UX3: the sheet prints a heading with no bindings under it", &ok)
        // The sheet is the discoverability surface UX3 asks for, so it has to
        // actually carry the app's bindings rather than a handful.
        let total = sections.reduce(0) { $0 + $1.entries.count }
        check(total >= 20, "UX3: the sheet lists only \(total) bindings - it is meant to surface every one", &ok)
        // An item with no chord must not appear: the sheet is a chord
        // reference, and a blank pill beside a title reads as a bug.
        check(sections.allSatisfy { $0.entries.allSatisfy { !$0.keys.isEmpty } },
              "UX3: the sheet lists an item with an empty chord", &ok)
        return ok
    }

    // MARK: UX13

    /// Review #3's UX13: "onboarding is a lock screen."
    ///
    /// Two halves: the welcome sheet's own step machine, and the hub's
    /// first-run hero copy. Both are asserted in **both** directions - a
    /// first-run banner that outstayed its welcome would be a permanent
    /// fixture on a working captain's hub, which is a worse bug than not
    /// having one.
    private static func checkFirstRunOnboarding() -> Bool {
        var ok = true

        // The hero copy. Nothing at all saved -> an invitation.
        guard let welcome = HomeCanvasController.firstRunHeroCopy(hosts: 0, tasks: 0, notes: 0) else {
            fail("UX13: an app with nothing in it showed no first-run copy at all", &ok)
            return ok
        }
        check(!welcome.title.isEmpty && !welcome.detail.isEmpty,
              "UX13: the first-run hero copy is blank", &ok)
        // It has to say what to do, not merely be friendly - that is the
        // "guided" in "a guided empty state".
        check(welcome.detail.lowercased().contains("host") && welcome.detail.lowercased().contains("task"),
              "UX13: the first-run copy does not name the first host or the first task: \"\(welcome.detail)\"", &ok)

        // Anything saved at all -> it is gone. Each store on its own, because
        // a captain with tasks but no hosts is not new, and being told to
        // "add your first host" would be the app misreading its own user.
        check(HomeCanvasController.firstRunHeroCopy(hosts: 1, tasks: 0, notes: 0) == nil,
              "UX13: the first-run hero survived a saved host", &ok)
        check(HomeCanvasController.firstRunHeroCopy(hosts: 0, tasks: 1, notes: 0) == nil,
              "UX13: the first-run hero survived a saved task", &ok)
        check(HomeCanvasController.firstRunHeroCopy(hosts: 0, tasks: 0, notes: 1) == nil,
              "UX13: the first-run hero survived a saved note", &ok)

        // **The invitation must never hide a verdict that needs the captain.**
        // The three stores it counts are *local*; `FleetGreeting` reports on
        // the crew. A crewmate can be parked on a decision while this machine
        // has nothing saved on it at all - a new Mac, a second user, a fresh
        // clone - and "Welcome aboard" over a blocked task would be strictly
        // worse than the all-clear this whole finding objects to.
        //
        // This was a real flaw in the first cut of UX13, caught by
        // `CanvasListsControlsSelfTest`'s C1 case rather than by reading the
        // code. The rule lives here now, on the property the canvas actually
        // branches on.
        let needsYou = FleetGreeting.answer(
            tasks: [FleetTask(id: "t1", repo: "grand-line", kind: "feature", pr: nil,
                              status: "needs_decision")],
            readyCount: 0, prFetchFailure: nil, homeOk: true)
        check(!needsYou.metaRestatesCards,
              "UX13: a needs-you answer must not be classed as a card restatement - "
              + "that is the flag the hub reads to decide the first-run hero may show", &ok)
        let allClear = FleetGreeting.answer(tasks: [], readyCount: 0,
                                            prFetchFailure: nil, homeOk: true)
        check(allClear.metaRestatesCards,
              "UX13/UX5: an all-clear answer should be classed as a restatement, or the "
              + "first-run hero can never appear at all", &ok)

        // The sheet's step machine. A window is not needed - the steps are
        // state, and `loadView` builds views with no window server.
        let sheet = WelcomeSheetController()
        sheet.loadView()
        check(WelcomeSheetController.debugStepCount == 3,
              "UX13: the finding asks for a three-step sheet, got \(WelcomeSheetController.debugStepCount)", &ok)
        check(sheet.debugStepIndex == 0, "UX13: the sheet should open on its first step", &ok)
        check(sheet.debugBackIsHidden, "UX13: there is nothing to go back to on the first step", &ok)
        check(!sheet.debugThemeGridIsHidden, "UX13: step one should show the theme picker", &ok)
        check(sheet.debugCommandWellIsHidden, "UX13: the lock command belongs on the last step only", &ok)

        sheet.debugNext()
        check(sheet.debugStepIndex == 1, "UX13: Next did not advance the sheet", &ok)
        check(!sheet.debugBackIsHidden, "UX13: Back should be available past the first step", &ok)
        check(sheet.debugThemeGridIsHidden, "UX13: the theme picker belongs on step one only", &ok)

        sheet.debugNext()
        check(sheet.debugStepIndex == 2, "UX13: Next did not reach the last step", &ok)
        check(!sheet.debugCommandWellIsHidden,
              "UX13: the last step should show the lock-setup command", &ok)
        check(sheet.debugNextButtonTitle != "Next",
              "UX13: the last step's primary button should not still say Next", &ok)

        sheet.debugBack()
        check(sheet.debugStepIndex == 1, "UX13: Back did not go back", &ok)
        return ok
    }

    // MARK: Helpers

    private struct Binding {
        let title: String
        let chord: String
    }

    /// Every key equivalent in the tree, flattened.
    private static func allBindings(_ menu: NSMenu) -> [Binding] {
        var out: [Binding] = []
        for item in menu.items {
            if let submenu = item.submenu {
                out += allBindings(submenu)
                continue
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { continue }
            out.append(Binding(
                title: item.title,
                chord: KeyboardShortcutCatalog.keycaps(keyEquivalent: item.keyEquivalent,
                                                       modifiers: item.keyEquivalentModifierMask).joined()))
        }
        return out
    }

    /// The app's own menu bar, built by the app's own `buildMenu()`.
    ///
    /// `installing: false` is what makes this safe in a headless process: it
    /// builds the identical tree, assigns nothing to `NSApp` (which is nil
    /// here - see that parameter's own doc comment) and never touches the lazy
    /// `appShell`. The tree returned is the real one this app installs at
    /// launch, not a reconstruction of it, which is the only version of these
    /// checks worth having.
    private static func buildRealMenuBar() -> NSMenu? {
        AppDelegate().buildMenu(installing: false)
    }
}

#endif
