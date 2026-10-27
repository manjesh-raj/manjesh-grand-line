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
//     "Overview" names nothing; and
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
        ok = checkQuickAccessCapAndOrder() && ok
        ok = checkQuickAccessRoundTrips() && ok
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
        ok = checkTheFeatureInventoryStaysWired() && ok
        ok = checkCopyNamesPlacesThroughPlaceName() && ok
        ok = checkTheMenuTargetsTheNavigator() && ok
        ok = checkTheShellHasNoForwards() && ok
        return ok
    }

    // MARK: R2-ARCH-05 - the menu reaches the navigator, and the shell forwards nothing

    /// Every main-menu item with a target must target an object that answers
    /// its action, in both layouts. The navigation verbs target the
    /// workspace's navigator and the layout's own verbs the shell - so a
    /// navigation item left on the shell after its forward was deleted would
    /// be a dead menu item, which is what this would catch. Built headless
    /// with stand-in targets (`MenuTargets`): a target is told apart by which
    /// stand-in it is, and its action is checked against the class it stands
    /// in for.
    private static func checkTheMenuTargetsTheNavigator() -> Bool {
        var ok = true
        let stored = AppDefaults.store.string(forKey: "fm.workspaceLayout")
        defer {
            if let stored { AppDefaults.store.set(stored, forKey: "fm.workspaceLayout") } else {
                AppDefaults.store.removeObject(forKey: "fm.workspaceLayout")
            }
        }
        for layout in WorkspaceLayout.allCases {
            AppSettings.shared.workspaceLayout = layout
            let shellMark = NSObject()
            let navigatorMark = NSObject()
            let menu = AppDelegate().buildMenu(installing: false,
                                               targets: MenuTargets(shell: shellMark, navigator: navigatorMark))
            var toNavigator = 0
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    if let sub = item.submenu { walk(sub) }
                    guard let action = item.action else { continue }
                    let navigatorAnswers = Navigator.instancesRespond(to: action)
                    let shellAnswers = layout.shellType.instancesRespond(to: action)
                    if item.target === navigatorMark {
                        toNavigator += 1
                        check(navigatorAnswers, "\(layout): \(item.title) targets the navigator, which has no \(action)", &ok)
                    } else if item.target === shellMark {
                        check(shellAnswers, "\(layout): \(item.title) targets the shell, which has no \(action) - a dead menu item", &ok)
                    } else if navigatorAnswers && !shellAnswers {
                        fail("\(layout): \(item.title) runs the navigator's \(action) but does not target it", &ok)
                    }
                }
            }
            walk(menu)
            // The fixture's own power: the menu really routes its navigation
            // verbs to the navigator, so a menu built with no targets at all
            // cannot pass.
            check(toNavigator >= 25, "\(layout): only \(toNavigator) menu items target the navigator", &ok)
        }
        if ok { print("  OK   R2-ARCH-05: every menu item targets an object that answers it, the navigator for navigation") }
        return ok
    }

    /// The shell used to carry about a hundred one-line forwards to the
    /// workspace's parts (`func openRunbook(id:) { workspace.navigator
    /// .openRunbook(id: id) }`). A member of the shell whose body only calls
    /// the same-named member on `workspace` or one of its parts is that
    /// shape again. A verb a layout overrides is the shell's own, whatever
    /// its base body is, so it is exempt. Debug-only test hooks are not
    /// production surface and are skipped.
    private static func checkTheShellHasNoForwards() -> Bool {
        var ok = true
        guard let dir = SelfTestSources.appSourceDirectory(),
              let shell = try? String(contentsOf: dir.appendingPathComponent("WorkspaceShellController.swift"), encoding: .utf8),
              let split = try? String(contentsOf: dir.appendingPathComponent("MainSplitShellController.swift"), encoding: .utf8),
              let classic = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8)
        else {
            fail("R2-ARCH-05: could not read the shells' sources - this check would silently pass", &ok)
            return ok
        }
        let guarded = E2ETestingPolicySelfTest.selfTestGuardedLines(shell)
        let production = zip(shell.components(separatedBy: "\n"), guarded).filter { !$0.1 }.map(\.0)
            .joined(separator: "\n")
        let declaration = #"(?m)^\s*(?:@objc\s+)?(?:@discardableResult\s+)?(?:static\s+)?(?:func|var)\s+([A-Za-z]+)"#
        guard let regex = try? NSRegularExpression(pattern: declaration) else { return false }
        let range = NSRange(production.startIndex..., in: production)
        var forwards: [String] = []
        var declared = 0
        for match in regex.matches(in: production, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: production),
                  let whole = Range(match.range, in: production) else { continue }
            declared += 1
            let name = String(production[nameRange])
            guard let open = production[whole.upperBound...].firstIndex(of: "{") else { continue }
            let body = FeatureInventorySelfTest.braceBody(production, from: production.index(after: open))
            let statements = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            let forwardsByName = statements.count <= 2 && statements.allSatisfy { line in
                line.range(of: #"^(get \{ |set \{ |return )?workspace(\.(navigator|hosts|lock|content))?\.\#(name)\b"#,
                           options: .regularExpression) != nil
            }
            let overridden = split.contains("override func \(name)") || classic.contains("override func \(name)")
                || split.contains("override var \(name)") || classic.contains("override var \(name)")
            if forwardsByName && !overridden { forwards.append(name) }
        }
        // The parse's own power: the shell still declares members for it to
        // read, so a file that moved or a broken pattern cannot pass empty.
        check(declared >= 20, "R2-ARCH-05: read only \(declared) declarations from the shell - the guard has lost its bearings", &ok)
        check(forwards.isEmpty, "R2-ARCH-05: the shell forwards to the workspace again: \(forwards.joined(separator: ", "))", &ok)
        if ok { print("  OK   R2-ARCH-05: the shell carries no one-line forwards to the workspace (\(declared) members read)") }
        return ok
    }

    // MARK: R2-BUG-06 - copy names a place the way the running layout does

    /// Copy kept naming the floating bar's map after the sidebar became the
    /// default: "on Bootstrap", "Install in Bootstrap", "Open Hosts", and a
    /// firstmate home "in Settings" that Settings never had. Every navigation
    /// sentence now names its target through `PlaceName`. Two halves: what
    /// `PlaceName` answers in each layout, and a source guard that no
    /// production string literal names a destination after a navigation
    /// word again.
    private static func checkCopyNamesPlacesThroughPlaceName() -> Bool {
        var ok = true
        let saved = PlaceName.layout
        defer { PlaceName.layout = saved }
        PlaceName.layout = .sidebar
        let sidebar = [PlaceName.of(.bootstrap), PlaceName.short(.bootstrap), PlaceName.of(.hosts),
                       PlaceName.of(.settings), PlaceName.of(.overview)]
        if sidebar != ["Setup \u{203A} Setup steps", "Setup steps", "Connections \u{203A} Hosts", "Settings",
                       "Crew \u{203A} In flight"] {
            fail("R2-BUG-06: the sidebar layout names its places \(sidebar)", &ok)
        }
        PlaceName.layout = .floatingBar
        let floating = [PlaceName.of(.bootstrap), PlaceName.short(.bootstrap), PlaceName.of(.hosts),
                        PlaceName.of(.overview)]
        if floating != ["Bootstrap", "Bootstrap", "Hosts", "Fleet"] {
            fail("R2-BUG-06: the floating bar names its places \(floating)", &ok)
        }

        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("app sources are not next to this binary - the copy guard would pass vacuously", &ok)
            return ok
        }
        // The names a sentence gets wrong in one layout or the other: every
        // destination whose place differs between the two (Bootstrap is
        // Setup › Setup steps, Hosts is Connections › Hosts, Fleet is Crew ›
        // In flight), and the two the review found pointing at the wrong
        // place altogether ("in Settings", "Open Setup").
        PlaceName.layout = .sidebar
        let moved = RailDestination.allCases.filter { PlaceName.of($0) != $0.title }.map(\.title)
        PlaceName.layout = saved
        let names = Set(moved + ["Settings", "Setup"])
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // A navigation word, then a destination's or a module's own name.
        // "copied from" and "came from" name where a clipboard entry came
        // from, not a place to go, and are left alone. R2-PROC-07 added
        // "Visit", "under" and "via", the three ways copy points somewhere
        // that the original words missed ("go to", "switch to" and "jump to"
        // already end in "to").
        let pattern = "\\b(?:in|on|to|Open|open|Go to|Visit|visit|under|Under|via|Via|(?<!copied )(?<!came )from)"
            + "\\s+(?:the\\s+)?(?:\(names))\\b"
        guard let navigation = try? NSRegularExpression(pattern: pattern),
              let literal = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) else {
            fail("R2-BUG-06: the copy guard's patterns do not compile", &ok)
            return ok
        }
        // The pattern has to catch what it exists to catch, or the sweep
        // below passes for nothing.
        let matches = { (text: String) in
            navigation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        for bad in ["Open Bootstrap", "set it again on Bootstrap", "Visit Hosts", "under Settings", "via the Fleet page",
                    "switch to Setup"] where !matches(bad) {
            fail("R2-PROC-07: the copy guard's pattern misses \"\(bad)\"", &ok)
        }
        for fine in ["copied from Hosts", "came from Fleet", "Bootstrap steps"] where matches(fine) {
            fail("R2-PROC-07: the copy guard's pattern flags \"\(fine)\", which names no place to go", &ok)
        }
        var offenders: [String] = []
        var scanned = 0
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // The menu bar (`MainMenuBuilder.swift` since R2-ARCH-02) and the ⌘K verbs name a feature under
        // its own name inside a menu or palette group of that name ("Log
        // Analyzer > Open Log Analyzer"), and the feature inventory keys
        // those rows by exactly that title - they are commands, not
        // directions to a place.
        let exempt: Set<String> = ["main.swift", "AppComposition.swift", "MainMenuBuilder.swift", "UnifiedSearchProviders.swift", "PlaceName.swift"]
        for file in files where file.pathExtension == "swift" && !exempt.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("*") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in literal.matches(in: line, range: range) {
                    scanned += 1
                    guard let span = Range(match.range, in: line) else { continue }
                    let string = String(line[span])
                    if navigation.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(string)")
                    }
                }
            }
        }
        if scanned < 1000 { fail("R2-BUG-06: the copy guard read only \(scanned) string literals - it reads nothing", &ok) }
        if !offenders.isEmpty {
            fail("R2-BUG-06: navigation copy names a place literally rather than through PlaceName: "
                 + offenders.joined(separator: "; "), &ok)
        }
        return ok
    }

    // MARK: The modular-shell migration's feature inventory

    /// Stage 1 of the modular-shell migration made the feature inventory the
    /// guard against losing a feature, and that guard is only as good as its
    /// wiring: a suite whose `FM_RUN_*` block is deleted from the dispatch
    /// still compiles and simply never runs (the runner discovers suites from
    /// that file), and an inventory that is moved fails every row at once
    /// rather than catching anything. This keeps both ends attached from a
    /// suite that already guards navigation.
    private static func checkTheFeatureInventoryStaysWired() -> Bool {
        var ok = true
        guard let main = SelfTestSources.selfTestDispatchSource() else {
            fail("modular shell: could not read SelfTestDispatch.swift - the inventory wiring check cannot run", &ok)
            return ok
        }
        for flag in ["FM_RUN_FEATURE_INVENTORY_TESTS", "FM_RUN_MODULE_TABLE_TESTS"] {
            check(main.contains("environment[\"\(flag)\"]"),
                  "modular shell: SelfTestDispatch.swift no longer dispatches \(flag), so the feature inventory is never checked", &ok)
        }
        let rows = FeatureInventorySelfTest.loadInventory() ?? []
        check(rows.count > 300, "modular shell: docs/modular-shell/feature-inventory.md is missing or nearly empty "
                + "(\(rows.count) rows)", &ok)
        // Every page the Go menu lists must be a row of the module table, so
        // the table cannot fall behind a new destination.
        for destination in RailDestination.allCases {
            check(ModuleTable.descriptor(for: destination) != nil,
                  "modular shell: \(destination.rawValue) has no ModuleTable row", &ok)
        }
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
            // `MainMenuBuilder.swift` (R2-ARCH-02; `main.swift` before) builds
            // the menu bar, where a character key equivalent is exactly right.
            guard !["main.swift", "AppComposition.swift", "MainMenuBuilder.swift"].contains(file.lastPathComponent) else { continue }
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
              "guard: nothing outside the menu builder sets `keyEquivalent` any more - either the "
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

    /// Home and Fleet name two things, and "Overview" names none.
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
    /// at. The things are named for what they are now: **Home** is the
    /// canvas and **Fleet** is the crew dashboard. (A third, **Today**, named
    /// the daily review page until that page was removed in
    /// `fm/grandline-remove-today-calendar-1792553365`.) "Overview" names
    /// nothing and is forbidden again.
    ///
    /// Comments are stripped before the search, so this file's own prose
    /// (and the several doc comments that explain the rename) do not fail
    /// the run. The stripping cuts at `//`, which also truncates a line
    /// carrying a URL - that only ever makes the guard more permissive,
    /// never a false alarm.
    private static func checkNavigationNamesAreDistinct() -> Bool {
        print("\n-- X3: Home and Fleet name two things, and \"Overview\" names none --")
        var ok = true

        // The behavioural half: two names, two things.
        let canvas = RailDestination.homeCanvas.title
        let fleet = RailDestination.overview.title
        check(canvas == "Home", "the canvas is called Home, got \(canvas)", &ok)
        check(fleet == "Fleet", "the crew dashboard is called Fleet, got \(fleet)", &ok)
        check(canvas != fleet,
              "the canvas and the fleet dashboard need distinct names, got \(canvas)/\(fleet)", &ok)

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
              "\"Overview\" names nothing in this app - the canvas is Home and "
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

        let hosts = AppDelegate.windowTitle(context: RailDestination.hosts.title)
        check(hosts == "\(bare) - Hosts", "expected \"\(bare) - Hosts\", got \"\(hosts)\"", &ok)
        check(hosts != bare, "...and it genuinely differs from the bare app name", &ok)

        // Two destinations must not produce the same title, or the whole
        // point (telling windows apart in Mission Control) is lost.
        let console = AppDelegate.windowTitle(context: RailDestination.console.title)
        check(console != hosts, "two destinations give two titles, both were \(hosts)", &ok)

        // A host page's own label, not the Hosts page's name.
        check(AppDelegate.windowTitle(context: "DEV Bastion") == "\(bare) - DEV Bastion",
              "a host page is titled by its own label", &ok)

        // Nothing dangling before the first navigation.
        check(AppDelegate.windowTitle(context: nil) == bare, "no context gives the bare app name", &ok)
        check(AppDelegate.windowTitle(context: "   ") == bare, "...and neither does a blank one", &ok)

        // The separator is a plain hyphen, matching the rest of this app's
        // copy - an em dash here would be the only one in the product.
        check(!hosts.contains("\u{2014}"), "the separator is a hyphen, not an em dash: \(hosts)", &ok)
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

    /// UX1's other half: a complete map nobody can open is still a map nobody
    /// can open.
    ///
    /// **This is a source guard because the defect it catches is invisible
    /// every other way.** `AppShellController.onShowAllDestinations` is an
    /// optional closure, ⌘K's "All Destinations…" verb is its only caller,
    /// and `main.swift` never assigned it - so the row rendered correctly,
    /// matched the captain's search correctly, highlighted correctly, and did
    /// nothing when invoked. Nothing failed: not a build, not a test, not a
    /// visual check. The bar's overflow menu carried a second row with the
    /// same defect, which is the one the captain reported
    /// (`fm/grandline-remove-dead-all-destinations-overflow`) and which was
    /// removed rather than repaired.
    ///
    /// Asserting the *assignment* rather than the behaviour is deliberate: the
    /// behaviour needs a real `AppDelegate`, which needs `NSApplication.shared`
    /// - and `NSApp` is nil in a headless suite, where reading it crashes
    /// rather than fails (AGENTS.md). The overlay's own behaviour is already
    /// covered above; what has no other witness is the wire.
    private static func checkTheMapIsActuallyReachable() -> Bool {
        var ok = true
        guard let main = SelfTestSources.appDelegateSource() else {
            fail("UX1: could not read the app delegate - this check would silently pass", &ok)
            return ok
        }
        // The sentinel first: a grep that matches nothing because the file
        // moved passes just as happily as one that matches because the wire
        // is there.
        check(main.contains("appShell.workspace.onSearchTapped ="),
              "UX1: main.swift no longer wires `onSearchTapped` either - this check has lost "
              + "its bearings and would pass vacuously", &ok)
        check(main.contains("appShell.onShowAllDestinations ="),
              "UX1: nothing in main.swift assigns `appShell.onShowAllDestinations`, so ⌘K's "
              + "\"All Destinations…\" is a dead row - it renders, matches and does nothing", &ok)
        return ok
    }

    // MARK: UX2

    private static func checkQuickAccessCapAndOrder() -> Bool {
        var ok = true
        // This case used to drive the *default* row, because the default was
        // the seven that shipped and therefore genuinely exceeded the cap.
        // Review U2 cut the default to four, and the comment that used to sit
        // here called that exact shot: "if the default ever shrinks to six,
        // every check below still passes while covering nothing." So the
        // overflow mechanism is driven from an explicit over-cap row now, and
        // the default's own size is asserted separately below as U2's claim
        // rather than as this mechanism's fixture.
        let shipped = QuickAccessConfiguration(pinned: [
            .stickyBoard, .codePreview, .shift, .strawHat, .poneglyph, .console, .hosts,
        ])
        check(shipped.pinned.count > QuickAccessConfiguration.visibleLimit,
              "UX2: the fixture row (\(shipped.pinned.count)) no longer exceeds the cap (\(QuickAccessConfiguration.visibleLimit)) - this suite's overflow checks are vacuous", &ok)
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

        // A fresh install pins the shipped seven, in the shipped order - U2's
        // brief cut to four (which removed Console, Hosts and Poneglyph) is
        // reverted, so the fixture above states the real default again
        // rather than an explicit over-cap row standing in for it.
        let fresh = QuickAccessConfiguration()
        check(fresh.pinned.count == 7,
              "a fresh install pins \(fresh.pinned.count) destinations, expected the shipped 7", &ok)
        check(fresh.overflow.count == 1,
              "the default row's overflow tail is \(fresh.overflow.count), expected the one icon past the cap of \(QuickAccessConfiguration.visibleLimit)", &ok)
        check(Array(QuickAccessConfiguration.defaultPinned)
              == [.stickyBoard, .codePreview, .shift, .strawHat, .poneglyph, .console, .hosts],
              "the default row was re-ordered rather than restored "
              + "(\(QuickAccessConfiguration.defaultPinned.map(\.rawValue)))", &ok)
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

    /// The captain asked for Clipboard History off the bar's shortcuts. Its
    /// square was a fixed bar control rather than a pinnable destination, so
    /// the removal is in `DaylightBarController` and its window-backed half
    /// is `BarNavigationModernizationSelfTest.test_clipboardHistoryIsOffTheBar`.
    /// This is the half that needs no window:
    ///
    ///   - the default row has no clipboard entry, and no destination exists
    ///     that would let Settings pin one back;
    ///   - a saved layout that names a clipboard entry (from a hand-edited
    ///     preference, or a build that had one) loads with that entry dropped
    ///     and every other shortcut kept, in its saved order - and re-saves
    ///     without it, so it does not come back on a downgrade-upgrade cycle;
    ///   - the feature is still reachable: the Edit menu's "Clipboard
    ///     History…" item is still there on ⇧⌘V, because once the square is
    ///     gone that item is the only way in;
    ///   - and that item follows Settings > Capture's switch, which is off by
    ///     default: hidden while the history is off (so ⇧⌘V does nothing and
    ///     no shortcut list prints it), shown once it is on.
    private static func checkClipboardHistoryIsNotAShortcut() -> Bool {
        var ok = true
        func isClipboard(_ raw: String) -> Bool { raw.localizedCaseInsensitiveContains("clipboard") }

        check(!QuickAccessConfiguration.defaultPinned.map(\.rawValue).contains(where: isClipboard),
              "the default shortcut row pins a clipboard entry: "
              + "\(QuickAccessConfiguration.defaultPinned.map(\.rawValue))", &ok)
        check(!RailDestination.allCases.map(\.rawValue).contains(where: isClipboard),
              "a clipboard destination exists, so Settings could pin it back onto the bar", &ok)
        check(!QuickAccessConfiguration().pinned.map(\.rawValue).contains(where: isClipboard),
              "a fresh install's shortcut row carries a clipboard entry", &ok)

        // A saved row with clipboard entries mixed into real shortcuts, in a
        // non-default order so a fall-back to the defaults cannot pass.
        let saved = #"{"pinned":["hosts","clipboardHistory","stickyBoard","clipboard","console","shift"]}"#
        let expected: [RailDestination] = [.hosts, .stickyBoard, .console, .shift]
        check(expected != Array(QuickAccessConfiguration.defaultPinned.prefix(expected.count)),
              "the saved-layout fixture matches the default row's prefix - a reset would pass vacuously", &ok)
        guard let migrated = try? JSONDecoder().decode(QuickAccessConfiguration.self,
                                                       from: Data(saved.utf8)) else {
            fail("a saved shortcut row naming Clipboard History failed to decode at all (GL-01) - "
                 + "the captain's whole layout would reset to the defaults", &ok)
            return ok
        }
        check(migrated.pinned == expected,
              "a saved row naming Clipboard History loaded as \(migrated.pinned.map(\.rawValue)), "
              + "expected \(expected.map(\.rawValue)) - the rest of the layout or its order was lost", &ok)
        if let data = try? JSONEncoder().encode(migrated),
           let text = String(data: data, encoding: .utf8) {
            check(!isClipboard(text), "the migrated row re-saves a clipboard entry: \(text)", &ok)
        } else {
            fail("the migrated shortcut row does not re-encode", &ok)
        }

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

        let before = AppSettings.shared.clipboardHistoryEnabled
        defer { AppSettings.shared.clipboardHistoryEnabled = before }
        func clipboardItem(_ menu: NSMenu) -> NSMenuItem? {
            menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Clipboard History\u{2026}" }
        }
        func listed(_ menu: NSMenu) -> Bool {
            KeyboardShortcutCatalog.menuItems(from: menu).flatMap(\.items)
                .contains { $0.title == "Clipboard History\u{2026}" }
        }
        AppSettings.shared.clipboardHistoryEnabled = false
        let delegate = AppDelegate()
        let offMenu = delegate.buildMenu(installing: false)
        check(clipboardItem(offMenu)?.isHidden == true,
              "with the clipboard history off, Edit > Clipboard History… is not hidden", &ok)
        check(!listed(offMenu), "a hidden Clipboard History… item is still listed as a shortcut", &ok)
        // The same delegate's item, re-shown by the preference rather than by
        // a rebuild - the path a Settings toggle takes.
        AppSettings.shared.clipboardHistoryEnabled = true
        delegate.applyClipboardHistoryMenuVisibility()
        check(clipboardItem(offMenu)?.isHidden == false,
              "with the clipboard history on, Edit > Clipboard History… is still hidden", &ok)
        check(listed(offMenu), "a visible Clipboard History… item is not listed as a shortcut", &ok)
        let onMenu = AppDelegate().buildMenu(installing: false)
        check(clipboardItem(onMenu)?.isHidden == false,
              "a menu built with the clipboard history on hides its item", &ok)
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

        // UX4's ⌘1-⌘5, which are the floating bar's spaces. R2-UX-02 took the
        // spaces out of the sidebar layout's menu; its number chords are the
        // sidebar's modules (`ReviewTwoUXModelSelfTest`).
        let floatingBound = allBindings(ReviewTwoUXModelSelfTest.mainMenu(for: .floatingBar))
        for index in 1...5 {
            check(floatingBound.contains(where: { $0.chord == "\u{2318}\(index)" }),
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
        // Each heading is the menu's own name, as the menu bar draws it. An
        // untitled bar item reports "NSMenuItem", and the sheet used to print
        // that above every section.
        let headings = sections.map(\.title)
        check(!headings.contains("NSMenuItem"),
              "UX3: a sheet heading reads \"NSMenuItem\" - it is the bar item's placeholder, not the menu's name: \(headings)", &ok)
        check(headings.first == AppPaths.displayName && headings.contains("File") && headings.contains("Edit"),
              "UX3: the sheet's headings are not the menu bar's own names: \(headings)", &ok)
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
        // Three steps, plus R2-UX-01 (b)'s profile choice in the sidebar
        // layout - the floating bar has no modules to choose between.
        let wantSteps = PlaceName.layout == .sidebar ? 4 : 3
        check(WelcomeSheetController.debugStepCount == wantSteps,
              "UX13: the sheet has \(WelcomeSheetController.debugStepCount) steps, want \(wantSteps)", &ok)
        check(sheet.debugStepIndex == 0, "UX13: the sheet should open on its first step", &ok)
        check(sheet.debugBackIsHidden, "UX13: there is nothing to go back to on the first step", &ok)
        check(!sheet.debugThemeGridIsHidden, "UX13: step one should show the theme picker", &ok)
        check(sheet.debugCommandWellIsHidden, "UX13: the lock command belongs on the last step only", &ok)

        sheet.debugNext()
        check(sheet.debugStepIndex == 1, "UX13: Next did not advance the sheet", &ok)
        check(!sheet.debugBackIsHidden, "UX13: Back should be available past the first step", &ok)
        check(sheet.debugThemeGridIsHidden, "UX13: the theme picker belongs on step one only", &ok)

        sheet.debugNext()
        if wantSteps == 4 { sheet.debugNext() }
        check(sheet.debugStepIndex == wantSteps - 1, "UX13: Next did not reach the last step", &ok)
        check(!sheet.debugCommandWellIsHidden,
              "UX13: the last step should show the lock-setup command", &ok)
        check(sheet.debugNextButtonTitle != "Next",
              "UX13: the last step's primary button should not still say Next", &ok)

        sheet.debugBack()
        check(sheet.debugStepIndex == wantSteps - 2, "UX13: Back did not go back", &ok)
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
