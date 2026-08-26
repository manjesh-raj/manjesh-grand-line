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
//   6. **Settings' two-column threshold is width-driven, and now a fixed
//      case below documents `fm/grandline-settings-layout-theme-dependent-
//      fix`'s own correction**: this used to also require `theme.isDaylight`,
//      so a captain switching between a Daylight theme and a legacy one at
//      the same window size saw the page itself restructure - one column
//      became two, and the Appearance card's own theme-grid density changed
//      with it, since that grid's column count is derived from
//      `appearanceContainer`'s real width, which differs between one- and
//      two-column mode. Selecting a theme must only ever change colours, so
//      the gate is gone: every theme now crosses to two columns at the same
//      width, and all six cards survive the reparent either way. Measured
//      from real frames. `SettingsThemeLayoutParitySelfTest` is the dedicated
//      suite proving a Daylight theme and a legacy theme resolve to a
//      byte-identical layout fingerprint at a shared width; this case is
//      what is left of the original Daylight-specific coverage.
//   7. **`HelmToggle` shows the pill on Daylight and a real `NSSwitch`
//      elsewhere**, moves its knob, and writes through to `AppSettings` - the
//      whole point of replacing the control is that it still is one.
//   8. **Settings' status pill is the shared one** (§6.7). Its private copy
//      painted a hue as its own label over a wash of itself, the audit's §5.7
//      defect - the same copy slice 2 deleted from Health. This was the last
//      one, so it is measured (contrast floor) and source-guarded.
//   9. **No new window-width floor.** Two columns doubles every minimum inside
//      Settings, and AGENTS.md gotcha (13) is this codebase's most expensive
//      recurring bug. `AppShellBodyWidthSelfTest` is the broad sweep; this is
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

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, checkOldCaptionsAreGone,
                      checkToolsGridUsesModulePlates, checkPlateNoteFits,
                      checkPlatesDoNotAccumulate,
                      checkCodeEditorsAreWells, checkSettingsTwoColumnLayout,
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
        print("\n-- §6.1: a plate's description fits `standardHeight` at every text scale --")
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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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
            host.layoutSubtreeIfNeeded()

            let anatomy = plate.anatomyForTests
            if abs(anatomy.cardHeight - HelmModuleCard.standardHeight) > 0.5 {
                print("  FAIL \(step.title): plate resolved to \(fmt(anatomy.cardHeight)), not standardHeight "
                    + "(\(fmt(HelmModuleCard.standardHeight))) - the grid row would be ragged")
                ok = false
            }
            // The real bound, and the reason this case exists at all.
            // `fittingSize` reports a wrapping label at its single-line width
            // when nothing has set `preferredMaxLayoutWidth` (which is exactly
            // the plate's situation - the row's `.fillEqually` distribution
            // sets its frame, not its intrinsic size), so measuring the body
            // alone would pass vacuously however high the cap were raised.
            // What actually bounds the label is `maximumNumberOfLines`, so the
            // worst case is that many full lines.
            let lineHeight = NSLayoutManager().defaultLineHeight(for: HelmType.caption())
            let worstCase = lineHeight * CGFloat(maxLines)
            if worstCase > anatomy.bodyAreaHeight + 0.5 {
                print("  FAIL \(step.title) (x\(step.scale)) at \(fmt(narrowest))pt: \(maxLines) lines need "
                    + "\(fmt(worstCase)) of \(fmt(anatomy.bodyAreaHeight)) - a long description would be clipped")
                ok = false
            } else {
                print("  ok   \(step.title): \(maxLines) lines need \(fmt(worstCase)) "
                    + "of \(fmt(anatomy.bodyAreaHeight)) at \(fmt(narrowest))pt")
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

    // MARK: 6. Settings' two-column layout (§7, corrected by
    // `fm/grandline-settings-layout-theme-dependent-fix`)

    private static func checkSettingsTwoColumnLayout(_ ok: inout Bool) {
        print("\n-- §7: Settings' two-column threshold is width-driven, not theme-driven --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        ThemeManager.shared.setTheme(daylight)
        let settings = makeSettings()
        let window = mount(settings, width: 1500)
        defer { _ = window }
        settings.view.layoutSubtreeIfNeeded()

        guard settings.debugCards.count == 6 else {
            print("  FAIL Settings has \(settings.debugCards.count) cards, want 6")
            ok = false
            return
        }
        if !settings.debugIsTwoColumn {
            print("  FAIL Settings stayed one column at 1500pt on Daylight")
            ok = false
        }
        var columnXs = Set<CGFloat>()
        for card in settings.debugCards {
            guard let origin = card.superview?.convert(card.frame.origin, to: settings.view) else { continue }
            columnXs.insert((origin.x * 10).rounded() / 10)
        }
        if columnXs.count != 2 {
            print("  FAIL cards sit at \(columnXs.count) distinct x positions, want 2: \(columnXs.sorted())")
            ok = false
        }
        for card in settings.debugCards where card.window == nil {
            print("  FAIL a card was orphaned by the reparent into columns")
            ok = false
        }

        // Narrow enough and it falls back to one column, on the same theme.
        window.setFrame(NSRect(x: 0, y: 0, width: 820, height: 900), display: true)
        settings.view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        settings.view.layoutSubtreeIfNeeded()
        if settings.debugIsTwoColumn {
            print("  FAIL Settings kept two columns at 820pt, below its own minimum")
            ok = false
        }
        if settings.debugCards.count != 6 {
            print("  FAIL a card was lost coming back to one column")
            ok = false
        }

        // `fm/grandline-settings-layout-theme-dependent-fix`: the twelve
        // legacy palettes now cross to two columns at the SAME width a
        // Daylight theme does - the opposite of what this case asserted
        // before that fix, which encoded the very bug being fixed
        // ("the twelve must be untouched") as expected behaviour. A captain
        // comparing "Daylight" against a legacy theme at the same window
        // size must see identical structure, not a page that reflows.
        ThemeManager.shared.setTheme(otherTheme)
        let legacy = makeSettings()
        let legacyWindow = mount(legacy, width: 1800)
        defer { _ = legacyWindow }
        legacy.view.layoutSubtreeIfNeeded()
        if !legacy.debugIsTwoColumn {
            print("  FAIL \(otherTheme.id) stayed one column at 1800pt; the layout must be width-driven, not theme-driven")
            ok = false
        }

        // And below the same threshold, the legacy theme falls back to one
        // column too - the threshold applies, not just "two columns forever
        // now regardless of width".
        let legacyNarrow = makeSettings()
        let legacyNarrowWindow = mount(legacyNarrow, width: 820)
        defer { _ = legacyNarrowWindow }
        legacyNarrow.view.layoutSubtreeIfNeeded()
        if legacyNarrow.debugIsTwoColumn {
            print("  FAIL \(otherTheme.id) kept two columns at 820pt, below its own minimum")
            ok = false
        }
        if ok { print("  ok   two columns on Daylight at 1500 and on \(otherTheme.id) at 1800, one column at 820 on both") }
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

        toggle.applyTheme(otherTheme)
        geometry = toggle.debugGeometry
        if geometry.showsPill || !geometry.showsFallbackSwitch {
            print("  FAIL \(otherTheme.id) does not keep the real NSSwitch")
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

        // And Settings' three really are it, and really write through.
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = settings.view.window.map { _ in () }; _ = window }
        if settings.debugToggles.count != 3 {
            print("  FAIL Settings exposes \(settings.debugToggles.count) toggles, want 3")
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
        if ok { print("  ok   pill on Daylight, NSSwitch on \(otherTheme.id), 3 wired toggles") }
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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

        guard settings.debugCards.count == 6 else {
            print("  FAIL Settings built \(settings.debugCards.count) cards, want 6")
            ok = false
            return
        }
        let inTree = settings.debugCardsInTree
        guard inTree == 6 else {
            print("  FAIL Settings built 6 cards but only \(inTree) reached the screen - the rest are orphaned")
            ok = false
            return
        }
        let texts = allLabelTexts(in: settings.view)
        guard texts.count > 20 else {
            print("  FAIL Settings' view tree carries only \(texts.count) labels - the page is effectively blank")
            ok = false
            return
        }
        print("  ok   Settings: 6/6 cards reached the tree, \(texts.count) labels rendered")
    }
}

#endif
