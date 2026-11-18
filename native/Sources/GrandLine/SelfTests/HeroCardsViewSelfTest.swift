// Grand Line - native macOS app.
//
// Home's two hero cards (the widget-style board's picks: the Claude card's
// split hero and the Fleet card's full hero), drawn by the real Home canvas
// in a real probe window.
//
// Window-backed, because what it asserts is real layout: where the gradient
// lands at each of the three sizes, that every word on it is painted in the
// palette's ink and fits inside the card, and that the style menu's size and
// colour items reach the arrangement and the card. The pure half - the
// palette over every preset and theme, the five states' words, the stored
// colour - is `HeroCardsSelfTest`.
//
// With `FM_HERO_RENDER_DIR` set it also writes one PNG per card, size, state
// and theme into that folder (the PR's renders). Nothing is written otherwise.
//
// Run with:
//   swift build && FM_RUN_HERO_CARDS_VIEW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum HeroCardsViewSelfTest {

    static func run() -> Bool {
        let savedTheme = ThemeManager.shared.theme
        let savedColors = AppSettings.shared.homeCardColors
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.homeCardColors = savedColors
        }
        AppSettings.shared.homeCardColors = [:]
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }

        var allOK = true
        let checks: [(inout Bool) -> Void] = [
            checkTheRegionFollowsTheSize,
            checkTheTitleStopsAtThePanel,
            checkEveryWordIsInkAndInsideTheCard,
            checkTheSizeItemsArrangeTheCard,
            checkTheColourItemsRepaintTheCard,
            checkTheMenuButtonDoesNotOpenTheCard,
            checkBothCardsOfferThePaletteAtEverySize,
            checkAnUnfinishedDragEndsWithCustomize,
            checkHideFromTheMenuAndBringItBack,
            writeRenders,
        ]
        for check in checks {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "HeroCardsViewSelfTest: all checks passed" : "HeroCardsViewSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    enum State: String, CaseIterable {
        case normal, warn, critical, stale, idle
    }

    static func quota(_ state: State) -> QuotaSnapshot {
        let resets = Date().addingTimeInterval(3 * 86_400)
        func window(_ kind: QuotaWindow.Kind, _ used: Double) -> QuotaWindow {
            QuotaWindow(kind: kind, percentUsed: used, resetsAt: resets, pace: .onPace)
        }
        let used: (Double, Double, Double, Double)
        switch state {
        case .normal, .stale: used = (0, 49, 33, 0)
        case .warn: used = (62, 84, 71, 4)
        case .critical: used = (100, 93, 88, 15)
        case .idle: used = (0, 0, 0, 0)
        }
        return QuotaSnapshot(plan: plan, session: window(.session, used.0), weekly: window(.weekly, used.1),
                             fable: window(.fable, used.2),
                             extraUsage: QuotaCreditWindow(percentUsed: nil, spentUsd: used.3, limitUsd: 15),
                             latency: 1.2, log: "")
    }

    static func fleet(_ state: State) -> FleetSnapshot {
        func task(_ id: String, _ status: String) -> FleetTask {
            var task = FleetTask(id: id, repo: "grand-line", kind: "ship", pr: nil)
            task.status = status
            return task
        }
        var tasks: [FleetTask]
        var watcher = "healthy"
        switch state {
        case .normal: tasks = [task("hero-cards", "working"), task("ci-flake", "working"), task("docs-sync", "working")]
        case .warn: tasks = [task("widget-style", "needs_decision"), task("hero-cards", "working"),
                             task("ci-flake", "working")]
        case .critical: tasks = [task("ci-shard-flake", "blocked"), task("widget-style", "needs_decision"),
                                 task("hero-cards", "working")]
        case .stale:
            tasks = [task("hero-cards", "working"), task("ci-flake", "working"), task("docs-sync", "working")]
            watcher = "stale"
        case .idle: tasks = []
        }
        return FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 46, doneCount: 20,
                             projectsCount: 4, watcher: WatcherHealth(status: watcher))
    }

    static let windowWidth: CGFloat = 1512
    /// The plan the Claude fixture reports. One check makes it long enough to
    /// reach past a split card's panel.
    static var plan = "team"

    /// The real canvas, Home's arranged cards set to the two hero cards at
    /// `mode`, fed `state`, in a probe window.
    static func mountCanvas(_ mode: HomeCardSizeMode, state: State, theme: HelmTheme,
                            body: (HomeCanvasController, NSWindow) -> Void) {
        ThemeManager.shared.setTheme(theme)
        let canvas = HomeCanvasController(sources: .init(
            shiftStore: ShiftStore(), hostStore: HostStore(), scheduleStore: ScheduleStore(),
            logAnalyzerStore: LogAnalyzerStore(), docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: CodePreviewStore(), notebookStore: NotebookStore(),
            readingListStore: ReadingListStore(), commandLibraryStore: CommandLibraryStore(),
            stickyBoardStore: StickyBoardStore()))
        let window = OffScreenProbe.window(width: windowWidth, height: 1100)
        window.contentView = canvas.view
        canvas.cardLayout = HomeCardLayout(shown: [.claudeStatus, .fleet],
                                           sizes: [.claudeStatus: mode.size, .fleet: mode.size])
        canvas.applyQuota(.success(quota(state)))
        if state == .stale { canvas.applyQuota(.failure("quota-axi timed out")) }
        canvas.applyFleet(snapshot: fleet(state), mergedPRs: [], prFetchFailure: nil)
        canvas.debugRenderNow()
        window.layoutIfNeeded()
        canvas.view.layoutSubtreeIfNeeded()
        body(canvas, window)
        window.contentView = nil
        window.close()
    }

    static var daylight: HelmTheme { HelmTheme.appThemes.first { $0.id == "daylight" } ?? ThemeManager.shared.theme }
    static var dusk: HelmTheme { HelmTheme.appThemes.first { $0.id == "dusk" } ?? ThemeManager.shared.theme }

    // MARK: Checks

    private static func checkTheRegionFollowsTheSize(_ ok: inout Bool) {
        let expected: [(HomeCardSizeMode, String)] = [(.narrow, "band"), (.standard, "leading:226"),
                                                      (.fullWidth, "leading:470")]
        for (mode, region) in expected {
            mountCanvas(mode, state: .normal, theme: daylight) { canvas, _ in
                guard let claude = canvas.cardForTests(.claudeStatus), let fleet = canvas.cardForTests(.fleet) else {
                    fail("\(mode): the canvas drew no Claude or Fleet card", &ok)
                    return
                }
                check(claude.debugHeroRegion == region,
                      "\(mode): the Claude card's gradient is \(claude.debugHeroRegion ?? "absent"), expected \(region)", &ok)
                check(fleet.debugHeroRegion == "card",
                      "\(mode): the Fleet card's gradient is \(fleet.debugHeroRegion ?? "absent"), expected the whole card", &ok)
                // The gradient's frame is the region: a split panel is its
                // width and the card's height, a band ends under the panel.
                if let surface = claude.debugHeroSurface {
                    let frame = surface.convert(surface.bounds, to: claude)
                    switch mode {
                    case .narrow:
                        let panel = claude.debugHeroPanelAnchor.map { $0.convert($0.bounds, to: claude) }
                        check(abs(frame.width - claude.bounds.width) < 1,
                              "narrow: the band is \(frame.width)pt of a \(claude.bounds.width)pt card", &ok)
                        check(panel.map { frame.minY < $0.minY && frame.height < claude.bounds.height * 0.75 } ?? false,
                              "narrow: the band does not end under the panel (band \(frame), panel \(String(describing: panel)))", &ok)
                    case .standard, .fullWidth:
                        let width: CGFloat = mode == .standard ? 226 : 470
                        check(abs(frame.width - width) < 1 && abs(frame.height - claude.bounds.height) < 1,
                              "\(mode): the panel is \(frame.size), expected \(width) x \(claude.bounds.height)", &ok)

                    }
                }
                // The card is the width the mode names.
                let expectedWidth = HomeCardGrid.width(columns: mode.columns, containerWidth: canvas.view.bounds.width
                                                         - HomeCanvasController.gutter * 2, spacing: HomeCanvasController.gridSpacing)
                check(abs(claude.bounds.width - expectedWidth) < 40,
                      "\(mode): the Claude card is \(claude.bounds.width)pt wide, about \(expectedWidth) expected", &ok)
            }
        }
    }

    /// Beside a split panel the header's title column stops inside the
    /// panel, so its white words never run onto the card's own surface. A
    /// long plan name is what would push it there.
    private static func checkTheTitleStopsAtThePanel(_ ok: inout Bool) {
        plan = "enterprise annual commitment"
        defer { plan = "team" }
        for (mode, width) in [(HomeCardSizeMode.standard, CGFloat(226)), (.fullWidth, 470)] {
            mountCanvas(mode, state: .normal, theme: daylight) { canvas, _ in
                guard let claude = canvas.cardForTests(.claudeStatus) else { return }
                let subtitle = claude.debugSubtitleLabel
                check(subtitle.stringValue.count > 30, "fixture: the plan name is short (\(subtitle.stringValue))", &ok)
                let frame = subtitle.convert(subtitle.bounds, to: claude)
                // A label's frame runs 2pt past its text on each side (the
                // cell's own padding), so the words end at the cap.
                check(frame.maxX <= width - HelmModuleCard.horizontalInset + 2.5,
                      "\(mode): \"\(subtitle.stringValue)\" runs to \(frame.maxX), past the \(width)pt panel", &ok)
            }
        }
    }

    private static func checkEveryWordIsInkAndInsideTheCard(_ ok: inout Bool) {
        for theme in [daylight, dusk] {
            for mode in HomeCardSizeMode.allCases {
                for state in State.allCases {
                    mountCanvas(mode, state: state, theme: theme) { canvas, _ in
                        for module in HomeCardStyle.modules {
                            guard let card = canvas.cardForTests(module), let surface = card.debugHeroSurface,
                                  let palette = surface.palette else {
                                fail("\(theme.id) \(mode) \(state): \(module) has no hero", &ok)
                                continue
                            }
                            let tag = "\(theme.id) \(mode) \(state) \(module.rawValue)"
                            let ink = HelmContrast.color(palette.ink)
                            check(HelmContrast.ratio(palette.ink, palette.start) >= HelmContrast.textTarget
                                    && HelmContrast.ratio(palette.ink, palette.end) >= HelmContrast.textTarget,
                                  "\(tag): the ink does not clear the text floor on both stops", &ok)
                            let words = card.debugHeroInkLabels
                            check(!words.isEmpty, "\(tag): no words on the hero", &ok)
                            for label in words + [card.debugTitleLabel] {
                                check(isPainted(label.textColor, ink),
                                      "\(tag): \"\(label.stringValue)\" is not painted in the hero's ink", &ok)
                                let frame = label.convert(label.bounds, to: card)
                                check(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                      "\(tag): \"\(label.stringValue)\" at \(frame) is outside the \(card.bounds.size) card", &ok)
                            }
                            // The Fleet hero's numbers are on the gradient too.
                            if module == .fleet {
                                let strip = card.debugKPIStrip
                                let known = strip?.debugValueColors.enumerated()
                                    .filter { (strip?.debugValues[$0.offset] ?? "0") != "0" } ?? []
                                check(!known.isEmpty && known.allSatisfy { isPainted($0.element, ink) },
                                      "\(tag): the KPI strip's figures are not in the hero's ink", &ok)
                            }
                            // Stale dims the colour (GL-14); every other state
                            // keeps the captain's colour.
                            let fresh = HelmModuleCard.HeroTone(colour: .themeAccent).palette(in: theme)
                            check((palette == fresh) == (state != .stale),
                                  "\(tag): the colour is \(state == .stale ? "not dimmed" : "dimmed")", &ok)
                        }
                        // A split card's report sits on the card's surface and
                        // keeps the theme's colours.
                        if let claude = canvas.cardForTests(.claudeStatus), mode != .narrow {
                            let caption = claude.debugHeaderCaptionLabel
                            check(caption.isHidden || caption.textColor.map {
                                HelmContrast.ratio($0, HelmTheme.mutedInk(theme)) < 1.001 } ?? false,
                                  "\(theme.id) \(mode) \(state): the split card's caption left the theme's muted ink", &ok)
                        }
                    }
                }
            }
        }
    }

    private static func checkTheSizeItemsArrangeTheCard(_ ok: inout Bool) {
        mountCanvas(.standard, state: .normal, theme: daylight) { canvas, _ in
            var kept: HomeCardLayout?
            canvas.onCardLayoutChanged = { kept = $0 }
            guard let card = canvas.cardForTests(.fleet), let menu = card.debugHeaderMenu() else {
                fail("the Fleet card has no style menu", &ok)
                return
            }
            let titles = menu.items.map(\.title)
            for title in ["Size", "Narrow", "Default", "Full width", "Colour", "Theme accent", "Custom colour\u{2026}"] {
                check(titles.contains(title), "the style menu has no \"\(title)\" item (\(titles))", &ok)
            }
            check(menu.items.first { $0.title == "Default" }?.state == .on,
                  "the Default size is not checked for a half-row card", &ok)
            guard let full = menu.items.first(where: { $0.title == "Full width" }) else { return }
            fire(full)
            check(canvas.cardLayout?.size(of: .fleet).columns == HomeCardGrid.columns,
                  "Full width left the card at \(canvas.cardLayout?.size(of: .fleet).columns ?? -1) columns", &ok)
            check(kept?.size(of: .fleet).columns == HomeCardGrid.columns,
                  "Full width was not handed to the shell to keep", &ok)
            canvas.view.layoutSubtreeIfNeeded()
            let menuAfter = canvas.cardForTests(.fleet)?.debugHeaderMenu()
            check(menuAfter?.items.first { $0.title == "Full width" }?.state == .on,
                  "the menu does not check Full width after choosing it", &ok)
        }
    }

    private static func checkTheColourItemsRepaintTheCard(_ ok: inout Bool) {
        mountCanvas(.standard, state: .normal, theme: daylight) { canvas, _ in
            guard let menu = canvas.cardForTests(.claudeStatus)?.debugHeaderMenu(),
                  let teal = menu.items.first(where: { $0.title == HomeCardColorPreset.teal.title }) else {
                fail("the Claude card's style menu has no Teal", &ok)
                return
            }
            let before = canvas.cardForTests(.claudeStatus)?.debugHeroSurface?.palette
            fire(teal)
            canvas.view.layoutSubtreeIfNeeded()
            let expected = HelmHeroSurface.palette(accent: HomeCardColor.preset(.teal).rgb(in: daylight))
            let after = canvas.cardForTests(.claudeStatus)?.debugHeroSurface?.palette
            check(before != expected, "fixture: the accent is already teal's palette", &ok)
            check(after == expected, "choosing Teal did not repaint the Claude card in teal", &ok)
            check(HomeCardStyle.color(for: .claudeStatus) == .preset(.teal), "Teal was not stored", &ok)
            check(canvas.cardForTests(.fleet)?.debugHeroSurface?.palette != expected,
                  "Teal reached the Fleet card too - the colour is per card", &ok)
            let checked = canvas.cardForTests(.claudeStatus)?.debugHeaderMenu()?.items
                .first { $0.title == HomeCardColorPreset.teal.title }?.state
            check(checked == .on, "the menu does not check Teal after choosing it", &ok)
            // A theme change keeps a preset (it is fixed) and moves the accent.
            ThemeManager.shared.setTheme(dusk)
            check(canvas.cardForTests(.claudeStatus)?.debugHeroSurface?.palette == expected,
                  "a preset moved with the theme", &ok)
            check(canvas.cardForTests(.fleet)?.debugHeroSurface?.palette
                    == HelmHeroSurface.palette(for: dusk),
                  "the accent card did not follow the theme to Dusk", &ok)
            HomeCardStyle.setColor(.accent, for: .claudeStatus)
        }
    }

    /// Gotcha (20): the card is one click target, and a click on the palette
    /// button must open the menu rather than the card's page.
    private static func checkTheMenuButtonDoesNotOpenTheCard(_ ok: inout Bool) {
        mountCanvas(.standard, state: .normal, theme: daylight) { canvas, window in
            guard let card = canvas.cardForTests(.fleet) else { return }
            let button = card.debugHeaderMenuButton
            check(!button.isHidden, "the palette button is hidden outside Customize", &ok)
            // Wired to the card, which opens the menu (popping it up would
            // start a modal tracking loop in a suite).
            check(button.target === card && button.action != nil,
                  "the palette button is not wired to its card", &ok)
            let recognizer = card.debugCardHitView.gestureRecognizers.first { $0 is NSClickGestureRecognizer }
            guard let recognizer else {
                fail("fixture: the card has no click recognizer", &ok)
                return
            }
            func event(at view: NSView) -> NSEvent? {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1)
            }
            if let onButton = event(at: button) {
                check(!card.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onButton),
                      "a click on the palette button would also open the card", &ok)
            }
            // The card's own surface still opens it, so the check above can fail.
            if let onBody = event(at: card.debugTitleLabel) {
                check(card.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onBody),
                      "fixture: a click on the card's title does not open the card either", &ok)
            }
            // And Customize takes the button away with the rest of the header.
            canvas.setCustomizing(true)
            check(canvas.cardForTests(.fleet)?.debugHeaderMenuButton.isHidden ?? false,
                  "the palette button stays up while Customize is arranging", &ok)
            canvas.setCustomizing(false)
        }
    }

    /// Both cards carry the palette at every size and in both themes, as one
    /// header control row: inside the card and clear of Refresh. The menu it
    /// opens offers the sizes, the colours and Hide.
    private static func checkBothCardsOfferThePaletteAtEverySize(_ ok: inout Bool) {
        for theme in [daylight, dusk] {
            for mode in HomeCardSizeMode.allCases {
                mountCanvas(mode, state: .normal, theme: theme) { canvas, _ in
                    for module in HomeCardStyle.modules {
                        let name = "\(theme.id) \(mode) \(module.title)"
                        guard let card = canvas.cardForTests(module) else {
                            fail("\(name): the canvas drew no card", &ok)
                            continue
                        }
                        let button = card.debugHeaderMenuButton
                        check(!button.isHidden, "\(name): the palette button is hidden", &ok)
                        let surface = card.debugCardHitView
                        let frame = button.convert(button.bounds, to: surface)
                        check(frame.width > 0 && surface.bounds.contains(frame),
                              "\(name): the palette button at \(frame) is outside the \(surface.bounds.size) card", &ok)
                        if let action = card.debugHeaderActionFrameInCard {
                            check(!action.intersects(frame),
                                  "\(name): the palette button \(frame) overlaps the header action \(action)", &ok)
                        }
                        let titles = card.debugHeaderMenu()?.items.map(\.title) ?? []
                        for title in ["Narrow", "Default", "Full width", "Theme accent", HomeCardStyleMenu.hideTitle] {
                            check(titles.contains(title), "\(name): the palette menu has no \(title) (\(titles))", &ok)
                        }
                    }
                }
            }
        }
    }

    /// A resize drag whose mouse-up never arrives must not outlive Customize.
    /// It did: Done rebuilt Home but kept the dragged card, strip and grips
    /// included, so the Claude card showed Customize's reset, move and hide
    /// controls where its palette belongs, while Fleet showed its palette.
    /// The drag enters through the grip's own mouse handlers.
    private static func checkAnUnfinishedDragEndsWithCustomize(_ ok: inout Bool) {
        for edge in HomeCardResizeHandle.Edge.allCases {
            mountCanvas(.standard, state: .normal, theme: daylight) { canvas, window in
                var stored: [HomeCardLayout] = []
                canvas.onCardLayoutChanged = { stored.append($0) }
                canvas.setCustomizing(true)
                window.layoutIfNeeded()
                guard let card = canvas.cardForTests(.claudeStatus),
                      let grip = canvas.resizeHandlesForTests[.claudeStatus]?.first(where: { $0.edge == edge }) else {
                    fail("\(edge): Customize drew no Claude card or grip", &ok)
                    return
                }
                let start = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
                func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)
                }
                let before = canvas.cardLayout
                if let down = event(.leftMouseDown, start) { grip.mouseDown(with: down) }
                if let drag = event(.leftMouseDragged, NSPoint(x: start.x + 120, y: start.y - 60)) {
                    grip.mouseDragged(with: drag)
                }
                // The drag really sized the card, so the checks below can fail.
                check(canvas.cardLayout != before, "\(edge): fixture: the drag did not size the card", &ok)
                let dragged = canvas.cardLayout

                canvas.setCustomizing(false)
                window.layoutIfNeeded()
                guard let after = canvas.cardForTests(.claudeStatus) else {
                    fail("\(edge): Done drew no Claude card", &ok)
                    return
                }
                check(after.debugHeaderAccessoryFrameInCard == nil,
                      "\(edge): the Claude card kept Customize's strip after Done", &ok)
                check(!after.subviews.contains { $0 is HomeCardResizeHandle },
                      "\(edge): the Claude card kept its grips after Done", &ok)
                check(!after.debugHeaderMenuButton.isHidden,
                      "\(edge): the Claude card's palette is hidden after Done", &ok)
                check(after !== card || after.debugHeaderAccessoryFrameInCard == nil,
                      "\(edge): Done kept the dragged card as it was", &ok)
                // The size the card was dragged to is what Home keeps.
                check(canvas.cardLayout == dragged && stored.last == dragged,
                      "\(edge): the dragged size was not kept (stored \(stored.count) layouts)", &ok)
            }
        }
    }

    /// "Hide from Home" on either card takes it off Home, the toast's Undo
    /// puts it back, and Customize's Add a Card brings it back too.
    private static func checkHideFromTheMenuAndBringItBack(_ ok: inout Bool) {
        for module in HomeCardStyle.modules {
            mountCanvas(.standard, state: .normal, theme: daylight) { canvas, window in
                var stored: [HomeCardLayout] = []
                canvas.onCardLayoutChanged = { stored.append($0) }
                func hide() {
                    let item = canvas.cardForTests(module)?.debugHeaderMenu()?.items
                        .first { $0.title == HomeCardStyleMenu.hideTitle }
                    guard let item else {
                        fail("\(module.title): the palette menu has no Hide", &ok)
                        return
                    }
                    fire(item)
                    window.layoutIfNeeded()
                }
                let before = canvas.cardLayout
                check(before?.shown.contains(module) ?? false, "\(module.title): fixture: the card is not on Home", &ok)

                hide()
                check(!(canvas.cardLayout?.shown.contains(module) ?? true) && canvas.cardForTests(module) == nil,
                      "\(module.title): Hide from Home left the card on Home", &ok)
                check(stored.last == canvas.cardLayout, "\(module.title): the hide was not kept", &ok)
                check(Toast.debugCount(in: canvas.view) == 1, "\(module.title): no toast said how to bring it back", &ok)
                let undo = allViews(in: canvas.view).compactMap { $0 as? HelmButton }.first { $0.title == "Undo" }
                check(undo != nil, "\(module.title): the toast has no Undo", &ok)
                undo?.performClick(nil)
                window.layoutIfNeeded()
                check(canvas.cardLayout == before && canvas.cardForTests(module) != nil && stored.last == before,
                      "\(module.title): Undo did not put the card back", &ok)

                hide()
                canvas.setCustomizing(true)
                let tray = canvas.customizeTrayForTests
                check(tray?.hiddenCards.contains(module) ?? false,
                      "\(module.title): Customize's Add a Card does not offer the hidden card", &ok)
                tray?.onAdd?(module)
                check(canvas.cardLayout?.shown.contains(module) ?? false && canvas.cardForTests(module) != nil,
                      "\(module.title): Add a Card did not bring the card back", &ok)
                canvas.setCustomizing(false)
            }
        }
    }

    private static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews(in: $0) }
    }

    /// `color` is exactly `ink`, alpha included. A luminance ratio is not
    /// enough here: a label left at the system's `labelColor` resolves to
    /// white at 85% under a dark appearance, which measures as white ink.
    static func isPainted(_ color: NSColor?, _ ink: NSColor) -> Bool {
        guard let color, color.type == .componentBased,
              let a = color.usingColorSpace(.sRGB), let b = ink.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }

    private static func fire(_ item: NSMenuItem) {
        // The item's own target and action, as the menu sends them. `NSApp`
        // is never touched in a suite (AGENTS.md).
        guard let action = item.action, let target = item.target as? NSObject else { return }
        target.perform(action, with: item)
    }

    // MARK: Renders

    private static func writeRenders(_ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_HERO_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colours: [(String, HomeCardColor)] = [("accent", .accent), ("ember", .preset(.ember)),
                                                  ("forest", .preset(.forest))]
        for theme in [daylight, dusk] {
            for (colourName, colour) in colours {
                let states: [State] = colourName == "accent" ? State.allCases : [.normal, .critical]
                for state in states {
                    for mode in HomeCardSizeMode.allCases {
                        HomeCardStyle.setColor(colour, for: .claudeStatus)
                        HomeCardStyle.setColor(colour, for: .fleet)
                        mountCanvas(mode, state: state, theme: theme) { canvas, _ in
                            for module in HomeCardStyle.modules {
                                guard let card = canvas.cardForTests(module) else { continue }
                                let name = "\(module == .claudeStatus ? "claude" : "fleet")-\(theme.id)-\(colourName)-\(state.rawValue)-\(mode.columns)col.png"
                                write(card, on: theme, to: folder.appendingPathComponent(name))
                            }
                        }
                    }
                }
            }
        }
        AppSettings.shared.homeCardColors = [:]
        print("HeroCardsViewSelfTest: renders written to \(dir)")
    }

    /// The card on a patch of the page's own ground, so its edge and shadow
    /// read as they do on Home.
    private static func write(_ card: HelmModuleCard, on theme: HelmTheme, to url: URL) {
        let margin: CGFloat = 16
        let frame = card.convert(card.bounds, to: card.superview).insetBy(dx: -margin, dy: -margin)
        guard let host = card.superview,
              let rep = host.bitmapImageRepForCachingDisplay(in: frame) else { return }
        host.cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: frame.size)
        image.lockFocus()
        HelmTheme.nsColor(theme.backgroundHex).setFill()
        NSRect(origin: .zero, size: frame.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: frame.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

#endif
