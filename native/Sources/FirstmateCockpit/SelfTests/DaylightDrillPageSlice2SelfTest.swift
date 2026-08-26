// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 2**'s own suite: the three destinations §7 puts
// next, Console, Hosts and Health.
//
// What each case is actually protecting, and why it is worth a test rather
// than a read-through:
//
//   1. **All three pages really reached the drill header** (§6.4). The seam is
//      a protocol conformance, and a missing one is invisible - the header just
//      renders the static per-area line and an empty trailing slot, which
//      looks like a design choice. Hosts is the case worth pinning hardest:
//      its action cluster changes with the tab, so this asserts the *same*
//      three button instances move in and out rather than copies being built.
//   2. **None of the three renders an in-page hero any more** (§6.4). Walked
//      over the real view tree, because the failure mode is a duplicate title
//      one row apart.
//   3. **§6.13's terminal card is permanent under Daylight and only there** -
//      and, the load-bearing half, **the terminal's frame is identical across
//      the theme switch that turns the card on.** A card that resized the
//      terminal would reflow the buffer and truncate a captain's scrollback,
//      which is the bug `fm/cockpit-sre-lead-ux-fixes` fixed once and
//      `SRELeadPerTabSelfTest.scrollbackSurvivesSRELeadToggle` guards for the
//      pane toggle. This slice added a *second* trigger for the same overlay,
//      so it gets the same assertion.
//   4. **A host row's gradient tile carries the captain's own colour**, not a
//      semantic hue mapped onto it (§7's "per-host gradient tiles from
//      `Host.accentHex`"). A tile that silently resolved a `HelmTint` instead
//      would still render a plausible gradient - which is exactly why this is
//      measured rather than eyeballed.
//   5. **Health's run ticks only ever report what the registry records.**
//      There is no run history in `ServiceHealthState`, so the interesting
//      failure is a *fabricated* tick on a service that has never run.
//   6. **No new window-width floor.** Every constraint this slice added sits
//      inside `bodyContainer`, and AGENTS.md gotcha (13) is this codebase's
//      most expensive recurring bug. `AppShellBodyWidthSelfTest` is the broad
//      sweep; this is the local one for the three pages just touched.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice2SelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, checkHeroTitlesAreGone,
                      checkTerminalCardIsPermanentOnDaylight,
                      checkHostRowGradientBadge, checkSegmentedTabsAreCapsules,
                      checkHealthTicksAndChips, checkNoWindowWidthFloor] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSlice2SelfTest: all checks passed"
                    : "DaylightDrillPageSlice2SelfTest: FAILED")
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

    /// Scratch store files, so nothing here can reach the captain's real data
    /// (the convention every store-backed suite in this repo follows).
    private static func scratchStores() -> (HostStore, SSHKeyStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-slice2-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        return (HostStore(), SSHKeyStore())
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func labels(in view: NSView, atLeast points: CGFloat) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, (label.font?.pointSize ?? 0) >= points,
           !label.stringValue.isEmpty, !label.isHidden {
            found.append(label)
        }
        for sub in view.subviews { found += labels(in: sub, atLeast: points) }
        return found
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// Pump the main runloop until `condition` holds or the timeout expires.
    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Component-wise, deliberately **not** `HelmContrast.ratio(a, b) < 1.01`:
    /// that compares relative *luminance*, so two entirely different hues of
    /// similar brightness pass it. Caught while injecting a regression into
    /// this suite - a gradient tile painting Daylight's teal instead of the
    /// host's own rose was reported as a match.
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    // MARK: 1. All three pages reached the drill header (§6.4)

    private static func checkDrillConformances(_ ok: inout Bool) {
        print("\n-- §6.4: Console / Hosts / Health carry live drill headers --")
        let (hostStore, keyStore) = scratchStores()

        // Console: a live subtitle from its own tab set, and a deliberately
        // empty action cluster (§6.13 keeps its actions in the page toolbar).
        let console = ConsoleController(keyStore: keyStore,
                                        isFirstmateConsole: false)
        let consoleWindow = mount(console)
        defer { _ = consoleWindow }
        guard let empty = console.drillHeaderSubtitle, !empty.isEmpty else {
            print("  FAIL Console reports no drill subtitle with no tabs open")
            ok = false
            return
        }
        console.debugOpenTestSSHTab(label: "bastion")
        guard let withTab = console.drillHeaderSubtitle, withTab.contains("tab") else {
            print("  FAIL Console's subtitle does not report its tab count (\(console.drillHeaderSubtitle ?? "nil"))")
            ok = false
            return
        }
        if !console.drillHeaderActions.isEmpty {
            print("  FAIL Console hoisted \(console.drillHeaderActions.count) action(s) that §6.13 keeps in the toolbar")
            ok = false
        }

        // Hosts: the add action for the tab that is showing, and the *same*
        // instance each time - a fresh button per read would silently drop the
        // tooltip and target the page set on it.
        hostStore.add(Host(label: "Prod Bastion", address: "prod.example.com"))
        let hosts = HostsController(hostStore: hostStore, keyStore: keyStore)
        let hostsWindow = mount(hosts)
        defer { _ = hostsWindow }
        var seen: [HostsTab: NSView] = [:]
        for tab in HostsTab.allCases {
            hosts.select(tab: tab)
            guard hosts.drillHeaderActions.count == 1, let action = hosts.drillHeaderActions.first else {
                print("  FAIL Hosts' \(tab.rawValue) tab hoists \(hosts.drillHeaderActions.count) actions, want 1")
                ok = false
                return
            }
            guard let button = action as? NSButton, !button.title.isEmpty else {
                print("  FAIL Hosts' \(tab.rawValue) action is not a titled button")
                ok = false
                return
            }
            seen[tab] = action
            guard let subtitle = hosts.drillHeaderSubtitle, !subtitle.isEmpty else {
                print("  FAIL Hosts' \(tab.rawValue) tab reports no drill subtitle")
                ok = false
                return
            }
        }
        if Set(seen.values.map { ObjectIdentifier($0) }).count != HostsTab.allCases.count {
            print("  FAIL Hosts' three tabs do not hoist three distinct add actions")
            ok = false
        }
        hosts.select(tab: .hosts)
        let firstRead = hosts.drillHeaderActions.first
        hosts.select(tab: .keys)
        hosts.select(tab: .hosts)
        if firstRead !== hosts.drillHeaderActions.first {
            print("  FAIL Hosts rebuilds its add button on every read instead of reusing it")
            ok = false
        }

        // Health: its one action is the card's own button instance, and the
        // subtitle counts the same registry the rows do.
        ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)
        let health = HealthController()
        let healthWindow = mount(health)
        defer { _ = healthWindow }
        guard health.drillHeaderActions.count == 1,
              let copyButton = health.drillHeaderActions.first as? NSButton,
              copyButton.title.lowercased().contains("diagnostics") else {
            print("  FAIL Health does not hoist its Copy diagnostics button")
            ok = false
            return
        }
        guard let healthSubtitle = health.drillHeaderSubtitle,
              healthSubtitle.contains("service") else {
            print("  FAIL Health's drill subtitle does not count services (\(health.drillHeaderSubtitle ?? "nil"))")
            ok = false
            return
        }
        // The button is caller-owned: reading twice must hand back the same
        // instance, or the page's own enabled/target state would be lost.
        if health.drillHeaderActions.first !== copyButton {
            print("  FAIL Health rebuilds its Copy diagnostics button on every read")
            ok = false
        }
        print("  OK - Console \"\(withTab)\" + 0 actions; Hosts 3 tabs / 3 stable actions; Health \"\(healthSubtitle)\"")
    }

    // MARK: 2. No in-page heroes left (§6.4)

    private static func checkHeroTitlesAreGone(_ ok: inout Bool) {
        print("\n-- §6.4: no in-page hero titles on Console / Hosts / Health --")
        // The drill header's own title is 26pt, so anything at or above 20pt
        // inside a page body is a second title competing with it.
        let heroFloor: CGFloat = 20
        let (hostStore, keyStore) = scratchStores()
        let pages: [(String, NSViewController)] = [
            ("Console", ConsoleController(keyStore: keyStore,
                                          isFirstmateConsole: false)),
            ("Hosts", HostsController(hostStore: hostStore, keyStore: keyStore)),
            ("Health", HealthController()),
        ]
        var clean = true
        for (name, page) in pages {
            let window = mount(page)
            defer { _ = window }
            let heroes = labels(in: page.view, atLeast: heroFloor)
            if !heroes.isEmpty {
                print("  FAIL \(name) still renders \(heroes.count) hero-sized label(s): "
                      + heroes.map { "\"\($0.stringValue)\" @\(fmt($0.font?.pointSize ?? 0))" }
                          .joined(separator: ", "))
                ok = false
                clean = false
            }
        }
        if clean { print("  OK - all three page bodies are free of hero-sized titles") }
    }

    // MARK: 3. §6.13's terminal card, and the frame it must never move

    private static func checkTerminalCardIsPermanentOnDaylight(_ ok: inout Bool) {
        print("\n-- §6.13: the terminal card is permanent under Daylight, and never resizes the terminal --")
        let (_, keyStore) = scratchStores()
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        // A dedicated host page: `terminalInset > 0`, so there is a margin for
        // the card to live in.
        //
        // `contentViewController` plus a real `viewDidAppear`, matching
        // `SRELeadPerTabSelfTest.makeStartedTestConsole` - assigning
        // `contentView` alone leaves the terminal at a zero frame, which would
        // make the "did not move" comparison below vacuous.
        let host = ConsoleController(keyStore: keyStore,
                                     isFirstmateConsole: false)
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        defer { _ = hostWindow }
        host.debugOpenTestSSHTab(label: "bastion")
        host.viewDidAppear()
        host.view.layoutSubtreeIfNeeded()

        ThemeManager.shared.setTheme(otherTheme)
        host.view.layoutSubtreeIfNeeded()
        // A window that is never ordered front resolves its terminal's real
        // geometry a runloop turn or two later - the same wait
        // `SRELeadPerTabSelfTest.scrollbackSurvivesSRELeadToggle` documents.
        // Without it the baseline is a zero rect and the comparison proves
        // nothing.
        _ = waitUntil(timeout: 6) {
            host.view.layoutSubtreeIfNeeded()
            return (host.debugCurrentTerminalFrame()?.width ?? 0) > 0
        }
        let beforeFrame = host.debugCurrentTerminalFrame()
        let beforeVisible = host.debugTerminalCardVisible()

        ThemeManager.shared.setTheme(daylight)
        host.view.layoutSubtreeIfNeeded()
        let afterFrame = host.debugCurrentTerminalFrame()
        let afterVisible = host.debugTerminalCardVisible()

        if beforeVisible {
            print("  FAIL the terminal card is drawn with no pane open off Daylight")
            ok = false
        }
        if !afterVisible {
            print("  FAIL the terminal card is not drawn under Daylight with no pane open")
            ok = false
        }
        guard let beforeFrame, let afterFrame else {
            print("  FAIL no terminal frame to compare")
            ok = false
            return
        }
        // A zero frame would make the comparison below vacuous - the whole
        // point is that a *real, laid-out* terminal did not move.
        if beforeFrame.width <= 0 || beforeFrame.height <= 0 {
            print("  FAIL the terminal never laid out (\(beforeFrame)) - the frame check would be vacuous")
            ok = false
        }
        if beforeFrame != afterFrame {
            // The whole reason the card is a drawn overlay rather than a
            // container - see `ConsoleCardChrome.swift`'s header.
            print("  FAIL the theme switch moved the terminal: \(beforeFrame) -> \(afterFrame)")
            ok = false
        }

        // The shared Firstmate console has no margin by design, so it must
        // never show the card in any palette.
        let shared = ConsoleController(keyStore: keyStore,
                                       isFirstmateConsole: true)
        let sharedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        sharedWindow.contentViewController = shared
        defer { _ = sharedWindow }
        shared.view.layoutSubtreeIfNeeded()
        if shared.terminalInset != 0 {
            print("  FAIL the shared Firstmate console has a non-zero terminal inset (\(fmt(shared.terminalInset)))")
            ok = false
        }
        if shared.debugTerminalCardVisible() {
            print("  FAIL the shared Firstmate console draws a terminal card under Daylight")
            ok = false
        }
        print("  OK - host page: hidden off Daylight, drawn on it, terminal frame \(beforeFrame) unchanged; "
              + "shared console never carded")
    }

    // MARK: 4. A host row's gradient tile is the captain's own colour (§7)

    private static func checkHostRowGradientBadge(_ ok: inout Bool) {
        print("\n-- §7: per-host gradient tiles come from Host.accentHex --")
        let literal = "D9527E"
        var content = HelmAccentRow.Content(tint: .accent, kicker: "PROD",
                                            title: "Prod Bastion", meta: "root@prod",
                                            badgeSymbol: "server.rack")
        content.tintHex = literal

        // Opted in: a gradient tile under Daylight, carrying the literal hue.
        let row = HelmAccentRow(gradientBadge: true)
        row.configure(content, theme: daylight)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 90))
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let tiles = gradientTiles(in: row).filter { !$0.isHidden }
        guard let tile = tiles.first, tiles.count == 1 else {
            print("  FAIL \(tiles.count) visible gradient tiles on a Daylight host row, want exactly 1")
            ok = false
            return
        }
        let expected = HelmTheme.nsColor(literal)
        guard sameColor(tile.resolvedColorsForTests.h1, expected) else {
            print("  FAIL the tile's darker stop is not the host's own accent "
                  + "(\(String(describing: tile.resolvedColorsForTests.h1)) vs #\(literal))")
            ok = false
            return
        }
        // The lighter stop must actually be lighter - a gradient collapsed to
        // one colour is a flat tile that still passes a "has two stops" check.
        if let h1 = tile.resolvedColorsForTests.h1, let h2 = tile.resolvedColorsForTests.h2,
           HelmContrast.relativeLuminance(HelmContrast.components(h2))
            <= HelmContrast.relativeLuminance(HelmContrast.components(h1)) {
            print("  FAIL the per-host gradient's second stop is not lighter than its first")
            ok = false
        }

        // Off Daylight the same row shows the wash tile it always did.
        row.applyTheme(otherTheme)
        host.layoutSubtreeIfNeeded()
        if gradientTiles(in: row).contains(where: { !$0.isHidden }) {
            print("  FAIL a gradient tile is visible in a non-Daylight palette")
            ok = false
        }

        // A row that did not opt in builds no gradient tile at all.
        let plain = HelmAccentRow()
        plain.configure(content, theme: daylight)
        if !gradientTiles(in: plain).isEmpty {
            print("  FAIL a row that did not opt in built a gradient tile anyway")
            ok = false
        }
        print("  OK - literal #\(literal) on Daylight, wash tile elsewhere, opt-in respected")
    }

    private static func gradientTiles(in view: NSView) -> [HelmGradientTile] {
        var found: [HelmGradientTile] = []
        if let tile = view as? HelmGradientTile { found.append(tile) }
        for sub in view.subviews { found += gradientTiles(in: sub) }
        return found
    }

    // MARK: 5. Keys/Snippets tabs are capsules under Daylight (§7)

    private static func checkSegmentedTabsAreCapsules(_ ok: inout Bool) {
        print("\n-- §7: the tab strip is space-pill capsules under Daylight --")
        let tabs = HelmSegmentedTabs(items: HostsTab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                    selected: HostsTab.hosts.rawValue)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        host.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tabs.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        tabs.applyTheme(daylight)
        host.layoutSubtreeIfNeeded()
        let g = tabs.debugGeometry()
        // Every pill is a capsule: half its own resolved height.
        let heights = tabs.debugPillsForAccessibilityTests().map { $0.bounds.height }
        guard let height = heights.first, height > 0 else {
            print("  FAIL the tab strip laid out with zero-height pills")
            ok = false
            return
        }
        if g.pillRadii.contains(where: { abs($0 - height / 2) > 0.51 }) {
            print("  FAIL pill radii \(g.pillRadii) are not capsules for height \(fmt(height))")
            ok = false
        }
        if g.capsuleBorderWidth != 0 {
            print("  FAIL the Daylight container still draws its own border")
            ok = false
        }

        // And the twelve palettes keep the bordered container they always had.
        tabs.applyTheme(otherTheme)
        host.layoutSubtreeIfNeeded()
        let other = tabs.debugGeometry()
        if abs(other.capsuleBorderWidth - 1) > 0.01 {
            print("  FAIL a non-Daylight palette lost its capsule border")
            ok = false
        }
        if other.pillRadii.contains(where: { abs($0 - HelmSegmentedTabs.Size.standard.pillRadius) > 0.01 }) {
            print("  FAIL a non-Daylight palette's pill radii changed: \(other.pillRadii)")
            ok = false
        }
        print("  OK - capsules (r\(fmt(height / 2))) on Daylight, r\(fmt(HelmSegmentedTabs.Size.standard.pillRadius)) bordered elsewhere")
    }

    // MARK: 6. Health's run ticks and KPI chips (§6.8 / §7)

    private static func checkHealthTicksAndChips(_ ok: inout Bool) {
        print("\n-- §6.8/§7: Health's run ticks report only what the registry records --")
        let check = "\u{2713}"
        let cross = "\u{2715}"

        var never = ServiceHealthState()
        if !HealthCardView.runTicks(never).isEmpty {
            print("  FAIL a service that has never reported got ticks: \"\(HealthCardView.runTicks(never))\"")
            ok = false
        }
        never.isRunning = true
        if !HealthCardView.runTicks(never).isEmpty {
            print("  FAIL a service still on its first run got ticks")
            ok = false
        }

        var healthy = ServiceHealthState()
        healthy.lastSuccess = Date()
        if HealthCardView.runTicks(healthy) != check {
            print("  FAIL a healthy service's ticks are \"\(HealthCardView.runTicks(healthy))\", want \"\(check)\"")
            ok = false
        }

        // Never succeeded, currently failing: one cross and **no** check. This
        // is the case that pins "a tick is only ever drawn for something the
        // registry actually recorded" - the other states below all happen to
        // have a real success on record, so they would still read correctly
        // even if the check mark were unconditional.
        var neverSucceeded = ServiceHealthState()
        neverSucceeded.lastFailure = Date()
        neverSucceeded.consecutiveFailures = 1
        if HealthCardView.runTicks(neverSucceeded) != cross {
            print("  FAIL a never-succeeded service reads \"\(HealthCardView.runTicks(neverSucceeded))\", want \"\(cross)\"")
            ok = false
        }

        var degraded = ServiceHealthState()
        degraded.lastSuccess = Date()
        degraded.lastFailure = Date()
        degraded.consecutiveFailures = 2
        if HealthCardView.runTicks(degraded) != cross + cross + check {
            print("  FAIL a two-failure streak reads \"\(HealthCardView.runTicks(degraded))\"")
            ok = false
        }

        // A long streak is capped rather than rendered as an unbounded run.
        var long = ServiceHealthState()
        long.lastFailure = Date()
        long.consecutiveFailures = 40
        let capped = HealthCardView.runTicks(long)
        if capped.count > 6 || capped.contains(check) {
            print("  FAIL a 40-failure streak rendered \(capped.count) glyphs: \"\(capped)\"")
            ok = false
        }

        // The KPI chips: one per non-empty bucket, on a real card.
        ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)
        ServiceHealthRegistry.shared.recordFailure(.backgroundSignals, "probe failure")
        let health = HealthController()
        let window = mount(health)
        defer { _ = window }
        health.view.layoutSubtreeIfNeeded()
        let counts = HealthCardView.verdictCounts()
        let expectedChips = [counts.failing, counts.degraded, counts.healthy, counts.pending]
            .filter { $0 > 0 }.count
        if health.debugHeaderChipCount != expectedChips {
            print("  FAIL Health's header shows \(health.debugHeaderChipCount) KPI chips, want \(expectedChips)")
            ok = false
        }
        if counts.total == 0 {
            print("  FAIL the registry reported nothing after two real reports")
            ok = false
        }
        print("  OK - ticks: none/none/\(check)/\(cross)\(cross)\(check)/capped; "
              + "\(expectedChips) KPI chip(s) for \(counts.total) service(s)")
    }

    // MARK: 7. No new window-width floor (AGENTS.md gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): the three restyled pages hold a narrow window --")
        let (hostStore, keyStore) = scratchStores()
        hostStore.add(Host(label: "Prod Bastion", address: "prod.example.com"))
        ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)

        func floor(of controller: NSViewController, label: String, widths: [CGFloat]) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: widths[0], height: 820),
                                  styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentViewController = controller
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
        // Console and Health carry nothing wide; Hosts' own list rows are the
        // only real candidate for a floor on these three.
        floor(of: ConsoleController(keyStore: keyStore,
                                    isFirstmateConsole: false),
              label: "Console", widths: [1400, 1100, 900])
        floor(of: HostsController(hostStore: hostStore, keyStore: keyStore),
              label: "Hosts", widths: [1400, 1100, 900])
        floor(of: HealthController(), label: "Health", widths: [1400, 1100, 900])
        print("  OK - Console / Hosts / Health all hold 900pt")
    }
}

#endif
