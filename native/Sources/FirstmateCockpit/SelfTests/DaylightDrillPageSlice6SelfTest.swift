// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 6**'s own suite: the last two destinations in §7's
// table, Tools and Settings.
//
// What each case is protecting, and why it is worth a test rather than a
// read-through:
//
//   1. **Both pages really reached the drill header** (§6.4). The seam is a
//      protocol conformance, and a missing one is invisible - the header just
//      renders the static per-area line, which looks like a design choice.
//      Tools' half is the live one: its subtitle counts open tool tabs.
//   2. **Neither renders its old in-page caption any more** (§6.4). Both said
//      almost exactly what the drill header one row above them now says, which
//      is the duplicate-title defect slices 1 and 2 corrected on Review and
//      Health. Walked over the real view tree, by string, because a stale
//      label is easy to leave behind and impossible to see in a diff.
//   3. **Tools' landing grid is the real `HelmModuleCard`** under Daylight and
//      the pre-Daylight card on the other twelve (§7's "module-style plates").
//      Asserted through the component's own anatomy - ribbon, gradient tile,
//      one uniform height - because a hand-rolled lookalike would pass a
//      "there are nine views" check and then drift from the hub a rail click
//      away. The plate's click really opens a new tab, driven through the same
//      `HoverHighlightView` press path a keyboard or VoiceOver activation uses.
//   4. **A plate's four-line description actually fits.** `HelmModuleCard`
//      caps its own height, so a note longer than the body area is *clipped*,
//      silently. This slice raised the cap from `HelmModuleCard`'s default 2 to
//      4 for exactly this grid, so the number is measured here - at the
//      narrowest real column and at every chrome text scale - rather than
//      assumed.
//   5. **Code editors are wells** (§7's "mono on `inset` wells"). The failure
//      that matters is repainting Daylight's `paper` instead: a code area would
//      then be the same colour as the page and have no boundary against the
//      card it sits in.
//   6. **Settings' page structure is a pure function of the captain's own
//      navigation, never of the theme.** This case has been through two
//      shapes. It began as §7's two-column threshold, then documented
//      `fm/grandline-settings-layout-theme-dependent-fix`'s correction to it
//      (the threshold used to also require `theme.isDaylight`, so switching
//      between a Daylight theme and a legacy one at the same window size
//      restructured the page). `fm/grandline-settings-page-sidebar-redesign`
//      then replaced the two-column arrangement entirely: Settings is a
//      sidebar-navigated master/detail page, and the detail pane stacks one
//      category's cards in a single capped column. The **property** is
//      unchanged and is what the case still asserts - the same category
//      shows the same cards at the same widths on every palette.
//      `SettingsThemeLayoutParitySelfTest` is the dedicated suite sweeping
//      all fourteen; `SettingsSidebarNavigationSelfTest` is the one that
//      proves the navigation itself works.
//   7. **`HelmToggle` shows the pill on Daylight and a real `NSSwitch`
//      elsewhere**, moves its knob, and writes through to `AppSettings` - the
//      whole point of replacing the control is that it still is one.
//   8. **Settings' status pill is the shared one** (§6.7). Its private copy
//      painted a hue as its own label over a wash of itself, the audit's §5.7
//      defect - the same copy slice 2 deleted from Health. This was the last
//      one, so it is measured (contrast floor) and source-guarded.
//   9. **No new window-width floor.** AGENTS.md gotcha (13) is this
//      codebase's most expensive recurring bug, and Settings has been a
//      repeat offender. `AppShellBodyWidthSelfTest` is the broad sweep; this is
//      the local one for the two pages just touched, on Daylight, which that
//      sweep does not select.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE6_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice6SelfTest {

    /// How many cards Settings builds, stated **once** for this whole file.
    ///
    /// Ten since F21 (`fm/grandline-feature-f21-f24-intents-import-export`)
    /// gave "Shortcuts & Siri" its own card, beside compact mode's; nine since
    /// F22 (`fm/grandline-feature-f22-menu-bar-mode`) gave compact
    /// mode its own card, immediately before Security; eight since
    /// `fm/grandline-feature-f20-daily-review-briefing` gave F20's daily
    /// review its own, immediately after F12's morning briefing; seven before
    /// that, since `fm/grand-line-terminal-shortcuts-settings` gave the
    /// Console's configurable shortcuts theirs.
    ///
    /// A literal rather than a derived count on purpose: this is the setup
    /// every column assertion in this file is measured against, and a card
    /// quietly appearing or vanishing should have to come here and say so.
    /// One named constant rather than the four scattered copies this had
    /// before, because F20 and F22 landed a day apart and each had to find and
    /// move all of them - the second of the two then hit a merge conflict in
    /// every copy.
    private static let expectedCardCount = 11


    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, checkOldCaptionsAreGone,
                      checkToolsGridUsesModulePlates, checkPlateNoteFits,
                      checkPlatesDoNotAccumulate,
                      checkCodeEditorsAreWells, checkSettingsDetailPaneIsThemeIndependent,
                      checkToggleRecipe, checkSharedPill, checkNoWindowWidthFloor,
                      checkSettingsRendersOnFirstLoad] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSlice6SelfTest: all checks passed"
                    : "DaylightDrillPageSlice6SelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylight: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static var otherTheme: HelmTheme {
        HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// Scratch store files, so nothing here can reach the captain's real data
    /// (the convention every store-backed suite in this repo follows).
    private static func scratchStores() -> (HostStore, SSHKeyStore, SnippetStore, DictationStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-slice6-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        return (HostStore(), SSHKeyStore(), SnippetStore(), DictationStore())
    }

    private static func makeSettings() -> SettingsController {
        let (hosts, keys, snippets, dictation) = scratchStores()
        return SettingsController(hostStore: hosts, keyStore: keys,
                                  snippetStore: snippets, dictationStore: dictation)
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1400) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: 900)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += descendants(type, in: sub) }
        return found
    }

    private static func allLabelTexts(in view: NSView) -> [String] {
        var found: [String] = []
        if let label = view as? NSTextField { found.append(label.stringValue) }
        for sub in view.subviews { found += allLabelTexts(in: sub) }
        return found
    }

    /// Component-wise, deliberately **not** a luminance-ratio comparison: that
    /// passes for two entirely different hues of similar brightness (the trap
    /// slice 2's own suite documents).
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    // MARK: 1. Both pages reached the drill header (§6.4)

    private static func checkDrillConformances(_ ok: inout Bool) {
        print("\n-- §6.4: Tools and Settings carry drill headers --")

        let tools = ToolsController()
        let toolsWindow = mount(tools)
        defer { _ = toolsWindow }

        guard let idle = tools.drillHeaderSubtitle else {
            print("  FAIL Tools reports no drill subtitle")
            ok = false
            return
        }
        if !idle.contains("\(ToolKind.allCases.count)") || !idle.contains("nothing open") {
            print("  FAIL Tools' idle subtitle does not report the catalogue and an empty tab set: \"\(idle)\"")
            ok = false
        }
        if !tools.drillHeaderActions.isEmpty {
            print("  FAIL Tools hoisted \(tools.drillHeaderActions.count) action(s); its toolbar keeps them (§6.13's rule)")
            ok = false
        }

        // The live half: the subtitle has to follow the tab set, and the page
        // has to *say* so - the shell only re-reads when told.
        var subtitleNotifications = 0
        tools.onDrillSubtitleChanged = { subtitleNotifications += 1 }
        let before = subtitleNotifications
        openFirstPlate(in: tools)
        guard tools.debugTabCount == 1 else {
            print("  FAIL opening a plate did not create a tab (\(tools.debugTabCount))")
            ok = false
            return
        }
        if subtitleNotifications <= before {
            print("  FAIL Tools never told the shell its subtitle moved after a tab opened")
            ok = false
        }
        guard let withTab = tools.drillHeaderSubtitle, withTab.contains("1 open") else {
            print("  FAIL Tools' subtitle does not report its open tab: \"\(tools.drillHeaderSubtitle ?? "nil")\"")
            ok = false
            return
        }
        print("  ok   Tools: \"\(idle)\" -> \"\(withTab)\", 0 hoisted actions")

        let settings = makeSettings()
        let settingsWindow = mount(settings)
        defer { _ = settingsWindow }
        guard let line = settings.drillHeaderSubtitle, line.contains("locally") else {
            print("  FAIL Settings' subtitle does not carry the local-storage claim: \"\(settings.drillHeaderSubtitle ?? "nil")\"")
            ok = false
            return
        }
        if !settings.drillHeaderActions.isEmpty {
            print("  FAIL Settings hoisted \(settings.drillHeaderActions.count) action(s); every action here belongs to one card")
            ok = false
        }
        print("  ok   Settings: \"\(line)\", 0 hoisted actions")
    }

    /// Fires the first landing plate's own primary action - the same path a
    /// click, a Return press and a VoiceOver activation all take.
    private static func openFirstPlate(in tools: ToolsController) {
        if let plate = descendants(HelmModuleCard.self, in: tools.view).first {
            _ = plate.debugActivate()
            return
        }
        // The pre-Daylight card is a plain `HoverHighlightView` carrying the
        // tool's raw value as its identifier.
        for card in descendants(HoverHighlightView.self, in: tools.view)
        where card.identifier.flatMap({ ToolKind(rawValue: $0.rawValue) }) != nil {
            _ = card.performPrimaryAction()
            return
        }
    }

    // MARK: 2. The old in-page captions are gone (§6.4)

    private static func checkOldCaptionsAreGone(_ ok: inout Bool) {
        print("\n-- §6.4: no page repeats its own drill header --")
        let cases: [(String, NSViewController, [String])] = [
            ("Tools", ToolsController(), ["Everyday DevOps utilities"]),
            ("Settings", makeSettings(), ["Connection, appearance, and terminal"]),
        ]
        for (name, controller, banned) in cases {
            let window = mount(controller)
            defer { _ = window }
            let texts = allLabelTexts(in: controller.view)
            for phrase in banned where texts.contains(where: { $0.contains(phrase) }) {
                print("  FAIL \(name) still renders its old caption (\"\(phrase)\") under the drill header")
                ok = false
            }
            if ok { print("  ok   \(name): caption deleted, \(texts.count) labels scanned") }
        }
    }

    // MARK: 3. Tools' landing grid is the real module plate (§7)

    private static func checkToolsGridUsesModulePlates(_ ok: inout Bool) {
        print("\n-- §7: Tools' landing grid uses module-style plates --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        ThemeManager.shared.setTheme(daylight)
        let tools = ToolsController()
        let window = mount(tools)
        defer { _ = window }
        tools.view.layoutSubtreeIfNeeded()

        let plates = descendants(HelmModuleCard.self, in: tools.view)
        guard plates.count == ToolKind.allCases.count else {
            print("  FAIL Daylight grid has \(plates.count) plates, want \(ToolKind.allCases.count)")
            ok = false
            return
        }
        var heights = Set<CGFloat>()
        for plate in plates {
            let anatomy = plate.anatomyForTests
            if !anatomy.hasRibbon || anatomy.ribbonStopCount != 2 {
                print("  FAIL a plate has no two-stop hue ribbon (§6.1)")
                ok = false
            }
            if !anatomy.hasTile {
                print("  FAIL a plate has no gradient tile (§6.1)")
                ok = false
            }
            if !anatomy.isCardActivatable || (anatomy.accessibilityLabel ?? "").isEmpty {
                print("  FAIL a plate is not an activatable, labelled button")
                ok = false
            }
            heights.insert((anatomy.cardHeight * 10).rounded() / 10)
        }
        if heights.count != 1 {
            print("  FAIL plates resolved to \(heights.count) different heights: \(heights.sorted())")
            ok = false
        }

        // Each tool keeps its own identity hue, re-expressed rather than
        // re-invented: the nine `ToolKind.tint` slots map 1:1 onto hues.
        let hues = Set(ToolKind.allCases.map { HelmDomainHue(tint: $0.tint) })
        if hues.count < 4 {
            print("  FAIL the nine plates resolve to only \(hues.count) distinct hues")
            ok = false
        }

        // Clicking a plate opens a *new* tab of that kind - never re-selects.
        openFirstPlate(in: tools)
        openFirstPlate(in: tools)
        if tools.debugTabCount != 2 {
            print("  FAIL two plate activations produced \(tools.debugTabCount) tabs, want 2")
            ok = false
        }

        // The other twelve keep the card they always had.
        ThemeManager.shared.setTheme(otherTheme)
        let legacy = ToolsController()
        let legacyWindow = mount(legacy)
        defer { _ = legacyWindow }
        legacy.view.layoutSubtreeIfNeeded()
        let legacyPlates = descendants(HelmModuleCard.self, in: legacy.view)
        if !legacyPlates.isEmpty {
            print("  FAIL \(otherTheme.id) renders \(legacyPlates.count) Daylight plates; the twelve must be untouched")
            ok = false
        }
        if ok {
            print("  ok   \(plates.count) plates, one height (\(fmt(heights.first ?? 0))), \(hues.count) hues, 0 on \(otherTheme.id)")
        }
    }

    // MARK: 4. The plate's four-line note fits its card (§6.1)

    private static func checkPlateNoteFits(_ ok: inout Bool) {
        print("\n-- §6.1: a plate's description fits its card at every text scale --")
        let restoreTheme = ThemeManager.shared.theme
        let restoreScale = ChromeTextScale.shared.scale
        defer {
            ThemeManager.shared.setTheme(restoreTheme)
            ChromeTextScale.shared.setScale(restoreScale)
        }
        ThemeManager.shared.setTheme(daylight)

        // The narrowest column the grid ever builds one plate at.
        let narrowest = ToolsController.minPlateWidthForTests
        let longest = ToolKind.allCases.max { $0.description.count < $1.description.count }!
        let maxLines = ToolsController.plateNoteLinesForTests

        let window = OffScreenProbe.window(width: 1200, height: 700, styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        defer { window.close() }

        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            let plate = HelmModuleCard()
            plate.configure(HelmModuleCard.Content(
                title: longest.title, subtitle: longest.shortName, symbol: longest.symbol,
                hue: HelmDomainHue(tint: longest.tint), chip: nil,
                body: .note(longest.description, maxLines: maxLines)))
            plate.applyTheme(daylight)
            host.addSubview(plate)
            let widthConstraint = plate.widthAnchor.constraint(equalToConstant: narrowest)
            widthConstraint.priority = HelmDaylightPriority.contentTie
            NSLayoutConstraint.activate([
                widthConstraint,
                plate.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                plate.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            // **Twice, and that is not belt-and-braces.** `applyNoteWrapWidth`
            // runs in the card's own `layout()` and assigns
            // `preferredMaxLayoutWidth`, which invalidates the label's
            // intrinsic size and schedules another pass. The first pass
            // therefore settles on a *one-line* label; the card's height is
            // derived from its content since PF2, so it is the second pass
            // that produces the real number. The app gets this for free (the
            // scheduled pass runs); a test that lays out once does not.
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()

            let anatomy = plate.anatomyForTests
            // PF2 replaced the fixed height with a floor plus per-row
            // equalisation, so "every plate is exactly `standardHeight`" is
            // deliberately no longer true. The floor is what is left of that
            // contract.
            if anatomy.cardHeight < HelmModuleCard.minimumHeight - 0.5 {
                print("  FAIL \(step.title): plate resolved to \(fmt(anatomy.cardHeight)), below the floor "
                    + "minimumHeight (\(fmt(HelmModuleCard.minimumHeight)))")
                ok = false
            }
            // **What replaced the worst-case check, and why it is stronger.**
            // This used to reserve `maxLines` full lines in every plate,
            // because with a fixed card height the only way a long
            // description could be safe was for every card to carry room for
            // one. A content-sized card does not need that - it grows - so
            // the honest check is that the description *this fixture actually
            // renders* fits, using the longest one in the real catalogue and
            // the count of lines the label really laid out. That is a measured
            // number rather than an upper bound, and it fails for the same
            // reason the old one did: a body clipped at the width the grid
            // really builds plates at.
            let lineHeight = NSLayoutManager().defaultLineHeight(for: HelmType.caption())
            let renderedLines = anatomy.noteRenderedLineCounts.first ?? 0
            let needed = lineHeight * CGFloat(renderedLines)
            if needed > anatomy.bodyAreaHeight + 0.5 {
                print("  FAIL \(step.title) (x\(step.scale)) at \(fmt(narrowest))pt: \(renderedLines) "
                    + "rendered line(s) need \(fmt(needed)) of \(fmt(anatomy.bodyAreaHeight)) "
                    + "- the description is clipped")
                ok = false
            } else {
                print("  ok   \(step.title): \(renderedLines) of \(maxLines) line(s) need \(fmt(needed)) "
                    + "of \(fmt(anatomy.bodyAreaHeight)) at \(fmt(narrowest))pt "
                    + "(card \(fmt(anatomy.cardHeight)))")
            }

            // Review #3, B7, and the half the bound above cannot see: a note
            // label that is `.byTruncatingTail` renders **one** line however
            // many `maximumNumberOfLines` allows, so every assertion here
            // passed while the longest description on the page showed as
            // "Compare two files line by li..." inside a body sized for four
            // lines. Read what rendered.
            let rendered = anatomy.noteRenderedLineCounts.first ?? 0
            // Vacuity guard: this only means anything while the fixture's own
            // description genuinely cannot fit on one line at this width. If a
            // future catalogue's longest tool description gets short, say so
            // rather than reporting a pass for a check that stopped checking.
            let oneLine = (longest.description as NSString)
                .size(withAttributes: [.font: HelmType.caption()]).width
            if oneLine <= narrowest {
                print("  NOTE the longest description now fits one line at \(fmt(narrowest))pt; "
                    + "the wrap check has nothing to measure")
            } else if rendered < 2 {
                print("  FAIL \(step.title): the note rendered \(rendered) line(s) at \(fmt(narrowest))pt - "
                    + "a \(longest.description.count)-character description cannot fit on one; "
                    + "the label is truncating rather than wrapping")
                ok = false
            } else if rendered > maxLines {
                print("  FAIL \(step.title): the note rendered \(rendered) lines, past its own cap of \(maxLines)")
                ok = false
            } else {
                print("  ok   \(step.title): the note really wraps (\(rendered) of \(maxLines) lines)")
            }
            plate.removeFromSuperview()
        }

        // And the real page really does hand the whole description over -
        // truncation, if it ever happens, is the label's business and not a
        // string this page shortened on the way in.
        let tools = ToolsController()
        let toolsWindow = mount(tools, width: 1100)
        defer { _ = toolsWindow }
        tools.view.layoutSubtreeIfNeeded()
        let notes = Set(descendants(HelmModuleCard.self, in: tools.view).flatMap { $0.anatomyForTests.noteTexts })
        for kind in ToolKind.allCases where !notes.contains(kind.description) {
            print("  FAIL \(kind.rawValue)'s plate does not carry its full description")
            ok = false
        }
    }

    // MARK: 4b. The grid's plates do not accumulate across rebuilds

    /// `HelmModuleCard` registers its own `ThemeManager` and Reduce Motion
    /// observers per instance, and this slice put nine of them on a grid that
    /// rebuilds on every window resize while the picker is showing. The canvas
    /// has the same shape and its own leak coverage; this is the local one for
    /// the surface just added.
    ///
    /// Each iteration gets its own `autoreleasepool` - without one a headless
    /// suite never drains, and removed views read as still-alive, which looks
    /// exactly like a retain cycle. That lesson is written up in
    /// `AppShellBodyWidthSelfTest`'s header and cost real time twice.
    private static func checkPlatesDoNotAccumulate(_ ok: inout Bool) {
        print("\n-- plate churn: a resizing grid does not leak cards --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)

        autoreleasepool {
            let tools = ToolsController()
            let window = mount(tools, width: 1400)
            defer { _ = window }
            tools.view.layoutSubtreeIfNeeded()

            var baseline = 0
            autoreleasepool { tools.debugRelayoutGrid(containerWidth: 1200) }
            autoreleasepool { baseline = HelmModuleCard.debugLiveInstanceCount }
            for width in stride(from: CGFloat(700), through: 1600, by: 100) {
                autoreleasepool { tools.debugRelayoutGrid(containerWidth: width) }
            }
            var after = 0
            autoreleasepool { after = HelmModuleCard.debugLiveInstanceCount }
            if after > baseline {
                print("  FAIL live plates grew \(baseline) -> \(after) over 10 rebuilds")
                ok = false
            } else {
                print("  ok   live plates \(baseline) -> \(after) over 10 rebuilds")
            }
        }
    }

    // MARK: 5. Code editors are `inset` wells (§7)

    private static func checkCodeEditorsAreWells(_ ok: inout Bool) {
        print("\n-- §7: Tools' code editors keep mono on `inset` wells --")
        for theme in [daylight, otherTheme] {
            let tool = ToolInstance(kind: .yaml, name: "YAML", theme: theme, toastHost: nil)
            tool.applyTheme(theme)
            let scrolls = tool.debugEditorScrollViews
            let views = tool.debugEditorTextViews
            guard !scrolls.isEmpty, !views.isEmpty else {
                print("  FAIL the YAML panel exposes no code editors")
                ok = false
                return
            }
            let wantRadius = theme.isDaylight ? HelmField.cornerRadius(for: theme) : 8
            let wantFill = theme.isDaylight ? HelmField.fill(theme) : HelmTheme.nsColor(theme.backgroundHex)
            for scroll in scrolls {
                let radius = scroll.layer?.cornerRadius ?? 0
                if abs(radius - wantRadius) > 0.01 {
                    print("  FAIL \(theme.id): editor radius \(fmt(radius)), want \(fmt(wantRadius))")
                    ok = false
                }
                if !sameColor(scroll.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, wantFill) {
                    print("  FAIL \(theme.id): editor fill is not the expected token")
                    ok = false
                }
            }
            for view in views {
                if !sameColor(view.backgroundColor, wantFill) {
                    print("  FAIL \(theme.id): the text view's own background disagrees with its well")
                    ok = false
                }
                if !(view.font?.isFixedPitch ?? false) {
                    print("  FAIL \(theme.id): a code editor is not monospaced")
                    ok = false
                }
            }
            // Daylight's `inset` must not be its `paper`: a code area painted
            // with the page colour has no boundary against the card behind it.
            if theme.isDaylight,
               sameColor(HelmField.fill(theme), HelmTheme.nsColor(theme.backgroundHex)) {
                print("  FAIL Daylight's editor well resolves to the page background")
                ok = false
            }
            print("  ok   \(theme.id): \(scrolls.count) editors at radius \(fmt(wantRadius))")
        }
    }

    // MARK: 6. Settings' detail pane (§7's two-column arrangement, replaced
    // by the sidebar redesign in `fm/grandline-settings-page-sidebar-redesign`)

    /// **This case used to assert §7's two-column card layout.** That layout
    /// is gone: Settings is now a sidebar-navigated master/detail page, and
    /// the detail pane stacks one category's cards in a single capped column.
    ///
    /// What the case is *for* has not changed, and it is the thing
    /// `fm/grandline-settings-layout-theme-dependent-fix` established -
    /// **selecting a theme changes colours and never structure.** The
    /// structural property being asserted is simply the new one: the same
    /// category shows the same cards, at the same width, whichever theme is
    /// active, and the pane never falls back to a second column.
    private static func checkSettingsDetailPaneIsThemeIndependent(_ ok: inout Bool) {
        print("\n-- §7: Settings' detail pane is category-driven, not theme-driven --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        ThemeManager.shared.setTheme(daylight)
        let settings = makeSettings()
        let window = mount(settings, width: 1500)
        defer { _ = window }
        settings.view.layoutSubtreeIfNeeded()

        // See `expectedCardCount` for the number and why it is a literal.
        // Every other card count in this file derives from this one.
        guard settings.debugCards.count == expectedCardCount else {
            print("  FAIL Settings has \(settings.debugCards.count) cards, "
                  + "want \(expectedCardCount)")
            ok = false
            return
        }
        // Every card belongs to exactly one category, so the seven panes
        // partition the ten cards. A card added without a category would be
        // unreachable, which is the one thing this redesign must never do.
        let mapped = SettingsController.Category.allCases.flatMap { settings.debugCards(in: $0) }
        if mapped.count != settings.debugCards.count {
            print("  FAIL \(mapped.count) of \(settings.debugCards.count) cards are reachable from a category")
            ok = false
        }

        // The fingerprint: for each category, which cards the pane holds and
        // how wide it lays them out.
        func fingerprint(_ page: SettingsController) -> [String] {
            SettingsController.Category.allCases.map { category in
                page.select(category)
                page.view.layoutSubtreeIfNeeded()
                let widths = page.debugMountedCards.map { ($0.frame.width * 10).rounded() / 10 }
                let xs = Set(page.debugMountedCards.compactMap { card in
                    card.superview.map { ((($0.convert(card.frame.origin, to: page.view)).x) * 10).rounded() / 10 }
                })
                return "\(category.rawValue):\(page.debugMountedCards.count) w=\(widths) x=\(xs.sorted())"
            }
        }

        let daylightPrint = fingerprint(settings)
        // One column means one distinct leading edge per pane, always.
        for category in SettingsController.Category.allCases {
            settings.select(category)
            settings.view.layoutSubtreeIfNeeded()
            let xs = Set(settings.debugMountedCards.compactMap { card in
                card.superview.map { ((($0.convert(card.frame.origin, to: settings.view)).x) * 10).rounded() / 10 }
            })
            if xs.count != 1 {
                print("  FAIL \(category.rawValue) laid its cards at \(xs.count) distinct x positions, want 1: \(xs.sorted())")
                ok = false
            }
            for card in settings.debugMountedCards where card.window == nil {
                print("  FAIL \(category.rawValue) orphaned a card on selection")
                ok = false
            }
        }

        ThemeManager.shared.setTheme(otherTheme)
        let legacy = makeSettings()
        let legacyWindow = mount(legacy, width: 1500)
        defer { _ = legacyWindow }
        legacy.view.layoutSubtreeIfNeeded()
        let legacyPrint = fingerprint(legacy)

        // Discriminating power first (AGENTS.md: a check that cannot fail is
        // worse than no check) - the fingerprint has to distinguish
        // *something*, or matching proves nothing.
        if Set(daylightPrint).count < 2 {
            print("  FAIL the fingerprint is vacuous - every category reads identically: \(daylightPrint)")
            ok = false
        }
        if daylightPrint != legacyPrint {
            print("  FAIL \(otherTheme.id) lays the panes out differently from Daylight at the same width")
            print("       daylight: \(daylightPrint)")
            print("       \(otherTheme.id): \(legacyPrint)")
            ok = false
        }

        if ok { print("  ok   seven panes, one column each, identical on Daylight and \(otherTheme.id) at 1500pt") }
    }

    // MARK: 7. `HelmToggle` (§6.9)

    private static func checkToggleRecipe(_ ok: inout Bool) {
        print("\n-- §6.9: the toggle recipe --")
        let toggle = HelmToggle()

        toggle.applyTheme(daylight)
        var geometry = toggle.debugGeometry
        if !geometry.showsPill || geometry.showsFallbackSwitch {
            print("  FAIL Daylight does not show the pill (pill=\(geometry.showsPill), switch=\(geometry.showsFallbackSwitch))")
            ok = false
        }
        if abs(geometry.pillRadius - geometry.pillSize.height / 2) > 0.01 {
            print("  FAIL the pill is not a capsule: radius \(fmt(geometry.pillRadius)) of height \(fmt(geometry.pillSize.height))")
            ok = false
        }
        if geometry.knobSide >= geometry.pillSize.height {
            print("  FAIL the knob (\(fmt(geometry.knobSide))) does not fit inside the pill (\(fmt(geometry.pillSize.height)))")
            ok = false
        }
        let offLeading = geometry.knobLeading
        toggle.isOn = true
        geometry = toggle.debugGeometry
        if geometry.knobLeading <= offLeading {
            print("  FAIL the knob did not travel on: \(fmt(offLeading)) -> \(fmt(geometry.knobLeading))")
            ok = false
        }
        if !sameColor(geometry.pillFill, HelmTheme.nsColor(DaylightPalette.ok)) {
            print("  FAIL the on state is not §6.9's `ok` fill")
            ok = false
        }

        // Inverted by the UI modernization audit's E5, which settles the open
        // captain decision this assertion used to record.
        //
        // Phase 4 slice 6 shipped the pill on Daylight/Dusk only and kept the
        // stock `NSSwitch` on the twelve legacy palettes deliberately -
        // answering "should every theme get a bespoke toggle?" was not that
        // slice's to make. §3E made the case (the stock switch beside themed
        // everything is chrome bleed-through, and the captain's own daily
        // palette is a legacy dark one) and the captain asked for the fix, so
        // the pill now renders on all fourteen. Kept as an assertion rather
        // than deleted, because "every theme shows the pill" is exactly what
        // a future regression would quietly undo.
        toggle.applyTheme(otherTheme)
        geometry = toggle.debugGeometry
        if !geometry.showsPill || geometry.showsFallbackSwitch {
            print("  FAIL \(otherTheme.id) does not show the pill (pill=\(geometry.showsPill), "
                  + "switch=\(geometry.showsFallbackSwitch)) - E5 settled this: HelmToggle everywhere")
            ok = false
        }
        if !sameColor(geometry.pillFill, HelmTheme.nsColor(HelmTint.good.hex(in: otherTheme))) {
            print("  FAIL \(otherTheme.id)'s on state is not the theme's own `.good` fill")
            ok = false
        }

        // It is still a control: a press flips it, reports it once, and reads
        // back through `isOn`.
        var fired = 0
        toggle.onToggle = { fired += 1 }
        toggle.isOn = false
        _ = toggle.accessibilityPerformPress()
        if !toggle.isOn || fired != 1 {
            print("  FAIL an accessibility press did not toggle exactly once (isOn=\(toggle.isOn), fired=\(fired))")
            ok = false
        }
        if toggle.accessibilityRole() != .checkBox || (toggle.accessibilityValue() as? Int) != 1 {
            print("  FAIL the toggle does not report checkbox semantics with a live value")
            ok = false
        }

        // And Settings' toggles really are all of them, and really write
        // through. Eight since F22 added compact mode's three; five since F20
        // added its own pair (the card, and its calendar column); three
        // before that (auto-reconnect, notifications, the morning briefing).
        // The count is asserted rather than ignored for the same reason the
        // card count above is: a toggle that appears without coming here is a
        // toggle nothing has checked renders as a Daylight pill rather than a
        // bare `NSSwitch`, which is exactly what the last check in this case
        // is about.
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = settings.view.window.map { _ in () }; _ = window }
        if settings.debugToggles.count != 8 {
            print("  FAIL Settings exposes \(settings.debugToggles.count) toggles, want 8")
            ok = false
        }
        let before = AppSettings.shared.autoReconnect
        defer { AppSettings.shared.autoReconnect = before }
        settings.debugToggles[0].isOn = !before
        _ = settings.debugToggles[0].accessibilityPerformPress()
        _ = settings.debugToggles[0].accessibilityPerformPress()
        if AppSettings.shared.autoReconnect != !before {
            print("  FAIL the reconnect toggle no longer writes through to AppSettings")
            ok = false
        }
        if descendants(NSSwitch.self, in: settings.view).contains(where: { !$0.isHidden }) {
            print("  FAIL a bare NSSwitch is still visible on Daylight")
            ok = false
        }
        if ok {
            print("  ok   the pill on Daylight and on \(otherTheme.id) (E5), "
                  + "\(settings.debugToggles.count) wired toggles")
        }
    }

    // MARK: 8. Settings' pill is the shared one (§6.7)

    private static func checkSharedPill(_ ok: inout Bool) {
        print("\n-- §6.7: no private pill copy survives on Settings --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP could not locate the app sources")
            return
        }
        let path = dir.appendingPathComponent("SettingsController.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            print("  SKIP could not read SettingsController.swift")
            return
        }
        // The signature of the deleted copy: a hue used as its own label over a
        // 15% wash of itself.
        for marker in ["withAlphaComponent(0.15)", "label.textColor = HelmTheme.nsColor(colorHex)"]
        where source.contains(marker) {
            print("  FAIL SettingsController still hand-rolls a chip (\(marker))")
            ok = false
        }
        if !source.contains("ToolRowLayout.pill(") {
            print("  FAIL SettingsController does not route its chip through the shared pill")
            ok = false
        }
        // And the shared one really does clear the text floor on every theme,
        // for the one status this page paints.
        for theme in HelmTheme.allThemes {
            let resolved = HelmContrast.tintedSurface(tintHex: theme.ansiHex[2], theme: theme,
                                                      target: HelmContrast.textTarget)
            let ratio = HelmContrast.ratio(resolved.foreground, resolved.fill)
            if ratio < HelmContrast.textTarget - 0.01 {
                print("  FAIL \(theme.id): the Enabled chip measures \(fmt(ratio)):1")
                ok = false
            }
        }
        if ok { print("  ok   shared pill only, all \(HelmTheme.allThemes.count) themes clear the text floor") }
    }

    // MARK: 9. No new window-width floor (AGENTS.md gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): neither page caps the window --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)

        for (name, controller) in [("Tools", ToolsController() as NSViewController),
                                   ("Settings", makeSettings() as NSViewController)] {
            let window = OffScreenProbe.window(width: 1500, height: 900, styleMask: [.titled, .resizable])
            window.contentViewController = controller
            for width in [CGFloat(1500), 1100, 900, 760, 1400] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                window.layoutIfNeeded()
                let got = window.contentView?.frame.width ?? 0
                if abs(got - width) > 1 {
                    print("  FAIL \(name) at \(fmt(width)): content view resolved to \(fmt(got))")
                    ok = false
                }
                let page = controller.view.frame.width
                if abs(page - got) > 1 {
                    print("  FAIL \(name) at \(fmt(width)): page width \(fmt(page)) does not track its container \(fmt(got))")
                    ok = false
                }
            }
            window.close()
        }
        if ok { print("  ok   both pages track the window from 760 to 1500 on Daylight") }
    }

    // MARK: 10. Settings actually renders content on its very first load
    //
    // A real, captain-reported regression, not a hypothetical: the drill
    // header rendered correctly ("Settings / N themes...") and the entire
    // body below it was completely empty - no cards, no wells, no toggles,
    // no theme grid. Root cause was in `rebuildCardLayout()`, not in Dusk
    // (Phase 6's 14th theme, which was the most recent change and the
    // obvious first suspect): `ThemeManager.shared.observe`'s closure fires
    // *synchronously* at registration - a documented, repeatedly-hit trap in
    // this codebase (see `HelmFormSheet`'s own header for the same shape).
    // That registration sits at the very top of `SettingsController.loadView`,
    // right after `view = root` (which is what flips `isViewLoaded` to
    // `true`) and well before `cardsInOrder`/`cardsContainer` are ever
    // populated a few lines later. The premature synchronous fire ran
    // `repaintForTheme()` -> `rebuildCardLayout()` against an *empty*
    // `cardsInOrder`, which did nothing visible but still consumed
    // `lastLayoutWasTwoColumn`'s "already built" cache state - so the real
    // call moments later, with all six cards finally populated, found
    // `lastLayoutWasTwoColumn` already matching the freshly computed
    // `twoColumn` value and returned early via that cache guard without ever
    // adding a single card to `cardsContainer`. It reproduces on every
    // theme, Daylight or not - it is not specific to the Daylight-family
    // theme count. Every *other* case in this file happens to mask it by
    // calling `ThemeManager.shared.setTheme(daylight)` before construction,
    // which flips `twoColumn`'s computed value on the very next real call
    // and accidentally forces the cache guard to pass - this case
    // deliberately mounts Settings with no theme forced first, the realistic
    // path a captain's own launch takes.
    private static func checkSettingsRendersOnFirstLoad(_ ok: inout Bool) {
        print("\n-- regression: Settings renders real content on its very first load --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        guard settings.debugCards.count == expectedCardCount else {
            print("  FAIL Settings built \(settings.debugCards.count) cards, "
                  + "want \(expectedCardCount)")
            ok = false
            return
        }
        // The detail pane holds exactly the selected category's cards, so
        // the expected number is that category's own - not all ten. The
        // regression this guards is unchanged: the page building every card
        // and putting none of them on screen.
        let want = settings.debugCards(in: settings.debugSelectedCategory).count
        let inTree = settings.debugCardsInTree
        guard want > 0, inTree == want else {
            print("  FAIL Settings' \(settings.debugSelectedCategory.rawValue) pane put \(inTree) "
                  + "of its \(want) cards on screen - the rest are orphaned")
            ok = false
            return
        }
        // And the sidebar is what makes the other nine reachable, so a page
        // that renders its first pane and no navigation is still broken.
        guard settings.debugSidebar.selection == settings.debugSelectedCategory.rawValue else {
            print("  FAIL the sidebar's selection is \(settings.debugSidebar.selection ?? "nil"), "
                  + "not \(settings.debugSelectedCategory.rawValue)")
            ok = false
            return
        }
        let texts = allLabelTexts(in: settings.view)
        guard texts.count > 20 else {
            print("  FAIL Settings' view tree carries only \(texts.count) labels - the page is effectively blank")
            ok = false
            return
        }
        print("  ok   Settings: \(inTree)/\(want) \(settings.debugSelectedCategory.rawValue) cards reached the tree, "
              + "\(texts.count) labels rendered")
    }
}

#endif
