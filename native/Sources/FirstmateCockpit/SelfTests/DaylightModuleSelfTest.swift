// Manjesh Grand Line - native macOS app.
//
// Daylight Phase 2's own suite: the shell (floating bar + home canvas +
// drill headers) that replaced the icon rail and the top bar.
//
// The migration spec names four things this has to pin (§8's "Testing
// requirements per phase"), and each maps to a case below:
//
//   1. **Module anatomy** - a module really is §6.1's card: ribbon, gradient
//      tile, header text, optional chip, one of the body kinds, and one
//      clickable target that announces as a button.
//   2. **Span-2 grid math** - the wide briefing consumes two columns, rows
//      never overflow their column count, and a short row is padded rather
//      than stretched.
//   3. **The space table matches the locked decision exactly** - restated
//      here as literal data, so a future edit to `DaylightModule.space` that
//      disagrees with the captain's decision fails rather than ships.
//   4. **The canvas constructs no store** - a source guard, because the
//      failure it prevents (a fetch on every hub visit) is invisible in a
//      passing behavioural test and only shows up as the app feeling slow.
//
// Plus two this phase added for its own risk profile:
//
//   5. **The bar cannot cap the window** - AGENTS.md gotcha (13) is this
//      codebase's most expensive recurring bug, and a full-width bar is the
//      most dangerous new surface for it. Measured against a real window, not
//      reasoned about. (`AppShellBodyWidthSelfTest` covers the body half.)
//   6. **No `NSVisualEffectView` in the bar** - gotcha (8), which §6.3 calls
//      out by name. Checked structurally rather than by eye.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_MODULE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightModuleSelfTest {

    static func run() -> Bool {
        // Each check gets its own flag and reports its own verdict, so one
        // failure never silences the seven checks after it - a suite that
        // stops printing OK lines after the first FAIL hides how much else is
        // broken, which is the opposite of what a regression run is for.
        var allOK = true
        for check in [checkSpaceTable, checkSymbolsResolve, checkSpanGridMath,
                      checkModuleAnatomy, checkCanvasConstructsNoStores,
                      checkBarAnatomy, checkBarDoesNotCapWindow,
                      checkCanvasAndDrillHeader] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightModuleSelfTest: all checks passed"
                    : "DaylightModuleSelfTest: FAILED")
        return allOK
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: 3 - the locked space table

    /// The captain's locked decision, restated as literal data.
    ///
    /// Deliberately typed out again rather than derived from
    /// `DaylightModule.space`: a test that reads the same table it is checking
    /// asserts nothing. These five lines are the decision block at the top of
    /// `daylight-ui-design.md`, verbatim.
    private static let lockedMembership: [DaylightSpace: Set<DaylightModule>] = [
        .command: [.console, .tasks, .mergeQueue],
        .operations: [.hosts, .logAnalyzer, .health, .schedules],
        .stores: [.vault, .docs, .tools, .dictation],
        .engineering: [.setup, .settings],
    ]

    /// The two that appear on Overview and nowhere else.
    private static let overviewOnly: Set<DaylightModule> = [.briefing, .fleet]

    private static func checkSpaceTable(_ ok: inout Bool) {
        print("\n-- space filter: the table matches the locked captain decision --")

        for (space, expected) in lockedMembership {
            let actual = Set(DaylightModule.allCases.filter { $0.space == space })
            if actual != expected {
                fail("\(space.rawValue): expected \(expected.map(\.rawValue).sorted()), got \(actual.map(\.rawValue).sorted())", &ok)
            }
        }

        let actualOverviewOnly = Set(DaylightModule.allCases.filter { $0.space == nil })
        if actualOverviewOnly != overviewOnly {
            fail("Overview-only set should be \(overviewOnly.map(\.rawValue).sorted()), got \(actualOverviewOnly.map(\.rawValue).sorted())", &ok)
        }

        // Overview shows everything; each other space shows only its own.
        let onOverview = DaylightModule.allCases.filter { $0.isVisible(in: .overview) }
        if onOverview.count != DaylightModule.allCases.count {
            fail("Overview must show every module, showed \(onOverview.count) of \(DaylightModule.allCases.count)", &ok)
        }
        for (space, expected) in lockedMembership {
            let visible = Set(DaylightModule.allCases.filter { $0.isVisible(in: space) })
            if visible != expected {
                fail("\(space.rawValue) should show exactly its own modules, showed \(visible.map(\.rawValue).sorted())", &ok)
            }
            for module in overviewOnly where module.isVisible(in: space) {
                fail("\(module.rawValue) must appear only on Overview, but is visible in \(space.rawValue)", &ok)
            }
        }

        // Every module belongs somewhere reachable, and every space has
        // something in it - a space pill that filters to nothing is a dead end.
        for space in DaylightSpace.allCases {
            if DaylightModule.allCases.filter({ $0.isVisible(in: space) }).isEmpty {
                fail("space \(space.rawValue) has no modules at all", &ok)
            }
        }

        // §5.4's copy, and the shortcut indices `⌘1`…`⌘5` carry.
        let expectedTitles = ["Overview", "Command", "Operations", "Stores", "Engineering"]
        let actualTitles = DaylightSpace.allCases.map(\.title)
        if actualTitles != expectedTitles {
            fail("space pill order/copy should be \(expectedTitles), got \(actualTitles)", &ok)
        }
        for (index, space) in DaylightSpace.allCases.enumerated() where space.shortcutIndex != index + 1 {
            fail("\(space.rawValue) should map to \u{2318}\(index + 1), reports \u{2318}\(space.shortcutIndex)", &ok)
        }
        for space in DaylightSpace.allCases where space.subtitle.isEmpty {
            fail("\(space.rawValue) has no subtitle copy", &ok)
        }

        if ok { print("  OK - 4 spaces x their locked modules, 2 Overview-only, 5 pills in \u{2318}1-\u{2318}5 order") }
    }

    // MARK: symbols

    /// `NSImage(systemSymbolName:)` returns nil *silently*, and this app has
    /// shipped an invisible icon exactly that way before (the `anchor`
    /// incident). Every glyph Phase 2 introduces is checked here.
    private static func checkSymbolsResolve(_ ok: inout Bool) {
        print("\n-- SF Symbols: every glyph this phase introduces actually resolves --")
        var names = DaylightModule.allCases.map(\.symbol)
        names.append(contentsOf: RailDestination.allCases.map(\.symbol))
        names.append(contentsOf: ["sailboat.fill", "magnifyingglass", "chevron.left",
                                  "arrow.clockwise", "bell.fill", "gearshape",
                                  "rectangle.portrait.and.arrow.right"])
        for name in Set(names) where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            fail("SF Symbol '\(name)' does not resolve - it would render as an invisible icon", &ok)
        }
        if ok { print("  OK - all \(Set(names).count) symbols resolve") }
    }

    // MARK: 2 - span-2 grid math

    private static func checkSpanGridMath(_ ok: inout Bool) {
        print("\n-- grid: span-2 packing, no overflow, padded partial rows --")

        // Pure packing first, with no views involved.
        //
        // Case A: the real canvas shape - one span-2 module (the briefing)
        // followed by fourteen span-1 modules.
        let canvasSpans = DaylightModule.canvasOrder.map(\.span)
        if canvasSpans.filter({ $0 == 2 }).count != 1 {
            fail("exactly one module should be wide (the briefing), \(canvasSpans.filter { $0 == 2 }.count) are", &ok)
        }
        if DaylightModule.briefing.span != 2 {
            fail("the Morning briefing must span 2 columns (\u{00A7}6.1's wide variant)", &ok)
        }

        for columns in 1...6 {
            let rows = HelmResponsiveGrid.packRows(spans: canvasSpans, columns: columns)
            // No row may exceed the column count.
            for (index, row) in rows.enumerated() {
                let used = row.reduce(0) { $0 + $1.span }
                if used > columns {
                    fail("at \(columns) columns, row \(index) uses \(used) columns", &ok)
                }
            }
            // Every item placed exactly once, in order.
            let placed = rows.flatMap { $0 }.map(\.index)
            if placed != Array(canvasSpans.indices) {
                fail("at \(columns) columns, packing lost or reordered items: \(placed)", &ok)
            }
            // A span-2 item degrades rather than overflowing a 1-column grid.
            if columns == 1 {
                let spans = Set(rows.flatMap { $0 }.map(\.span))
                if spans != [1] {
                    fail("at 1 column every item must degrade to span 1, got spans \(spans.sorted())", &ok)
                }
            } else {
                let briefing = rows.flatMap { $0 }.first { $0.index == 0 }
                if briefing?.span != 2 {
                    fail("at \(columns) columns the briefing should still span 2, got \(briefing?.span ?? -1)", &ok)
                }
            }
        }

        // Column count is monotonic in width and never below one.
        var previous = 0
        for width in stride(from: CGFloat(200), through: 2400, by: 100) {
            let columns = HelmResponsiveGrid.columns(containerWidth: width,
                                                     minItemWidth: HomeCanvasController.minModuleWidth,
                                                     spacing: HomeCanvasController.gridSpacing)
            if columns < 1 { fail("column count fell below 1 at width \(width)", &ok) }
            if columns < previous { fail("column count is not monotonic: \(previous) -> \(columns) at width \(width)", &ok) }
            previous = columns
        }

        // Now the built rows: every row is padded to the full column count, so
        // a partial row's cards stay the same width as a full row's.
        let container: CGFloat = 1100
        let columns = HelmResponsiveGrid.columns(containerWidth: container,
                                                 minItemWidth: HomeCanvasController.minModuleWidth,
                                                 spacing: HomeCanvasController.gridSpacing)
        let unit = HelmResponsiveGrid.itemWidth(containerWidth: container, columns: columns,
                                                spacing: HomeCanvasController.gridSpacing)
        let rows = HelmResponsiveGrid.spanningRows(
            DaylightModule.canvasOrder,
            spans: { $0.span },
            containerWidth: container,
            minItemWidth: HomeCanvasController.minModuleWidth,
            spacing: HomeCanvasController.gridSpacing
        ) { _, _ in
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            return v
        }
        for (index, row) in rows.enumerated() {
            let widths = row.arrangedSubviews.compactMap { view in
                view.constraints.first { $0.firstAttribute == .width }?.constant
            }
            let total = widths.reduce(0, +) + HomeCanvasController.gridSpacing * CGFloat(max(0, widths.count - 1))
            // Padding to the column count means the *cell* total always fills
            // the container, whatever mix of spans the row holds.
            if abs(total - container) > 1.0 {
                fail("row \(index) covers \(total)pt of a \(container)pt container - padding is wrong", &ok)
            }
            // Every width constraint must sit below the window's own
            // stay-put priority (gotcha (13)).
            for view in row.arrangedSubviews {
                for constraint in view.constraints where constraint.firstAttribute == .width {
                    if constraint.priority.rawValue >= 500 {
                        fail("a grid width constraint is priority \(constraint.priority.rawValue) - "
                             + "anything >= 500 can cap the window", &ok)
                    }
                }
            }
        }
        // Sanity: at 1100pt with a 255pt minimum there is genuinely more than
        // one column, or the span check above proves nothing.
        if columns < 2 {
            fail("expected multiple columns at 1100pt (unit \(unit)), got \(columns)", &ok)
        }

        if ok { print("  OK - packing, degradation, monotonic columns, padded rows, sub-500 widths") }
    }

    // MARK: 1 - module anatomy

    private static func checkModuleAnatomy(_ ok: inout Bool) {
        print("\n-- module card: \u{00A7}6.1's anatomy, and one clickable target --")

        let bodies: [(String, HelmModuleCard.Body)] = [
            ("metric", .metric(value: "3", unit: "tasks", note: "One is overdue.")),
            ("peekRows", .peekRows([
                HelmModulePeekRow(state: .ok, text: "one", value: "live"),
                HelmModulePeekRow(state: .warn, text: "two", value: "idle"),
            ])),
            ("ring", .ring(value: 4, total: 5, title: "Healthy", note: "One service is degraded.")),
            ("progress", .progress(value: 4, total: 5, note: "One step drifted.")),
            ("note", .note("A single wrapping line.")),
        ]

        for (name, body) in bodies {
            let card = HelmModuleCard()
            var opened = 0
            card.onOpen = { opened += 1 }
            card.configure(.init(title: "Title", subtitle: "subtitle",
                                 symbol: "sailboat.fill", hue: .teal,
                                 chip: .ok("All clear"), body: body))
            card.frame = NSRect(x: 0, y: 0, width: 300, height: 170)
            card.layoutSubtreeIfNeeded()

            let a = card.anatomyForTests
            if !a.hasRibbon { fail("\(name): no ribbon layer", &ok) }
            if a.ribbonStopCount != 2 { fail("\(name): ribbon has \(a.ribbonStopCount) gradient stops, expected 2", &ok) }
            if abs(a.ribbonHeight - 6) > 0.01 { fail("\(name): ribbon is \(a.ribbonHeight)pt, \u{00A7}6.1 says 6", &ok) }
            if abs(a.cornerRadius - HelmMetrics.dModule) > 0.01 {
                fail("\(name): radius \(a.cornerRadius), expected \(HelmMetrics.dModule)", &ok)
            }
            if !HelmMetrics.daylightRadii.contains(a.cornerRadius) {
                fail("\(name): radius \(a.cornerRadius) is not in \u{00A7}2.6's scale", &ok)
            }
            // The two-layer shadow arrangement (\u{00A7}2.5): the shadow host must
            // not clip, the card must.
            if a.shadowHostClipsToBounds { fail("\(name): the shadow host clips - it would cast no shadow", &ok) }
            if !a.cardClipsToBounds { fail("\(name): the card does not clip - its ribbon would escape the radius", &ok) }
            if a.borderWidth != 1 { fail("\(name): border is \(a.borderWidth)pt, expected 1", &ok) }
            if !a.hasTile { fail("\(name): the gradient tile has no glyph", &ok) }
            if a.title != "Title" || a.subtitle != "subtitle" { fail("\(name): header text did not render", &ok) }
            if a.chipText != "All clear" { fail("\(name): chip text is \(a.chipText ?? "nil")", &ok) }

            // \u{00A7}6.1: the whole card is one click target, announcing as a button
            // with "<title>, <subtitle>, <chip text>".
            if !a.isCardActivatable { fail("\(name): the card is not activatable - it would be invisible to VoiceOver", &ok) }
            if a.accessibilityLabel != "Title, subtitle, All clear" {
                fail("\(name): accessibility label is \(a.accessibilityLabel ?? "nil")", &ok)
            }
            card.debugActivate()
            if opened != 1 { fail("\(name): a press fired onOpen \(opened) times, expected 1", &ok) }
        }

        // A body with no chip renders no chip, and the label drops it.
        let bare = HelmModuleCard()
        bare.configure(.init(title: "Tools", subtitle: "9 utilities",
                             symbol: "wrench.and.screwdriver.fill", hue: .slate,
                             chip: nil, body: .note("YAML \u{00B7} JSON")))
        if bare.anatomyForTests.chipText != nil {
            fail("a module with no chip still rendered one", &ok)
        }
        if bare.anatomyForTests.accessibilityLabel != "Tools, 9 utilities" {
            fail("chipless label is \(bare.anatomyForTests.accessibilityLabel ?? "nil")", &ok)
        }

        // \u{00A7}6.1's "2-3 rows": a fourth row is dropped rather than turning the
        // canvas into a table.
        let crowded = HelmModuleCard()
        crowded.configure(.init(title: "Hosts", subtitle: "5 saved", symbol: "desktopcomputer",
                                hue: .teal, chip: nil,
                                body: .peekRows((1...6).map {
                                    HelmModulePeekRow(state: .idle, text: "host \($0)", value: "idle")
                                })))
        if crowded.anatomyForTests.peekRowCount != HelmModuleCard.maxPeekRows {
            fail("six peek rows rendered as \(crowded.anatomyForTests.peekRowCount), expected \(HelmModuleCard.maxPeekRows)", &ok)
        }

        // The gauges carry the value they were given rather than a placeholder.
        let ring = HelmRingGauge()
        ring.configure(value: 3, total: 4)
        if abs(ring.fractionForTests - 0.75) > 0.001 { fail("ring fraction \(ring.fractionForTests), expected 0.75", &ok) }
        if ring.centreLabelForTests != "3/4" { fail("ring label \(ring.centreLabelForTests), expected 3/4", &ok) }
        ring.configure(value: 0, total: 0)
        if ring.fractionForTests != 0 { fail("an empty ring should be 0, got \(ring.fractionForTests)", &ok) }

        let bar = HelmProgressBar()
        bar.configure(fraction: 2.5)
        if bar.fractionForTests != 1 { fail("progress fraction should clamp to 1, got \(bar.fractionForTests)", &ok) }

        if ok { print("  OK - ribbon/tile/header/chip/body, two-layer shadow, button semantics, row cap, gauges") }
    }

    // MARK: 4 - the canvas constructs no store

    private static func checkCanvasConstructsNoStores(_ ok: inout Bool) {
        print("\n-- canvas: reads already-owned state, never constructs a store --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - app sources are not next to this binary")
            return
        }
        let url = dir.appendingPathComponent("HomeCanvasController.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fail("could not read HomeCanvasController.swift - has it moved? this check would silently pass", &ok)
            return
        }
        // Comments name these types on purpose (explaining what is injected and
        // why), so only real code lines are scanned.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // A constructor call, not a mention: `Store()` / `Source()`.
        let banned = ["ShiftStore(", "HostStore(", "ScheduleStore(", "LogAnalyzerStore(",
                      "DocsRunbookStore(", "CommandLibraryStore(", "SnippetStore(",
                      "SSHKeyStore(", "DictationStore(", "IncidentStore(", "FleetLogStore("]
        for name in banned where code.contains(name) {
            fail("HomeCanvasController constructs a \(name.dropLast()) - it must be injected "
                 + "(see the file header: a store built here means a fetch on every hub visit)", &ok)
        }
        // The expensive fleet/PR reads in particular must never appear here.
        for name in ["FleetDataSource.snapshot(", "OpenPRsSource.fetch", "VaultSource.loadSnapshot("] {
            if code.contains(name) {
                fail("HomeCanvasController calls \(name)) - \u{00A7}6.1 forbids a fresh fetch from the canvas", &ok)
            }
        }
        if ok { print("  OK - no store construction, no fleet/PR/vault fetch") }
    }

    // MARK: 6 - bar anatomy

    private static func checkBarAnatomy(_ ok: inout Bool) {
        print("\n-- floating bar: \u{00A7}6.3's geometry, five pills, and no vibrancy --")
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.frame = NSRect(x: 0, y: 0, width: 1200, height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()

        let geometry = bar.geometryForTests
        // gotcha (8): the single most-repeated bug class in this codebase, and
        // \u{00A7}6.3 rules it out by name for this exact surface.
        if geometry.usesVisualEffect {
            fail("the bar contains an NSVisualEffectView - \u{00A7}6.3 and AGENTS.md gotcha (8) both forbid it", &ok)
        }
        if abs(geometry.cornerRadius - HelmMetrics.dBar) > 0.01 {
            fail("bar radius \(geometry.cornerRadius), expected \(HelmMetrics.dBar)", &ok)
        }
        if abs(geometry.barFrame.height - DaylightBarController.height) > 0.5 {
            fail("bar height \(geometry.barFrame.height), expected \(DaylightBarController.height)", &ok)
        }
        if abs(geometry.barFrame.minX - DaylightBarController.sideMargin) > 0.5 {
            fail("bar leading inset \(geometry.barFrame.minX), expected \(DaylightBarController.sideMargin)", &ok)
        }
        let trailingInset = bar.view.bounds.width - geometry.barFrame.maxX
        if abs(trailingInset - DaylightBarController.sideMargin) > 0.5 {
            fail("bar trailing inset \(trailingInset), expected \(DaylightBarController.sideMargin)", &ok)
        }
        if geometry.shadowOpacity <= 0 {
            fail("the bar casts no shadow - \u{00A7}6.3 asks for the resting level", &ok)
        }
        if geometry.pillCount != DaylightSpace.allCases.count {
            fail("\(geometry.pillCount) pills, expected \(DaylightSpace.allCases.count)", &ok)
        }

        // Radio semantics, exactly one selected, and a real click through the
        // recognizer moves it.
        var picked: [DaylightSpace] = []
        bar.onSelectSpace = { picked.append($0) }
        let pills = bar.debugPills()
        for pill in pills {
            if pill.accessibilityRoleOverride != .radioButton {
                fail("a space pill announces as \(String(describing: pill.accessibilityRoleOverride)), expected .radioButton", &ok)
            }
            if !pill.isActivatable { fail("a space pill is not activatable", &ok) }
        }
        let selectedCount = pills.filter { $0.accessibilityValueOverride == "selected" }.count
        if selectedCount != 1 { fail("\(selectedCount) pills report as selected, expected exactly 1", &ok) }

        guard pills.count >= 3 else {
            fail("not enough pills to drive a selection", &ok)
            return
        }
        pills[2].performPrimaryAction()
        if picked != [.operations] {
            fail("clicking the third pill reported \(picked.map(\.rawValue)), expected [operations]", &ok)
        }
        if bar.selectedSpaceForTests != .operations {
            fail("the bar's own selection is \(bar.selectedSpaceForTests.rawValue) after a click on Operations", &ok)
        }
        // `setSelectedSpace` moves the pill without reporting - the path a
        // `\u{2318}N` shortcut or a restore takes.
        picked.removeAll()
        bar.setSelectedSpace(.stores)
        if !picked.isEmpty { fail("setSelectedSpace fired onSelectSpace - it must not", &ok) }
        if bar.selectedSpaceForTests != .stores { fail("setSelectedSpace did not move the selection", &ok) }

        if ok { print("  OK - geometry, shadow, no vibrancy, 5 radio pills, click and silent-select") }
    }

    // MARK: 5 - the bar cannot cap the window

    private static func checkBarDoesNotCapWindow(_ ok: inout Bool) {
        print("\n-- gotcha (13): the bar cannot set a window-width floor --")
        let bar = DaylightBarController()
        bar.loadView()

        for (description, priority) in bar.debugWidthConstraints() where priority >= 500 {
            fail("a bar width constraint sits at priority \(priority) - anything >= "
                 + "NSLayoutPriorityWindowSizeStayPut (500) can cap the window: \(description)", &ok)
        }

        // Measured, not reasoned: a real window carrying the bar has to hold a
        // width well below \u{00A7}6.3's own comfortable floor.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = bar
        for width in [CGFloat(1400), 900, 640, 520, 420] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 200), display: true)
            let actual = window.frame.width
            if abs(actual - width) > 1.0 {
                fail("asked for a \(width)pt window, got \(actual)pt - the bar is capping it", &ok)
            }
        }
        if ok { print("  OK - every bar constraint < 500, and a real window holds 420pt") }
    }

    // MARK: canvas + drill header, driven through the real shell

    private static func checkCanvasAndDrillHeader(_ ok: inout Bool) {
        print("\n-- shell: the canvas is the landing, every drill page has a back button --")
        withScratchEnv {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            let shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore, dictationStore: DictationStore()),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: ShiftStore(), dictationStore: DictationStore(),
                commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
                makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                     isFirstmateConsole: false) }
            )
            window.contentViewController = shell
            window.layoutIfNeeded()

            let canvas = shell.homeCanvasForTests

            // The canvas is eagerly mounted - it is the launch landing and
            // every back button's target, so it can never be a lazy slot.
            if !shell.mountedDestinationSlotsForTests.contains(.homeCanvas) {
                fail("the home canvas is not mounted at launch", &ok)
            }

            // Overview shows every module; each other space shows only its own.
            shell.selectSpace(.overview)
            if canvas.visibleModulesForTests.count != DaylightModule.allCases.count {
                fail("Overview shows \(canvas.visibleModulesForTests.count) modules, expected all "
                     + "\(DaylightModule.allCases.count)", &ok)
            }
            if canvas.moduleCardsForTests.count != DaylightModule.allCases.count {
                fail("Overview built \(canvas.moduleCardsForTests.count) cards for "
                     + "\(DaylightModule.allCases.count) modules", &ok)
            }
            for space in DaylightSpace.allCases where space != .overview {
                shell.selectSpace(space)
                let visible = Set(canvas.visibleModulesForTests)
                guard let expected = lockedMembership[space] else { continue }
                if visible != expected {
                    fail("\(space.rawValue) rendered \(visible.map(\.rawValue).sorted()), "
                         + "expected \(expected.map(\.rawValue).sorted())", &ok)
                }
                if canvas.moduleCardsForTests.count != expected.count {
                    fail("\(space.rawValue) built \(canvas.moduleCardsForTests.count) cards for "
                         + "\(expected.count) modules", &ok)
                }
                // \u{00A7}5.4's exact copy for a non-Overview space.
                let greeting = canvas.greetingForTests
                if greeting.title != space.title || greeting.subtitle != space.subtitle {
                    fail("\(space.rawValue) greeting is \(greeting), expected \((space.title, space.subtitle))", &ok)
                }
                // Selecting a space lands on the canvas, whichever page was up.
                if shell.drillHeaderIsHiddenForTests == false {
                    fail("selecting \(space.rawValue) left a drill header showing - it should be on the canvas", &ok)
                }
            }

            // The canvas has no drill header; every other destination does,
            // and its back button returns to the canvas with the space intact.
            shell.selectSpace(.stores)
            shell.show(.homeCanvas)
            if !shell.drillHeaderIsHiddenForTests || shell.drillHeaderHeightForTests != 0 {
                fail("the canvas shows a drill header (hidden=\(shell.drillHeaderIsHiddenForTests), "
                     + "height=\(shell.drillHeaderHeightForTests)) - the hub has no back", &ok)
            }

            for dest in RailDestination.allCases where dest != .homeCanvas {
                shell.show(dest)
                if shell.drillHeaderIsHiddenForTests {
                    fail("\(dest) has no drill header - it would have no way back", &ok)
                }
                if abs(shell.drillHeaderHeightForTests - HelmDrillHeader.height) > 0.01 {
                    fail("\(dest)'s drill header is \(shell.drillHeaderHeightForTests)pt tall", &ok)
                }
                if shell.drillHeaderForTests.titleForTests != dest.bodyTitle {
                    fail("\(dest)'s drill header says '\(shell.drillHeaderForTests.titleForTests)', "
                         + "expected '\(dest.bodyTitle)'", &ok)
                }
                // The real back path a click or a VoiceOver press takes.
                if !shell.drillHeaderForTests.debugActivateBack() {
                    fail("\(dest)'s back button did not activate", &ok)
                }
                if !shell.drillHeaderIsHiddenForTests {
                    fail("back from \(dest) did not land on the canvas", &ok)
                }
                // The space survives the round trip - the canvas is never
                // rebuilt, which is what \u{00A7}5.2's "keeps its last space
                // selection" means.
                if canvas.selectedSpace != .stores {
                    fail("the canvas lost its space over a \(dest) round trip: now \(canvas.selectedSpace.rawValue)", &ok)
                }
            }

            // The canvas rebuilds fifteen self-theming cards on every space
            // switch. Each card - and each card's gradient tile - registers a
            // `ThemeManager` observer and unregisters in `deinit`, so a card
            // that failed to deallocate would leak a dead closure per rebuild.
            //
            // **`autoreleasepool` is load-bearing here, and finding out why
            // cost real time.** A first version of this check without it
            // reported 224 leaked observers over 20 switches and a live-card
            // count climbing 69 -> 181, which reads exactly like a retain
            // cycle. It is not one: a headless suite never turns the run loop,
            // so nothing drains the pool that removed views are autoreleased
            // into, and every discarded card stays alive until the process
            // exits. Draining per switch reports a flat 69 -> 69. Any future
            // AppKit self-test that measures deallocation needs the same
            // wrapper, or it will chase a cycle that does not exist.
            autoreleasepool { shell.selectSpace(.overview) }
            let baselineObservers = ThemeManager.shared.observerCountForTests
            for _ in 0..<4 {
                for space in DaylightSpace.allCases {
                    autoreleasepool { shell.selectSpace(space) }
                }
            }
            autoreleasepool { shell.selectSpace(.overview) }
            let afterObservers = ThemeManager.shared.observerCountForTests
            if afterObservers > baselineObservers {
                fail("20 space switches left \(afterObservers - baselineObservers) extra ThemeManager "
                     + "observers behind (\(baselineObservers) -> \(afterObservers)) - a module card "
                     + "is not being deallocated", &ok)
            }

            // Overview's greeting comes from `FleetGreeting`, shared with the
            // Overview page - not a second implementation.
            shell.selectSpace(.overview)
            let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                         queuedCount: 0, doneCount: 0, projectsCount: 0,
                                         watcher: WatcherHealth(status: "healthy"))
            canvas.applyFleet(snapshot: snapshot, mergedPRs: [], prFetchFailure: nil)
            let greeting = canvas.greetingForTests
            if greeting.title != FleetGreeting.greeting(captain: "Manjesh") {
                fail("Overview greeting is '\(greeting.title)', expected FleetGreeting's own", &ok)
            }
            let expectedAnswer = FleetGreeting.answer(tasks: [], readyCount: 0,
                                                      prFetchFailure: nil, homeOk: true).canvasLine
            if greeting.subtitle != expectedAnswer {
                fail("Overview subtitle is '\(greeting.subtitle)', expected the answer banner's own line", &ok)
            }
            // GL-14: a failed PR scan must not read as a confident zero.
            canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: "no network")
            if canvas.greetingForTests.subtitle.contains("0 PRs ready") {
                fail("a failed PR scan rendered as '0 PRs ready' - GL-14's exact rule", &ok)
            }

            if ok {
                print("  OK - eager canvas, per-space filtering and copy, drill headers on "
                      + "\(RailDestination.allCases.count - 1) destinations, back preserves the space")
            }
        }
    }

    // MARK: Helpers

    /// Scratch overrides for every store the shell builds, so this suite never
    /// touches the captain's real hosts/keys/snippets/tasks/dictation data -
    /// the same convention `AppShellBodyWidthSelfTest` established.
    private static func withScratchEnv(_ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-daylight-module-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_SCHEDULES_FILE": dir.appendingPathComponent("schedules.json").path,
        ]
        var saved: [String: String?] = [:]
        for (key, value) in overrides {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, old) in saved {
                if let old { setenv(key, old, 1) } else { unsetenv(key) }
            }
        }
        body()
    }
}

#endif
