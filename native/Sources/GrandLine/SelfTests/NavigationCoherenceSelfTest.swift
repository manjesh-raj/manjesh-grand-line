// Grand Line - native macOS app.
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
//   * **§7** - the naming and window-title halves of review #3's "other
//     issues". "Home" names the canvas, "Fleet" names the fleet dashboard,
//     "Overview" names exactly one thing (the daily review page, which
//     `fm/grandline-overview-page-daily-review` added); and
//     `AppDelegate.windowTitle(context:)` puts the current page in the window
//     title, which is what Mission Control and the Window menu read. The
//     *live* half - navigating actually renames the window - lives in
//     `DestinationMountingSelfTest`, which already mounts a real shell in a
//     real window.
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
        ok = checkTheMapIsActuallyReachable() && ok
        ok = checkClipboardHistoryIsNotAShortcut() && ok
        ok = checkContextualNewRouting() && ok
        ok = checkMenuBarShape() && ok
        ok = checkTheAppMenuSaysTheDisplayName() && ok
        ok = checkShortcutCatalog() && ok
        ok = checkFirstRunOnboarding() && ok
        ok = checkDestinationNamingIsCanonical() && ok
        ok = checkNavigationNamesAreDistinct() && ok
        ok = checkWindowTitleComposition() && ok
        ok = checkNoControlOwnsACharacterChord() && ok
        return ok
    }

    // MARK: B27 - a page-scoped control must not own a window-wide chord

    /// `NSControl.keyEquivalent` is resolved by the **window's**
    /// `performKeyEquivalent`, so a button that sets one claims that chord for
    /// every view in the window while its page is mounted.
    ///
    /// The Command Library's Copy button set ⌘C that way, and the collision
    /// went both ways: where the Edit menu's Copy is enabled (any field with a
    /// selection) the menu wins and the button's chord is dead, and where it
    /// is disabled ⌘C silently copied the selected command template instead of
    /// doing nothing. AppKit has no way to scope a control's key equivalent to
    /// a subtree, so the rule is simply that a control may not carry a
    /// *character* one.
    ///
    /// Return and Escape are exempt and are the whole point of the exemption:
    /// they are AppKit's default/cancel button convention, they are what a
    /// sheet or popover is expected to honour, and they are not chords a menu
    /// competes for. Every other key belongs in `NSApp.mainMenu`, where
    /// `checkMenuBarShape`'s duplicate rule already governs it.
    private static func checkNoControlOwnsACharacterChord() -> Bool {
        var ok = true
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("app sources are not next to this binary - this guard would pass vacuously", &ok)
            return ok
        }
        let allowed = ["\"\\r\"", "\"\\u{1b}\"", "\"\""]
        var offenders: [String] = []
        var sawAny = false
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "swift" {
            // `main.swift` builds the menu bar, where a character key
            // equivalent is exactly right.
            guard file.lastPathComponent != "main.swift" else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                guard let range = code.range(of: ".keyEquivalent = ") else { continue }
                sawAny = true
                let value = String(code[range.upperBound...])
                guard !allowed.contains(where: { value.hasPrefix($0) }) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        // Discriminating power: the exempt Return/Escape assignments still
        // spell the property, so a grep that stopped matching fails here.
        check(sawAny,
              "guard: nothing outside main.swift sets `keyEquivalent` any more - either the "
              + "default-button convention was removed (then delete this guard) or the grep "
              + "is broken", &ok)
        check(offenders.isEmpty,
              "B27: a control's `keyEquivalent` is window-wide, so a page-scoped button that "
              + "sets a character chord steals it from every other view (and loses it to any "
              + "enabled menu item with the same chord). Only Return and Escape - AppKit's "
              + "default/cancel convention - are allowed here; everything else belongs in "
              + "`NSApp.mainMenu`. Offenders: " + offenders.joined(separator: ", "), &ok)
        return ok
    }

    // MARK: Review #3 §7 - one name per thing

    /// The canvas is "Home" and the fleet dashboard is "Fleet", on every
    /// surface that names either.
    ///
    /// Review #3 §7 found three user-facing names - "Home", "Overview" and
    /// "Fleet" - for two things, spread across the rail title, the canvas
    /// space pill, the module card and the drill page's own tab strip. The
    /// two things are genuinely distinct (a hub of module cards, and a
    /// dashboard drill page), so the fix settles one name each rather than
    /// merging them.
    ///
    /// **Discriminating power first**: the two canonical names are asserted
    /// to actually differ, so a future change that collapses them into one
    /// string cannot make every check below pass vacuously.
    private static func checkDestinationNamingIsCanonical() -> Bool {
        print("\n-- §7: one canonical name per destination --")
        var ok = true
        let canvas = RailDestination.homeCanvas.title
        let fleet = RailDestination.overview.title
        guard canvas != fleet else {
            fail("the canvas and the fleet page must be two different names, both are \(canvas)", &ok)
            return false
        }
        check(canvas == "Home", "the canvas is called Home, got \(canvas)", &ok)
        check(fleet == "Fleet", "the fleet dashboard is called Fleet, got \(fleet)", &ok)

        // The canvas's own space pill, and the Recents kicker that falls back
        // to it, both say what the canvas is called. (It is the *second* pill
        // since `fm/grandline-overview-page-daily-review`; which slot it sits
        // in is `DaylightModuleSelfTest.checkSpaceTable`'s literal title list,
        // not this suite's business - what matters here is the name.)
        check(DaylightSpace.overview.title == canvas,
              "the canvas's space pill says \(canvas), got \(DaylightSpace.overview.title)", &ok)
        check(RecentDestinationKind.rail(.homeCanvas).kicker == canvas,
              "a Recents row for the canvas is kickered \(canvas), got \(RecentDestinationKind.rail(.homeCanvas).kicker)", &ok)

        // The card that opens the fleet page and the page itself agree.
        check(DaylightModule.fleet.title == fleet,
              "the Fleet card and the Fleet page agree, got \(DaylightModule.fleet.title)", &ok)
        check(DaylightModule.fleet.opens == .overview,
              "...and that card really is the one that opens it", &ok)

        // A tab strip inside the page must not repeat the page's own name,
        // and must not borrow the canvas's.
        let tabs = FleetController.debugTabTitles
        check(!tabs.isEmpty, "the fleet page has tabs to check - this is vacuous otherwise", &ok)
        check(!tabs.contains(fleet), "a tab must not repeat the page's own name, got \(tabs)", &ok)
        check(!tabs.contains(canvas), "...nor borrow the canvas's, got \(tabs)", &ok)
        return ok
    }

    /// "Overview" names exactly one thing, and it is the daily review page.
    ///
    /// **UX issue X3 of the 2026-09-27 review.** The rule this guard
    /// enforces has now moved twice, and the history matters because the
    /// defect came back both times.
    ///
    /// Review #3 §7 found three user-facing names - "Home", "Overview",
    /// "Fleet" - for two things, and this guard forbade "Overview"
    /// outright. `fm/grandline-overview-page-daily-review` then gave the
    /// word a third, real referent on the captain's own ask, and the rule
    /// relaxed to "exactly one thing is called it". The 2026-09-27 review
    /// found the result anyway: a bar with "Overview" and "Home" pills, a
    /// menu listing "Home", "Overview", "Home", an "Overview" header
    /// containing an "Overview" item, and an "Elsewhere" group holding
    /// "Home" and "Fleet".
    ///
    /// The word itself was the problem. "Overview" does not say what the
    /// page is - it is what *any* landing page could be called, which is
    /// why it kept attaching itself to whichever one somebody was looking
    /// at. The three things are named for what they are now: **Home** is
    /// the canvas, **Today** is the daily review, **Fleet** is the crew
    /// dashboard. "Overview" names nothing and is forbidden again.
    ///
    /// Comments are stripped before the search, so this file's own prose
    /// (and the several doc comments that explain the rename) do not fail
    /// the run. The stripping cuts at `//`, which also truncates a line
    /// carrying a URL - that only ever makes the guard more permissive,
    /// never a false alarm.
    private static func checkNavigationNamesAreDistinct() -> Bool {
        print("\n-- X3: Home, Today and Fleet name three things, and \"Overview\" names none --")
        var ok = true

        // The behavioural half: three names, three things, no two alike.
        let canvas = RailDestination.homeCanvas.title
        let fleet = RailDestination.overview.title
        let review = RailDestination.dailyOverview.title
        check(review == "Today", "the daily review page is called Today, got \(review)", &ok)
        check(canvas == "Home", "the canvas is called Home, got \(canvas)", &ok)
        check(fleet == "Fleet", "the crew dashboard is called Fleet, got \(fleet)", &ok)
        check(Set([canvas, fleet, review]).count == 3,
              "the canvas, the fleet dashboard and the daily review page need three distinct names, got "
              + "\(canvas)/\(fleet)/\(review)", &ok)
        check(DaylightSpace.dailyOverview.title == review,
              "the pill and the page it opens agree, pill says \(DaylightSpace.dailyOverview.title)", &ok)
        check(DaylightSpace.dailyOverview.destination == .dailyOverview,
              "...and the pill really opens that page", &ok)

        // No two space pills may share a label with each other or with a
        // top-level destination either - the bar is the surface the review
        // actually read the collision off.
        let pillTitles = DaylightSpace.allCases.map(\.title)
        check(Set(pillTitles).count == pillTitles.count,
              "two space pills share a label: \(pillTitles)", &ok)

        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not resolve the app's own source directory - this guard silently passes otherwise", &ok)
            return false
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swift" } ?? []
        guard files.count > 50 else {
            fail("expected the app's whole source directory, found \(files.count) files", &ok)
            return false
        }
        // The guard has to be able to fire: a literal it must find, and one
        // it must not.
        let canary = "\"Overview\""
        check(stripComments("let x = \(canary)").contains(canary),
              "the stripper must leave a real string literal alone", &ok)
        check(!stripComments("// a comment mentioning \(canary)").contains(canary),
              "...and must remove one inside a comment", &ok)

        var offenders: [String] = []
        for file in files {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard stripComments(raw).contains(canary) else { continue }
            offenders.append(file.lastPathComponent)
        }
        check(offenders.isEmpty,
              "\"Overview\" names nothing in this app - the canvas is Home, the daily review is Today, "
              + "the crew dashboard is Fleet. Still in: \(offenders.sorted())", &ok)
        return ok
    }

    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let slashes = line.range(of: "//") else { return line }
            return line[line.startIndex..<slashes.lowerBound]
        }.joined(separator: "\n")
    }

    // MARK: Review #3 §7 - the window title carries the destination

    /// `AppDelegate.windowTitle(context:)` composes app name plus page.
    ///
    /// The window title was the bundle name alone, so Mission Control and the
    /// Window menu showed one indistinguishable entry for twenty-seven pages.
    /// This is the pure half; `DestinationMountingSelfTest` asserts that a
    /// real navigation actually reaches it.
    private static func checkWindowTitleComposition() -> Bool {
        print("\n-- §7: the window title names the current page --")
        var ok = true
        let bare = AppDelegate.windowTitle()
        check(!bare.isEmpty, "the app name is not empty - everything below is relative to it", &ok)

        // UX-12: the title is visible in the toolbar and names the module, so
        // the real app's is the module alone; a differently named build (the
        // probe) keeps its own name in front.
        let named = { (context: String) in bare == "Grand Line" ? context : "\(bare) - \(context)" }
        let hosts = AppDelegate.windowTitle(context: "Connections")
        check(hosts == named("Connections"), "expected \"\(named("Connections"))\", got \"\(hosts)\"", &ok)
        check(hosts != bare, "...and it genuinely differs from the bare app name", &ok)

        // Two destinations must not produce the same title, or the whole
        // point (telling windows apart in Mission Control) is lost.
        let tasks = AppDelegate.windowTitle(context: "Tasks")
        check(tasks != hosts, "two modules give two titles, both were \(hosts)", &ok)

        // Nothing dangling before the first navigation.
        check(AppDelegate.windowTitle(context: nil) == bare, "no context gives the bare app name", &ok)
        check(AppDelegate.windowTitle(context: "   ") == bare, "...and neither does a blank one", &ok)

        // The separator is a plain hyphen, matching the rest of this app's
        // copy - an em dash here would be the only one in the product.
        check(!AppDelegate.windowTitle(context: "Tasks").contains("\u{2014}"),
              "the separator is a hyphen, not an em dash", &ok)
        return ok
    }

    // MARK: UX1, and UX-01 of the 2026-10 review

    /// The map is complete and lists nothing twice. UX-01 made the map the
    /// Workspace sidebar, drawn from `ModuleTable`, and the Window menu lists
    /// the same table - so every route must be a tab of exactly one module
    /// and every module a Window-menu row.
    ///
    /// **Discriminating power first**: the table is asserted non-trivial -
    /// more than one section, and more modules than any one section holds -
    /// before the completeness claim.
    private static func checkEveryDestinationIsOnTheMap() -> Bool {
        var ok = true
        let sections = WorkspaceSection.allCases.map { ModuleTable.modules(in: $0) }
        check(sections.filter { !$0.isEmpty }.count > 1, "UX-01: the sidebar collapsed to one section", &ok)
        if let biggest = sections.map(\.count).max() {
            check(ModuleTable.all.count > biggest, "UX-01: every module landed in one section", &ok)
        }
        let routed = ModuleTable.all.flatMap(\.routes)
        let missing = Set(RailDestination.allCases).subtracting(routed).map(\.rawValue).sorted()
        check(missing.isEmpty, "UX-01: no module lists \(missing) - a page nobody can reach from the sidebar", &ok)
        check(routed.count == Set(routed).count, "UX-01: a route is listed under two modules", &ok)
        guard let menu = buildRealMenuBar(),
              let window = menu.items.compactMap(\.submenu).first(where: { $0.title == "Window" }) else {
            fail("UX-01: could not build the Window menu - the menu half is vacuous", &ok)
            return ok
        }
        let rows = window.items.compactMap { $0.representedObject as? String }
        check(rows == ModuleTable.all.map(\.id.rawValue),
              "UX-01: the Window menu's module rows \(rows) disagree with the sidebar's table", &ok)
        return ok
    }

    /// UX1's other half: a complete map nobody can open is still a map nobody
    /// can open. The sidebar's selection must be wired to navigation, and the
    /// window must wear the toolbar - a source guard, because both wires are
    /// closures and calls whose absence nothing else would notice (a sidebar
    /// that draws, highlights and does nothing when clicked).
    private static func checkTheMapIsActuallyReachable() -> Bool {
        var ok = true
        guard let dir = SelfTestSources.appSourceDirectory(),
              let main = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            fail("UX-01: could not read the app sources - this check would silently pass", &ok)
            return ok
        }
        check(main.contains("appShell.onSearchTapped ="),
              "UX-01: main.swift no longer wires `onSearchTapped` either - this check has lost its bearings", &ok)
        check(shell.contains("sidebar.onSelectModule = { [weak self] id in self?.showModule(id) }"),
              "UX-01: the sidebar's module selection is not wired to `showModule` - the map would be dead", &ok)
        check(shell.contains("sidebar.onSelectChild ="),
              "UX-01: the sidebar's child rows are not wired - a live session in the sidebar would do nothing", &ok)
        check(main.contains("WorkspaceWindowChrome.apply(to: window, toolbar: appShell.toolbarController.toolbar)"),
              "UX-12: the main window no longer wears the Workspace toolbar", &ok)
        return ok
    }

    // MARK: UX2

    // The quick-access row's cap, order and saved-layout round trips were
    // retired with the row itself: UX-01 made the sidebar the quick access.

    /// The captain asked for Clipboard History off the bar's shortcuts, and
    /// UX-01 retired the shortcut row; the window-backed half (no toolbar
    /// control is the clipboard history) is
    /// `BarNavigationModernizationSelfTest.test_clipboardHistoryIsOffTheBar`.
    /// This is the half that needs no window: no module or route exists that
    /// would put it back in the sidebar, and the Edit menu's "Clipboard
    /// History…" item is still there on ⇧⌘V, the one way in.
    private static func checkClipboardHistoryIsNotAShortcut() -> Bool {
        var ok = true
        func isClipboard(_ raw: String) -> Bool { raw.localizedCaseInsensitiveContains("clipboard") }
        check(!RailDestination.allCases.map(\.rawValue).contains(where: isClipboard),
              "a clipboard destination exists, so it could come back as a sidebar item", &ok)
        check(!ModuleTable.all.map(\.title).contains(where: isClipboard),
              "a clipboard module exists in the sidebar", &ok)

        guard let menu = buildRealMenuBar() else {
            fail("could not build the app's menu bar - the Clipboard History reachability check is vacuous", &ok)
            return ok
        }
        let item = allBindings(menu).first { $0.title == "Clipboard History\u{2026}" }
        check(item != nil,
              "the Edit menu has no \"Clipboard History…\" item - with the bar square gone the feature is unreachable",
              &ok)
        if let item {
            let wanted = KeyboardShortcutCatalog.keycaps(keyEquivalent: "v", modifiers: [.command, .shift]).joined()
            check(item.chord == wanted, "Clipboard History is on \(item.chord), expected \(wanted)", &ok)
        }
        return ok
    }

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

        for wanted in ["File", "Window", "Help"] {
            check(titles.contains(wanted), "UX3: there is no \(wanted) menu - menu bar is \(titles)", &ok)
        }
        // UX-01: the Go menu's spaces and destination list are the sidebar
        // now, and its rows moved to the Window menu.
        check(!titles.contains("Go"), "UX-01: the Go menu is back - menu bar is \(titles)", &ok)
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

        // UX-01 (the review's section 4.7): ⌘1-⌘6 select Home and the Work
        // group's five modules, in sidebar order.
        let chordModules = ModuleTable.all.filter { $0.chord != nil }
        for (index, module) in chordModules.enumerated() {
            let binding = bound.first(where: { $0.chord == "\u{2318}\(index + 1)" })
            check(binding?.title == module.title,
                  "UX-01: \u{2318}\(index + 1) is bound to \(binding?.title ?? "nothing"), expected \(module.title)", &ok)
        }
        // ⌘⇧] / ⌘⇧[ step through a module's tabs; ⌥⌘S toggles the sidebar.
        // ⌘⇧] is spelled the way AppKit matches it: "}" under ⌘ (measured -
        // "]" under ⌘⇧ never fires), so read the chord back the same way.
        let shiftedBracket = { (key: String) in
            KeyboardShortcutCatalog.keycaps(keyEquivalent: key, modifiers: [.command]).joined()
        }
        for (chord, title) in [(shiftedBracket("}"), "Next Module Tab"), (shiftedBracket("{"), "Previous Module Tab"),
                               ("\u{2325}\u{2318}S", "Toggle Sidebar")] {
            check(bound.contains(where: { $0.chord == chord && $0.title == title }),
                  "UX-01: \(title) is not on \(chord)", &ok)
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


    /// **Review bug B12**: the App menu read "Quit GrandLine".
    ///
    /// It was built from `ProcessInfo.processInfo.processName`, which is the
    /// *executable* name - and the executable is `GrandLine` while the app is
    /// "Grand Line". AGENTS.md's naming rule and
    /// `LegacyRenameMigrationSelfTest` guard the spelling in the sources, and
    /// neither could see this: the sources spell no name at all there.
    ///
    /// Asserted against `AppPaths.displayName` rather than a literal, so the
    /// check is "the menu agrees with the app's one definition of its name"
    /// rather than a second place to update at the next rename - plus a
    /// standing refusal of the run-together spelling, which is the specific
    /// defect and the one a future `processName` would bring back.
    private static func checkTheAppMenuSaysTheDisplayName() -> Bool {
        var ok = true
        guard let menu = buildRealMenuBar() else {
            fail("the app's menu bar could not be built, so this checked nothing", &ok)
            return ok
        }
        guard let appMenu = menu.items.first?.submenu else {
            fail("the menu bar has no App menu", &ok)
            return ok
        }
        let titles = appMenu.items.map(\.title)
        let name = AppPaths.displayName

        // Discriminating power: the display name has to be the human spelling,
        // or every check below passes against the executable's own name.
        check(name.contains(" "),
              "AppPaths.displayName is '\(name)' - the app's display name has a space in it; "
              + "resolving to the executable name is exactly B12", &ok)
        check(name != ProcessInfo.processInfo.processName || name == "Grand Line",
              "the display name must not simply be the process name", &ok)

        for verb in ["About", "Hide", "Quit"] {
            check(titles.contains("\(verb) \(name)"),
                  "the App menu should carry \"\(verb) \(name)\" - it has \(titles)", &ok)
        }
        check(!titles.contains(where: { $0.contains("GrandLine") }),
              "no App menu item may spell the executable name \"GrandLine\" - that is B12, "
              + "\"Quit GrandLine\" in the captain's own menu bar. Got \(titles)", &ok)
        return ok
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
