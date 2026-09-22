#if FM_SELFTESTS
import AppKit

/// Review #3's bug list (`data/grandline-full-review-3/report.md` §1 and §1b),
/// for the findings whose fix has no existing suite that already owns it.
///
/// The ones that do are strengthened in place instead, per this codebase's own
/// rule that an assertion which has become a record of the old behaviour is
/// inverted rather than left beside a new one:
///
/// - **B2** -> `ReadyToMergeCountSelfTest.checkReviewPageAgrees`, which read
///   the tiles and the subtitle only. It reads every row's chip now, which is
///   what would have caught the defect the first time.
/// - **B5** -> `AppShellBodyWidthSelfTest`, which measured width only and now
///   measures the body's **height** against the window's too.
/// - **B7** -> `DaylightDrillPageSlice6SelfTest.checkToolPlateNoteLines`, which
///   asserted the `maximumNumberOfLines` bound rather than what rendered.
/// - **B13/B14** -> `TerminalShortcutsSelfTest`, which already drives real
///   split panes in a real console.
/// - **B15** -> `ConfirmMigrationSelfTest`, whose Escape check called
///   `performClick` and so never went near the dispatch that was broken.
/// - **B18** -> `WhiteboardDSLSelfTest`, which owns the parser.
///
/// Window-backed: most of these are geometry, and geometry with no window is
/// geometry nobody measured. Registered in `run-all-tests.sh`'s `NEEDS_SESSION`.
enum Audit3BugFixesSelfTest {

    static func run() -> Bool {
        print("Audit3BugFixesSelfTest: review #3's bug fixes")
        var allOK = true
        for check in [checkKanbanColumnFitsItsPlan,
                      checkEmptyStateWatermarkIsNeverASlab,
                      checkDrillTitleHasAFloorAndYieldsLast,
                      checkQuickAccessCollapsesAndStillReachesEveryDestination,
                      checkUpdatesToastStaysOnItsOwnPage,
                      checkSettingsColumnsKeepCardsAtTheirOwnHeight,
                      checkDictationChipIsContentSized,
                      checkTaskPanelShowsWholeRows,
                      checkStickyFirstNoteClearsTheHeader,
                      checkCrewHandoffRefusesARestoredPage,
                      checkStaleTouchIDKeyIsNotAWrongPassword] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "Audit3BugFixesSelfTest: all checks passed"
                    : "Audit3BugFixesSelfTest: FAILED")
        return allOK
    }


    private static func check(_ condition: Bool, _ label: String, _ ok: inout Bool) {
        SelfTestAssertions.recordNarrated(condition, label, &ok)
    }

    /// Every `FM_*` store this suite can reach, pointed at scratch.
    ///
    /// `fm.themeID`/`fm.fontSize` are saved and restored for the reason this
    /// codebase has had to write down four times: mounting a real controller
    /// writes the theme through to the real preference domain, and a run that
    /// leaves it changed makes unrelated suites measure geometry under a theme
    /// nobody selected.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-audit3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
            "FM_STICKY_BOARD_DIR": dir.appendingPathComponent("sticky").path,
            "FM_CREDENTIAL_VAULT_DIR": dir.appendingPathComponent("vault").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer { for (key, value) in previous { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    // MARK: B3 - the Kanban column's cap matches its own plan

    /// The cap and the plan are computed from the same two constants, so a
    /// column that shows `visibleRows` meta-line cards cannot clip one.
    ///
    /// Arithmetic **and** a real render: the arithmetic is what would have
    /// caught the shipped 16pt shortfall (420 against a 436pt plan), and the
    /// render is what proves the plan reaches the column rather than being a
    /// number in a function nobody called.
    private static func checkKanbanColumnFitsItsPlan(_ ok: inout Bool) {
        print("\n-- B3: a full Backlog column shows four meta-line cards whole --")

        let rows = CGFloat(ShiftBoardView.visibleRows)
        let need = ShiftBoardView.cardRowHeightWithMeta * rows + HelmMetrics.s2 * (rows - 1)
        check(ShiftBoardColumnView.maxBodyHeight >= need - 0.5,
              "the cap (\(ShiftBoardColumnView.maxBodyHeight)) covers the plan's own worst case (\(need))", &ok)

        // A literal cannot stay right across the chrome text scales, which is
        // why the fix derives it - so this asserts the relationship at every
        // scale rather than at the one the captain happens to be on.
        let savedScale = AppSettings.shared.uiTextScale
        defer { ChromeTextScale.shared.setScale(savedScale) }
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            let scaledNeed = ShiftBoardView.cardRowHeightWithMeta * rows + HelmMetrics.s2 * (rows - 1)
            if ShiftBoardColumnView.maxBodyHeight < scaledNeed - 0.5 {
                fail("at \(step.title) the cap is \(ShiftBoardColumnView.maxBodyHeight) for a \(scaledNeed)pt plan", &ok)
            }
        }
        ChromeTextScale.shared.setScale(savedScale)

        withScratchEnv {
            let board = ShiftBoardView()
            let window = OffScreenProbe.window(width: 1300, height: 900)
            window.contentView = board
            board.frame = NSRect(x: 0, y: 0, width: 1300, height: 900)

            // Four Backlog tasks that each carry a meta line - the shape the
            // finding measured. A fixture of plain cards would fit under the
            // old cap too, i.e. it would pass against the bug.
            // A due date is what gives a card its meta line - see
            // `ShiftBoardView.cardHeight(for:)`. Without one these are plain
            // 82pt cards, which fit under the old cap too.
            let tasks = (1...4).map { n -> ShiftTask in
                var task = ShiftTask.fresh()
                task.title = "Task \(n)"
                task.status = .todo
                task.dueDate = "2026-09-30"
                return task
            }
            board.setTasks([.backlog: tasks], projects: [], theme: ThemeManager.shared.theme)
            board.needsLayout = true
            board.layoutSubtreeIfNeeded()

            guard let column = board.debugColumn(.backlog) else {
                fail("the board has no Backlog column", &ok); return
            }
            let cards = column.debugCardViews
            guard cards.count == ShiftBoardView.visibleRows else {
                fail("Backlog rendered \(cards.count) cards, expected \(ShiftBoardView.visibleRows)", &ok)
                return
            }
            // Vacuity guard: a fixture whose cards lost their meta line would
            // fit under any cap and prove nothing.
            let tallest = cards.map(\.frame.height).max() ?? 0
            guard tallest >= ShiftBoardView.cardRowHeightWithMeta - 1 else {
                fail("the fixture's cards are \(tallest)pt - they lost their meta line, so this check is vacuous", &ok)
                return
            }
            let occupied = cards.reduce(0) { $0 + $1.frame.height }
                + HelmMetrics.s2 * CGFloat(cards.count - 1)
            check(column.debugScrollHeight >= occupied - 0.5,
                  "the column body (\(column.debugScrollHeight)) holds all \(cards.count) cards (\(occupied))", &ok)
            if column.debugScrollHeight < occupied - 0.5 {
                fail("review #3's B3 is back: the fourth card is sliced by "
                     + "\(occupied - column.debugScrollHeight)pt", &ok)
            }
        }
    }

    // MARK: B4 - the watermark is a silhouette, never a tile

    private static func checkEmptyStateWatermarkIsNeverASlab(_ ok: inout Bool) {
        print("\n-- B4: an opaque raster is not drawn as a 26% slab behind the copy --")

        // The premise, measured rather than assumed: every raster this app can
        // hand the watermark really is a solid rectangle. If a future asset is
        // genuinely cut out, the silhouette path below is the one it takes and
        // this check says so instead of failing.
        var slabs = 0
        for destination in RailDestination.allCases {
            guard let artwork = destination.drillHeaderArtwork else { continue }
            if HelmEmptyState.artworkIsOpaqueSlab(artwork) { slabs += 1 }
        }
        check(slabs > 0,
              "\(slabs) destination artwork(s) are opaque tiles - the case the fix is for", &ok)

        // And the state built with one draws the symbol instead. Read off the
        // rendered image view: a check that only asked whether `artwork` was
        // passed would pass against the slab being drawn.
        guard let artwork = RailDestination.kubernetes.drillHeaderArtwork else {
            fail("Kubernetes has no artwork - this check is vacuous", &ok); return
        }
        let state = HelmEmptyState(symbol: RailDestination.kubernetes.symbol,
                                   title: "No cluster yet",
                                   body: "Connect a host and pick its feed tab.",
                                   size: .standard,
                                   hue: RailDestination.kubernetes.domainHue,
                                   artwork: artwork)
        let window = OffScreenProbe.window(width: 600, height: 400)
        window.contentView = state
        state.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        state.layoutSubtreeIfNeeded()
        guard let drawn = state.debugWatermarkImage else {
            fail("the empty state rendered no watermark at all", &ok); return
        }
        check(drawn !== artwork,
              "the watermark is not the raster tile itself", &ok)
        check(!HelmEmptyState.artworkIsOpaqueSlab(drawn),
              "and what it does draw is a silhouette, not another solid tile", &ok)
    }

    // MARK: B6 - the page's own name is not the first thing to go

    private static func checkDrillTitleHasAFloorAndYieldsLast(_ ok: inout Bool) {
        print("\n-- B6: the drill title keeps a floor, and the search pill yields first --")

        let bar = DaylightBarController()
        bar.loadView()
        // Actions as well as a title: the finding's own render is the
        // Schedules page, which carries two, and they are part of what was
        // squeezing the title out.
        let action = HelmButton(title: "New Schedule", variant: .primary)
        for width in [1512.0, 1200.0, 1000.0, 900.0] as [CGFloat] {
            bar.view.frame = NSRect(x: 0, y: 0, width: width,
                                    height: DaylightBarController.height + DaylightBarController.topMargin)
            bar.setDrillContext(.init(title: RailDestination.schedules.title,
                                      subtitle: "3 saved \u{00B7} 1 needs you",
                                      symbol: RailDestination.schedules.symbol,
                                      hue: RailDestination.schedules.domainHue,
                                      artwork: nil))
            bar.setDrillActions([action])
            bar.view.layoutSubtreeIfNeeded()

            let titleWidth = bar.debugDrillTitleWidth()
            if titleWidth < HelmDrillHeader.titleMinWidth - 0.5 {
                fail("at \(width)pt the title is \(titleWidth)pt, below its \(HelmDrillHeader.titleMinWidth)pt floor", &ok)
            }
        }
        check(true, "the title holds its floor from 1512 down to 900", &ok)

        // And the pill is what pays for it. At a width where something has to
        // give, the search pill must be off its preferred 230 before the title
        // is off its own natural width.
        bar.view.frame = NSRect(x: 0, y: 0, width: 900,
                                height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()
        let pillWidth = bar.debugSearchPill().frame.width
        check(pillWidth < 230,
              "at 900pt the search pill has given up its preferred width (\(pillWidth))", &ok)
    }

    private static func checkQuickAccessCollapsesAndStillReachesEveryDestination(_ ok: inout Bool) {
        print("\n-- B6: the shortcut row collapses into a menu, and loses nothing --")

        let bar = DaylightBarController()
        bar.loadView()
        let height = DaylightBarController.height + DaylightBarController.topMargin

        bar.view.frame = NSRect(x: 0, y: 0, width: 1512, height: height)
        bar.view.layoutSubtreeIfNeeded()
        let expanded = bar.debugDestinationButtons().filter { !$0.isHidden }
        check(expanded.count == bar.debugDestinationButtons().count,
              "every shortcut shows at 1512pt (\(expanded.count))", &ok)
        // **Review #3's UX2 capped the drawn row at six**, so the overflow
        // button is now present even on a wide bar - it carries the seventh
        // pinned shortcut. This assertion is inverted rather than deleted:
        // what B6 was really about is that a *narrow* bar gives the row's
        // width back to the title, which is still checked below.
        let pinned = bar.quickAccessConfiguration.pinned
        check(pinned.count > QuickAccessConfiguration.visibleLimit,
              "the default row (\(pinned.count)) no longer exceeds UX2's cap - this case's "
              + "overflow checks would be vacuous", &ok)
        check(!bar.debugQuickAccessOverflowButton().isHidden,
              "the overflow button should carry the shortcuts past UX2's cap", &ok)

        // The row's own width while expanded, so the collapse below is
        // measured as a real reclaim rather than assumed.
        let expandedRowWidth = bar.debugQuickAccessRow().frame.width
        check(expandedRowWidth > 100,
              "the expanded shortcut row has no width (\(expandedRowWidth)) - the collapse "
              + "check below would be vacuous", &ok)

        bar.view.frame = NSRect(x: 0, y: 0, width: 1100, height: height)
        bar.view.layoutSubtreeIfNeeded()
        let collapsed = bar.debugDestinationButtons().filter { !$0.isHidden }
        check(collapsed.isEmpty, "at 1100pt the row is gone (\(collapsed.count) still showing)", &ok)
        check(!bar.debugQuickAccessOverflowButton().isHidden,
              "and the overflow button has taken its place", &ok)
        // **The width really comes back**, which is the half B6 exists for.
        // UX2 moved the buttons into an `NSStackView`, so a hidden arranged
        // subview genuinely leaves layout (the one exemption to gotcha (11))
        // and the *row* collapses - which is what to measure now. Reading the
        // buttons' own frames would report their last laid-out size and pass
        // while the row still cost its full width.
        let collapsedRowWidth = bar.debugQuickAccessRow().frame.width
        check(collapsedRowWidth < 0.5,
              "the collapsed shortcut row still costs \(collapsedRowWidth)pt "
              + "(was \(expandedRowWidth)pt expanded)", &ok)

        // Nothing is lost: the menu reaches every pinned destination, in
        // order, through the same callback a click on the icon uses. **Every
        // pinned one, not just the six drawn** - a collapsed bar has no icons
        // at all, so the menu is the only way to any of them.
        var picked: [RailDestination] = []
        bar.onSelectDestination = { picked.append($0) }
        let menu = bar.debugQuickAccessOverflowMenu()
        for item in menu.items where item.action != nil {
            _ = item.target?.perform(item.action, with: item)
        }
        check(picked == pinned,
              "the collapsed menu should reach \(pinned.map(\.title)) (reached \(picked.map(\.title)))", &ok)
    }

    // MARK: B8 - a toast belongs to the page that raised it

    private static func checkUpdatesToastStaysOnItsOwnPage(_ ok: inout Bool) {
        print("\n-- B8: the Updates sweep's toast does not land on another page --")
        withScratchEnv {
            let controller = UpdatesController()
            let window = OffScreenProbe.window(width: 1200, height: 800)
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            controller.view.layoutSubtreeIfNeeded()

            func toastCount() -> Int {
                guard let root = window.contentView else { return 0 }
                return Toast.debugCount(in: root)
            }

            controller.view.isHidden = false
            controller.debugShowCompletionToast("Checked 13 tools - all up to date")
            let onScreen = toastCount()
            check(onScreen == 1, "showing, the toast appears (\(onScreen))", &ok)

            // Navigating away hides the page; it stays mounted (GL-37), which
            // is exactly why the old `window.contentView` presentation kept
            // working and landed on whatever page was showing instead.
            controller.view.isHidden = true
            let before = toastCount()
            controller.debugShowCompletionToast("Checked 13 tools, 2 updates available")
            let after = toastCount()
            check(after == before,
                  "hidden, the sweep's completion raises no toast (\(before) -> \(after))", &ok)
        }
    }

    // MARK: B9 - a card is as tall as its own content

    /// B9 was measured against §7's two-column arrangement, where the short
    /// column was stretched to the tall one's height and the slack landed on
    /// one card (the Connection card resolving to 504pt against 133pt of
    /// content). `fm/grandline-settings-page-sidebar-redesign` replaced that
    /// arrangement with a sidebar and a single-column detail pane, so the
    /// exact mechanism is gone - but **the property B9 is about is not**, and
    /// a vertical `NSStackView` at the default `.gravityAreas` distribution
    /// is precisely the thing that reintroduces it. The case now sweeps every
    /// category's pane rather than one two-column render.
    private static func checkSettingsColumnsKeepCardsAtTheirOwnHeight(_ ok: inout Bool) {
        print("\n-- B9: a detail pane does not stretch a card past its own content --")
        withScratchEnv {
            let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                              snippetStore: SnippetStore(), dictationStore: DictationStore())
            let window = OffScreenProbe.window(width: 1512, height: 950)
            window.contentView = settings.view
            settings.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)
            settings.view.layoutSubtreeIfNeeded()
            settings.viewDidLayout()
            settings.view.layoutSubtreeIfNeeded()

            var worst: (name: String, frame: CGFloat, fitting: CGFloat)?
            var measured = 0
            for category in SettingsController.Category.allCases {
                settings.select(category)
                settings.view.layoutSubtreeIfNeeded()
                // Vacuity guard: a pane that mounted nothing, or mounted
                // cards that never laid out, would pass while measuring
                // nothing at all.
                let mounted = settings.debugMountedCards
                guard !mounted.isEmpty, mounted.allSatisfy({ $0.frame.height > 1 }) else {
                    fail("\(category.rawValue) mounted \(mounted.count) laid-out cards - this check is vacuous", &ok)
                    return
                }
                measured += mounted.count
                for card in mounted {
                    let slack = card.frame.height - card.fittingSize.height
                    if slack > 1, slack > (worst.map { $0.frame - $0.fitting } ?? 0) {
                        worst = (category.rawValue, card.frame.height, card.fittingSize.height)
                    }
                }
            }
            if let worst {
                fail("\(worst.name): a card is \(worst.frame)pt tall against \(worst.fitting)pt of content - "
                     + "review #3's B9 is back", &ok)
            } else {
                check(true, "every one of \(measured) cards is exactly as tall as its own content", &ok)
            }
        }
    }

    // MARK: B10 - a chip is content-sized

    private static func checkDictationChipIsContentSized(_ ok: inout Bool) {
        print("\n-- B10: the \"Model ready\" chip is not stretched across the card --")
        withScratchEnv {
            for width in [1512.0, 1100.0] as [CGFloat] {
                let controller = DictationController(store: DictationStore())
                let window = OffScreenProbe.window(width: width, height: 820)
                window.contentView = controller.view
                controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
                controller.view.layoutSubtreeIfNeeded()
                controller.debugSetStatus(.ready)
                controller.view.layoutSubtreeIfNeeded()

                // The page keeps its width: the pill was the row's only
                // flexible member, so making it rigid without a spacer took
                // the whole page down to its fitting width (measured, 391pt).
                check(abs(controller.view.frame.width - width) < 0.5,
                      "@\(width): the page is still \(width)pt wide (\(controller.view.frame.width))", &ok)

                let pill = controller.debugModelReadyPillFrame
                guard pill.width > 0 else {
                    fail("@\(width): the chip has no width at all", &ok); continue
                }
                check(pill.width < 200,
                      "@\(width): the chip is content-sized (\(pill.width)pt)", &ok)
                if pill.width > width / 2 {
                    fail("@\(width): review #3's B10 is back - the chip is \(pill.width)pt", &ok)
                }
            }
        }
    }

    // MARK: B11 - the panel shows whole rows

    private static func checkTaskPanelShowsWholeRows(_ ok: inout Bool) {
        print("\n-- B11: the My Tasks panel is a whole number of rows tall --")
        let box = ShiftController.debugTaskFollowUpPanelBodyHeight
        let row = ShiftTaskListView.rowHeight
        let rows = box / row
        check(abs(rows - rows.rounded()) < 0.01,
              "the box (\(box)) is exactly \(rows.rounded()) rows of \(row)", &ok)
        if abs(rows - rows.rounded()) >= 0.01 {
            fail("review #3's B11 is back: \(rows) rows, so the last one renders sliced", &ok)
        }

        // At every chrome text scale, not just the captain's current one - a
        // literal could not have stayed whole across them, which is why the
        // fix derives it.
        let saved = AppSettings.shared.uiTextScale
        defer { ChromeTextScale.shared.setScale(saved) }
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            let scaledRows = ShiftController.debugTaskFollowUpPanelBodyHeight / ShiftTaskListView.rowHeight
            if abs(scaledRows - scaledRows.rounded()) >= 0.01 {
                fail("at \(step.title) the panel is \(scaledRows) rows tall", &ok)
            }
        }
    }

    // MARK: B12 - the first note clears the header

    private static func checkStickyFirstNoteClearsTheHeader(_ ok: inout Bool) {
        print("\n-- B12: a cascaded note starts below the board header --")
        withScratchEnv {
            let controller = StickyBoardController()
            let window = OffScreenProbe.window(width: 1400, height: 900)
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            controller.view.layoutSubtreeIfNeeded()

            // Measured against the real header rather than against the
            // constant, so the constant cannot drift away from the thing it
            // was measured from.
            let header = controller.debugBoardHeaderBottomInset
            guard header > 0 else {
                fail("the board header measured \(header)pt - this check is vacuous", &ok); return
            }
            let firstNoteTop = StickyBoardMetrics.cascadeOrigin(index: 0).y
            check(firstNoteTop >= header,
                  "the first note starts at \(firstNoteTop), below the header's \(header)", &ok)
            if firstNoteTop < header {
                fail("review #3's B12 is back: the first note is \(header - firstNoteTop)pt under the header", &ok)
            }

            // Every cascaded note, not only the first: the row height and the
            // clearance have to agree or the second row lands back under it.
            for index in 0..<6 where StickyBoardMetrics.cascadeOrigin(index: index).y < header {
                fail("note \(index) cascades to y \(StickyBoardMetrics.cascadeOrigin(index: index).y), under the header", &ok)
            }

            // And the placeholder reads as a prompt rather than as a title.
            check(StickyNoteView.titlePlaceholder != "Title",
                  "an untitled note does not show a literal \"Title\" (shows \"\(StickyNoteView.titlePlaceholder)\")", &ok)
        }
    }

    // MARK: B16 - a crew handoff needs a live session

    private static func checkCrewHandoffRefusesARestoredPage(_ ok: inout Bool) {
        print("\n-- B16: the crew's SRE Lead link will not wake a restored page --")
        let registry = HostSessionRegistry()
        let hostID = UUID()
        registry.register(hostID: hostID, label: "Prod Bastion", accentHex: nil, state: .restored)
        check(!registry.isConnected(hostID),
              "a restored entry is in the registry and is not connected", &ok)
        // The predicate the fix turns on, asserted directly: the method itself
        // needs a whole mounted shell, and what went wrong was reading
        // `sessions` where `isConnected` was meant.
        check(registry.sessions.filter(\.isConnected).isEmpty,
              "and filtering to connected sessions leaves nothing to hand off to", &ok)
        registry.setState(hostID: hostID, .connected)
        check(registry.sessions.filter(\.isConnected).count == 1,
              "once it really connects, the same filter finds it", &ok)

        // And a source guard, because the two checks above assert the
        // predicate rather than the call site - which is exactly what went
        // wrong. `openSRELeadForCrew` read `sessions.sessions`, a set that
        // includes a page F2 restored but never connected, so the crew's link
        // offered to open SRE Lead on a host with no live session. Driving the
        // real method needs a whole mounted shell plus a real host page; the
        // regression worth catching is one word at one call site.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"),
                                       encoding: .utf8) else {
            print("  NOTE could not locate the app's sources; skipping B16's wiring guard")
            return
        }
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        check(code.contains("sessions.sessions.filter(\\.isConnected)"),
              "the crew handoff still filters the registry to genuinely connected sessions", &ok)
    }

    // MARK: B17 - a stale Touch ID key is not a wrong password

    private static func checkStaleTouchIDKeyIsNotAWrongPassword(_ ok: inout Bool) {
        print("\n-- B17: a stale stored key gets its own outcome --")
        // The outcome exists and is distinct - a check that only asserted
        // "unlock failed" would pass with it folded back into `.wrongPassword`,
        // which is the defect.
        let stale = VaultUnlockOutcome.staleTouchIDKey
        check(stale != .wrongPassword(attemptsUntilDelay: 1),
              "`.staleTouchIDKey` is not a `.wrongPassword`", &ok)
        check(stale != .failed("x"),
              "and not folded into the generic failure either", &ok)

        // And the call site, as source. Reaching `finishUnlock`'s
        // keychain-key branch for real needs an encrypted vault on disk plus a
        // stored key in this Mac's login Keychain that no longer opens it -
        // neither of which a headless suite may create (and the second would
        // prompt). What the two checks above can see is that the case exists;
        // what went wrong is which case that branch returns, whether the dead
        // key is removed, and whether a failure nobody caused is counted
        // against the password throttle.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("CredentialVaultStore.swift"),
                                       encoding: .utf8) else {
            print("  NOTE could not locate the app's sources; skipping B17's wiring guard")
            return
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let branch = lines.firstIndex(where: { $0.contains("if keyCameFromKeychain {") }) else {
            check(false, "the stale-key branch is gone from `finishUnlock`", &ok)
            return
        }
        let body = lines[branch..<min(branch + 8, lines.count)]
            .prefix { !$0.contains("failedAttempts += 1") }
            .joined(separator: "\n")
        check(body.contains("return .staleTouchIDKey"),
              "a key that came from the Keychain and does not open the vault reports `.staleTouchIDKey`", &ok)
        check(body.contains("CredentialVaultKeyStore.remove()"),
              "and the dead key is removed rather than left to fail the same way next time", &ok)
        check(!body.contains("failedAttempts += 1"),
              "and it is not counted against the password throttle", &ok)
    }
}
#endif
