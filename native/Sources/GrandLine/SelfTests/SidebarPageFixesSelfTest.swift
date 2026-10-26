// Grand Line - native macOS app.
//
// Stage 6 of the modular-shell migration: the sidebar-layout fixes the
// captain asked for after using it, on the real off-screen shells.
//
//   1. **Connections** is the prototype's page: the tab's primary action at
//      the toolbar's far right after Search (Add Host, New Key, New Snippet),
//      the toolbar's tabs counting their records, one filter row under the
//      toolbar with the search and All / Online, no stat strip and no shortcut
//      footer, tables that end under their last row, Touch ID's reading on the
//      Keys card, the snippet expansion switch as a plain row, and Activity
//      still the module's action.
//   2. **Logs**: Analyze is the toolbar's primary action and still answers
//      ⌘↵, the header counts the lines, and an analysis opens on the summary
//      cards, the patterns table and the likely cause with its follow-ups.
//      And one defect found on the way, in both layouts: a finished analysis
//      showed an empty Analysis tab until a tab was clicked.
//   3. **Health**: summary cards over one service table, Copy diagnostics at
//      the far right, Refresh beside it, and Retry only on a failing service
//      that can be re-run - running that service's own action. No row offers
//      an empty ⋯.
//   4. **The floating bar is unchanged** on all three pages.
//
// The sidebar's own items (Pinned, the account menu, the header rule, no
// status strip under any module) are `MainSplitShellSelfTest`'s and
// `SplitShellModelSelfTest`'s.
//
// It never runs `claude -p`, `av`, a git sync or a real check: the Log
// Analyzer's fixture is rendered through `debugRender`, ⌘↵ is sent with
// nothing to analyze, and Retry's actions are replaced with counters. Every
// store a page it mounts can write is pointed at the suite's own folder, and
// the caller's stores are fingerprinted either side.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_SIDEBAR_PAGE_FIXES_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SidebarPageFixesSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-page-fixes-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            do {
                let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                resize(window, width: 1512, shell)
                ReviewTourLab.seedDemoHosts(shell.workspace)
                settle(shell)
                for check in [checkConnections, checkConnectionsKeysAndSnippets, checkLogs, checkHealth] {
                    var ok = true
                    check(shell, window, &ok)
                    allOK = allOK && ok
                }
            }
            do {
                var ok = true
                checkTheFloatingBarIsUnchanged(&ok)
                checkTheWiring(&ok)
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SidebarPageFixesSelfTest: all checks passed" : "SidebarPageFixesSelfTest: FAILED")
        return allOK
    }

    // MARK: 1 - Connections

    private static func checkConnections(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let hosts = shell.workspace.hostsPanel
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        clickTab("Hosts", shell)
        check(hosts.drawsSidebarLayout, "Connections did not adopt its sidebar presentation", &ok)

        // The tabs count what each holds, read from the page's own stores -
        // and the Hosts count agrees with the table under it.
        let counts = hosts.moduleTabCounts
        let records = hosts.debugHostsTable.debugRows.filter { $0.isRecord && $0.key != HostsController.firstmateRowKey }
        check((counts["Hosts"] ?? 0) > 0 && counts["Hosts"] == records.count,
              "the Hosts tab counts \(String(describing: counts["Hosts"])), the table lists \(records.count) saved hosts", &ok)
        let want = WorkspaceModule.connections.tabs.map { WorkspaceToolbar.tabLabel($0.name, count: counts[$0.name]) }
        check(shell.toolbar.debugTabLabels == want, "the tabs read \(shell.toolbar.debugTabLabels), want \(want)", &ok)
        check(shell.toolbar.debugTabNames == WorkspaceModule.connections.tabs.map(\.name),
              "a count leaked into the tab names \(shell.toolbar.debugTabNames)", &ok)

        // The primary action: one control at the far right, after Search.
        // H8 and K2 of the Termius-style plan made Add Host and New Key split
        // buttons (`HelmSplitButton`), so for those two the far-right control
        // is the split and its main half carries the title; New Snippet is
        // still one button with its own selector.
        for (tab, title, selector) in [("Hosts", "Add Host", nil), ("Keys", "New Key", nil),
                                       ("Snippets", "New Snippet", "newSnippet") as (String, String, String?)] {
            clickTab(tab, shell)
            let ids = shell.toolbar.debugItemIdentifiers
            let primaryView = shell.toolbar.debugPrimaryAction
            let primary = (primaryView as? HelmSplitButton)?.mainButton ?? primaryView as? HelmButton
            check(ids.last == WorkspaceToolbar.ItemID.primaryAction
                    && ids.firstIndex(of: WorkspaceToolbar.ItemID.primaryAction) == ids.firstIndex(of: WorkspaceToolbar.ItemID.search).map { $0 + 1 },
                  "on \(tab) the primary action is not the last item, right after Search: \(ids.map(\.rawValue))", &ok)
            check(primary?.title == title && (selector.map { primary?.action == NSSelectorFromString($0) } ?? (primaryView is HelmSplitButton)),
                  "on \(tab) the far-right button is \(primary?.title ?? "missing"), want \(title)", &ok)
            check(!shell.toolbar.debugPageActions.contains { $0 === primaryView },
                  "on \(tab) \(title) is drawn twice, among the page's other actions too", &ok)
        }
        clickTab("Hosts", shell)
        check(shell.toolbar.debugModuleActionButton?.title == "Activity", "Connections lost its Activity action", &ok)

        // No stat strip over the tabs and no shortcut footer under them: the
        // tab view starts at the content column's top.
        check(hosts.debugWorkspacePanel.isHidden && hosts.debugQuickActions.isHidden,
              "the stat strip or the shortcut footer still shows", &ok)
        let page = hosts.view
        let tab = hosts.debugTabView.convert(hosts.debugTabView.bounds, to: page)
        let top = page.isFlipped ? tab.minY : page.bounds.height - tab.maxY
        check(abs(top - HelmMetrics.s5) < 1, "the tab view starts \(top)pt down the page, want \(HelmMetrics.s5)", &ok)

        // One filter row: the search first, then All / Online in place of
        // the floating bar's toggle.
        let row = hosts.debugFilterRow?.arrangedSubviews.filter { !$0.isHidden } ?? []
        check(row.first === hosts.debugSearchField && row.contains { $0 === hosts.debugOnlineFilter }
                && !row.contains { $0 === hosts.debugOnlineChip },
              "the filter row is not the search then All / Online", &ok)
        let search = hosts.debugSearchField.convert(hosts.debugSearchField.bounds, to: page)
        let filter = hosts.debugOnlineFilter.convert(hosts.debugOnlineFilter.bounds, to: page)
        check(abs(search.midY - filter.midY) < 2 && search.width >= HostsController.sidebarSearchMinimumWidth - 0.5,
              "the search (\(search)) and the filter (\(filter)) are not on one row", &ok)

        // All / Online filters the table and counts both buckets.
        guard let liveKey = records.first?.key, let liveID = UUID(uuidString: liveKey) else {
            fail("no demo host to put a session on - the Online check would pass vacuously", &ok)
            return
        }
        shell.workspace.hosts.sessions.register(hostID: liveID, label: "Fixture", accentHex: nil, state: .connected)
        settle(shell)
        hosts.debugOnlineFilter.debugClickTab(id: HostsController.onlineFilterID)
        settle(shell)
        let online = hosts.debugHostsTable.debugRows.filter { $0.isRecord && $0.key != HostsController.firstmateRowKey }
        check(online.map(\.key) == [liveKey], "Online lists \(online.map(\.key)), want the one live host", &ok)
        check(hosts.debugOnlineChip.state == .on, "the floating bar's Online toggle does not follow the segments", &ok)
        hosts.debugOnlineFilter.debugClickTab(id: HostsController.allFilterID)
        settle(shell)
        check(hosts.debugHostsTable.debugRows.filter { $0.isRecord }.count == records.count + 1,
              "All did not bring every host back", &ok)
        shell.workspace.hosts.sessions.unregister(hostID: liveID)
        settle(shell)

        // The table ends under its last row rather than filling the page.
        let card = hosts.debugHostsTable.card.convert(hosts.debugHostsTable.card.bounds, to: page)
        check(hosts.debugHostsTable.hugsRows && card.height < tab.height - 60,
              "the hosts card is \(card.height)pt in a \(tab.height)pt tab - it fills the page", &ok)
    }

    private static func checkConnectionsKeysAndSnippets(_ shell: MainSplitShellController, _ window: NSWindow,
                                                        _ ok: inout Bool) {
        let hosts = shell.workspace.hostsPanel
        clickTab("Keys", shell)
        let pill = hosts.debugKeysTouchID
        let available = CredentialVaultKeyStore.biometryAvailable
        check(pill.isDescendant(of: hosts.debugKeysTable.card) && pill.window != nil,
              "Touch ID's reading is not on the Keys card", &ok)
        check(pill.label.stringValue == HostsKeychainCard.biometryPhrase(available, capitalized: true),
              "the Keys card says \"\(pill.label.stringValue)\" about Touch ID", &ok)

        clickTab("Snippets", shell)
        let strip = hosts.debugExpansionStrip
        check(strip.style == .inline && !strip.debugUsesACard && strip.window != nil,
              "the snippet expansion switch is not the plain row over the table", &ok)
        let table = hosts.debugSnippetsTable.card
        let page = hosts.view
        let stripFrame = strip.convert(strip.bounds, to: page)
        let tableFrame = table.convert(table.bounds, to: page)
        check(page.isFlipped ? stripFrame.maxY <= tableFrame.minY : stripFrame.minY >= tableFrame.maxY,
              "the expansion row is not above the Snippets table", &ok)
        // The switch reaches the page's own handler through its click.
        var toggled: Bool?
        let previous = hosts.onSnippetExpansionToggled
        hosts.onSnippetExpansionToggled = { toggled = $0 }
        defer { hosts.onSnippetExpansionToggled = previous }
        let before = strip.debugToggleIsOn
        strip.debugFlipToggle()
        check(toggled == !before, "flipping the expansion switch did not reach the page (got \(String(describing: toggled)))", &ok)
        clickTab("Hosts", shell)
    }

    // MARK: 2 - Logs

    private static func checkLogs(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let logs = shell.workspace.logAnalyzer
        shell.workspace.navigator.show(.logAnalyzer)
        settle(shell)
        check(logs.drawsSidebarLayout, "Logs did not adopt its sidebar presentation", &ok)
        check(shell.toolbar.debugPrimaryAction === logs.debugAnalyzeButton
                && shell.toolbar.debugItemIdentifiers.last == WorkspaceToolbar.ItemID.primaryAction,
              "Analyze is not the toolbar's far-right action", &ok)
        check(!logs.debugInputControls.contains { $0 === logs.debugAnalyzeButton },
              "Analyze is still on the input card too", &ok)
        check(!logs.debugHintIsShown, "the shortcut line still shows under the input", &ok)
        check(shell.toolbar.debugPageActions.count == 2, "New and History are not both in the toolbar", &ok)

        // ⌘↵ still reaches Analyze from its toolbar home: sent through the
        // window with nothing to analyze, it says so rather than analyzing.
        logs.newInvestigation()
        let toasts = Toast.debugCount(in: logs.view)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        let handled = event.map { window.performKeyEquivalent(with: $0) } ?? false
        check(handled && Toast.debugCount(in: logs.view) == toasts + 1,
              "⌘↵ did not reach Analyze in the toolbar (handled: \(handled))", &ok)

        // The header counts the lines being pasted.
        logs.debugSetInput("one\ntwo\nthree")
        check(shell.debugHeader?.subtitle == "Log Analyzer \u{00B7} 3 lines \u{00B7} not analyzed yet",
              "the header reads \"\(shell.debugHeader?.subtitle ?? "nothing")\"", &ok)
        logs.debugSetInput("")

        // An analysis: the summary, the patterns and the likely cause.
        let fixture = ReviewTourLab.demoLogInvestigation()
        logs.debugRender(fixture)
        settle(shell)
        check(logs.debugTabIsShown("analysis"), "a finished analysis shows an empty Analysis tab", &ok)
        let groups = fixture.analysis?.local.groups ?? []
        var high = 0, warning = 0
        for line in fixture.evidence.flatMap({ $0.text.components(separatedBy: "\n") }) {
            switch LogErrorExtractor.severity(forLine: line) {
            case .critical, .high: high += 1
            case .warning: warning += 1
            default: break
            }
        }
        check(high > 0 && groups.count > 1, "the fixture has no severe lines or patterns - the counts would pass vacuously", &ok)
        let values = logs.debugMetricCards.map(\.debugValue)
        check(values == ["\(high)", "\(warning)", "\(groups.count)"],
              "the summary cards read \(values), want \([high, warning, groups.count])", &ok)
        check(logs.debugPatternsTable.debugRows.filter(\.isRecord).map(\.key) == groups.map(\.pattern),
              "the patterns table does not list the analyzer's groups", &ok)
        check(logs.debugActionBarIsUnderTheLikelyCause, "the follow-up actions are not under the likely cause", &ok)
        check(logs.debugInputSummary.hasPrefix("\(fixture.evidence[0].lineCount) lines"),
              "the input card reads \"\(logs.debugInputSummary)\"", &ok)
        // A pattern opens its lines.
        _ = logs.debugPatternsTable.debugActionsCell(key: groups[0].pattern)?.debugPrimaryButton.performClick(nil)
        settle(shell)
        check(logs.debugTabs.selected == "groups" && logs.debugTabIsShown("groups"),
              "a pattern's Lines did not open the Error Groups tab", &ok)
        logs.debugTabs.debugClickTab(id: "analysis")
        logs.newInvestigation()
    }

    // MARK: 3 - Health

    private static func checkHealth(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let health = shell.workspace.health
        let wired = health.retryActions
        ReviewTourLab.seedDemoHealth(health)
        var retried: [HealthService] = []
        health.retryActions = [.backgroundSignals: { retried.append(.backgroundSignals) },
                               .dotfilesAutoSync: { retried.append(.dotfilesAutoSync) }]
        defer { health.retryActions = wired }
        shell.workspace.navigator.show(.health)
        settle(shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        settle(shell)
        let card = health.debugHealthCard
        check(health.drawsSidebarLayout && card.drawsTable && card.card.isHidden,
              "Health did not swap its card for the summary and the table", &ok)
        check(shell.toolbar.debugPrimaryAction === card.diagnosticsButton, "Copy diagnostics is not the far-right action", &ok)
        check(shell.toolbar.debugPageActions.contains { $0 === health.debugRefreshButton }, "Refresh is not in the toolbar", &ok)

        let counts = HealthCardView.verdictCounts()
        let values = card.debugMetricCards.map(\.debugValue)
        check(values == ["\(counts.healthy) / \(counts.total)", "\(counts.degraded)", "\(counts.failing)", "\(counts.pending)"],
              "the summary cards read \(values) against \(counts)", &ok)
        check(counts.degraded >= 1 && counts.failing >= 1 && counts.healthy >= 1,
              "the seeded verdicts did not land - the checks below would pass vacuously", &ok)
        let table = card.debugServicesTable
        let keys = table.debugRows.filter(\.isRecord).compactMap(\.key)
        check(keys == ServiceHealthRegistry.shared.knownServices().map(\.rawValue),
              "the table lists \(keys), not every known service in order", &ok)

        // Retry only where a failing service can be re-run, and it runs that.
        let withRetry = table.debugRows.filter { $0.primary?.title == "Retry" }.compactMap(\.key)
        check(Set(withRetry) == [HealthService.backgroundSignals.rawValue, HealthService.dotfilesAutoSync.rawValue],
              "Retry shows on \(withRetry)", &ok)
        table.debugActionsCell(key: HealthService.dotfilesAutoSync.rawValue)?.debugPrimaryButton.performClick(nil)
        check(retried == [.dotfilesAutoSync], "Retry ran \(retried), want the dotfiles sync's own action", &ok)
        // A row with nothing to do has no ⋯.
        let quiet = table.debugActionsCell(key: HealthService.fleetTasks.rawValue)
        check(quiet != nil && quiet?.debugOverflowButton.isHidden == true && quiet?.debugPrimaryButton.isHidden == true,
              "a healthy row offers an empty ⋯ or a button", &ok)
        // A recovered service loses its Retry.
        ServiceHealthRegistry.shared.recordSuccess(.backgroundSignals)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        health.debugRefresh()
        check(!table.debugRows.contains { $0.key == HealthService.backgroundSignals.rawValue && $0.primary != nil },
              "a healthy service still offers Retry", &ok)
    }

    // MARK: 4 - the floating bar

    private static func checkTheFloatingBarIsUnchanged(_ ok: inout Bool) {
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        ReviewTourLab.seedDemoHosts(shell.workspace)
        settle(shell)
        let hosts = shell.workspace.hostsPanel
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        check(!hosts.drawsSidebarLayout && hosts.workspacePrimaryAction == nil, "the floating bar's Hosts has a toolbar primary action", &ok)
        check(!hosts.debugWorkspacePanel.isHidden && !hosts.debugQuickActions.isHidden && !hosts.debugOnlineChip.isHidden,
              "the floating bar's Hosts lost its stat strip, its shortcut line or its Online toggle", &ok)
        check(hosts.drillHeaderActions.count == 1, "the floating bar's Hosts header actions changed", &ok)

        let logs = shell.workspace.logAnalyzer
        shell.workspace.navigator.show(.logAnalyzer)
        settle(shell)
        check(!logs.drawsSidebarLayout && logs.workspacePrimaryAction == nil
                && logs.debugInputControls.contains { $0 === logs.debugAnalyzeButton } && logs.debugHintIsShown,
              "the floating bar's Log Analyzer moved Analyze or lost its shortcut line", &ok)
        check(logs.drillHeaderSubtitle?.hasPrefix("Paste raw logs") == true,
              "the floating bar's Log Analyzer header changed: \(logs.drillHeaderSubtitle ?? "nil")", &ok)
        logs.debugRender(ReviewTourLab.demoLogInvestigation())
        settle(shell)
        check(logs.debugTabIsShown("analysis"), "the floating bar's finished analysis shows an empty Analysis tab", &ok)
        logs.newInvestigation()

        let health = shell.workspace.health
        shell.workspace.navigator.show(.health)
        settle(shell)
        check(!health.drawsSidebarLayout && !health.debugHealthCard.drawsTable && health.workspacePrimaryAction == nil
                && health.drillHeaderActions.count == 1,
              "the floating bar's Health page changed", &ok)
    }

    /// Source guards for wiring a behaviour check cannot see: Retry's real
    /// actions are the services' own entry points.
    private static func checkTheWiring(_ ok: inout Bool) {
        guard let workspace = FeatureInventorySelfTest.source("Workspace.swift") else {
            fail("could not read Workspace.swift - the guard would pass vacuously", &ok)
            return
        }
        check(workspace.contains(".backgroundSignals: { BackgroundSignalsPoller.shared.checkNow() }")
                && workspace.contains(".dotfilesAutoSync: { DotfilesAutoSync.shared.syncNowFromUI() }"),
              "Health's Retry no longer runs the services' own entry points", &ok)
    }

    // MARK: Helpers

    private static func clickTab(_ name: String, _ shell: MainSplitShellController) {
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return }
        shell.debugClickTab(index)
        settle(shell)
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size = NSSize(width: width, height: 950)
        window.setFrame(frame, display: false)
        settle(shell)
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }
}

#endif
