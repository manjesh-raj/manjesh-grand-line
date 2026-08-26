// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 3**'s own suite: the two destinations §7 puts
// next, Setup (four tabs) and Schedules.
//
// What each case is actually protecting, and why it is worth a test rather
// than a read-through:
//
//   1. **Both pages really reached the drill header** (§6.4), and Setup's line
//      is genuinely *per tab*. The seam is a protocol conformance, and a
//      missing one is invisible - the header just renders the static per-area
//      line, which looks like a design choice. Setup is the case worth pinning
//      hardest: four sub-pages count entirely different things, so a subtitle
//      that did not follow the tab would still read plausibly on whichever tab
//      happened to be showing when it was written.
//   2. **A page that has not finished its first check says so.** This is
//      Phase 3's honesty rule applied to a header line: "0 need attention" on
//      a page whose sweep has not run yet is a confident claim it has not
//      earned, and the failure is silent (a real, plausible-looking number).
//   3. **Schedules' add action is the card's own button instance, hoisted** -
//      not a copy built for the header, and no longer in the card header. A
//      second "+ New Schedule" a few rows apart is exactly the duplication
//      §6.4's cluster exists to remove.
//   4. **§6.5's Daylight row recipe, measured** - one radius / one fill / one
//      border / one hover per theme across `ToolRowLayout`'s real rows, and
//      the load-bearing half: a signal row carries its state as a **wash of
//      the semantic hue** with a *neutral* border, while every non-Daylight
//      palette keeps the tinted border and no wash. Both halves matter: the
//      first is the restyle, the second is the "the other twelve render
//      byte-identically" rule this whole migration turns on.
//   5. **§7's amber primary Update.** Its fill has to be Setup's own domain
//      hue run through §2.4's correction (a raw amber under a white label
//      measures 3.85), and it has to be `accentHex` again off Daylight -
//      `HelmButton.domainHue` changes a `.primary` on all thirteen palettes,
//      so a hue set unconditionally would restyle twelve of them.
//   6. **§7's mono time column really is a column** - one constant x down the
//      list, mono font - and **a never-run schedule gets no tick.** There is
//      no run history in `AutomationSchedule`, so the interesting failure is a
//      *fabricated* glyph, exactly as for Health's ticks in slice 2.
//   7. **No new window-width floor.** Every constraint this slice added sits
//      inside `bodyContainer`, and AGENTS.md gotcha (13) is this codebase's
//      most expensive recurring bug. `AppShellBodyWidthSelfTest` is the broad
//      sweep; this is the local one for the two pages just touched.
//
// **Nothing here calls `viewWillAppear` on a Setup sub-page.** All four start
// their real `brew`/`npm`/`git`/`gh` sweeps from that callback, so a suite that
// mounted them through `contentViewController` (which fires appearance
// callbacks) would shell out against the captain's real machine. Mounting the
// container's *view* builds every page's `loadView` - which touches no
// subprocess - and nothing more.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE3_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice3SelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkSetupDrillHeaderIsPerTab,
                      checkSchedulesDrillHeader,
                      checkRowRecipeAndSignalWash,
                      checkUpdateButtonIsAmberPrimary,
                      checkTimeColumnAndTicks,
                      checkNoWindowWidthFloor] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSlice3SelfTest: all checks passed"
                    : "DaylightDrillPageSlice3SelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylight: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    /// Any non-Daylight palette, for the "the other twelve are untouched" half.
    private static var otherTheme: HelmTheme {
        HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-slice3-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scratch store files, so nothing here can reach the captain's real data
    /// (the convention every store-backed suite in this repo follows).
    private static func scratchStores() -> (HostStore, SSHKeyStore, DictationStore, ScheduleStore) {
        let dir = scratchDir()
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        setenv("FM_SCHEDULES_FILE", dir.appendingPathComponent("schedules.json").path, 1)
        return (HostStore(), SSHKeyStore(), DictationStore(), ScheduleStore())
    }

    private static func makeSetup() -> SetupContainerController {
        let (hostStore, keyStore, dictationStore, _) = scratchStores()
        return SetupContainerController(
            updates: UpdatesController(),
            bootstrap: BootstrapController(hostStore: hostStore, keyStore: keyStore,
                                           dictationStore: dictationStore),
            automation: AutomationController(hostStore: hostStore, keyStore: keyStore,
                                             dictationStore: dictationStore),
            githubSync: GitHubSyncController())
    }

    /// Mounts a controller's **view** in a window - never as
    /// `contentViewController`, which would fire the appearance callbacks that
    /// start the Setup pages' real check sweeps (see the file header).
    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// Component-wise, deliberately **not** `HelmContrast.ratio(a, b) < 1.01`:
    /// that compares relative *luminance*, so two entirely different hues of
    /// similar brightness pass it (slice 2's own recorded lesson).
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    /// A layer's border colour as an `NSColor`, or nil.
    private static func borderColor(of view: NSView) -> NSColor? {
        view.layer?.borderColor.map { NSColor(cgColor: $0) } ?? nil
    }

    private static func labels(in view: NSView, containing needle: String) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, label.stringValue.contains(needle) { found.append(label) }
        for sub in view.subviews { found += labels(in: sub, containing: needle) }
        return found
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found += buttons(in: sub) }
        return found
    }

    // MARK: 1 + 2 - Setup's per-tab live subtitle (§6.4)

    private static func checkSetupDrillHeaderIsPerTab(_ ok: inout Bool) {
        print("\n-- §6.4: Setup's drill header carries a live, per-tab line --")
        let setup = makeSetup()
        _ = mount(setup)

        guard let page = setup as DaylightDrillActions? else {
            print("  FAIL SetupContainerController does not conform to DaylightDrillActions")
            ok = false
            return
        }

        var seen: [SetupTab: String] = [:]
        var subtitleChanges = 0
        setup.onDrillSubtitleChanged = { subtitleChanges += 1 }

        for tab in SetupTab.allCases {
            setup.select(tab: tab)
            guard let line = page.drillHeaderSubtitle, !line.isEmpty else {
                print("  FAIL \(tab.title): no subtitle at all")
                ok = false
                continue
            }
            guard line.hasPrefix(tab.title) else {
                print("  FAIL \(tab.title): subtitle does not name the showing tab (\"\(line)\")")
                ok = false
                continue
            }
            seen[tab] = line
            print("  \(tab.title.padding(toLength: 12, withPad: " ", startingAt: 0)) -> \(line)")
        }

        // The line has to actually *differ* per tab. Four identical lines would
        // pass every "has a subtitle" check while telling the captain nothing.
        if Set(seen.values).count < seen.count {
            print("  FAIL two tabs render the identical subtitle: \(Array(seen.values))")
            ok = false
        }
        // And a tab switch is itself a subtitle change - the shell has no other
        // way to know, since no page's own numbers moved.
        if subtitleChanges < SetupTab.allCases.count {
            print("  FAIL only \(subtitleChanges) subtitle notifications for \(SetupTab.allCases.count) tab switches")
            ok = false
        }

        // Phase 3's honesty rule: a page whose first sweep has not run reports
        // that, not a zero. Neither Updates nor GitHub Sync has been visited
        // here (no `viewWillAppear`), so both are genuinely un-swept.
        for (tab, line) in seen where tab == .updates || tab == .githubSync {
            if !line.contains("not checked yet") && !line.contains("checking") {
                print("  FAIL \(tab.title) claims a real verdict before its first check: \"\(line)\"")
                ok = false
            }
        }

        // §7's "capsule tab pills": the shared control, whose own Daylight
        // recipe `HelmContrastSelfTest.checkSegmentedTabsRecipe` pins per
        // theme. Asserted structurally rather than re-measured here - a
        // hand-rolled pill row would render plausibly and silently opt out of
        // that check.
        func hasSegmentedTabs(_ view: NSView) -> Bool {
            if view is HelmSegmentedTabs { return true }
            return view.subviews.contains(where: hasSegmentedTabs)
        }
        if !hasSegmentedTabs(setup.view) {
            print("  FAIL Setup's tab strip is not the shared HelmSegmentedTabs")
            ok = false
        }

        // §6.4's cluster is deliberately empty here - see the property's own
        // note. Asserted so a later slice that fills it does so on purpose.
        if !page.drillHeaderActions.isEmpty {
            print("  note Setup now carries \(page.drillHeaderActions.count) header action(s) - update the property's doc comment")
        }
        if ok { print("  OK - four tabs, four distinct honest lines, and switching notifies the shell") }
    }

    // MARK: 3 - Schedules' hoisted add action (§6.4)

    private static func checkSchedulesDrillHeader(_ ok: inout Bool) {
        print("\n-- §6.4: Schedules' header line and its hoisted add action --")
        let (_, _, _, store) = scratchStores()
        let controller = SchedulesController(scheduleStore: store)
        _ = mount(controller)

        guard let page = controller as DaylightDrillActions? else {
            print("  FAIL SchedulesController does not conform to DaylightDrillActions")
            ok = false
            return
        }

        guard let empty = page.drillHeaderSubtitle, empty.contains("No schedules") else {
            print("  FAIL empty store should say so, got \"\(page.drillHeaderSubtitle ?? "nil")\"")
            ok = false
            return
        }
        print("  empty  -> \(empty)")

        store.add(AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0)))
        store.add(AutomationSchedule(action: .forkSync, cadence: .weekly(weekday: 2, hour: 22, minute: 30),
                                     isEnabled: false))
        controller.viewWillAppear()
        guard let two = page.drillHeaderSubtitle, two.contains("2 schedules"), two.contains("paused") else {
            print("  FAIL two schedules (one paused) not reflected: \"\(page.drillHeaderSubtitle ?? "nil")\"")
            ok = false
            return
        }
        print("  loaded -> \(two)")

        // The header's action has to be the card's *own* button, not a copy.
        guard page.drillHeaderActions.count == 1,
              let hoisted = page.drillHeaderActions.first as? NSButton else {
            print("  FAIL expected exactly one header action, got \(page.drillHeaderActions.count)")
            ok = false
            return
        }
        if hoisted.title != "+ New Schedule" {
            print("  FAIL header action is \"\(hoisted.title)\", not the add button")
            ok = false
        }
        if hoisted.target == nil || hoisted.action == nil {
            print("  FAIL the hoisted button lost its own target/action")
            ok = false
        }
        // ...and it must no longer also be in the page body.
        let inBody = buttons(in: controller.view).filter { $0.title == "+ New Schedule" }
        if !inBody.isEmpty {
            print("  FAIL \"+ New Schedule\" still renders inside the page body (\(inBody.count) copies)")
            ok = false
        }
        // §6.4's "the old in-page explanatory line disappears".
        if !labels(in: controller.view, containing: "Pick one of the app's existing actions and a cadence, and it runs").isEmpty {
            print("  FAIL the page-level subtitle is still rendered")
            ok = false
        }
        if ok { print("  OK - live line, one hoisted card-owned button, nothing duplicated in the body") }
    }

    // MARK: 4 - §6.5's Daylight row recipe and its signal wash

    private static func checkRowRecipeAndSignalWash(_ ok: inout Bool) {
        print("\n-- §6.5: ToolRowLayout's Daylight card row, and the signal wash --")

        /// A real row, built and themed exactly as Updates/GitHub Sync build
        /// and theme theirs.
        func row(theme: HelmTheme, cardStyle: Bool, attentionHex: String?) -> ToolRowLayout.Views {
            let views = ToolRowLayout.Views(
                iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
                detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
                pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
                detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
                logContainer: NSView(), rowContainer: HoverHighlightView())
            _ = ToolRowLayout.build(views, iconSymbol: "shippingbox", tint: .neutral,
                                    name: "firstmate", identifier: "probe", cardStyle: cardStyle)
            ToolRowLayout.applyTheme(views, theme: theme, detailFailed: false,
                                     cardStyle: cardStyle, attentionHex: attentionHex,
                                     accentBar: attentionHex != nil)
            return views
        }

        // --- Daylight: one radius, `card` fill, full-strength `hair` border.
        let d = daylight
        let plainD = row(theme: d, cardStyle: true, attentionHex: nil)
        let cardFill = HelmTheme.nsColor(d.chromeBackgroundHex)
        let hair = HelmTheme.nsColor(d.chromeLineHex)

        if plainD.rowContainer.cornerRadius != HelmMetrics.dWell {
            print("  FAIL Daylight card row radius \(fmt(plainD.rowContainer.cornerRadius)), expected \(fmt(HelmMetrics.dWell))")
            ok = false
        }
        if !sameColor(plainD.rowContainer.normalColor, cardFill) {
            print("  FAIL Daylight card row is not the `card` fill")
            ok = false
        }
        if !sameColor(plainD.rowContainer.hoverColor, HelmTheme.nsColor(DaylightPalette.rowHover)) {
            print("  FAIL Daylight card row hover is not `rowHover`")
            ok = false
        }
        if !sameColor(borderColor(of: plainD.rowContainer), hair) {
            print("  FAIL Daylight card row border is not full-strength `hair`")
            ok = false
        }

        // --- The load-bearing half: a signal row washes, and does NOT tint
        // its border. §7's update row is `warn`.
        let warn = d.ansiHex[3]
        let signalD = row(theme: d, cardStyle: true, attentionHex: warn)
        let expectedWash = HelmContrast.color(
            HelmContrast.mix(HelmContrast.components(HelmTheme.nsColor(warn)),
                             HelmContrast.components(cardFill),
                             Double(ToolRowLayout.signalWashAlpha)))
        if !sameColor(signalD.rowContainer.normalColor, expectedWash) {
            print("  FAIL Daylight signal row is not a \(fmt(ToolRowLayout.signalWashAlpha * 100))% wash of its hue")
            ok = false
        }
        if sameColor(signalD.rowContainer.normalColor, cardFill) {
            print("  FAIL Daylight signal row renders identically to a healthy row")
            ok = false
        }
        if !sameColor(borderColor(of: signalD.rowContainer), hair) {
            print("  FAIL Daylight signal row tints its border - §6.5 puts the signal in the bar + wash")
            ok = false
        }
        if signalD.accentBar.isHidden {
            print("  FAIL Daylight signal row shows no 3pt accent bar")
            ok = false
        }

        // --- And every other palette is byte-identical to what it always was:
        // tinted border, no wash, the 10/8 radius pair.
        let o = otherTheme
        let plainO = row(theme: o, cardStyle: true, attentionHex: nil)
        let signalO = row(theme: o, cardStyle: true, attentionHex: o.ansiHex[3])
        if plainO.rowContainer.cornerRadius != 10 {
            print("  FAIL \(o.id) card row radius \(fmt(plainO.rowContainer.cornerRadius)), expected 10")
            ok = false
        }
        if !sameColor(signalO.rowContainer.normalColor, HelmTheme.nsColor(o.chromeBackgroundHex)) {
            print("  FAIL \(o.id) signal row gained a wash - the twelve palettes must be unchanged")
            ok = false
        }
        let signalOBorder = borderColor(of: signalO.rowContainer)
        if sameColor(signalOBorder, HelmTheme.nsColor(o.chromeLineHex)) {
            print("  FAIL \(o.id) signal row lost its tinted border")
            ok = false
        }
        // A flat (non-card) row's hover, both ways.
        let flatD = row(theme: d, cardStyle: false, attentionHex: nil)
        if !sameColor(flatD.rowContainer.hoverColor, HelmTheme.nsColor(DaylightPalette.rowHover)) {
            print("  FAIL Daylight flat row hover is not `rowHover`")
            ok = false
        }
        if flatD.rowContainer.cornerRadius != HelmMetrics.dTileSmall {
            print("  FAIL Daylight flat row radius \(fmt(flatD.rowContainer.cornerRadius))")
            ok = false
        }
        if ok { print("  OK - Daylight: r\(fmt(HelmMetrics.dWell)) / card / hair / rowHover, signal = bar + wash; \(o.id) unchanged") }
    }

    // MARK: 5 - §7's amber primary Update

    private static func checkUpdateButtonIsAmberPrimary(_ ok: inout Bool) {
        print("\n-- §7: the update row's Update button is an amber primary --")
        let hue = RailDestination.updates.domainHue
        if hue != .amber {
            print("  FAIL Setup's domain hue is \(hue.rawValue), not amber (§2.2)")
            ok = false
        }

        let d = daylight
        // With the hue set (what a Daylight update row does).
        let withHue = HelmButton.palette(variant: .primary, tint: nil, theme: d, domainHue: hue)
        let expected = DaylightPalette.primaryButtonFill(for: hue, theme: d)
        if !sameColor(withHue.fill, expected) {
            print("  FAIL Daylight primary fill is not §2.4's corrected amber")
            ok = false
        }
        if HelmContrast.ratio(withHue.label, withHue.fill) < HelmContrast.textTarget {
            print("  FAIL Daylight amber primary label measures \(String(format: "%.2f", HelmContrast.ratio(withHue.label, withHue.fill))):1")
            ok = false
        }
        // The raw §2.2 amber is what the correction exists for - if the two
        // ever match, the correction has been dropped.
        if sameColor(expected, hue.baseColor(in: d)) {
            print("  FAIL the corrected amber equals the raw §2.2 amber - §2.4's correction is gone")
            ok = false
        }

        // And off Daylight, a hue-less primary is still the palette accent -
        // which is what the row passes there, so twelve palettes are unchanged.
        let o = otherTheme
        let noHue = HelmButton.palette(variant: .primary, tint: nil, theme: o, domainHue: nil)
        if !sameColor(noHue.fill, HelmTheme.nsColor(o.accentHex)) {
            print("  FAIL \(o.id) primary is not `accentHex`")
            ok = false
        }
        let withHueOff = HelmButton.palette(variant: .primary, tint: nil, theme: o, domainHue: hue)
        if sameColor(withHueOff.fill, noHue.fill) {
            print("  FAIL setting a hue is a no-op on \(o.id) - then nothing proves the row must not set it there")
            ok = false
        }
        // The mechanism above is per-theme by construction, so the remaining
        // failure is a *call site* that sets the hue unconditionally - which
        // would restyle a `.primary` on all twelve other palettes while every
        // assertion above still passed. A source guard is the only thing that
        // can see that, since `applyThemeToRow` is private and the wrong
        // behaviour renders as a plausible button either way.
        if let dir = SelfTestSources.appSourceDirectory(),
           let text = try? String(contentsOf: dir.appendingPathComponent("UpdatesController.swift"),
                                  encoding: .utf8) {
            let hueLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains("updateButton.domainHue") }
            if hueLines.isEmpty {
                print("  FAIL UpdatesController no longer sets the update button's domain hue at all")
                ok = false
            } else if let bad = hueLines.first(where: { !$0.contains("theme.isDaylight") }) {
                print("  FAIL the update button's hue is set unconditionally: \(bad.trimmingCharacters(in: .whitespaces))")
                ok = false
            }
        } else {
            print("  skip source guard - could not locate the app's source directory")
        }
        if ok { print("  OK - corrected amber under Daylight, accentHex elsewhere, and the hue genuinely matters") }
    }

    // MARK: 6 - §7's mono time column and honest ticks

    private static func checkTimeColumnAndTicks(_ ok: inout Bool) {
        print("\n-- §7: Schedules' mono time column, and no fabricated ticks --")
        let (_, _, _, store) = scratchStores()

        // Three cadences whose clock strings differ in width ("2:00 AM" vs
        // "10:30 PM"), which is exactly what a non-column would misalign.
        let never = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0))
        let clean = AutomationSchedule(action: .toolUpdateCheck,
                                       cadence: .daily(hour: 22, minute: 30),
                                       lastRun: ScheduleRunRecord(verdict: .clean, summary: "No drift", at: Date()))
        let failed = AutomationSchedule(action: .forkSync,
                                        cadence: .weekly(weekday: 3, hour: 11, minute: 5),
                                        lastRun: ScheduleRunRecord(verdict: .failed, summary: "gh not authenticated", at: Date()))
        for schedule in [never, clean, failed] { store.add(schedule) }

        let controller = SchedulesController(scheduleStore: store)
        let window = mount(controller)
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()

        guard let card = controller.debugSchedulesCard else {
            print("  FAIL no schedules card to read")
            ok = false
            return
        }

        var xs: [CGFloat] = []
        for (schedule, expectedTick) in [(never, ""), (clean, "\u{2713}"), (failed, "\u{2715}")] {
            guard let cols = card.debugTrailingColumns(for: schedule.id) else {
                print("  FAIL no time/tick columns for \(schedule.action.title)")
                ok = false
                continue
            }
            let expectedTime = ScheduleCadence.clockString(hour: schedule.cadence.normalized.hour,
                                                           minute: schedule.cadence.normalized.minute)
            if cols.time != expectedTime {
                print("  FAIL \(schedule.action.title): time column reads \"\(cols.time)\", expected \"\(expectedTime)\"")
                ok = false
            }
            if cols.ticks != expectedTick {
                print("  FAIL \(schedule.action.title): ticks read \"\(cols.ticks)\", expected \"\(expectedTick)\"")
                ok = false
            }
            xs.append(cols.timeFrameInCard.minX)
            print("  \(expectedTime.padding(toLength: 9, withPad: " ", startingAt: 0)) x=\(fmt(cols.timeFrameInCard.minX)) w=\(fmt(cols.timeFrameInCard.width)) ticks=\"\(cols.ticks)\"")
        }

        // A *column*: one constant x, not a label drifting with the title.
        if let first = xs.first, xs.contains(where: { abs($0 - first) > 0.5 }) {
            print("  FAIL the time column is not aligned: xs = \(xs.map(fmt))")
            ok = false
        }
        if !SchedulesCardView.timeColumnWidth.isFinite || SchedulesCardView.timeColumnWidth <= 0 {
            print("  FAIL the time column has no width")
            ok = false
        }
        if ok { print("  OK - one aligned mono column, and a never-run schedule shows no tick") }
    }

    // MARK: 7 - gotcha (13)

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): the two restyled pages hold a narrow window --")
        let (_, _, _, store) = scratchStores()
        store.add(AutomationSchedule(action: .configBackupExport, cadence: .daily(hour: 3, minute: 15)))

        func floor(of controller: NSViewController, label: String, widths: [CGFloat]) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: widths[0], height: 820),
                                  styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            // `contentView`, not `contentViewController` - see the file header:
            // appearance callbacks would start the Setup pages' real sweeps.
            window.contentView = controller.view
            for width in widths {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 820), display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                let got = window.frame.width
                if got > width + 0.5 {
                    print("  FAIL \(label) will not shrink to \(fmt(width)) (window came back \(fmt(got)))")
                    ok = false
                }
            }
        }
        floor(of: makeSetup(), label: "Setup", widths: [1400, 1100, 900])
        floor(of: SchedulesController(scheduleStore: store), label: "Schedules", widths: [1400, 1100, 900])
        if ok { print("  OK - Setup and Schedules both hold 900pt") }
    }
}

#endif
