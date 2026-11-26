// Grand Line - native macOS app.
//
// Health's and Connections' hero columns (H-4 and C-4 on the page-redesign
// board), mounted in a real off-screen sidebar shell with the tour lab's demo
// hosts and service reports, and driven through the pages' own controls.
//
// Window-backed, because what it asserts is real layout and real dispatch:
//
//   - H-4: the column is the split's sidebar and the table starts at the top
//     of the page beside it, the column is red while a service fails and the
//     accent otherwise, its buckets read the registry, its Retry pill runs
//     the service's own retry, and a narrow page moves the same column across
//     the top of the table as a band and back.
//   - C-4: the column sits beside the host cards, which run two to a row at
//     C-1's 98pt; Recent is the column's (with Switch for a live session and
//     Connect otherwise) and leaves the grid, and comes back to the grid when
//     the column is put away; Quick connect's Return connects; and no line of
//     a card runs under its action column.
//   - The Keys tab is the Hosts tab's twin: the same column speaks for the
//     keys (Touch ID, the in-use ring, Recent keys with a Copy pill, Generate
//     and Import), the key cards are the host cards' size and run two to a
//     row, a fingerprint stops before the action column, the toolbar's Grid /
//     List ends where the cards do, and Recent keys moves into the grid when
//     the column is put away.
//   - Every word and control on either column is in the hero's ink.
//
// The words themselves - every verdict, the ring, the buckets, the pills -
// are asserted headless in `PageHeroColumnsSelfTest`.
//
// With `FM_PAGE_HERO_RENDER_DIR` set it also writes one PNG per page, state,
// width and theme into that folder (the PR's renders). Nothing is written
// otherwise.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_PAGE_HERO_COLUMNS_VIEW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum PageHeroColumnsViewSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-hero-columns-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            ThemeManager.shared.setTheme(daylight)
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            ReviewTourLab.seedDemoHosts(shell.workspace)
            settle(shell)
            let checks: [(MainSplitShellController, NSWindow, inout Bool) -> Void] = [
                checkHealthColumn, checkHealthTone, checkHealthRetry, checkHealthBand,
                checkConnectionsColumn, checkConnectionsRecent, checkConnectionsQuickConnect,
                checkConnectionsCards, checkConnectionsCollapse, checkKeysColumn, checkKeysCards,
                checkKeysCollapse, checkSnippetsColumn, writeRenders,
            ]
            for check in checks {
                var ok = true
                autoreleasepool { check(shell, window, &ok) }
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "PageHeroColumnsViewSelfTest: all checks passed" : "PageHeroColumnsViewSelfTest: FAILED")
        return allOK
    }

    // MARK: Harness

    static var daylight: HelmTheme { HelmTheme.appThemes.first { $0.id == "daylight" } ?? ThemeManager.shared.theme }
    static var dusk: HelmTheme { HelmTheme.appThemes.first { $0.id == "dusk" } ?? ThemeManager.shared.theme }

    static func settle(_ shell: WorkspaceShellController) {
        for _ in 0..<3 {
            shell.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        shell.view.layoutSubtreeIfNeeded()
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    /// Every registered service gone, so a check starts from nothing.
    static func clearHealth() {
        let registry = ServiceHealthRegistry.shared
        for service in registry.knownServices() { registry.unregister(service) }
    }

    /// Every service healthy.
    static func seedHealthy() {
        clearHealth()
        let now = Date()
        for (index, service) in HealthService.allCases.enumerated() {
            ServiceHealthRegistry.shared.recordSuccess(service, at: now.addingTimeInterval(-Double(20 + index * 37)))
        }
    }

    @discardableResult
    static func showHealth(_ shell: MainSplitShellController) -> HealthController {
        shell.workspace.navigator.show(.health)
        settle(shell)
        let health = shell.workspace.health
        health.debugRefresh()
        settle(shell)
        return health
    }

    @discardableResult
    static func showHosts(_ shell: MainSplitShellController) -> HostsController {
        shell.workspace.navigator.show(.hosts)
        let hosts = shell.workspace.hostsPanel
        hosts.selectModuleTab(named: "Hosts")
        shell.setInspectorShown(false)
        settle(shell)
        return hosts
    }

    /// A frame in the page's own coordinates.
    static func frame(of view: NSView, in page: NSView) -> NSRect {
        view.convert(view.bounds, to: page)
    }

    /// Whether `color` is `ink` (components and alpha), not merely as bright.
    static func isInk(_ color: NSColor?, _ ink: NSColor, alpha: CGFloat = 1) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB), let ink = ink.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - ink.redComponent) < 0.02 && abs(color.greenComponent - ink.greenComponent) < 0.02
            && abs(color.blueComponent - ink.blueComponent) < 0.02 && abs(color.alphaComponent - alpha) < 0.03
    }

    // MARK: H-4

    private static func checkHealthColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        seedHealthy()
        let health = showHealth(shell)
        let card = health.debugHealthCard
        let column = card.heroColumn
        guard let split = health.splitPage else {
            fail("H-4: Health is not a split page in the sidebar layout", &ok)
            return
        }
        check(column.superview === split.sidebarPane && !split.isSidebarCollapsed,
              "H-4: the hero column is not in the split's open sidebar pane", &ok)
        check(column.arrangement == .column, "H-4: the column is drawn as a \(column.arrangement)", &ok)
        let page = health.view
        let columnFrame = frame(of: column, in: page)
        let tableFrame = frame(of: card.debugServicesTable.card, in: page)
        check(abs(columnFrame.width - HelmHeroColumn.width) < 1, "H-4: the column is \(columnFrame.width)pt wide", &ok)
        // Nothing above the table: it starts on the column's own top line.
        // The column only stays while the table keeps every column.
        let runs = card.debugServicesTable.debugTable.column(withIdentifier: NSUserInterfaceItemIdentifier("runs"))
        check(runs >= 0 && !card.debugServicesTable.debugTable.tableColumns[runs].isHidden,
              "H-4: beside the column the table has lost Recent runs (\(tableFrame.width)pt)", &ok)
        check(abs(columnFrame.maxY - tableFrame.maxY) < 1.5,
              "H-4: the table's top (\(tableFrame.maxY)) is not the column's (\(columnFrame.maxY))", &ok)
        check(tableFrame.minX > columnFrame.maxX + HelmMetrics.s4 - 0.5,
              "H-4: the table (\(tableFrame.minX)) does not start past the column (\(columnFrame.maxX))", &ok)
        let counts = ServiceHealthRegistry.shared.summary()
        checkHealthColumnsHug(card.debugServicesTable, &ok)
        check(card.debugHeroBucketFigures == ["\(counts.total)", "0", "0", "0"],
              "H-4: an all-healthy column reads \(card.debugHeroBucketFigures)", &ok)
        check(column.debugHeadline.contains("healthy"), "H-4: the headline reads \(column.debugHeadline)", &ok)
        // Every word on the column in the ink.
        let ink = column.ink
        check(isInk(column.debugHeadlineLabel.textColor, ink), "H-4: the headline is not in the hero's ink", &ok)
        for row in column.debugRows {
            check(isInk(row.titleLabel.textColor, ink), "H-4: the \(row.titleLabel.stringValue) row's title is not in the ink", &ok)
        }
        // The column takes Toggle Sidebar like any split page's column.
        check((health as HelmSplitPageHosting).splitPage === split, "H-4: Toggle Sidebar cannot reach the column", &ok)
    }

    /// UI-07 of full review 4: Status, Last run and Recent runs are as wide
    /// as what they hold, the service takes the rest, and a description
    /// wraps to two lines before it is cut. The three columns sat at 150,
    /// 150 and 110pt holding a few characters, and seven of eight
    /// descriptions were cut at one line.
    private static func checkHealthColumnsHug(_ table: HelmDataTable, _ ok: inout Bool) {
        for (id, cap) in [("status", 150), ("lastRun", 150), ("runs", 110)] as [(String, CGFloat)] {
            guard let width = table.debugColumnWidth(id) else {
                fail("UI-07: the \(id) column is not shown at 1512", &ok)
                continue
            }
            check(width < cap - 10, "UI-07: the \(id) column is \(width)pt, as wide as its old fixed \(cap)", &ok)
        }
        var wrapped = 0
        for row in 0..<table.debugRows.count {
            guard let label = table.debugSubtitleLabel(row: row), !label.isHidden, label.frame.width > 0,
                  let font = label.font else { continue }
            let probe = NSTextField(wrappingLabelWithString: label.stringValue)
            probe.font = font
            probe.maximumNumberOfLines = 0
            let whole = probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0
            let line = (font.ascender - font.descender + font.leading).rounded(.up)
            let needed = min(whole, 2 * line)
            if whole > line * 1.5 { wrapped += 1 }
            check(label.frame.height + 1 >= needed,
                  "UI-07: \"\(label.stringValue)\" draws \(label.frame.height)pt of the \(needed)pt two lines give it", &ok)
            check(label.maximumNumberOfLines == 2, "UI-07: a description may take \(label.maximumNumberOfLines) lines", &ok)
        }
        // The fixture can fail: some description really needs a second line.
        check(wrapped > 0, "UI-07: fixture: no service description needs a second line at 1512", &ok)
    }

    private static func checkHealthTone(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let theme = ThemeManager.shared.theme
        let accent = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme)
        let redRGB = HelmContrast.components(HelmTheme.nsColor(HelmTint.critical.hex(in: theme)))
        let red = HelmHeroColumn.palette(for: .init(colour: .fixed(red: redRGB.0, green: redRGB.1, blue: redRGB.2)), in: theme)
        check(accent != red, "fixture: the accent and the red palettes are the same, the tone check measures nothing", &ok)

        seedHealthy()
        var health = showHealth(shell)
        check(health.debugHealthCard.heroColumn.debugPalette == accent, "H-4: a healthy column is not the accent", &ok)

        ReviewTourLab.seedDemoHealth(health)
        health = showHealth(shell)
        let column = health.debugHealthCard.heroColumn
        // UX-18: one failing service of eight keeps the accent; the pill
        // under the kicker and the ring's arc carry the state.
        check(column.debugPalette == accent && column.debugStatusPill != nil
                && column.debugStatusPill.map { $0.convert($0.bounds, to: column).minY } != nil,
              "UX-18: one failing service turned the column red, or it shows no status pill", &ok)
        check(health.debugHealthCard.heroWords(ServiceHealthRegistry.shared.summary()).ringState == .bad,
              "UX-18: the ring's arc does not carry the failure", &ok)
        // UX-18: the failing row offers Copy error beside Retry now.
        let rows = health.debugHealthCard.debugServicesTable.debugRows
        if let dotfiles = rows.first(where: { $0.key == HealthService.dotfilesAutoSync.rawValue }) {
            check((dotfiles.accessory as? HelmButton)?.title == HealthCardView.copyErrorTitle
                    && dotfiles.menu.contains { $0.title == HealthCardView.copyErrorTitle },
                  "UX-18: the failing row has no Copy error", &ok)
            let saved = NSPasteboard.general.string(forType: .string)
            (dotfiles.accessory as? HelmButton)?.performClick(nil)
            check(NSPasteboard.general.string(forType: .string)?.contains("git push was rejected") == true,
                  "UX-18: Copy error did not put the row's error on the pasteboard", &ok)
            if let saved { copyToPasteboard(saved) }
        } else {
            fail("UX-18: the table has no Dotfiles auto-sync row", &ok)
        }

        check(column.debugHeadline.hasPrefix(HealthService.dotfilesAutoSync.title),
              "H-4: the failing headline reads \(column.debugHeadline)", &ok)
        // Most services failing is an outage, and the column is red.
        for service in HealthService.allCases.prefix(6) {
            for _ in 0..<3 { ServiceHealthRegistry.shared.recordFailure(service, "outage") }
        }
        health = showHealth(shell)
        check(health.debugHealthCard.heroColumn.debugPalette == red,
              "UX-18: most services failing did not turn the column red", &ok)

        clearHealth()
        health = showHealth(shell)
        let unknown = health.debugHealthCard.heroColumn
        check(unknown.debugPalette == HelmHeroColumn.palette(for: .init(colour: .themeAccent, isDimmed: true), in: theme),
              "H-4: a column with nothing reported is not the dimmed accent (GL-14)", &ok)
        check(unknown.debugRing == nil && health.debugHealthCard.debugHeroBucketFigures.allSatisfy { $0 == "\u{2014}" },
              "H-4: nothing reported still draws a ring or zeros (\(health.debugHealthCard.debugHeroBucketFigures))", &ok)
    }

    private static func checkHealthRetry(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        var health = showHealth(shell)
        ReviewTourLab.seedDemoHealth(health)
        var retried: [HealthService] = []
        health.retryActions = [.backgroundSignals: { retried.append(.backgroundSignals) },
                               .dotfilesAutoSync: { retried.append(.dotfilesAutoSync) }]
        health = showHealth(shell)
        let column = health.debugHealthCard.heroColumn
        func buttons(in view: NSView) -> [HelmButton] {
            (view as? HelmButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let pills = column.footViews.flatMap(buttons)
        // Three pills wrap rather than run the column past its pane.
        let columnFrame = column.convert(column.bounds, to: nil)
        check(pills.allSatisfy { $0.convert($0.bounds, to: nil).maxX <= columnFrame.maxX - HelmHeroColumn.insets.right + 0.5 },
              "H-4: a foot pill runs past the column", &ok)
        check(abs(column.frame.width - HelmHeroColumn.width) < 1, "H-4: with three pills the column is \(column.frame.width)pt", &ok)
        let titles = pills.map(\.title)
        check(titles.count == 3 && titles.last == "Diagnostics", "H-4: the foot's pills are \(titles)", &ok)
        // Worst first: the failing dotfiles sync, then the signals' recent failure.
        pills.first?.performClick(nil)
        check(retried == [.dotfilesAutoSync], "H-4: the first Retry ran \(retried)", &ok)
        check(pills.allSatisfy { isInk($0.heroInk, column.ink) }, "H-4: a foot pill is not in the hero's ink", &ok)
        health.retryActions = [.backgroundSignals: {}, .dotfilesAutoSync: {}]
    }

    private static func checkHealthBand(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let health = showHealth(shell)
        guard let split = health.splitPage, let scaffold = health.debugScaffold else {
            fail("H-4: no split page", &ok)
            return
        }
        let column = health.debugHealthCard.heroColumn
        // Between the old fixed 880 and the table's full width: the column
        // goes, rather than Recent runs.
        resize(window, width: 1277, shell)
        settle(shell)
        let servicesTable = health.debugHealthCard.debugServicesTable.debugTable
        let runs = servicesTable.column(withIdentifier: NSUserInterfaceItemIdentifier("runs"))
        check(split.isSidebarCollapsed && runs >= 0 && !servicesTable.tableColumns[runs].isHidden,
              "H-4: at 1277 the column stayed (\(!split.isSidebarCollapsed)) or Recent runs hid", &ok)
        resize(window, width: 1000, shell)
        settle(shell)
        check(health.view.bounds.width < HealthController.heroCollapseWidth,
              "fixture: at 1000 the page is \(health.view.bounds.width)pt, not narrow", &ok)
        check(split.isSidebarCollapsed, "H-4: a narrow page keeps the column open", &ok)
        check(column.superview === scaffold && column.arrangement == .band,
              "H-4: a narrow page does not show the verdict as a band over the table", &ok)
        let band = frame(of: column, in: health.view)
        let table = frame(of: health.debugHealthCard.debugServicesTable.card, in: health.view)
        check(band.minY >= table.maxY - 0.5, "H-4: the band (\(band)) overlaps the table (\(table))", &ok)
        resize(window, width: 1512, shell)
        settle(shell)
        check(!split.isSidebarCollapsed && column.superview === split.sidebarPane && column.arrangement == .column,
              "H-4: widening the page did not bring the column back", &ok)
    }

    // MARK: C-4

    private static func checkConnectionsColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        guard let column = hosts.heroColumn, let split = hosts.splitPage else {
            fail("C-4: Connections has no hero column in the sidebar layout", &ok)
            return
        }
        check(hosts.heroColumnShowing && column.superview === split.sidebarPane && !column.isHidden,
              "C-4: the hero column is not showing in the split's pane", &ok)
        let page = hosts.view
        let columnFrame = frame(of: column, in: page)
        let gridFrame = frame(of: hosts.hostsGrid, in: page)
        check(abs(columnFrame.width - HelmHeroColumn.width) < 1, "C-4: the column is \(columnFrame.width)pt wide", &ok)
        check(gridFrame.minX > columnFrame.maxX + HelmMetrics.s4 - 0.5,
              "C-4: the cards (\(gridFrame.minX)) do not start past the column (\(columnFrame.maxX))", &ok)
        check(hosts.hostsGrid.columnCount == 2, "C-4: the cards run \(hosts.hostsGrid.columnCount) to a row at 1512", &ok)
        check(column.debugSectionTitles == ["Recent", "Quick connect"], "C-4: the sections are \(column.debugSectionTitles)", &ok)
        check(isInk(column.debugHeadlineLabel.textColor, column.ink), "C-4: the headline is not in the hero's ink", &ok)
        check(isInk(hosts.heroQuickConnectField.heroInk, column.ink), "C-4: Quick connect is not drawn for the gradient", &ok)
    }

    private static func checkConnectionsRecent(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let store = shell.workspace.hostStore
        guard let grafana = store.hosts.first(where: { $0.label == "grafana" }),
              let bastion = store.hosts.first(where: { $0.label == "bastion-stg" }),
              let edge = store.hosts.first(where: { $0.label == "edge-proxy-01" }) else {
            fail("C-4: the demo hosts are missing", &ok)
            return
        }
        store.recordConnection(id: edge.id, at: Date().addingTimeInterval(-2 * 86_400))
        store.recordConnection(id: grafana.id, at: Date().addingTimeInterval(-3 * 3600))
        store.recordConnection(id: bastion.id, at: Date().addingTimeInterval(-42 * 60))
        let savedLive = hosts.liveSession, savedSwitch = hosts.onSwitchToSession, savedConnect = hosts.onConnect
        var switched: [UUID] = []
        var connected: [UUID?] = []
        hosts.liveSession = { id in
            id == bastion.id ? HostSession(hostID: id, label: "bastion-stg", accentHex: nil,
                                           startedAt: Date().addingTimeInterval(-42 * 60), state: .connected) : nil
        }
        hosts.onSwitchToSession = { switched.append($0) }
        hosts.onConnect = { id, _, _, _, _, _ in connected.append(id) }
        defer { hosts.liveSession = savedLive; hosts.onSwitchToSession = savedSwitch; hosts.onConnect = savedConnect }
        hosts.refreshLiveSessionState()
        settle(shell)
        guard let column = hosts.heroColumn else { return }
        let rows = column.debugRows.filter { $0.trailing != nil }
        check(rows.map(\.titleLabel.stringValue) == ["bastion-stg", "grafana", "edge-proxy-01"],
              "C-4: Recent reads \(rows.map(\.titleLabel.stringValue)), newest first", &ok)
        check(column.debugHeadline == "1 live session, on bastion-stg.", "C-4: the headline reads \(column.debugHeadline)", &ok)
        check(!hosts.hostsGrid.debugSectionTitles.contains("Recent"),
              "C-4: the grid still draws a Recent row beside the column (\(hosts.hostsGrid.debugSectionTitles))", &ok)
        let pills = rows.compactMap { $0.trailing as? HelmButton }
        check(pills.first?.title == "Switch", "C-4: a live host's pill reads \(pills.first?.title ?? "nothing")", &ok)
        pills.first?.performClick(nil)
        check(switched == [bastion.id], "C-4: Switch ran \(switched)", &ok)
        if pills.count > 1 { pills[1].performClick(nil) }
        check(connected == [grafana.id], "C-4: grafana's Connect ran \(connected)", &ok)
        check(pills.allSatisfy { isInk($0.heroInk, column.ink) }, "C-4: a Recent pill is not in the hero's ink", &ok)
    }

    private static func checkConnectionsQuickConnect(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let savedConnect = hosts.onConnect
        var connects: [(id: UUID?, label: String)] = []
        hosts.onConnect = { id, label, _, _, _, _ in connects.append((id, label)) }
        defer { hosts.onConnect = savedConnect }
        let field = hosts.heroQuickConnectField
        field.stringValue = "deploy@build-07.example.test"
        let consumed = field.onCommand?(#selector(NSResponder.insertNewline(_:))) ?? false
        check(consumed, "C-4: Return in Quick connect was not handled", &ok)
        check(connects.count == 1 && connects.first?.id == nil && connects.first?.label.contains("build-07") == true,
              "C-4: Quick connect ran \(connects.map(\.label))", &ok)
        check(field.stringValue.isEmpty, "C-4: Quick connect kept its text after connecting", &ok)
        field.stringValue = "grafana"
        _ = field.onCommand?(#selector(NSResponder.insertNewline(_:)))
        let grafana = shell.workspace.hostStore.hosts.first { $0.label == "grafana" }
        check(connects.count == 2 && connects.last?.id == grafana?.id, "C-4: a saved host's name did not connect it", &ok)
    }

    private static func checkConnectionsCards(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let grid = hosts.hostsGrid
        check(abs(grid.cardHeight - HelmType.scaledRowHeight(HelmCardGrid.roomyCardHeight)) < 0.5,
              "C-1: the host cards are \(grid.cardHeight)pt tall", &ok)
        // A host whose address cannot fit, so the check can see a line that
        // runs under the buttons.
        let long = Host(label: "long-address", address: "bastion-01.staging.eu-west-1.compute.example.test",
                        port: 2222, username: "deploy-automation")
        shell.workspace.hostStore.add(long)
        settle(shell)
        defer { shell.workspace.hostStore.delete(id: long.id); settle(shell) }
        var overlaps: [String] = []
        var truncated = false
        for entry in grid.debugPlaced {
            guard let card = grid.debugCardView(key: entry.key) else { continue }
            card.layoutSubtreeIfNeeded()
            let label = card.debugSubtitleLabel
            if entry.key == long.id.uuidString { truncated = label.frame.width < label.attributedStringValue.size().width }
            let actionsLeft = card.debugActionButtons.map { card.convert($0.bounds, from: $0).minX }.min() ?? card.bounds.maxX
            let right = card.convert(label.bounds, from: label).maxX
            if right > actionsLeft + 0.5 { overlaps.append("\(card.debugTitle): \(right) > \(actionsLeft)") }
        }
        check(truncated, "fixture: the long address fits its card, so the overlap check measures nothing", &ok)
        check(overlaps.isEmpty, "C-1: a card's address runs under its icon buttons: \(overlaps)", &ok)
        // The buttons stand in a column: one above the other.
        if let card = grid.debugPlaced.dropFirst().first.flatMap({ grid.debugCardView(key: $0.key) }) {
            let frames = card.debugActionButtons.map { card.convert($0.bounds, from: $0) }
            check(frames.count == 2 && abs(frames[0].midX - frames[1].midX) < 0.5 && abs(frames[0].midY - frames[1].midY) > 20,
                  "C-1: the bolt and pencil are not stacked in a column (\(frames))", &ok)
        }
    }

    private static func checkConnectionsCollapse(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        guard let split = hosts.splitPage else { return }
        let store = shell.workspace.hostStore
        if let lab = store.hosts.first(where: { $0.label == "lab-box" }) { store.recordConnection(id: lab.id) }
        // The shell's inspector opening is what narrows the page at 1512.
        shell.setInspectorShown(true)
        settle(shell)
        check(hosts.view.bounds.width < split.collapsesBelowWidth ?? 0,
              "fixture: with the inspector open the page is \(hosts.view.bounds.width)pt, not narrower than the column needs", &ok)
        // Gotcha (13): the column gives way; the window does not grow for it.
        check(abs(window.frame.width - 1512) < 0.5, "C-4: opening the inspector grew the window to \(window.frame.width)", &ok)
        check(split.isSidebarCollapsed && !hosts.heroColumnShowing, "C-4: a narrow page keeps the column open", &ok)
        check(hosts.hostsGrid.debugSectionTitles.first == "Recent",
              "C-4: with the column away the grid has no Recent row (\(hosts.hostsGrid.debugSectionTitles))", &ok)
        // UX-27: the page keeps its hero as Health's band over the tabs: the
        // verdict, the ring and Quick connect.
        if let column = hosts.heroColumn {
            let band = frame(of: column, in: hosts.view)
            let grid = frame(of: hosts.hostsGrid, in: hosts.view)
            check(hosts.heroIsBand && column.arrangement == .band && column.window != nil && !column.isHiddenOrHasHiddenAncestor,
                  "UX-27: with the column away the page shows no hero band", &ok)
            check(column.debugRing != nil && hosts.heroQuickConnectField.isDescendant(of: column)
                    && hosts.heroQuickConnectField.window != nil,
                  "UX-27: the band lost its ring or Quick connect", &ok)
            check(band.height > 0 && band.minY >= grid.maxY - 0.5,
                  "UX-27: the band (\(band)) does not sit above the grid (\(grid))", &ok)
        } else {
            fail("UX-27: Connections built no hero column", &ok)
        }
        shell.setInspectorShown(false)
        settle(shell)
        check(abs(window.frame.width - 1512) < 0.5, "C-4: closing the inspector left the window at \(window.frame.width)", &ok)
        check(!split.isSidebarCollapsed && hosts.heroColumnShowing, "C-4: widening the page did not bring the column back", &ok)
        check(abs(split.sidebarPane.frame.width - (HelmMetrics.pageGutter + HelmHeroColumn.width)) < 0.5,
              "C-4: the column came back \(split.sidebarPane.frame.width)pt wide", &ok)
        check(!hosts.hostsGrid.debugSectionTitles.contains("Recent"), "C-4: Recent did not move back into the column", &ok)
        check(!hosts.heroIsBand && hosts.heroColumn?.arrangement == .column && hosts.heroColumn?.superview === split.sidebarPane,
              "UX-27: widening the page left the hero as a band", &ok)
        // Toggle Sidebar puts it away too, and is remembered across a width change.
        split.toggleSidebar(nil)
        settle(shell)
        check(split.isSidebarCollapsed && hosts.hostsGrid.debugSectionTitles.first == "Recent",
              "C-4: Toggle Sidebar did not put the column away and bring Recent back", &ok)
        split.toggleSidebar(nil)
        settle(shell)
        check(!split.isSidebarCollapsed, "C-4: Toggle Sidebar did not bring the column back", &ok)
    }

    // MARK: The Keys tab

    @discardableResult
    static func showKeys(_ shell: MainSplitShellController) -> HostsController {
        let hosts = showHosts(shell)
        hosts.selectModuleTab(named: "Keys")
        settle(shell)
        return hosts
    }

    private static func checkKeysColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showKeys(shell)
        defer { hosts.selectModuleTab(named: "Hosts"); settle(shell) }
        let keyStore = shell.workspace.keyStore
        guard let column = hosts.heroColumn, let split = hosts.splitPage,
              let ops = keyStore.keys.first(where: { $0.label == "ops-ed25519" }) else {
            fail("Keys: no hero column, or the demo keys are missing", &ok)
            return
        }
        check(hosts.heroColumnShowing && column.superview === split.sidebarPane,
              "Keys: the hero column is not showing beside the key cards", &ok)
        check(column.debugKicker == "Keys" && column.debugSectionTitles == ["Recent keys", "Add a key"],
              "Keys: the column reads \(column.debugKicker) with \(column.debugSectionTitles)", &ok)
        let expected = KeysHeroWords.make(
            keysReadable: true,
            keys: keyStore.keys.map { key in
                .init(label: key.label, hostCount: shell.workspace.hostStore.hosts.filter { $0.keyID == key.id }.count,
                      lastUsedAt: key.lastUsedAt)
            },
            hostsWithAKey: shell.workspace.hostStore.hosts.filter { $0.keyID != nil }.count,
            biometryAvailable: CredentialVaultKeyStore.biometryAvailable)
        check(column.debugHeadline == expected.headline && column.debugRing != nil,
              "Keys: the headline reads \(column.debugHeadline), want \(expected.headline)", &ok)

        // Recent keys: the key a host just connected with, with a Copy pill
        // in the hero's ink, and no Recent row in the grid beside it.
        keyStore.recordUse(id: ops.id)
        settle(shell)
        let rows = column.debugRows.filter { $0.trailing != nil }
        check(rows.map(\.titleLabel.stringValue) == ["ops-ed25519"], "Keys: Recent keys reads \(rows.map(\.titleLabel.stringValue))", &ok)
        let copy = rows.first?.trailing as? HelmButton
        check(copy?.toolTip == "Copy ops-ed25519's public key" && copy.map { isInk($0.heroInk, column.ink) } == true,
              "Keys: the Recent key's pill is \(copy?.toolTip ?? "missing"), or not in the hero's ink", &ok)
        check(!hosts.keysGrid.debugSectionTitles.contains("Recent"),
              "Keys: the grid draws a Recent row beside the column (\(hosts.keysGrid.debugSectionTitles))", &ok)

        // Generate runs K2's own Generate: a new key's form, in generate mode.
        func buttons(in view: NSView) -> [HelmButton] {
            (view as? HelmButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let addPills = buttons(in: column).filter { ["Generate", "Import"].contains($0.title) }
        check(addPills.map(\.title) == ["Generate", "Import"] && addPills.allSatisfy { isInk($0.heroInk, column.ink) },
              "Keys: Add a key's pills are \(addPills.map(\.title)), or not in the hero's ink", &ok)
        // UX-26: a new key is made in a sheet over the page.
        addPills.first?.performClick(nil)
        settle(shell)
        let sheet = hosts.presentedViewControllers?.compactMap { $0 as? KeyEditorController }.first
        check(sheet?.presentation == .sheet && sheet?.debugMode == "generate",
              "Keys: Generate opened \(sheet?.debugMode ?? "no sheet")", &ok)
        if let sheet { hosts.dismiss(sheet) }
        settle(shell)
        check(hosts.presentedViewControllers?.isEmpty != false, "Keys: the new key's sheet stayed open", &ok)

        // The column follows the tab: back on Hosts it speaks for the hosts.
        hosts.selectModuleTab(named: "Hosts")
        settle(shell)
        check(column.debugKicker == "Connections" && column.debugSectionTitles == ["Recent", "Quick connect"],
              "Keys: back on Hosts the column reads \(column.debugKicker) with \(column.debugSectionTitles)", &ok)
    }

    /// UI-10 of full review 4: on Snippets the column speaks for snippets
    /// and holds the trigger switch, which leaves the page body while the
    /// column shows and comes back when the column is put away. It wore the
    /// Hosts words: "No live session", a ring of hosts online, Quick connect.
    private static func checkSnippetsColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        hosts.selectModuleTab(named: "Snippets")
        settle(shell)
        defer { hosts.selectModuleTab(named: "Hosts"); resize(window, width: 1512, shell); settle(shell) }
        guard let column = hosts.heroColumn else {
            fail("UI-10: Connections has no hero column", &ok)
            return
        }
        check(hosts.heroColumnShowing, "UI-10: fixture: the column is not showing at 1512", &ok)
        check(column.debugKicker == "Snippets" && column.debugSectionTitles == ["Expand while I type", "Triggers"]
                && column.debugRing == nil,
              "UI-10: the column reads \(column.debugKicker) with \(column.debugSectionTitles)", &ok)
        let store = shell.workspace.snippetStore
        check(column.debugHeadline.hasPrefix(store.snippets.count == 1 ? "1 snippet" : "\(store.snippets.count) snippets"),
              "UI-10: the headline reads \(column.debugHeadline)", &ok)
        check(hosts.debugExpansionStrip.isHiddenOrHasHiddenAncestor,
              "UI-10: the trigger switch is in the page body as well as the column", &ok)

        // The column's switch runs the page's own handler.
        func tabs(in view: NSView) -> [HelmSegmentedTabs] {
            (view as? HelmSegmentedTabs).map { [$0] } ?? view.subviews.flatMap(tabs)
        }
        let saved = hosts.onSnippetExpansionToggled
        var flipped: [Bool] = []
        hosts.onSnippetExpansionToggled = { flipped.append($0) }
        defer { hosts.onSnippetExpansionToggled = saved }
        if let toggle = tabs(in: column).first {
            check(isInk(toggle.heroInk, column.ink), "UI-10: the switch is not in the hero's ink", &ok)
            toggle.debugClickTab(id: toggle.selected == "on" ? "off" : "on")
            check(flipped.count == 1, "UI-10: the column's switch did not reach the page's handler (\(flipped))", &ok)
        } else {
            fail("UI-10: the column holds no switch", &ok)
        }

        // Put away, the column takes the switch with it, so the strip is back.
        resize(window, width: 1000, shell)
        settle(shell)
        check(!hosts.heroColumnShowing, "UI-10: fixture: the column still shows at 1000", &ok)
        check(!hosts.debugExpansionStrip.isHiddenOrHasHiddenAncestor && hosts.debugExpansionStrip.window != nil,
              "UI-10: with the column put away the trigger switch is nowhere", &ok)
    }

    private static func checkKeysCards(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showKeys(shell)
        defer { hosts.selectModuleTab(named: "Hosts"); settle(shell) }
        let grid = hosts.keysGrid
        let keyStore = shell.workspace.keyStore
        // A key whose name and fingerprint cannot fit, so the overlap check
        // can see a line that runs under the buttons.
        let long = SSHKey(label: "github-actions-production-deploy-rsa-4096-2026", type: .rsa,
                          publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABFixtureOnly long@example.test",
                          fingerprint: "SHA256:Fx7q2ZpLm9WcR4tYvB8nK3sD6hJ1aE5oUiQ0gXyTzNw")
        keyStore.add(long)
        settle(shell)
        defer {
            var keys = keyStore.keys
            keys.removeAll { $0.id == long.id }
            keyStore.debugReplaceAll(keys)
            settle(shell)
        }
        check(abs(grid.cardHeight - hosts.hostsGrid.cardHeight) < 0.5 && grid.columnCount == 2,
              "Keys: the key cards are \(grid.cardHeight)pt, \(grid.columnCount) to a row (hosts: \(hosts.hostsGrid.cardHeight)pt)", &ok)
        guard let column = hosts.heroColumn, let first = grid.debugPlaced.first,
              let card = grid.debugCardView(key: long.id.uuidString) else {
            fail("Keys: no column or no key cards", &ok)
            return
        }
        let page = hosts.view
        check(frame(of: grid, in: page).minX > frame(of: column, in: page).maxX + HelmMetrics.s4 - 0.5,
              "Keys: the key cards do not start past the column", &ok)
        check(abs(first.frame.width - (hosts.hostsGrid.debugPlaced.first?.frame.width ?? 0)) < 0.5,
              "Keys: a key card is \(first.frame.width)pt wide, a host card \(hosts.hostsGrid.debugPlaced.first?.frame.width ?? 0)pt", &ok)
        // The whole fingerprint in the code face, cut in the middle, and
        // the type as the chip.
        card.layoutSubtreeIfNeeded()
        let label = card.debugSubtitleLabel
        check(card.debugSubtitle == long.fingerprint && label.lineBreakMode == .byTruncatingMiddle
                && label.font == HelmType.code() && card.debugChip == long.type.displayName,
              "Keys: the card reads \(card.debugSubtitle) with chip \(card.debugChip ?? "none")", &ok)
        check(label.frame.width < label.attributedStringValue.size().width,
              "fixture: the long fingerprint fits its card, so the overlap check measures nothing", &ok)
        var overlaps: [String] = []
        for entry in grid.debugPlaced {
            guard let view = grid.debugCardView(key: entry.key) else { continue }
            view.layoutSubtreeIfNeeded()
            let actionsLeft = view.debugActionButtons.map { view.convert($0.bounds, from: $0).minX }.min() ?? view.bounds.maxX
            let line = view.debugSubtitleLabel
            let right = view.convert(line.bounds, from: line).maxX
            if right > actionsLeft + 0.5 { overlaps.append("\(view.debugTitle): \(right) > \(actionsLeft)") }
        }
        check(overlaps.isEmpty, "Keys: a card's fingerprint runs under its icon buttons: \(overlaps)", &ok)
        let frames = card.debugActionButtons.map { card.convert($0.bounds, from: $0) }
        check(frames.count == 2 && abs(frames[0].midX - frames[1].midX) < 0.5 && abs(frames[0].midY - frames[1].midY) > 20,
              "Keys: copy and edit are not stacked in a column (\(frames))", &ok)
        // The toolbar row is the Hosts row's shape: the switch ends where
        // the cards do, and Touch ID follows the search.
        let switchFrame = frame(of: hosts.keysViewModeControl, in: page)
        let gridFrame = frame(of: grid, in: page)
        let hostsSwitch = frame(of: hosts.hostsViewModeControl, in: page)
        check(abs(switchFrame.maxX - hostsSwitch.maxX) < 1 && abs(switchFrame.width - hostsSwitch.width) < 1,
              "Keys: Grid / List ends at \(switchFrame.maxX) (\(switchFrame.width)pt), the Hosts one at \(hostsSwitch.maxX) (\(hostsSwitch.width)pt); cards end at \(gridFrame.maxX)", &ok)
        check(frame(of: hosts.keysTouchID, in: page).minX > frame(of: hosts.keySearchField, in: page).maxX,
              "Keys: Touch ID does not follow the search", &ok)
    }

    private static func checkKeysCollapse(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showKeys(shell)
        defer { hosts.selectModuleTab(named: "Hosts"); settle(shell) }
        guard let split = hosts.splitPage else { return }
        let keyStore = shell.workspace.keyStore
        if let ci = keyStore.keys.first(where: { $0.label == "ci-deploy" }) { keyStore.recordUse(id: ci.id) }
        // The Keys row is narrower than the Hosts filter row, so the column
        // stays beside the inspector at 1512; a narrow window puts it away.
        resize(window, width: 1100, shell)
        check(hosts.view.bounds.width < split.collapsesBelowWidth ?? 0,
              "fixture: at 1100 the page is \(hosts.view.bounds.width)pt, not narrower than the column needs", &ok)
        check(split.isSidebarCollapsed && !hosts.heroColumnShowing, "Keys: a narrow page keeps the column open", &ok)
        check(hosts.keysGrid.debugSectionTitles == ["Recent", "All keys"],
              "Keys: with the column away the grid reads \(hosts.keysGrid.debugSectionTitles)", &ok)
        check(abs(window.frame.width - 1100) < 0.5, "Keys: the narrow page grew the window to \(window.frame.width)", &ok)
        resize(window, width: 1512, shell)
        check(!split.isSidebarCollapsed && hosts.heroColumnShowing && hosts.keysGrid.debugSectionTitles.isEmpty,
              "Keys: widening the page left the grid reading \(hosts.keysGrid.debugSectionTitles)", &ok)
        // Searching hides Recent, as on Hosts.
        split.toggleSidebar(nil)
        settle(shell)
        hosts.keySearchField.stringValue = "ci-"
        hosts.keySearchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        settle(shell)
        check(hosts.keysGrid.debugSectionTitles.isEmpty, "Keys: a search still draws Recent (\(hosts.keysGrid.debugSectionTitles))", &ok)
        hosts.keySearchField.stringValue = ""
        hosts.keySearchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        split.toggleSidebar(nil)
        settle(shell)
    }

    // MARK: Renders

    private static func writeRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_PAGE_HERO_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = shell.workspace.hostStore
        let bastion = store.hosts.first { $0.label == "bastion-stg" }
        let hosts = shell.workspace.hostsPanel
        let savedLive = hosts.liveSession
        defer { hosts.liveSession = savedLive }
        for theme in [daylight, dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                // Health: healthy, failing, nothing reported.
                for state in ["healthy", "failing", "unknown"] {
                    switch state {
                    case "healthy": seedHealthy()
                    case "failing": clearHealth(); ReviewTourLab.seedDemoHealth(shell.workspace.health)
                    default: clearHealth()
                    }
                    let health = showHealth(shell)
                    write(health.view, to: folder.appendingPathComponent("health-\(theme.id)-\(state)-\(Int(width)).png"))
                }
                // Connections: no live session, and one.
                for state in ["idle", "live"] {
                    hosts.liveSession = state == "live" ? { id in
                        id == bastion?.id ? HostSession(hostID: id, label: "bastion-stg", accentHex: nil,
                                                        startedAt: Date().addingTimeInterval(-42 * 60),
                                                        state: .connected) : nil
                    } : nil
                    showHosts(shell)
                    hosts.refreshLiveSessionState()
                    settle(shell)
                    write(hosts.view, to: folder.appendingPathComponent("connections-\(theme.id)-\(state)-\(Int(width)).png"))
                }
                // Keys: with keys, and with none. At 1100 the column is put
                // away, which is the narrow render.
                hosts.liveSession = nil
                showKeys(shell)
                write(hosts.view, to: folder.appendingPathComponent("keys-\(theme.id)-keys-\(Int(width)).png"))
                let savedKeys = shell.workspace.keyStore.keys
                shell.workspace.keyStore.debugReplaceAll([])
                settle(shell)
                write(hosts.view, to: folder.appendingPathComponent("keys-\(theme.id)-empty-\(Int(width)).png"))
                shell.workspace.keyStore.debugReplaceAll(savedKeys)
                hosts.selectModuleTab(named: "Hosts")
            }
        }
        ThemeManager.shared.setTheme(daylight)
        resize(window, width: 1512, shell)
        print("PageHeroColumnsViewSelfTest: renders written to \(dir)")
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

#endif
