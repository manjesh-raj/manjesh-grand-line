// Grand Line - native macOS app.
//
// The later page work of the modular-shell migration: the four pages the
// sidebar layout redesigns, mounted in a real off-screen sidebar shell and
// driven through their own controls - and the floating bar's same pages,
// checked to be what they were.
//
//   1. **Connections** draws Hosts, Keys and Snippets as tables. A row's
//      selection fills the shell's inspector with that record's details and
//      every action, the page's own detail column stays away, the snippet
//      expansion switch is a strip over its table, and the inspector opens at
//      1100 without growing the window.
//   2. **Secrets** draws Poneglyph's credentials as a table that keeps Reveal,
//      Copy and the live 2FA code on the row, hosts the credential inspector
//      in the shell's pane, and lets it go when the vault locks. Automic
//      Vault's two lists are tables under their own cards, with B1's three
//      states intact.
//   3. **Knowledge** draws no column beside its tabs (stage 7 removed the
//      tree): Notebook keeps its own page column, Runbooks and Postmortems
//      list their items, and the toolbar's Search finds all three kinds.
//   4. **Crew › Needs you** is a real tab: the parked tasks and their open
//      decisions, with Reply, an honest summary, and the bell's and Home's
//      ways in. Since CR-1 (the hero restyle board) Needs you and In flight
//      each open on the Crew band: its words per state, the dimmed tone over
//      a failed read with the rows carried, the briefing's tiles opening
//      their pages, Ready to merge still opening Review, the header line
//      given up, and no width held above gotcha (13)'s 499. Crew › Review
//      opens on the same band: its ring at the band's trailing edge, the
//      forge cards under it, Show folder path on a scan that reached nothing,
//      the pull requests a partial scan found kept, and Refresh still in the
//      toolbar. RP-2 (the same board): Reply turns its row into one card
//      whose head is the question in full, focus lands in the well and
//      survives a refresh that moves the list, ⌘↩ and Esc arrive through the
//      window's own key paths, the three outcomes say what they said, a
//      blocked task's head is amber, and the card holds no width (gotcha
//      (13)), in Lavender and Powder.
//   5. **The floating bar is unchanged**: none of the above happens there,
//      Review's count line, boxed figures and empty forge cards included.
//      And one floating-bar defect found on the way stays fixed: the Hosts
//      column's footer stays at the column's bottom after a tab round trip
//      (`HelmPageSidebar.setFooter`).
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_PAGE_REDESIGNS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum PageRedesignsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedFleetState = FleetActions.stateDirectoryOverrideForTests
        defer { FleetActions.stateDirectoryOverrideForTests = savedFleetState }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-redesigns-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Every store this suite seeds, and every one a page it mounts can
        // write, in the suite's own folder (`SelfTestScratchStores.within`).
        // The caller's stores are fingerprinted either side, so a run that
        // writes past the wrapper fails by name rather than in the next suite.
        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            do {
                let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                ReviewTourLab.seedDemoHosts(shell.workspace)
                ReviewTourLab.seedDemoKnowledge(shell.workspace)
                settle(shell)
                for check in [checkConnectionsTables, checkTheInspectorKeepsTheWindow, checkPoneglyphTable,
                              checkAutomicVaultTables, checkKnowledgeHasNoTree, checkNeedsYou, checkReplyQuestionHead,
                              checkInFlightBand, checkReviewBand, checkLogBand,
                              checkDevOpsHub,
                              ConnectionFormsWindowChecks.checkForms, ConsoleFixesWindowChecks.checkConsole] {
                    var ok = true
                    check(shell, window, scratch, &ok)
                    allOK = allOK && ok
                }
            }
            do {
                var ok = true
                checkTheFloatingBarIsUnchanged(&ok)
                checkTheHostsFooterStaysDown(scratch, &ok)
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "PageRedesignsSelfTest: all checks passed" : "PageRedesignsSelfTest: FAILED")
        return allOK
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    /// A real Return on a table, through its own `keyDown(with:)`.
    private static func pressReturn(in tableView: NSTableView) {
        _ = NSApplication.shared
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: tableView.window?.windowNumber ?? 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else { return }
        tableView.keyDown(with: event)
    }

    /// Pumps the main run loop until `condition()` is true or `timeout`
    /// elapses (`HerdrRestartButtonSelfTest.waitUntil`'s convention).
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    /// Click the toolbar's tab with this name, through its own target and
    /// action.
    @discardableResult
    private static func clickTab(_ name: String, _ shell: MainSplitShellController) -> Bool {
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return false }
        shell.toolbar.debugClickTab(index)
        settle(shell)
        return true
    }

    private static func onScreen(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// A table whose columns end at its card's edge: nothing scrolls sideways.
    private static func checkFits(_ table: HelmDataTable, _ label: String, _ ok: inout Bool) {
        let tableView = table.debugTable
        guard let clip = tableView.enclosingScrollView?.contentView else {
            fail("\(label): the table is not in a scroll view", &ok)
            return
        }
        check(tableView.frame.width <= clip.bounds.width + 0.5,
              "\(label): the table is \(tableView.frame.width)pt wide in a \(clip.bounds.width)pt card - it scrolls sideways", &ok)
    }

    // MARK: 1 - Connections

    private static func checkConnectionsTables(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                               _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.hosts)
        clickTab("Hosts", shell)
        let hosts = shell.workspace.hostsPanel
        check(hosts.drawsSidebarLayout, "Hosts did not switch to the sidebar layout's presentation", &ok)
        // C4 of the Termius-style plan made the cards the default view; this
        // check is the table's, which is the List side of the same switch.
        // The cards are `ConnectionsCardsSelfTest`'s.
        hosts.setConnectionsShowList(true)
        defer { hosts.setConnectionsShowList(false) }
        settle(shell)
        let table = hosts.debugHostsTable
        check(onScreen(table.card), "the host table is not on screen", &ok)
        check(!onScreen(hosts.debugHostsList.card), "the floating bar's host list still shows in the sidebar layout", &ok)
        check(table.debugHeaderTitles.starts(with: ["Host", "Address"]),
              "the host table's header reads \(table.debugHeaderTitles)", &ok)
        let keys = table.debugRows.compactMap(\.key)
        check(keys.first == HostsController.firstmateRowKey, "the built-in Firstmate row is not first: \(keys.prefix(2))", &ok)
        check(keys.count == shell.workspace.hostStore.hosts.count + 1,
              "the table lists \(keys.count) rows for \(shell.workspace.hostStore.hosts.count) hosts and Firstmate", &ok)
        let groups = table.debugRows.compactMap { row -> String? in
            if case .group(let name) = row.kind { return name }
            return nil
        }
        check(groups == ["Observability", "Production", "Staging", "Ungrouped"],
              "the host groups are \(groups), the floating bar's list groups the same hosts the same way", &ok)
        checkFits(table, "the host table at 1512", &ok)

        // A selection fills the shell's inspector with the host's details.
        guard let edge = shell.workspace.hostStore.hosts.first(where: { $0.label == "edge-proxy-01" }) else {
            fail("the seeded host edge-proxy-01 is missing", &ok)
            return
        }
        table.debugSelect(key: edge.id.uuidString)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "selecting a host did not open the inspector", &ok)
        // H6 of the Termius-style plan: a host's details are its form in the
        // panel - every field the read-only details listed, now editable -
        // with Connect at its foot and the rest of its actions in its menu.
        // `ConnectionsCardsSelfTest` drives the form itself.
        let panel = hosts.hostPanel
        check(panel != nil && shell.inspector.hostedContentView === panel?.view,
              "the inspector is not showing the host's form", &ok)
        check(shell.inspector.debugTitle == "edge-proxy-01", "the inspector is titled \"\(shell.inspector.debugTitle)\"", &ok)
        check(panel?.debugAddressField.stringValue == edge.address && panel?.debugUsernameField.stringValue == edge.username,
              "the host form does not hold the host's address and user", &ok)
        check(panel?.debugFooterTitles == ["Connect", "Test", "More actions"], "the host form's footer is \(panel?.debugFooterTitles ?? [])", &ok)
        check(panel?.debugPanelMenuTitles == ["Duplicate\u{2026}", "Delete\u{2026}"],
              "the host form's menu is \(panel?.debugPanelMenuTitles ?? [])", &ok)
        check(hosts.debugSideStackIsHidden, "the page's own detail column shows beside the inspector", &ok)

        // The row's menu is the floating bar's overflow, and runs it.
        let menu = table.debugMenuTitles(key: edge.id.uuidString)
        check(menu == ["Connect", "Edit\u{2026}", "Duplicate\u{2026}", "Delete\u{2026}"], "the host row's menu is \(menu)", &ok)
        let before = shell.workspace.hostStore.hosts.count
        check(table.debugPickMenuItem(key: edge.id.uuidString, title: "Duplicate\u{2026}"),
              "the host row's Duplicate could not be picked", &ok)
        settle(shell)
        check(shell.workspace.hostStore.hosts.count == before + 1,
              "Duplicate from the table's menu did not duplicate the host", &ok)
        if let copy = shell.workspace.hostStore.hosts.first(where: { $0.label == "edge-proxy-01 copy" }) {
            shell.workspace.hostStore.delete(id: copy.id)
            settle(shell)
        }

        // The row's actions show on hover and on the selected row.
        let other = shell.workspace.hostStore.hosts.first { $0.label == "grafana" }
        check(table.debugTracksThePointer, "the host table does not track the pointer, so no row ever shows hovered", &ok)
        if let other {
            check(table.debugActionsCell(key: other.id.uuidString)?.debugRevealed == false,
                  "an unselected, unhovered host row shows its actions at rest", &ok)
            table.debugHover(key: other.id.uuidString)
            check(table.debugActionsCell(key: other.id.uuidString)?.debugRevealed == true,
                  "hovering a host row did not show its Connect", &ok)
            table.debugHover(key: nil)
        }

        // Clearing the selection closes the inspector it opened.
        table.debugSelect(key: nil)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "clearing the selection left the inspector open", &ok)

        // Keys and Snippets.
        clickTab("Keys", shell)
        let keysTable = hosts.debugKeysTable
        check(onScreen(keysTable.card), "the key table is not on screen on Keys", &ok)
        if let key = shell.workspace.keyStore.keys.first(where: { $0.label == "ops-ed25519" }) {
            keysTable.debugSelect(key: key.id.uuidString)
            settle(shell)
            check(shell.inspector.debugTitle == "ops-ed25519" && !shell.debugInspectorIsCollapsed,
                  "selecting a key did not show it in the inspector", &ok)
            // K7 of the Termius-style plan: a key's details are its form in
            // the panel, fingerprint included.
            check(shell.inspector.hostedContentView === hosts.keyPanel?.view && hosts.keyPanel?.debugFingerprint == key.fingerprint,
                  "the key's form in the inspector has no fingerprint", &ok)
            keysTable.debugSelect(key: nil)
            settle(shell)
        } else {
            fail("the seeded key ops-ed25519 is missing", &ok)
        }
        clickTab("Snippets", shell)
        check(onScreen(hosts.debugSnippetsTable.card), "the snippet table is not on screen on Snippets", &ok)
        // Stage 6 made the strip a plain row (`.inline`), still over the
        // table; `SidebarPageFixesSelfTest` checks its placement and wiring.
        check(onScreen(hosts.debugExpansionStrip) && hosts.debugExpansionStrip.style == .inline,
              "the snippet expansion switch is not the row over the Snippets table", &ok)
        check(hosts.debugSideStackIsHidden, "the floating bar's right column shows on Snippets in the sidebar layout", &ok)
        clickTab("Hosts", shell)
    }

    // MARK: 1b - the inspector never grows the window

    private static func checkTheInspectorKeepsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ scratch: URL, _ ok: inout Bool) {
        resize(window, width: 1100, shell)
        shell.workspace.navigator.show(.hosts)
        clickTab("Hosts", shell)
        let table = shell.workspace.hostsPanel.debugHostsTable
        guard let host = shell.workspace.hostStore.hosts.first else {
            fail("no seeded host", &ok)
            return
        }
        table.debugSelect(key: host.id.uuidString)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "at 1100 a selection did not open the inspector", &ok)
        check(abs(window.frame.width - 1100) < 0.5,
              "opening the inspector on a selection grew a 1100pt window to \(window.frame.width)pt", &ok)
        check(shell.debugColumnMinimum == MainSplitShellController.inspectorColumnMinimum,
              "with details in the inspector the column's floor is \(shell.debugColumnMinimum), "
                + "want \(MainSplitShellController.inspectorColumnMinimum)", &ok)
        checkFits(table, "the host table at 1100 with the inspector", &ok)

        // Off a page that fills it, the inspector closes and the floor goes
        // back up - without the window moving.
        shell.workspace.navigator.show(.logAnalyzer)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector stayed open on Logs", &ok)
        // R2-UX-10: back up to Log Analyzer's own floor.
        check(shell.debugColumnMinimum == MainSplitShellController.contentMinimum(for: .logAnalyzer),
              "the column's floor stayed at \(shell.debugColumnMinimum) off Hosts", &ok)
        check(abs(window.frame.width - 1100) < 0.5, "leaving Hosts grew the window to \(window.frame.width)pt", &ok)

        // The captain's choice holds: hidden from the toolbar, a new
        // selection does not reopen it until the button does.
        shell.workspace.navigator.show(.hosts)
        clickTab("Hosts", shell)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "coming back to a selected host did not reopen its details", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector), "the inspector button has no action", &ok)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector button did not close the inspector", &ok)
        if let next = shell.workspace.hostStore.hosts.dropFirst().first {
            table.debugSelect(key: next.id.uuidString)
            settle(shell)
            check(shell.debugInspectorIsCollapsed, "a new selection reopened an inspector the captain closed", &ok)
        }
        _ = shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "the inspector button did not reopen the inspector", &ok)
        check(abs(window.frame.width - 1100) < 0.5, "reopening the inspector grew the window to \(window.frame.width)pt", &ok)
        table.debugSelect(key: nil)
        shell.debugResetInspectorPreference()
        settle(shell)
        resize(window, width: 1512, shell)
    }

    // MARK: 2 - Secrets

    private static func checkPoneglyphTable(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                            _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let store = shell.debugPoneglyphStore
        let seeded = ReviewTourLab.seedDemoVault(store)
        check(store.isUnlocked && store.credentials.count == 7, "the scratch vault was not created: \(seeded)", &ok)
        shell.workspace.navigator.show(.poneglyph)
        settle(shell)
        let page = shell.debugPoneglyph
        check(page.drawsSidebarLayout, "Poneglyph did not switch to the sidebar layout's presentation", &ok)
        let table = page.debugCredentialTable
        check(onScreen(table.card), "the credential table is not on screen", &ok)
        check(!onScreen(page.debugList.card), "the floating bar's credential list still shows", &ok)
        check(page.debugInspector.isHostedInWorkspaceInspector, "the credential inspector is still the page's own column", &ok)
        check(!page.debugInspector.isDescendant(of: page.view), "the credential inspector is still inside the page", &ok)
        let titles = table.debugRows.compactMap { row -> String? in
            if case .title(let text, _, _, _, _, _)? = row.cells["name"] { return text }
            return nil
        }
        check(titles.count == 7, "the credential table lists \(titles.count) credentials, want 7", &ok)
        let groups = table.debugRows.compactMap { row -> String? in
            if case .group(let name) = row.kind { return name }
            return nil
        }
        check(groups.count == 4 && groups.allSatisfy { $0.contains("\u{00B7}") },
              "the credential groups are \(groups), want one per category with its count", &ok)
        checkFits(table, "the credential table", &ok)

        guard let aws = store.credentials.first(where: { $0.title == "AWS console (staging)" }),
              let work = store.credentials.first(where: { $0.title == "Work email" }) else {
            fail("the seeded credentials are missing", &ok)
            return
        }
        check(page.debugTOTPCellIDs == [aws.id], "the live 2FA cells are \(page.debugTOTPCellIDs), want the AWS one only", &ok)
        check(page.debugTOTPCell(aws.id)?.debugCodeButton.title.isEmpty == false,
              "the AWS row's 2FA cell shows no code", &ok)
        // The row's own controls: Reveal shows the value on the row and never
        // touches the clipboard (no Touch ID asked of this one).
        guard let controls = table.debugRows.first(where: { $0.key == work.id })?.accessory as? CredentialRowControls,
              let reveal = controls.debugRevealButton else {
            fail("the Work email row has no Reveal", &ok)
            return
        }
        check(controls.debugCopyButton != nil, "the Work email row has no Copy", &ok)
        let pasteboardBefore = NSPasteboard.general.changeCount
        reveal.performClick(nil)
        settle(shell)
        check(page.debugRevealedIDs.contains(work.id), "Reveal on the table row did not reveal the value", &ok)
        let subtitle = table.debugRows.first(where: { $0.key == work.id }).flatMap { row -> String? in
            if case .title(_, let subtitle, let isCode, _, _, _)? = row.cells["name"], isCode { return subtitle }
            return nil
        }
        check(subtitle == work.secret, "the revealed value is not on the row's second line", &ok)
        check(NSPasteboard.general.changeCount == pasteboardBefore, "Reveal touched the clipboard", &ok)
        (table.debugRows.first(where: { $0.key == work.id })?.accessory as? CredentialRowControls)?
            .debugRevealButton?.performClick(nil)
        settle(shell)
        check(!page.debugRevealedIDs.contains(work.id), "Reveal did not hide the value again", &ok)
        let menu = table.debugMenuTitles(key: work.id)
        check(menu == ["Show in Inspector", "Edit\u{2026}", "Copy account", "Delete\u{2026}"], "the credential row's menu is \(menu)", &ok)

        // A selection hosts the credential inspector in the shell's pane.
        table.debugSelect(key: aws.id)
        settle(shell)
        check(page.debugSelectedID == aws.id, "selecting a table row did not select the credential", &ok)
        check(!shell.debugInspectorIsCollapsed && shell.inspector.hostedContentView === page.debugInspector,
              "the credential inspector is not in the shell's inspector", &ok)
        check(shell.inspector.debugTitle == aws.title, "the inspector is titled \"\(shell.inspector.debugTitle)\"", &ok)
        check(page.debugInspector.debugCloseButton.isHidden, "the credential inspector draws a second close button", &ok)
        check(table.selectedKey == aws.id, "the table let go of the selected credential", &ok)
        // A theme change keeps the table's selection (measured: a reload once
        // dropped it with no notification).
        let savedTheme = ThemeManager.shared.theme
        if let other = HelmTheme.theme(id: savedTheme.isDaylight ? "dusk" : "daylight") {
            ThemeManager.shared.setTheme(other)
            settle(shell)
            check(table.selectedKey == aws.id, "a theme change dropped the credential table's selection", &ok)
            ThemeManager.shared.setTheme(savedTheme)
            settle(shell)
        }

        // Return on a selected row opens it in the inspector the captain
        // closed: a real key event through the table's own `keyDown(with:)`,
        // to the `doubleAction` handler a double click reaches too. A real
        // mouse click cannot be driven here. Measured: in this off-screen
        // window `NSTableView.mouseDown(with:)` never ran its tracking loop
        // (the queued mouse-up stayed queued) whether it was called directly,
        // sent through the window, sent after `makeKey`, or with the mouse-up
        // queued last. So the selection goes through the table's selection
        // path, which is where a click's selection change lands.
        let tableView = table.debugTable
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector), "the inspector button has no action", &ok)
        settle(shell)
        table.debugSelect(key: work.id)
        settle(shell)
        check(page.debugSelectedID == work.id && shell.debugInspectorIsCollapsed,
              "selecting a credential row reopened the inspector the captain closed", &ok)
        pressReturn(in: tableView)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed && shell.inspector.hostedContentView === page.debugInspector
                && shell.inspector.debugTitle == work.title,
              "Return on the selected credential did not open it in the inspector", &ok)
        // Return turns details back on, but unlike the toolbar's button it
        // does not hold the pane open, so the pane closes with the details.
        // Back to the launch state, so the lock below measures an inspector
        // its selection opened.
        shell.debugResetInspectorPreference()
        settle(shell)

        // Drag to reorder, through the table's own drag source and drop
        // target: the dragged row's pasteboard item, then a drop on a
        // boundary. A drop within the category moves the credential, and one
        // into another category or onto a row is refused.
        check(tableView.registeredDraggedTypes.contains(CredentialVaultDragPasteboard.credentialType),
              "the credential table does not accept a credential drag", &ok)
        let emailRows = table.debugRows.indices.filter { table.debugRows[$0].reorderGroup == work.category.rawValue }
        if emailRows.count == 2, let first = table.debugRows[emailRows[0]].key,
           let second = table.debugRows[emailRows[1]].key,
           let awsRow = table.debugRows.firstIndex(where: { $0.key == aws.id }),
           let source = tableView.dataSource, let item = source.tableView?(tableView, pasteboardWriterForRow: emailRows[1]) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("fm.selftest.page-redesigns.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let drop = CredentialVaultStubDraggingInfo(pasteboard: pasteboard, window: window)
            let across = source.tableView?(tableView, validateDrop: drop, proposedRow: awsRow, proposedDropOperation: .above)
            check(across == [], "a credential dragged into another category was accepted (\(String(describing: across)))", &ok)
            let onto = source.tableView?(tableView, validateDrop: drop, proposedRow: emailRows[0], proposedDropOperation: .on)
            check(onto == [], "a credential dropped onto a row was accepted (\(String(describing: onto)))", &ok)
            let within = source.tableView?(tableView, validateDrop: drop, proposedRow: emailRows[0], proposedDropOperation: .above)
            check(within == .move, "a credential dragged within its category was refused (\(String(describing: within)))", &ok)
            let accepted = source.tableView?(tableView, acceptDrop: drop, row: emailRows[0], dropOperation: .above)
            settle(shell)
            let shown = table.debugRows.filter { $0.reorderGroup == work.category.rawValue }.compactMap(\.key)
            let stored = store.credentials.filter { $0.category == work.category }
                .sorted(by: VaultCredential.displayOrder).map(\.id)
            check(accepted == true && shown == [second, first] && stored == [second, first],
                  "dragging the second email credential above the first left the table at \(shown) and the store at "
                    + "\(stored), want \([second, first])", &ok)
        } else {
            fail("the credential table has no two email rows to reorder, or its rows cannot be dragged", &ok)
        }

        // Locking lets go of the decrypted credential and closes the pane.
        page.debugLockTapped()
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "locking the vault left the inspector open", &ok)
        check(page.debugInspector.credential == nil, "locking the vault left the inspector holding a credential", &ok)
        check(shell.inspector.hostedContentView == nil, "locking the vault left the credential inspector in the pane", &ok)
        check(!onScreen(table.card), "the credential table still shows behind the lock", &ok)
    }

    private static func checkAutomicVaultTables(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                                _ ok: inout Bool) {
        let vault = shell.workspace.vault
        vault.debugPrepareUnreadForTests()
        shell.workspace.navigator.show(.vault)
        settle(shell)
        // The visit starts the page's own read, which this process refuses.
        // It has to land before the fixture does, or it lands on top of it.
        check(waitUntil(timeout: 10) { !vault.debugIsReading }, "Automic Vault's own read never finished", &ok)
        check(vault.drawsSidebarLayout, "Automic Vault did not switch to the sidebar layout's presentation", &ok)
        let secrets = vault.debugSecretsTable
        // S-1: the launchers are the split card's rows; their table is kept
        // current but not drawn.
        check(onScreen(secrets.card) && onScreen(vault.debugHeroSplit),
              "Automic Vault's secrets table or split card is not on screen", &ok)
        check(!onScreen(vault.debugToolsTable.card), "the launchers' table still shows beside the split card", &ok)
        check(vault.debugSecretRows.allSatisfy { !onScreen($0) }, "the floating bar's secret rows still show", &ok)
        vault.debugRender(secrets: [VaultSecret(name: "GITHUB_TOKEN"), VaultSecret(name: "STAGING_DB_PASSWORD")],
                          tools: [VaultTool(name: "terraform", commands: ["terraform"], status: .needsAttention(issueCount: 2))])
        settle(shell)
        check(secrets.debugRows.compactMap(\.key) == ["GITHUB_TOKEN", "STAGING_DB_PASSWORD"],
              "the secrets table lists \(secrets.debugRows.compactMap(\.key))", &ok)
        check(secrets.debugMenuTitles(key: "GITHUB_TOKEN") == ["Run Injected\u{2026}", "Copy Name"],
              "a secret row's actions are \(secrets.debugMenuTitles(key: "GITHUB_TOKEN"))", &ok)
        let status = vault.debugToolsTable.debugRows.first?.cells["status"]
        if case .status(let text, let tint)? = status {
            check(text == "2 issues" && tint == .warn, "the launcher's status reads \(text)", &ok)
        } else {
            fail("the launcher row has no status", &ok)
        }
        // B1: a read that failed is not an empty list.
        vault.debugRender(secrets: nil, tools: nil)
        settle(shell)
        let unread = secrets.debugRows.first.map { row -> String in
            if case .empty(_, let title, let body) = row.kind { return title + " " + body }
            return ""
        } ?? ""
        check(unread.contains("Couldn\u{2019}t read secrets") || unread.contains(VaultSource.isolationNote),
              "a failed read shows \"\(unread)\" rather than saying it could not read", &ok)
    }

    // MARK: 3 - Knowledge

    /// Stage 7: the captain asked whether Knowledge needed its second
    /// sidebar, and it did not. Every row it held is still one click from
    /// its own tab, and its search is the toolbar's: the module draws no
    /// column beside the body, Notebook keeps its own page column (the only
    /// tab whose items are not listed on the page itself), Runbooks and
    /// Postmortems list theirs, and ⌘K finds a page, a runbook and a
    /// postmortem from anywhere.
    private static func checkKnowledgeHasNoTree(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                                _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let pane = shell.debugContentPane
        let body = shell.debugBodyContainer
        for route in [RailDestination.notebook, .runbooks, .postmortems, .docs, .readingList] {
            shell.workspace.navigator.show(route)
            settle(shell)
            let frame = body.convert(body.bounds, to: pane)
            check(frame.minX.magnitude < 0.5 && abs(frame.width - pane.bounds.width) < 0.5,
                  "\(route.title) draws the body from \(frame.minX)pt, \(frame.width)pt of a \(pane.bounds.width)pt pane - "
                      + "a column is back beside it", &ok)
        }
        check(!pane.subviews.contains { $0 !== body && !($0 is NSStackView) && !$0.isHidden },
              "the content pane holds a view beside its header and body", &ok)

        // Notebook's own page column is back: the tree was the reason it
        // was put away.
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        let notebook = shell.workspace.notebook
        check(notebook.splitPage?.pageForcesCollapse == false && notebook.splitPage?.isSidebarCollapsed == false
                && onScreen(notebook.debugSidebar),
              "Notebook's page column is not showing in the sidebar layout", &ok)
        let pages = Set(notebook.debugPages.map(\.title))
        check(pages.isSuperset(of: ["Ideas", "Edge architecture", "On-call handbook"]),
              "Notebook lists \(pages), want the three seeded pages", &ok)

        // Runbooks and Postmortems list their own items.
        shell.workspace.navigator.show(.runbooks)
        settle(shell)
        let runbooks = Set(shell.workspace.runbooks.debugRunbookPlates.map(\.debugTitle))
        check(runbooks == ["Rotate a TLS certificate", "Fail over the database"], "Runbooks lists \(runbooks)", &ok)
        shell.workspace.navigator.show(.postmortems)
        settle(shell)
        let postmortems = Set(shell.workspace.postmortems.debugPostmortemPlates.map(\.debugTitle))
        check(postmortems == ["Cache outage, 9 October", "Certificate expiry, 2 September"],
              "Postmortems lists \(postmortems)", &ok)

        // The tree's own search has its home in the toolbar's: the palette's
        // providers find each kind, and a result opens its tab and the item.
        let index = UnifiedSearchIndex()
        index.register(UnifiedSearchDocsProvider(
            store: shell.workspace.docsRunbookStore,
            onOpenRunbook: { [weak shell] id in shell?.workspace.navigator.openRunbook(id: id) },
            onOpenPostmortem: { [weak shell] id in shell?.workspace.navigator.openPostmortem(id: id) }))
        index.register(UnifiedSearchNotebookProvider(
            store: shell.workspace.notebookStore,
            onOpen: { [weak shell] id in shell?.workspace.navigator.openNotebookPage(id: id) }))
        let found = index.flatItems(query: "cert").map(\.title)
        check(found.contains("Rotate a TLS certificate") && found.contains("Certificate expiry, 2 September")
                && !found.contains("Fail over the database"),
              "searching \"cert\" finds \(found)", &ok)
        check(index.flatItems(query: "edge").contains { $0.title == "Edge architecture" },
              "searching \"edge\" does not find the Notebook page", &ok)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        if let runbook = index.flatItems(query: "Rotate").first(where: { $0.title == "Rotate a TLS certificate" }) {
            runbook.activate()
            settle(shell)
            check(shell.debugCurrentDestination == .runbooks && shell.debugCurrentTab?.name == "Runbooks"
                    && shell.workspace.runbooks.debugRunbookEditorIsOpen,
                  "a runbook found by Search did not open in Runbooks", &ok)
            shell.workspace.runbooks.debugCancelRunbookEditor()
        } else {
            fail("Search has no result for the seeded runbook", &ok)
        }
    }

    // MARK: 4 - Crew › Needs you

    // MARK: DevOps Hub

    /// DevOps Hub in a real sidebar shell: one row with no project under it,
    /// a real click that opens the project cards, a real Start through a
    /// card's own button that serves a scratch site over loopback and opens
    /// it in the project view, the strip's Projects button, the window's
    /// Back, the row's click back to the cards, Stop, the busy-port and
    /// missing-folder cards, the pencil's sheet, and the band at 1100.
    private static func checkDevOpsHub(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                       _ ok: inout Bool) {
        print("\n-- DevOps Hub: one sidebar row, the project cards, a real start, the project view and back --")
        _ = NSApplication.shared
        resize(window, width: 1512, shell)
        let registry = LocalProjectRegistry.shared
        check(registry.debugStoreURL.path.hasPrefix(scratch.path),
              "the shared registry reads \(registry.debugStoreURL.path), not the suite's own store", &ok)
        let (site, _) = DevOpsHubModelSelfTest.makeSite()
        // A share image as wide as the course's own (1200pt), which the
        // project view shows as its preview.
        let preview = NSImage(size: NSSize(width: 1200, height: 630), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        if let tiff = preview.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: site.appendingPathComponent("og.png"))
        }
        var project = LocalProject.devopsAtlas
        project.folderOverride = site.path
        project.port = DevOpsHubModelSelfTest.freePort()
        LocalProjectStore.save([project], at: registry.debugStoreURL)
        registry.debugReload()
        defer { registry.stopAll(reason: .stopped) }
        let id = project.id
        let hubRow = WorkspaceSidebarEntry.module(.devopsHub)
        settle(shell)

        // One row: DevOps Hub after Secrets, with no project under it.
        let entries = shell.sidebar.debugVisibleEntries
        guard let hub = entries.firstIndex(of: hubRow), hub > 0, hub + 1 < entries.count else {
            fail("the sidebar has no DevOps Hub row: \(entries)", &ok)
            return
        }
        var nextIsSection = false
        if case .section = entries[hub + 1] { nextIsSection = true }
        check(entries[hub - 1] == .module(.secrets) && nextIsSection,
              "DevOps Hub's neighbours are \(entries[hub - 1]) and \(entries[hub + 1]), want Secrets and the next group", &ok)

        // A real click on the row opens the project cards and lights the row.
        check(shell.sidebar.debugClick(hubRow), "the DevOps Hub row could not be clicked", &ok)
        settle(shell)
        let page = shell.workspace.devopsHub
        let cards = page.cards
        check(page.isViewLoaded && page.view.window === window && !page.view.isHiddenOrHasHiddenAncestor
                && page.mode == .cards && !cards.view.isHidden && page.projectView.view.isHidden,
              "a click on the DevOps Hub row did not show the project cards", &ok)
        check(shell.sidebar.debugSelectedEntry == hubRow,
              "the lit row is \(String(describing: shell.sidebar.debugSelectedEntry))", &ok)
        check(!shell.toolbar.debugCrumb.contains("devops-atlas"), "the cards' crumb reads \(shell.toolbar.debugCrumb)", &ok)
        check(cards.heroColumn.superview === cards.splitPage?.sidebarPane && !cards.showsBand,
              "at 1512 the hero column is not in the page's column", &ok)
        check(cards.heroWords?.headline == "Nothing running." && cards.heroWords?.ring?.total == 1,
              "the column reads \(cards.heroWords?.headline ?? "-")", &ok)
        check(cards.grid.debugPlaced.map(\.key) == [id, DevOpsHubCardsController.addCardKey],
              "the grid holds \(cards.grid.debugPlaced.map(\.key))", &ok)
        guard let card = cards.grid.debugCardView(key: id), card.debugActionButtons.count == 3 else {
            fail("the devops-atlas card is missing or does not have its three buttons", &ok)
            return
        }
        check(card.debugStatus == nil && card.debugDetail == "Not started" && card.debugSubtitle == project.displayFolder,
              "the card reads \(card.debugSubtitle) / \(card.debugDetail ?? "-")", &ok)
        if case .count = (shell.sidebar.debugCell(for: hubRow) as? WorkspaceSidebarPageCell)?.debugBadge?.mark {
            fail("the row counts a project running while none is", &ok)
        }

        // A real Start, through the card's own first button. "Show the site
        // when it's ready" is on, so the project view opens with the site.
        card.debugActionButtons[0].performClick(nil)
        let running = waitUntil(timeout: 5) { registry.state(of: id).isRunning }
        check(running, "the card's Start did not run the server: \(registry.state(of: id))", &ok)
        let opened = waitUntil(timeout: 5) { page.mode == .project(id) }
        check(opened, "the project view did not open once the site served", &ok)
        let shown = waitUntil(timeout: 15) { page.projectView.debugShowsSite }
        check(shown, "the site did not load into the project view (\(page.projectView.words?.headline ?? "no hero"))", &ok)
        check(page.projectView.debugWebView?.webView.url?.port == Int(project.port),
              "the web view is on \(String(describing: page.projectView.debugWebView?.webView.url))", &ok)
        let strip = page.projectView.debugStrip
        check(strip.debugAddress == "127.0.0.1:\(project.port)" && strip.debugLine.hasPrefix("up "),
              "the strip reads \(strip.debugAddress) / \(strip.debugLine)", &ok)
        settle(shell)
        check(shell.toolbar.debugCrumb.contains("devops-atlas"), "the project view's crumb reads \(shell.toolbar.debugCrumb)", &ok)
        check(shell.sidebar.debugSelectedEntry == hubRow, "the project view lights \(String(describing: shell.sidebar.debugSelectedEntry))", &ok)
        let badge = (shell.sidebar.debugCell(for: hubRow) as? WorkspaceSidebarPageCell)?.debugBadge
        check(badge?.mark == .count("1"), "the row's badge is \(String(describing: badge?.mark)) while one project runs", &ok)

        // The strip's Projects button goes back to the cards, and the site
        // keeps running.
        strip.debugButton(.back).performClick(nil)
        settle(shell)
        check(page.mode == .cards && !cards.view.isHidden && registry.state(of: id).isRunning,
              "Projects left the page on \(page.mode) with \(registry.state(of: id))", &ok)
        check(cards.heroWords?.headline == "1 project running." && card.debugStatus?.hasPrefix("Running") == true
                && card.debugSubtitle == "127.0.0.1:\(project.port)",
              "the cards read \(cards.heroWords?.headline ?? "-") / \(card.debugStatus ?? "-")", &ok)
        // Gotchas (13) and (15): the project view is hidden now, and nothing
        // in it - the strip, or the 1200pt share image behind its hero - may
        // hold the window at its own width. Measured with the real course
        // before the fix: the window stayed at 1513.
        resize(window, width: 1100, shell)
        check(abs(window.frame.width - 1100) < 1 && cards.showsBand,
              "with a project's view hidden the window stayed \(window.frame.width)pt wide", &ok)
        resize(window, width: 1512, shell)

        // Open, then the window's Back: the project view is a place in the
        // history, so Back steps to the cards.
        card.debugActionButtons[1].performClick(nil)
        settle(shell)
        check(page.mode == .project(id) && page.projectView.debugShowsSite,
              "the card's Open left the page on \(page.mode)", &ok)
        shell.toolbar.onBack?()
        settle(shell)
        check(page.mode == .cards, "the window's Back left the page on \(page.mode)", &ok)

        // The DevOps Hub row, clicked while a project shows, goes back to
        // the cards. From another page it opens the hub as it was left.
        card.debugActionButtons[1].performClick(nil)
        settle(shell)
        shell.workspace.navigator.show(.health)
        settle(shell)
        check(shell.sidebar.debugClick(hubRow), "the DevOps Hub row could not be clicked again", &ok)
        settle(shell)
        check(page.mode == .project(id), "coming back from Health did not find the project as it was left", &ok)
        check(shell.sidebar.debugClick(hubRow), "the DevOps Hub row could not be clicked a third time", &ok)
        settle(shell)
        check(page.mode == .cards, "the row's click on the project view did not go back to the cards", &ok)

        // The card's Stop, through the same first button.
        card.debugActionButtons[0].performClick(nil)
        settle(shell)
        check(registry.state(of: id) == .notStarted && card.debugDetail == "Not started \u{00B7} last ran just now",
              "Stop left \(registry.state(of: id)) / \(card.debugDetail ?? "-")", &ok)
        let reuse = LocalStaticServer(root: site, port: project.port)
        check(DevOpsHubModelSelfTest.outcome(DevOpsHubModelSelfTest.start(reuse)) == "ready",
              "the port was not free after Stop", &ok)

        // A busy port: the blocker above still holds it. The card says so in
        // red, and the column leads with it.
        card.debugActionButtons[0].performClick(nil)
        _ = waitUntil(timeout: 5) { registry.state(of: id) != .starting }
        check(card.debugStatus == "Port \(project.port) in use"
                && cards.heroWords?.tone == .red && cards.heroWords?.headline == "devops-atlas couldn\u{2019}t start."
                && page.mode == .cards,
              "a busy port shows \(card.debugStatus ?? "-") / \(cards.heroWords?.headline ?? "-") on \(page.mode)", &ok)
        if case .dot = (shell.sidebar.debugCell(for: hubRow) as? WorkspaceSidebarPageCell)?.debugBadge?.mark {} else {
            fail("a failed start draws no dot on the DevOps Hub row", &ok)
        }
        reuse.stop()

        // The pencil opens the Project settings sheet for this card.
        card.debugActionButtons[2].performClick(nil)
        settle(shell)
        let sheet = page.presentedViewControllers?.compactMap { $0 as? DevOpsHubSettingsSheet }.first
        check(sheet?.mode == .edit && sheet?.debugPortText == "\(project.port)",
              "the pencil did not open devops-atlas's settings", &ok)
        if let sheet { page.dismiss(sheet) }
        settle(shell)

        // A narrow window: the column becomes a band over the cards.
        resize(window, width: 1100, shell)
        settle(shell)
        check(cards.showsBand, "at 1100 the hero column did not become a band", &ok)
        resize(window, width: 1512, shell)
        settle(shell)
        check(!cards.showsBand, "back at 1512 the hero column did not return to its column", &ok)

        writeDevOpsHubRenders(shell, window, page, project: project)

        // A folder that is not there: the amber card, with Choose Folder first.
        var gone = project
        gone.folderOverride = site.appendingPathComponent("gone").path
        registry.update(gone)
        settle(shell)
        cards.grid.debugCardView(key: id)?.debugActionButtons.first?.performClick(nil)
        settle(shell)
        let missing = cards.grid.debugCardView(key: id)
        check(missing?.debugStatus == "Folder not found" && cards.heroWords?.tone == .amber
                && missing?.debugActionButtons.first?.symbolName == "folder",
              "a missing folder shows \(missing?.debugStatus ?? "-") / \(cards.heroWords?.headline ?? "-")", &ok)
        registry.update(project)
    }

    /// With `FM_DEVOPS_HUB_RENDER_DIR` set, one PNG of the whole window per
    /// state, in Daylight and Dusk: no projects, not started, starting,
    /// running with the course shown, a busy port, a missing folder, three
    /// projects, and the narrowest window on the cards and on the course.
    /// `FM_DEVOPS_HUB_RENDER_SITE` serves a real site (a real course clone)
    /// for the running states instead of the fixture. It is read, never
    /// written. The states a real run passes through too fast to capture are
    /// set on the registry directly (`debugSetState`).
    private static func writeDevOpsHubRenders(_ shell: MainSplitShellController, _ window: NSWindow,
                                              _ page: DevOpsHubController, project: LocalProject) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FM_DEVOPS_HUB_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        let registry = LocalProjectRegistry.shared
        var shown = project
        if let site = env["FM_DEVOPS_HUB_RENDER_SITE"], !site.isEmpty { shown.folderOverride = site }
        let id = shown.id
        let now = registry.clock()
        var notes = LocalProject(id: "runbook-site", name: "runbook-site", kind: .staticSite,
                                 folderOverride: "~/code/runbooks/dist", port: shown.port &+ 1,
                                 opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        notes.lastRun = LocalProject.LastRun(startedAt: now.addingTimeInterval(-3 * 3600),
                                             endedAt: now.addingTimeInterval(-2 * 3600), reason: "stopped")
        let incident = LocalProject(id: "incident-notes", name: "incident-notes", kind: .staticSite,
                                    folderOverride: "~/code/incident-notes/build", port: shown.port &+ 10,
                                    opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        func use(_ projects: [LocalProject]) {
            registry.stopAll(reason: .stopped)
            LocalProjectStore.save(projects, at: registry.debugStoreURL)
            registry.debugReload()
        }
        func write(_ name: String, _ theme: HelmTheme) {
            settle(shell)
            ReviewTourLab.writeSplitShellPNG(shell, window: window,
                                             to: folder.appendingPathComponent("devops-hub-\(name)-\(theme.id).png"))
        }
        func runCourse() {
            registry.start(id)
            _ = waitUntil(timeout: 15) { page.projectView.debugShowsSite }
            // The site's own animation settles before the snapshot.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        }
        let since = now.addingTimeInterval(-42 * 60)
        for theme in [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk] {
            ThemeManager.shared.setTheme(theme)
            resize(window, width: 1512, shell)
            use([])
            page.showCards()
            write("0-no-projects", theme)
            use([shown])
            write("1-not-started", theme)
            registry.debugSetState(.starting, for: id)
            write("2-starting", theme)
            page.start(projectID: id)
            registry.debugSetState(.notStarted, for: id)
            page.start(projectID: id)
            _ = waitUntil(timeout: 5) { page.mode == .project(id) }
            runCourse()
            write("3-running-course", theme)
            page.showCards()
            write("4-running-cards", theme)
            registry.debugSetState(.failed(.portInUse(holder: "python3 (pid 48211)")), for: id)
            write("5-port-busy", theme)
            registry.debugSetState(.folderNotFound(noIndex: false), for: id)
            write("6-folder-not-found", theme)
            use([shown, notes, incident])
            registry.debugSetState(.running(since: since), for: id)
            registry.debugSetState(.failed(.portInUse(holder: "python3 (pid 48211)")), for: incident.id)
            write("7-three-projects", theme)
            resize(window, width: 1100, shell)
            write("8-narrow-cards", theme)
            use([shown])
            page.start(projectID: id)
            _ = waitUntil(timeout: 5) { page.mode == .project(id) }
            runCourse()
            write("9-narrow-course", theme)
            page.showCards()
            registry.stop(id)
        }
        ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight)
        resize(window, width: 1512, shell)
        use([project])
        settle(shell)
        print("PageRedesignsSelfTest: DevOps Hub renders written to \(dir)")
    }

    /// The band as drawn on the showing tab, its words, and whether it is in
    /// the dimmed tone (GL-14).
    private static func band(_ fleet: FleetController) -> HelmHeroColumn? { fleet.debugCrewBand }
    private static func isDimmed(_ band: HelmHeroColumn) -> Bool {
        band.debugPalette == HelmHeroColumn.palette(for: .init(colour: .themeAccent, isDimmed: true),
                                                     in: ThemeManager.shared.theme)
    }
    private static func figures(_ band: HelmHeroColumn) -> [String] {
        guard let strip = band.debugFootViews.first as? HelmKPIStrip, strip.superview != nil else { return [] }
        return zip(strip.debugValues, strip.debugCaptions).map { "\($0) \($1)" }
    }

    /// Gotcha (13): every horizontal constraint in `root`'s tree held between
    /// 500 and required, any of which can resize the window, and every
    /// horizontal stack clipping at that level.
    private static func widthsHeldAbove499(_ root: NSView) -> [String] {
        var offenders: [String] = []
        func scan(_ view: NSView) {
            for constraint in view.constraints where constraint.isActive && constraint.priority.rawValue >= 500
                && constraint.priority < .required {
                switch constraint.firstAttribute {
                case .width, .leading, .trailing, .left, .right, .centerX:
                    offenders.append("\(type(of: view)) \(constraint.priority.rawValue)")
                default: break
                }
            }
            if let stack = view as? NSStackView, stack.orientation == .horizontal,
               stack.clippingResistancePriority(for: .horizontal).rawValue >= 500,
               stack.clippingResistancePriority(for: .horizontal) < .required {
                offenders.append("clipping \(stack.clippingResistancePriority(for: .horizontal).rawValue)")
            }
            view.subviews.forEach(scan)
        }
        scan(root)
        return offenders
    }

    private static func checkNeedsYou(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                      _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        check(WorkspaceModule.crew.tabs.first?.name == "Needs you" && WorkspaceModule.crew.tabs.first?.route == .overview,
              "Crew's first tab is not the Fleet page's Needs you", &ok)
        shell.workspace.navigator.show(.overview)
        settle(shell)
        let fleet = shell.workspace.overview
        check(clickTab("Needs you", shell), "the toolbar has no Needs you tab on Crew", &ok)
        check(fleet.debugNeedsYouShowing, "the Needs you tab did not show Needs you", &ok)
        check(fleet.debugNeedsSectionIsOnNeedsYou, "the Needs your call list is not on Needs you", &ok)
        check(fleet.selectedModuleTabName == "Needs you" && shell.debugCurrentTab?.name == "Needs you",
              "the toolbar does not light Needs you", &ok)

        ReviewTourLab.seedDemoDecision(fleet, scratch: scratch)
        settle(shell)
        // CR-1: the band is the tab's summary, its empty state and its
        // failure, in place of the grey line and the boxed empty card.
        guard let needsBand = band(fleet) else {
            fail("CR-1: Needs you opens on no band", &ok)
            return
        }
        check(needsBand.arrangement == .band && needsBand.debugHeadline == "1 task is waiting on you"
                && needsBand.debugKicker.hasPrefix("Needs you \u{00B7} checked ")
                && needsBand.debugBody == "1 open decision \u{00B7} 1 waiting on a decision. The crew is holding for you.",
              "CR-1: Needs you's band reads \(needsBand.debugKicker) / \(needsBand.debugHeadline) / \(needsBand.debugBody ?? "-")", &ok)
        check(figures(needsBand) == ["1 Open decisions", "1 Need a decision", "0 Blocked"] && needsBand.debugFootRule != nil,
              "CR-1: Needs you's figures are \(figures(needsBand))", &ok)
        check(!isDimmed(needsBand), "CR-1: a good read painted the dimmed tone", &ok)
        check(needsBand.accessibilityRole() == .group && (needsBand.accessibilityLabel() ?? "").contains(needsBand.debugHeadline),
              "CR-1: the band is not one group named by its headline (\(needsBand.accessibilityLabel() ?? "nothing"))", &ok)
        check(!fleet.debugNeedsHeadingShown, "CR-1: the Needs your call heading still repeats the band's count", &ok)
        check(shell.debugContentPaneHeader.isHiddenOrHasHiddenAncestor && shell.debugHeader == nil
                && !(fleet.drillHeaderSubtitle ?? "").isEmpty,
              "CR-1: Needs you keeps the grey header line over its band (\(String(describing: shell.debugHeader)))", &ok)
        check(!fleet.debugNeedsYouSkeletonShowing, "CR-1: the skeleton rows stay after the first read", &ok)
        check(fleet.debugNeedsRowCount == 1, "Needs you lists \(fleet.debugNeedsRowCount) rows for one parked task", &ok)
        if let reply = fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID) {
            reply.performClick(nil)
            settle(shell)
            check(fleet.debugOpenReplyTaskID == ReviewTourLab.demoDecisionTaskID
                    && fleet.debugCardTakesItsRowsPlace(taskID: ReviewTourLab.demoDecisionTaskID, at: 0),
                  "RP-2: Reply on Needs you did not turn its row into the reply card", &ok)
            fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID)?.performClick(nil)
            settle(shell)
        } else {
            fail("Needs you's row has no Reply", &ok)
        }

        // In flight no longer carries the list; its banner still counts it.
        clickTab("In flight", shell)
        check(!fleet.debugNeedsYouShowing && !onScreen(fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID)),
              "In flight still shows the Needs your call list", &ok)

        // Nothing waiting is said plainly by the band, with when it was
        // checked, and with no second empty card under it.
        let quiet = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [], queuedCount: 0, doneCount: 0,
                                  projectsCount: 0, watcher: WatcherHealth(status: "healthy"))
        fleet.debugRender(snapshot: quiet, mergedPRs: [])
        clickTab("Needs you", shell)
        if let calm = band(fleet) {
            check(calm.debugHeadline == "Nothing needs you" && calm.debugKicker.hasPrefix("Needs you \u{00B7} checked ")
                    && calm.debugFootViews.isEmpty && fleet.debugNeedsRowCount == 0 && fleet.debugNeedsSectionHidden,
                  "CR-1: with nothing parked the band says \(calm.debugHeadline) with \(calm.debugFootViews.count) foot views "
                    + "and \(fleet.debugNeedsRowCount) rows", &ok)
        } else {
            fail("CR-1: Needs you lost its band with nothing parked", &ok)
        }

        // A read that fails keeps the last good list and says when it was
        // read (GL-14): the dimmed tone, the time, and the carried rows.
        var parked = FleetTask(id: "needs-you-probe", repo: "grand-line", kind: "ship", pr: nil)
        parked.state = "parked"
        parked.source = "crew"
        parked.status = "needs_decision"
        func reading(_ tasks: [FleetTask], listRead: Bool = true) -> FleetSnapshot {
            FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 0, doneCount: 0,
                          projectsCount: 0, watcher: WatcherHealth(status: "healthy"), tasksRead: listRead)
        }
        fleet.debugRender(snapshot: reading([parked]), mergedPRs: [])
        settle(shell)
        check(fleet.debugNeedsRowCount == 1 && band(fleet)?.debugHeadline == "1 task is waiting on you",
              "a parked task reads \(fleet.debugNeedsRowCount) rows and \"\(band(fleet)?.debugHeadline ?? "-")\"", &ok)
        fleet.debugRender(snapshot: reading([], listRead: false), mergedPRs: [])
        settle(shell)
        if let failed = band(fleet) {
            check(fleet.debugNeedsRowCount == 1 && isDimmed(failed)
                    && failed.debugHeadline.hasPrefix("Couldn\u{2019}t read the crew\u{2019}s state at")
                    && (failed.debugBody ?? "").hasPrefix("Showing what was read at")
                    && failed.debugKicker.hasPrefix("Needs you \u{00B7} last read "),
                  "CR-1: after a failed read Needs you lists \(fleet.debugNeedsRowCount) rows under \(failed.debugKicker) / "
                    + "\(failed.debugHeadline) / \(failed.debugBody ?? "-"), dimmed \(isDimmed(failed))", &ok)
        } else {
            fail("CR-1: a failed read took Needs you's band away", &ok)
        }
        var unread = parked
        unread.state = "unknown"
        unread.source = "none"
        unread.status = "unknown"
        fleet.debugRender(snapshot: reading([unread]), mergedPRs: [])
        settle(shell)
        check(fleet.debugNeedsRowCount == 1 && (band(fleet)?.debugBody ?? "").contains("could not be read just now")
                && !(band(fleet).map(isDimmed) ?? true),
              "a parked task whose state could not be read reads \(fleet.debugNeedsRowCount) rows and "
                + "\"\(band(fleet)?.debugBody ?? "-")\"", &ok)
        var working = parked
        working.state = "working"
        working.status = "working"
        fleet.debugRender(snapshot: reading([working]), mergedPRs: [])
        settle(shell)
        check(fleet.debugNeedsRowCount == 0 && band(fleet)?.debugHeadline == "Nothing needs you",
              "a task that went back to work is still on Needs you", &ok)
        fleet.debugRender(snapshot: reading([], listRead: false), mergedPRs: [])
        settle(shell)
        check((band(fleet)?.debugBody ?? "").contains("Nothing was waiting on you when it was last read")
                && (band(fleet).map(isDimmed) ?? false) && band(fleet)?.debugHeadline != "Nothing needs you",
              "a failed read after an empty one says \"\(band(fleet)?.debugBody ?? "-")\"", &ok)

        // No firstmate home: the band says so and its foot is Open Setup.
        let unset = FleetSnapshot(homeOk: false, captain: "Manjesh", tasks: [], queuedCount: 0, doneCount: 0,
                                  projectsCount: 0, watcher: WatcherHealth(status: "off"))
        fleet.debugRender(snapshot: unset, mergedPRs: [])
        settle(shell)
        if let setup = band(fleet) {
            check(setup.debugHeadline == "Grand Line isn\u{2019}t pointed at a firstmate home yet"
                    && setup.debugFootViews.first === fleet.debugBandSetupButton
                    && fleet.debugBandSetupButton.heroInk != nil && onScreen(fleet.debugBandSetupButton),
                  "CR-1: Needs you without a home reads \(setup.debugHeadline) with foot \(setup.debugFootViews)", &ok)
            fleet.debugBandSetupButton.performClick(nil)
            settle(shell)
            check(shell.debugCurrentDestination == .bootstrap, "CR-1: the band's Open Setup did not open Setup", &ok)
        } else {
            fail("CR-1: Needs you without a home has no band", &ok)
        }
        shell.workspace.navigator.show(.overview)
        settle(shell)
        fleet.debugRender(snapshot: quiet, mergedPRs: [])
        settle(shell)

        // Home's fleet row and the bell's entry land on Needs you.
        clickTab("In flight", shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        shell.workspace.homeCanvas.onOpenCrewDecisions?()
        settle(shell)
        check(shell.debugCurrentDestination == .overview && fleet.debugNeedsYouShowing
                && shell.debugCurrentTab?.name == "Needs you",
              "Home's fleet row did not land on Crew › Needs you", &ok)
    }

    /// CR-1 on In flight: the verdict, the watcher's pill, the briefing as
    /// tiles that open their pages, the six figures with Ready to merge still
    /// the one that opens Review, the dimmed tone for a failed PR scan, and
    /// Log keeping its header line until its own band lands.
    private static func checkInFlightBand(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                          _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let settings = AppSettings.shared
        let savedEnabled = settings.morningBriefingEnabled
        let savedRecord = settings.morningBriefingRecord
        defer {
            settings.morningBriefingEnabled = savedEnabled
            settings.morningBriefingRecord = savedRecord
        }
        let fleet = shell.workspace.overview
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("In flight", shell)

        func task(_ id: String, _ status: String) -> FleetTask {
            var task = FleetTask(id: id, repo: "grand-line", kind: "ship", pr: nil)
            task.status = status
            task.state = status == "working" ? "working" : "parked"
            task.source = "crew"
            return task
        }
        let tasks = [task("crew-a", "working"), task("crew-b", "working"), task("crew-c", "working"),
                     task("crew-d", "needs_decision"), task("crew-e", "blocked")]
        let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 2, doneCount: 4,
                                     projectsCount: 6, watcher: WatcherHealth(status: "healthy"))
        func pr(_ n: Int, checks: String, task: String?) -> MergedPR {
            MergedPR(source: task == nil ? "forge" : "work", taskID: task, repo: "grand-line",
                     url: "https://github.com/o/grand-line/pull/\(n)", number: n, title: "PR \(n)",
                     checks: checks, forge: "github")
        }
        let prs = [pr(1, checks: "green", task: "crew-a"), pr(2, checks: "green", task: "crew-b"),
                   pr(3, checks: "pending", task: nil)]
        fleet.debugRender(snapshot: snapshot, mergedPRs: prs)
        settle(shell)
        guard let flight = band(fleet) else {
            fail("CR-1: In flight opens on no band", &ok)
            return
        }
        let answer = FleetGreeting.answer(tasks: tasks, prs: .value(2), homeOk: true)
        check(flight.debugKicker.hasPrefix("In flight \u{00B7} ") && flight.debugHeadline == answer.title
                && flight.debugBody == answer.meta && flight.debugHeadline == "2 tasks need your call",
              "CR-1: In flight's band reads \(flight.debugKicker) / \(flight.debugHeadline) / \(flight.debugBody ?? "-")", &ok)
        check(figures(flight) == ["3 Working", "2 Ready to merge", "2 Queued", "4 Done today", "6 Projects", "OK Watcher healthy"],
              "CR-1: In flight's figures are \(figures(flight))", &ok)
        let theme = ThemeManager.shared.theme
        let palette = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme)
        if let pill = flight.debugStatusPill {
            let good = HelmHeroSurface.signalColor(tintHex: HelmTint.good.hex(in: theme), on: palette)
            let dot = pill.debugDotColor.map { HelmContrast.components($0) } ?? (0, 0, 0)
            let want = HelmContrast.components(good)
            let off = max(abs(dot.0 - want.0), abs(dot.1 - want.1), abs(dot.2 - want.2))
            check(pill.debugText == "Watcher healthy" && off < 0.01 && onScreen(pill),
                  "CR-1: the watcher pill reads \(pill.debugText) with dot \(String(describing: pill.debugDotColor))", &ok)
            // Level with the kicker, at the band's top right.
            let pillFrame = pill.convert(pill.bounds, to: flight)
            check(abs(pillFrame.maxX - (flight.bounds.width - HelmHeroColumn.bandInsets.right)) < 1.5,
                  "CR-1: the watcher pill ends at \(pillFrame.maxX), want the band's trailing inset", &ok)
        } else {
            fail("CR-1: In flight has no watcher pill", &ok)
        }
        check(!fleet.debugDashboardChromeShown.banner && !fleet.debugDashboardChromeShown.stats
                && !fleet.debugDashboardChromeShown.briefing,
              "CR-1: the sidebar layout still draws the answer banner, the boxed figures or the briefing card", &ok)
        check(shell.debugContentPaneHeader.isHiddenOrHasHiddenAncestor && shell.debugHeader == nil,
              "CR-1: In flight keeps the grey header line over its band", &ok)
        check(onScreen(fleet.debugInFlightRowViews.first), "CR-1: the working rows left In flight", &ok)
        // The band sits at the top of the page, above the working rows.
        if let row = fleet.debugInFlightRowViews.first {
            let bandBottom = flight.convert(NSPoint(x: 0, y: flight.isFlipped ? flight.bounds.height : 0), to: nil).y
            let rowTop = row.convert(NSPoint(x: 0, y: row.isFlipped ? 0 : row.bounds.height), to: nil).y
            check(bandBottom > rowTop, "CR-1: the band is not above the working rows (\(bandBottom) vs \(rowTop))", &ok)
        }

        // Ready to merge is still the one figure that is a button, into Review.
        let strip = fleet.debugBandFigures
        let actions = (0..<6).filter { strip.debugActionCell(at: $0) != nil }
        check(actions == [1] && strip.debugCaptionIsUnderlined(at: 1) && !strip.debugCaptionIsUnderlined(at: 0),
              "CR-1: the figures that are buttons are \(actions)", &ok)
        if let ready = strip.debugActionCell(at: 1) {
            check(ready.accessibilityRole() == .button && ready.accessibilityLabel() == "Ready to merge, 2"
                    && ready.canBecomeKeyView,
                  "CR-1: Ready to merge reads \(String(describing: ready.accessibilityRole())) "
                    + "\(ready.accessibilityLabel() ?? "-") to VoiceOver", &ok)
            ready.debugSetPressed(true)
            check((ready.layer?.animationKeys() ?? []).isEmpty, "CR-1: under Reduce Motion pressing a figure animates", &ok)
            ready.debugSetPressed(false)
            ready.performPrimaryAction()
            settle(shell)
            check(shell.debugCurrentDestination == .review, "CR-1: Ready to merge did not open Review", &ok)
        }
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("In flight", shell)

        // The Morning briefing: its line with Regenerate and Dismiss as ghost
        // icons, and one Br-3 tile per sentence that opens its page.
        let clauses = [BriefingClause(text: "2 PRs ready to merge", target: .review),
                       BriefingClause(text: "3 tasks due or overdue", target: .tasks),
                       BriefingClause(text: "2 forks behind upstream", target: .githubSync),
                       BriefingClause(text: "A quiet morning otherwise", target: .none)]
        settings.morningBriefingEnabled = true
        settings.morningBriefingRecord = MorningBriefing.record(inputs: BriefingInputs(), clauses: clauses,
                                                                isDegraded: false, degradedReason: nil)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("In flight", shell)
        guard let briefed = band(fleet), let line = fleet.debugBandBriefingRow else {
            fail("CR-1: today's briefing did not reach In flight's band", &ok)
            return
        }
        let tiles = fleet.debugBandTiles
        check(tiles.map(\.debugText) == clauses.map(\.text) && briefed.debugBandViews.count == 2
                && tiles.allSatisfy(onScreen),
              "CR-1: the band's tiles read \(tiles.map(\.debugText))", &ok)
        check(tiles.map(\.isActivatable) == [true, true, true, false],
              "CR-1: the tiles that open a page are \(tiles.map(\.isActivatable))", &ok)
        check(tiles.first?.debugLabel == PlaceName.short(.review).uppercased() && tiles.last?.debugLabel == "NOTE",
              "CR-1: the tiles are labelled \(tiles.map { $0.debugLabel ?? "-" })", &ok)
        check(line.subtitleLabel.stringValue.hasPrefix("Generated ")
                && fleet.debugBandRegenerateButton.heroInk != nil && fleet.debugBandDismissButton.heroInk != nil
                && onScreen(fleet.debugBandRegenerateButton) && onScreen(fleet.debugBandDismissButton),
              "CR-1: the briefing line reads \(line.subtitleLabel.stringValue) without its two ghost icons", &ok)
        check(!fleet.debugDashboardChromeShown.briefing, "CR-1: the briefing card came back beside the band", &ok)
        if let tile = tiles.first {
            tile.debugSetPressed(true)
            check((tile.layer?.animationKeys() ?? []).isEmpty, "CR-1: under Reduce Motion pressing a tile animates", &ok)
            tile.debugSetPressed(false)
            tile.performPrimaryAction()
            settle(shell)
            check(shell.debugCurrentDestination == .review, "CR-1: the Review tile did not open Review", &ok)
        }
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("In flight", shell)
        fleet.debugBandTiles.dropFirst(2).first?.performPrimaryAction()
        settle(shell)
        check(shell.debugCurrentDestination == .githubSync, "CR-1: the GitHub Sync tile did not open GitHub Sync", &ok)
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("In flight", shell)
        fleet.debugBandDismissButton.performClick(nil)
        settle(shell)
        check(fleet.debugBandBriefingRow == nil && band(fleet)?.debugBandViews.isEmpty == true
                && settings.morningBriefingRecord?.dismissed == true,
              "CR-1: Dismiss until tomorrow did not take the briefing off the band", &ok)

        // A PR scan that failed leaves the verdict partly unknown: dimmed.
        fleet.debugRender(snapshot: snapshot, mergedPRs: [], prFetchFailure: "gh failed")
        settle(shell)
        if let partly = band(fleet) {
            check(isDimmed(partly) && figures(partly).contains("\u{2014} PRs unavailable")
                    && fleet.debugBandFigures.debugActionCell(at: 1) != nil,
                  "CR-1: a failed PR scan reads \(figures(partly)), dimmed \(isDimmed(partly))", &ok)
        }
        // No home: the verdict's setup prompt, and Open Setup in the foot.
        let unset = FleetSnapshot(homeOk: false, captain: "Manjesh", tasks: [], queuedCount: 0, doneCount: 0,
                                  projectsCount: 0, watcher: WatcherHealth(status: "off"))
        fleet.debugRender(snapshot: unset, mergedPRs: [])
        settle(shell)
        if let setup = band(fleet) {
            check(setup.debugHeadline == "Point Grand Line at your firstmate home"
                    && setup.debugFootViews.first === fleet.debugBandSetupButton && setup.debugStatusPill == nil,
                  "CR-1: In flight without a home reads \(setup.debugHeadline) with foot \(setup.debugFootViews)", &ok)
        }
        fleet.debugRender(snapshot: snapshot, mergedPRs: prs)
        settle(shell)

        // Log opens on its own band now (`checkLogBand`), and back on In
        // flight the band says In flight's words again.
        clickTab("Log", shell)
        check(band(fleet)?.debugKicker.hasPrefix("Log") == true && shell.debugContentPaneHeader.isHiddenOrHasHiddenAncestor,
              "CR-1: Log drew no band of its own or kept its header line", &ok)
        clickTab("In flight", shell)
        check(band(fleet)?.debugKicker.hasPrefix("In flight") == true && figures(band(fleet)!).count == 6,
              "CR-1: back on In flight the band did not say In flight's words", &ok)

        // Gotcha (13): the band holds no width above 499, so a window narrower
        // than everything it says still keeps the width it was given.
        let offenders = band(fleet).map(widthsHeldAbove499) ?? []
        check(offenders.isEmpty, "CR-1: the band holds a width between 500 and required: \(offenders)", &ok)
        let floor = band(fleet).map { HelmSplitPage.floorWidth(of: $0) } ?? 0
        check(floor > 0 && floor < 420, "CR-1: the band's required floor is \(floor)pt, wider than any narrow window", &ok)
        resize(window, width: 1100, shell)
        check(abs(window.frame.width - 1100) < 0.5 && (band(fleet)?.frame.width ?? 0) < 1100,
              "CR-1: at 1100pt the window is \(window.frame.width) and the band \(band(fleet)?.frame.width ?? 0)", &ok)
        resize(window, width: 1512, shell)
    }

    /// The words on each of a segmented strip's pills, in order.
    private static func pillTitles(_ tabs: HelmSegmentedTabs) -> [String] {
        tabs.debugPillsForAccessibilityTests().map { pill in
            pill.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "?"
        }
    }

    /// CR-1 on Log: the page opens on the same band, "5 events today" over
    /// what they were, with the filter on the band's foot as the same
    /// `HelmSegmentedTabs` in the hero ink and with its counts. It keeps its
    /// radio roles and ← →, and filters the feed exactly as it did. The
    /// header line goes, the band is the empty state of an empty log, a log
    /// that could not be read is dimmed and says when (GL-14), and the band
    /// holds no width above 499 (gotcha (13)).
    private static func checkLogBand(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                     _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let fleet = shell.workspace.overview
        defer { fleet.debugUseLogStore(.shared) }
        let folder = scratch.appendingPathComponent("log-band", isDirectory: true)
        // Shift's activity is the feed's other half. The suite's own Shift
        // store must hold none, or the counts below are not this fixture's.
        let none = FleetLogFeed.read(store: FleetLogStore(directory: folder.appendingPathComponent("none")),
                                     shift: shell.workspace.shiftStore)
        check(none.events.isEmpty && !none.activityUnreadable,
              "fixture: the suite's Shift store already holds \(none.events.count) activity entries", &ok)

        // The board's typical log: five events today, three yesterday, two
        // on an older day.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute,
                          to: calendar.date(byAdding: .day, value: day, to: today)!)!
        }
        let store = FleetLogStore(directory: folder.appendingPathComponent("typical"))
        for event in [FleetLogEvent(date: at(-3, 9, 3), kind: .task, title: "Completed \u{201C}Weekly review\u{201D}"),
                      FleetLogEvent(date: at(-3, 11, 20), kind: .merge, title: "Merged PR #628"),
                      FleetLogEvent(date: at(-1, 14, 47), kind: .task, title: "Completed \u{201C}Renew the Grafana API token\u{201D}"),
                      FleetLogEvent(date: at(-1, 16, 2), kind: .sync, title: "Shift sync conflict resolved"),
                      FleetLogEvent(date: at(-1, 18, 18), kind: .merge, title: "Merged PR #629"),
                      FleetLogEvent(date: at(0, 8, 34), kind: .incident, title: "Started incident INC-7"),
                      FleetLogEvent(date: at(0, 9, 12), kind: .incident, title: "Ended incident INC-7"),
                      FleetLogEvent(date: at(0, 9, 41), kind: .investigation, title: "Saved investigation"),
                      FleetLogEvent(date: at(0, 10, 5), kind: .task, title: "Completed \u{201C}Rotate the staging certificate\u{201D}"),
                      FleetLogEvent(date: at(0, 10, 32), kind: .merge, title: "Merged PR #630")] {
            store.append(event)
        }
        fleet.debugUseLogStore(store)
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("Log", shell)
        guard let logBand = band(fleet) else {
            fail("CR-1: Log opens on no band", &ok)
            return
        }
        let day = CrewHeroWords.dayFormatter.string(from: Date())
        check(logBand.debugKicker == "Log \u{00B7} \(day)" && logBand.debugHeadline == "5 events today"
                && logBand.debugBody == "1 merge \u{00B7} 1 task update \u{00B7} 1 investigation saved \u{00B7} 2 incident updates. "
                    + "Latest at \(CrewBand.time(at(0, 10, 32)))."
                && !isDimmed(logBand),
              "CR-1: Log's band reads \(logBand.debugKicker) / \(logBand.debugHeadline) / \(logBand.debugBody ?? "-")", &ok)
        check(logBand.accessibilityRole() == .group && (logBand.accessibilityLabel() ?? "").contains("5 events today"),
              "CR-1: Log's band reads \(logBand.accessibilityLabel() ?? "-") to VoiceOver", &ok)
        check(shell.debugContentPaneHeader.isHiddenOrHasHiddenAncestor && shell.debugHeader == nil,
              "CR-1: Log keeps the grey header line over its band", &ok)

        // The filter is on the band's foot, the same strip, in the hero ink
        // with the chosen segment solid ink and the gradient's deep stop for
        // its words, and with its counts.
        let tabs = fleet.debugLogFilters
        let palette = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: ThemeManager.shared.theme)
        let navInk = HelmHeroColumn.NavInk(palette: palette)
        check(logBand.debugFootViews.count == 1 && logBand.debugFootViews.first === tabs
                && tabs.isDescendant(of: logBand) && onScreen(tabs),
              "CR-1: Log's filter is not on the band's foot (foot \(logBand.debugFootViews))", &ok)
        check(tabs.heroInk == logBand.ink && tabs.heroSelection == navInk.selectedInk,
              "CR-1: the filter is not in the band's ink: \(String(describing: tabs.heroInk)) for \(logBand.ink)", &ok)
        check(pillTitles(tabs) == ["All\u{2002}10", "Merges\u{2002}3", "Tasks\u{2002}3", "Sync\u{2002}1",
                                   "Investigations\u{2002}1", "Incidents\u{2002}2"],
              "CR-1: the filter's segments read \(pillTitles(tabs))", &ok)
        let pills = tabs.debugPillsForAccessibilityTests()
        check(pills.count == 6 && pills.allSatisfy { $0.accessibilityRole() == .radioButton }
                && pills.map { $0.accessibilityLabel() ?? "" } == ["All", "Merges", "Tasks", "Sync", "Investigations", "Incidents"]
                && pills.map { ($0.accessibilityValue() as? String) ?? "" }.first == "selected",
              "CR-1: the filter's segments are not six radio buttons named as before", &ok)
        let colors = tabs.debugPillLabelColors
        if colors.count == 6 {
            let chosen = HelmContrast.ratio(colors[0], logBand.ink)
            check(colors[0] == navInk.selectedInk && colors.dropFirst().allSatisfy { $0 == logBand.ink }
                    && chosen >= HelmContrast.textTarget,
                  "CR-1: the chosen segment's words are \(colors[0]) (\(String(format: "%.2f", chosen)):1 on the ink)", &ok)
        }
        // The feed sits straight under the band, as it always read.
        let list = fleet.debugLogList
        check(fleet.debugLogListShowing && list.debugRowCount == 13 && onScreen(list),
              "CR-1: the feed under Log's band has \(list.debugRowCount) rows, showing \(fleet.debugLogListShowing)", &ok)
        let bandBottom = logBand.convert(NSPoint(x: 0, y: logBand.isFlipped ? logBand.bounds.height : 0), to: nil).y
        let listTop = list.convert(NSPoint(x: 0, y: list.isFlipped ? 0 : list.bounds.height), to: nil).y
        // The first day sits right under the band (its header row holds its
        // own space above the day's name), and the last card is whole: the
        // table is as tall as its rows. It was 16pt short before CR-1, and
        // the last card was cut 13pt.
        check(bandBottom >= listTop - 0.5 && bandBottom - listTop < HelmMetrics.s1,
              "CR-1: the feed starts \(bandBottom - listTop)pt under the band", &ok)
        func feedIsWhole() -> Bool {
            let rows = list.tableView.numberOfRows
            return rows > 0 && list.tableView.rect(ofRow: rows - 1).maxY <= list.tableView.bounds.height + 0.5
        }
        check(feedIsWhole(), "CR-1: the feed's last row ends at \(list.tableView.rect(ofRow: list.tableView.numberOfRows - 1).maxY) "
                + "in a \(list.tableView.bounds.height)pt table", &ok)

        // ← → through the pill's own keyDown, as a key press reaches it: the
        // selection and focus move, and the feed filters exactly as before.
        HelmFocusVisibility.overrideForTests = true
        defer { HelmFocusVisibility.overrideForTests = nil }
        func arrow(_ code: UInt16, on pill: HoverHighlightView) {
            guard let event = keyEvent(code, "", [], window) else { return }
            pill.keyDown(with: event)
            settle(shell)
        }
        window.makeFirstResponder(pills[0])
        arrow(124, on: pills[0])
        check(tabs.selected == "merge" && window.firstResponder === pills[1] && list.debugRowCount == 6
                && band(fleet) === logBand && logBand.debugHeadline == "5 events today" && feedIsWhole(),
              "CR-1: → from All moved to \(tabs.selected) with \(list.debugRowCount) rows", &ok)
        check(tabs.debugHeroRing.isShowing && !tabs.debugHeroRing.systemRingIsOn,
              "CR-1: a keyed focus on the filter draws no ink ring", &ok)
        // Reduce Motion (pinned on for this suite): the thumb is already
        // under the chosen pill, with nothing sliding.
        let pillFrame = pills[1].convert(pills[1].bounds, to: tabs)
        check(abs(tabs.debugThumbFrame.width - pillFrame.width) < 0.5,
              "CR-1: under Reduce Motion the filter's thumb is \(tabs.debugThumbFrame) for \(pillFrame)", &ok)
        arrow(124, on: pills[1])
        check(tabs.selected == "task" && list.debugRowCount == 6, "CR-1: → to Tasks shows \(list.debugRowCount) rows", &ok)
        arrow(123, on: pills[2])
        arrow(123, on: pills[1])
        check(tabs.selected == "all" && window.firstResponder === pills[0] && list.debugRowCount == 13,
              "CR-1: ← back to All shows \(list.debugRowCount) rows on \(tabs.selected)", &ok)
        tabs.debugClickTab(id: "incident")
        settle(shell)
        check(list.debugRowCount == 3 && pills.map { ($0.accessibilityValue() as? String) ?? "" }[5] == "selected",
              "CR-1: Incidents shows \(list.debugRowCount) rows", &ok)
        tabs.debugClickTab(id: "all")
        window.makeFirstResponder(nil)
        settle(shell)

        // Gotcha (13): the band holds no width above 499 of its own. The
        // strip's pill row is the kit's unchanged `.gravityAreas` stack, whose
        // own spacing constraints sit at 749.95 to 750 between pills inside a
        // capsule of required edges, so they are left out of the scan and the
        // band's floor and the narrow windows below are the measurement: the
        // band's own floor is far under the strip, and the window keeps every
        // width it is given, down to the app's smallest, with the whole strip
        // inside the band.
        let offenders = widthsHeldAbove499(logBand).filter { !$0.hasPrefix("NSStackView 7") }
        let inStrip = widthsHeldAbove499(tabs)
        check(offenders.isEmpty && inStrip.count == widthsHeldAbove499(logBand).count - offenders.count,
              "CR-1: Log's band holds a width between 500 and required outside its filter: \(offenders)", &ok)
        let floor = HelmSplitPage.floorWidth(of: logBand)
        check(floor > 0 && floor < 420, "CR-1: Log's band's required floor is \(floor)pt", &ok)
        for width in [1100, AppDelegate.minContentSize.width] as [CGFloat] {
            resize(window, width: width, shell)
            let stripFrame = tabs.convert(tabs.bounds, to: logBand)
            check(abs(window.frame.width - width) < 0.5 && stripFrame.minX >= HelmHeroColumn.bandInsets.left - 0.5
                    && stripFrame.maxX <= logBand.bounds.width - HelmHeroColumn.bandInsets.right + 0.5,
                  "CR-1: at \(width)pt the window is \(window.frame.width) and the filter spans \(stripFrame) "
                    + "of a \(logBand.bounds.width)pt band", &ok)
        }
        resize(window, width: 1512, shell)

        // Nothing today: quiet, with when the last event was.
        let quiet = FleetLogStore(directory: folder.appendingPathComponent("quiet"))
        quiet.append(FleetLogEvent(date: at(-1, 18, 18), kind: .merge, title: "Merged PR #629"))
        fleet.debugUseLogStore(quiet)
        settle(shell)
        check(logBand.debugHeadline == "Quiet so far today"
                && logBand.debugBody == "The last event was yesterday at \(CrewBand.time(at(-1, 18, 18)))."
                && pillTitles(tabs).first == "All\u{2002}1" && fleet.debugLogListShowing,
              "CR-1: a quiet log reads \(logBand.debugHeadline) / \(logBand.debugBody ?? "-")", &ok)

        // An empty log: the band is the empty state, with no filter and no
        // second empty card under it.
        fleet.debugUseLogStore(FleetLogStore(directory: folder.appendingPathComponent("empty")))
        settle(shell)
        check(logBand.debugHeadline == "Nothing logged yet" && logBand.debugBody == CrewHeroWords.emptyLogBody
                && logBand.debugKicker == "Log" && logBand.debugFootViews.isEmpty && !tabs.isDescendant(of: logBand)
                && !fleet.debugLogListShowing && !isDimmed(logBand),
              "CR-1: an empty log drew \(logBand.debugHeadline) with foot \(logBand.debugFootViews), "
                + "list \(fleet.debugLogListShowing)", &ok)

        // GL-14: a log file that is there and cannot be read is not an empty
        // log. Dimmed, said with the time, no filter and no count.
        let brokenFolder = folder.appendingPathComponent("broken", isDirectory: true)
        try? FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        let broken = FleetLogStore(directory: brokenFolder)
        try? Data([0xFF, 0xFE, 0xC3, 0x28, 0x0A]).write(to: broken.debugFileURL)
        fleet.debugUseLogStore(broken)
        settle(shell)
        check(isDimmed(logBand) && logBand.debugHeadline.hasPrefix("Couldn\u{2019}t read the log at ")
                && logBand.debugHeadline.hasSuffix(CrewBand.time(fleet.debugLogReading.readAt ?? Date()))
                && logBand.debugBody == "Merges, sync fixes, investigations and incidents could not be read, so no count is shown."
                && logBand.debugFootViews.isEmpty && !fleet.debugLogListShowing,
              "CR-1: an unreadable log drew \(logBand.debugHeadline) / \(logBand.debugBody ?? "-"), dimmed \(isDimmed(logBand))", &ok)
        // What this session appended to it since is shown and counted, and
        // the kinds the file holds say no count rather than a zero.
        broken.append(FleetLogEvent(date: at(0, 10, 32), kind: .merge, title: "Merged PR #630"))
        tabs.debugClickTab(id: "investigation")
        settle(shell)
        check(isDimmed(logBand) && logBand.debugHeadline.hasPrefix("Couldn\u{2019}t read all of the log at ")
                && pillTitles(tabs) == ["All", "Merges", "Tasks\u{2002}0", "Sync", "Investigations", "Incidents"]
                && list.debugEmptyText.title == "Couldn\u{2019}t read the log"
                && list.debugEmptyText.body.hasPrefix("Saved investigations could not be read at "),
              "CR-1: a partly read log drew \(logBand.debugHeadline), segments \(pillTitles(tabs)), "
                + "list \(list.debugEmptyText)", &ok)
        tabs.debugClickTab(id: "all")
        settle(shell)
        clickTab("In flight", shell)
    }

    /// The PRs Review's checks draw: the board's nine, two of them ready to
    /// merge, three with checks running and one failing, on two forges.
    private static func reviewFixture() -> [MergedPR] {
        func pr(_ n: Int, _ forge: String, _ checks: String, task: String? = nil) -> MergedPR {
            MergedPR(source: task == nil ? "forge" : "work", taskID: task, repo: "grand-line",
                     url: "https://\(forge == "github" ? "github.com" : "bitbucket.org")/o/grand-line/pull/\(n)",
                     number: n, title: "PR \(n)", checks: checks, forge: forge)
        }
        return [pr(631, "github", "green", task: "crew-a"), pr(88, "github", "green", task: "crew-b"),
                pr(632, "github", "pending", task: "crew-c"), pr(214, "github", "pending"), pr(212, "github", "red"),
                pr(86, "github", "green"), pr(57, "github", "pending"), pr(41, "bitbucket", "none"),
                pr(19, "bitbucket", "green")]
    }

    /// Review's own refresh scans every clone on a visit. A stub keeps it
    /// offline and quick, and the wait lets it land before a fixture is
    /// drawn, so the fixture is what stays on screen.
    private static func settleReview(_ review: ReviewController) {
        _ = waitUntil(timeout: 10) { !review.debugIsLoading }
    }

    /// CR-1 on Crew › Review: the band in every state the page can be in, the
    /// forge cards under it, the header line given up, Refresh still in the
    /// toolbar and no width held above gotcha (13)'s 499.
    private static func checkReviewBand(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                        _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        OpenPRsSource.debugFetcher = { OpenPRsSource.FetchResult() }
        defer { OpenPRsSource.debugFetcher = nil }
        let review = shell.workspace.review
        shell.workspace.navigator.show(.overview)
        settle(shell)
        check(clickTab("Review", shell) && shell.debugCurrentDestination == .review,
              "CR-1: Crew's Review tab opened \(String(describing: shell.debugCurrentDestination))", &ok)
        settleReview(review)
        review.debugRender(reviewFixture())
        settle(shell)
        guard let band = review.debugReviewBand, onScreen(band) else {
            fail("CR-1: Review opens on no band", &ok)
            return
        }
        check(band.accessibilityRole() == .group && (band.accessibilityLabel() ?? "").contains(band.debugHeadline),
              "CR-1: Review's band is not one group named by its headline (\(band.accessibilityLabel() ?? "nothing"))", &ok)
        check(band.debugKicker.hasPrefix("Review \u{00B7} 9 open \u{00B7} checked ")
                && band.debugHeadline == "2 pull requests are ready to merge"
                && band.debugBody == "3 with checks running \u{00B7} 1 failing \u{00B7} across GitHub and Bitbucket."
                && !isDimmed(band),
              "CR-1: Review's band reads \(band.debugKicker) / \(band.debugHeadline) / \(band.debugBody ?? "-")", &ok)
        check(figures(band) == ["9 Open PRs", "2 Ready to merge", "3 Checks running", "1 Checks failing"],
              "CR-1: Review's figures are \(figures(band))", &ok)
        // The ring sits at the band's trailing edge, as the board draws it
        // (HelmHeroColumn 1.5.1), not wherever the words happen to end.
        if let ring = band.debugRing, onScreen(ring) {
            let frame = ring.convert(ring.bounds, to: band)
            check(ring.centreLabelForTests == "2/9" && abs(ring.fractionForTests - 2.0 / 9.0) < 0.001
                    && frame.minX > band.bounds.width * 0.6,
                  "CR-1: Review's ring reads \(ring.centreLabelForTests) at x \(frame.minX) of \(band.bounds.width)", &ok)
        } else {
            fail("CR-1: Review's band has no ring on screen", &ok)
        }
        check(shell.debugContentPaneHeader.isHiddenOrHasHiddenAncestor && shell.debugHeader == nil
                && !(review.drillHeaderSubtitle ?? "").isEmpty,
              "CR-1: Review keeps the grey header line over its band, or lost its summary", &ok)
        check(!review.debugIsStatsRowVisible && !review.debugIsBodySubtitleVisible && !review.debugIsFailureStateVisible,
              "CR-1: Review still draws its boxed figures, its count line or its failure block beside the band", &ok)
        // Refresh stays in the toolbar, never on the band.
        if let refresh = review.drillHeaderActions.first {
            check(onScreen(refresh) && !refresh.isDescendant(of: band) && !refresh.isDescendant(of: review.view),
                  "CR-1: Refresh left the toolbar", &ok)
        } else {
            fail("CR-1: Review has no Refresh", &ok)
        }
        // The forge cards stay under the band, their rows and Merge gate as they were.
        check(review.debugAreForgeSectionsVisible && review.debugGithubRowCount == 7 && review.debugBitbucketRowCount == 2,
              "CR-1: Review's forge cards hold \(review.debugGithubRowCount) and \(review.debugBitbucketRowCount) rows", &ok)
        let row = review.debugGitHubRowButtonState(at: 0)
        check(review.debugGitHubRowChipText(at: 0) == "Checks running" && (row?.reviewFrame.width ?? 0) > 0
                && row?.mergeHidden == true,
              "CR-1: Review's first row reads \(review.debugGitHubRowChipText(at: 0) ?? "nothing") with \(String(describing: row))", &ok)

        // GL-14: a scan that reached nothing is dimmed, counts nothing, keeps
        // no empty forge card, and offers the folder path on the band.
        review.debugRender([], scan: OpenPRsSource.FetchResult(projectsUnreadable: true))
        settle(shell)
        let folder = review.debugBandFolderButton
        check(isDimmed(band) && band.debugHeadline.hasPrefix("Couldn\u{2019}t read your projects at ")
                && figures(band).isEmpty && band.debugRing == nil && onScreen(folder) && folder.heroInk != nil
                && !review.debugAreForgeSectionsVisible && !review.debugIsFailureStateVisible,
              "CR-1: an unreadable projects folder reads \(band.debugHeadline), dimmed \(isDimmed(band)), "
                + "figures \(figures(band))", &ok)
        folder.performClick(nil)
        settle(shell)
        check(onScreen(review.debugBandFolderRow) && folder.title == "Hide folder path"
                && review.debugBandFolderRow.subtitleLabel.stringValue == FirstmateHome.projects.path,
              "CR-1: Show folder path did not put the path on the band", &ok)
        folder.performClick(nil)
        settle(shell)
        check(!onScreen(review.debugBandFolderRow) && folder.title == "Show folder path",
              "CR-1: Hide folder path left the path on the band", &ok)
        // A scan that missed some forges keeps the rows it found, dimmed.
        review.debugRender(Array(reviewFixture().prefix(7)),
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["pramata-status", "pramata-hive"]))
        settle(shell)
        check(isDimmed(band) && figures(band).first == "7 Open PRs" && review.debugGithubRowCount == 7
                && review.debugAreForgeSectionsVisible,
              "CR-1: a partial scan reads \(figures(band)) over \(review.debugGithubRowCount) rows, dimmed \(isDimmed(band))", &ok)
        // Nothing open after a clean scan: the band is the empty state.
        review.debugRender([])
        settle(shell)
        check(band.debugHeadline == "No open pull requests right now" && figures(band).isEmpty && !isDimmed(band)
                && !review.debugAreForgeSectionsVisible && onScreen(band),
              "CR-1: an empty Review reads \(band.debugHeadline) with forge cards \(review.debugAreForgeSectionsVisible)", &ok)
        review.debugRender(reviewFixture())
        settle(shell)

        // Gotcha (13), as on In flight.
        let offenders = widthsHeldAbove499(band)
        check(offenders.isEmpty, "CR-1: Review's band holds a width between 500 and required: \(offenders)", &ok)
        let floor = HelmSplitPage.floorWidth(of: band)
        check(floor > 0 && floor < 420, "CR-1: Review's band's required floor is \(floor)pt", &ok)
        resize(window, width: 1100, shell)
        check(abs(window.frame.width - 1100) < 0.5 && band.frame.width < 1100,
              "CR-1: at 1100pt Review's window is \(window.frame.width) and its band \(band.frame.width)", &ok)
        resize(window, width: 1512, shell)
    }

    // MARK: 4b - RP-2, the Needs you reply composer

    private static func keyEvent(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags,
                                 _ window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)
    }

    /// The head's painted pixel 16pt in from its leading edge and 4pt down,
    /// next to the gradient's lighter-start corner, in the rep's raw components.
    private static func headSample(_ card: FleetReplyCard) -> (sample: (Double, Double, Double), space: NSColorSpace)? {
        let head = card.debugHeadView
        guard head.bounds.width > 0, let rep = head.bitmapImageRepForCachingDisplay(in: head.bounds) else { return nil }
        head.cacheDisplay(in: head.bounds, to: rep)
        // Gotcha: the rep is in pixels, not points.
        let scale = CGFloat(rep.pixelsWide) / head.bounds.width
        guard let color = rep.colorAt(x: Int(16 * scale), y: Int(4 * scale)) else { return nil }
        return ((Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)), rep.colorSpace)
    }

    /// How far `sample` is from a palette's start stop, the expected colour
    /// converted into the rep's own space (never the sample - AGENTS.md's
    /// "Verifying native UI bugs" rule).
    private static func distance(_ sample: (Double, Double, Double), toStartOf palette: HelmHeroSurface.Palette,
                                 in space: NSColorSpace) -> Double {
        let expected = HelmContrast.color(palette.start).usingColorSpace(space) ?? HelmContrast.color(palette.start)
        return max(abs(sample.0 - Double(expected.redComponent)), abs(sample.1 - Double(expected.greenComponent)),
                   abs(sample.2 - Double(expected.blueComponent)))
    }

    private static func checkReplyQuestionHead(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                               _ ok: inout Bool) {
        let savedTheme = ThemeManager.shared.theme
        let wasLocked = AppLockGate.shared.isLocked
        let savedScript = FleetActions.sendScriptOverrideForTests
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppLockGate.shared.setLocked(wasLocked)
            FleetActions.sendScriptOverrideForTests = savedScript
            resize(window, width: 1512, shell)
        }
        AppLockGate.shared.setLocked(false)
        let state = scratch.appendingPathComponent("rp2-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FleetActions.stateDirectoryOverrideForTests = state
        // A stand-in for `fm-send.sh` that exits with each outcome's status,
        // so no reply is ever sent anywhere.
        let script = scratch.appendingPathComponent("rp2-fake-fm-send.sh")
        FleetActions.sendScriptOverrideForTests = script.path
        func fakeSend(exit status: Int, after seconds: Int = 0) {
            try? "#!/bin/bash\nsleep \(seconds)\nprintf 'pane\\n'\nexit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let note = "Which design to build for the notifications panel: N-1, N-2, N-3, N-4, or none yet. "
            + ReviewTourLab.demoDecisionNote + " " + ReviewTourLab.demoDecisionNote
        try? ("needs-decision [at=1791950800] [key=helm-bump]: Bump Helm?\n"
              + "needs-decision [at=1791950801] [key=board-review]: \(note)\n")
            .write(to: state.appendingPathComponent("rp2-wait.status"), atomically: true, encoding: .utf8)
        // An unbroken URL, the note no word wrap can break (gotcha (13)'s case).
        try? "blocked [at=1791950802]: \(LayoutStabilitySelfTest.unbrokenNote)\n"
            .write(to: state.appendingPathComponent("rp2-block.status"), atomically: true, encoding: .utf8)
        func task(_ id: String, _ repo: String, _ status: String) -> FleetTask {
            var task = FleetTask(id: id, repo: repo, kind: "ship", pr: nil)
            task.status = status
            task.state = "parked"
            return task
        }
        let wait = task("rp2-wait", "grand-line", "needs_decision")
        let block = task("rp2-block", "pramata-status", "blocked")
        func snapshot(_ tasks: [FleetTask]) -> FleetSnapshot {
            FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 0, doneCount: 0,
                          projectsCount: 2, watcher: WatcherHealth(status: "healthy"))
        }
        let fleet = shell.workspace.overview
        shell.workspace.navigator.show(.overview)
        settle(shell)
        clickTab("Needs you", shell)

        for id in ["lavender", "powder"] {
            guard let theme = HelmTheme.appThemes.first(where: { $0.id == id }) else {
                fail("RP-2: no \(id) theme", &ok)
                continue
            }
            ThemeManager.shared.setTheme(theme)
            resize(window, width: 1512, shell)
            fleet.debugRender(snapshot: snapshot([wait, block]), mergedPRs: [])
            settle(shell)
            let tag = "RP-2 \(id)"
            // The kit's quiet-ink rule on the theme's hero accent and on its
            // amber, not re-derived through the card's own function.
            let accent = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme)
            let warn = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            let amberPalette = HelmHeroColumn.palette(for: .init(colour: .fixed(red: warn.0, green: warn.1, blue: warn.2)),
                                                      in: theme)

            // Reply: the row becomes the card, and the well takes focus.
            guard let reply = fleet.debugReplyButton(taskID: wait.id) else {
                fail("\(tag): the waiting row has no Reply", &ok)
                continue
            }
            reply.performClick(nil)
            settle(shell)
            guard let card = fleet.debugOpenReplyCard else {
                fail("\(tag): Reply opened no card", &ok)
                continue
            }
            check(fleet.debugCardTakesItsRowsPlace(taskID: wait.id, at: 0) && onScreen(card),
                  "\(tag): the card is not on screen in its row's place", &ok)
            check(window.firstResponder === card.debugTextView && card.debugWell.debugIsFocused,
                  "\(tag): focus on open is \(String(describing: window.firstResponder)), not the well", &ok)

            // The question, whole: every line it needs, its wrap width from
            // the card's own (gotcha (22)).
            // Measured from the words themselves, not the cell, which would
            // answer within its own line limit.
            let headline = card.debugHeadlineLabel
            let lineHeight = ceil((headline.font ?? HelmType.caption()).boundingRectForFont.height)
            func needed(_ label: NSTextField) -> CGFloat {
                let column = label.alignmentRect(forFrame: label.frame).width
                return ceil(label.attributedStringValue.boundingRect(
                    with: NSSize(width: column, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            }
            check(needed(headline) > 2.5 * lineHeight, "fixture: the note needs only \(needed(headline))pt", &ok)
            check(headline.stringValue == note && needed(headline) <= headline.alignmentRect(forFrame: headline.frame).height + 1,
                  "\(tag): the headline needs \(needed(headline))pt and has \(headline.bounds.height)pt", &ok)
            let wrap = floor(card.bounds.width) - FleetReplyCard.headInsets.left - FleetReplyCard.headInsets.right - HelmMetrics.s1
            // Auto Layout pins a field's alignment rect, so that is the
            // column its words wrap in.
            let column = headline.alignmentRect(forFrame: headline.frame).width
            check(abs(headline.preferredMaxLayoutWidth - wrap) < 1 && abs(column - wrap) < 1,
                  "\(tag): the headline wraps at \(headline.preferredMaxLayoutWidth)pt in a \(column)pt column, "
                    + "the card's own is \(wrap)pt", &ok)
            check(card.debugDetailLabel.stringValue == "grand-line \u{00B7} 2 open decisions: helm-bump, board-review"
                    && card.debugWell.debugHintLabel.isHidden && card.debugStatusText == nil,
                  "\(tag): the second line reads \(card.debugDetailLabel.stringValue)", &ok)

            // Painted: the quiet-ink accent gradient, where the board puts it.
            check(card.palette == accent && accent != amberPalette, "\(tag): a waiting task's head is not the accent's", &ok)
            if let painted = headSample(card) {
                let near = distance(painted.sample, toStartOf: accent, in: painted.space)
                let far = distance(painted.sample, toStartOf: amberPalette, in: painted.space)
                check(near < 0.05 && far > 0.08, "\(tag): the head's corner is \(painted.sample) (accent \(near), amber \(far))", &ok)
            } else {
                fail("\(tag): the head has no bitmap", &ok)
            }

            // ↩ is a new line, typed through the window like a real key.
            card.debugTextView.insertText("Go with N-1.", replacementRange: NSRange(location: NSNotFound, length: 0))
            if let plain = keyEvent(36, "\r", [], window) { window.sendEvent(plain) }
            check(card.text == "Go with N-1.\n" && !card.debugIsBusy,
                  "\(tag): Return did not insert a new line (\(card.text.debugDescription))", &ok)

            // A refresh that puts a new task above: the same card, its text,
            // its place under the newcomer, and focus still in the well.
            fleet.debugRender(snapshot: snapshot([task("rp2-new", "grand-line", "needs_decision"), wait, block]), mergedPRs: [])
            settle(shell)
            check(fleet.debugOpenReplyCard === card && card.text == "Go with N-1.\n"
                    && fleet.debugCardTakesItsRowsPlace(taskID: wait.id, at: 1)
                    && window.firstResponder === card.debugTextView,
                  "\(tag): a refresh lost the card, its text, its place or focus "
                    + "(\(String(describing: window.firstResponder)))", &ok)

            // ⌘↩ elsewhere on the page sends nothing.
            window.makeFirstResponder(nil)
            if let chord = keyEvent(36, "\r", .command, window) { _ = window.performKeyEquivalent(with: chord) }
            check(!card.debugIsBusy && card.text == "Go with N-1.\n", "\(tag): \u{2318}\u{21A9} away from the well sent the reply", &ok)
            window.makeFirstResponder(card.debugTextView)

            // ⌘↩ in the well, through the window's key-equivalent path. Sent
            // but unconfirmed: the text clears, the amber line stays, a
            // warning toast, and the card stays open with focus.
            // Each toast posts one announcement, recorded in order - a count
            // of pills on screen would race the 1.8s a plain toast stays.
            fakeSend(exit: 3)
            var announced = Toast.debugAnnouncements.count
            let handled = keyEvent(36, "\r", .command, window).map { window.performKeyEquivalent(with: $0) } ?? false
            check(handled && card.debugIsBusy && !card.debugSendButton.isEnabled && !card.debugCloseButton.isEnabled,
                  "\(tag): \u{2318}\u{21A9} did not start a send (handled \(handled))", &ok)
            check(waitUntil(timeout: 20) { !card.debugIsBusy }, "\(tag): the unconfirmed send never finished", &ok)
            settle(shell)
            let unconfirmed = FleetReplyOutcome.sentUnconfirmed("").message
            check(fleet.debugOpenReplyCard === card && card.text.isEmpty && card.debugStatusText == unconfirmed
                    && Toast.debugAnnouncements.count == announced + 1
                    && Toast.debugAnnouncements.last?.contains(unconfirmed) == true
                    && window.firstResponder === card.debugTextView,
                  "\(tag): unconfirmed left \(card.text.debugDescription) / \(card.debugStatusText ?? "no status"), "
                    + "focus \(String(describing: window.firstResponder))", &ok)
            check(card.debugStatusLabel.textColor == HelmContrast.legibleTintedText(
                    tintHex: HelmTint.warn.hex(in: theme), over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme),
                  "\(tag): the unconfirmed line is not in the warn tint", &ok)

            // Failed: the text is kept, the red line says why, and Send can try again.
            card.debugTextView.insertText("Add the secret.", replacementRange: NSRange(location: NSNotFound, length: 0))
            fakeSend(exit: 1)
            if let chord = keyEvent(36, "\r", .command, window) { _ = window.performKeyEquivalent(with: chord) }
            check(waitUntil(timeout: 20) { !card.debugIsBusy }, "\(tag): the failed send never finished", &ok)
            settle(shell)
            check(fleet.debugOpenReplyCard === card && card.text == "Add the secret."
                    && (card.debugStatusText ?? "").hasPrefix("Reply not sent: ") && card.debugSendButton.isEnabled
                    && card.debugStatusLabel.textColor == HelmContrast.legibleTintedText(
                        tintHex: HelmTint.critical.hex(in: theme), over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme),
                  "\(tag): failed left \(card.text.debugDescription) / \(card.debugStatusText ?? "no status")", &ok)

            // Delivered: the card closes, the row is back with its Reply, and a toast.
            fakeSend(exit: 0)
            announced = Toast.debugAnnouncements.count
            card.debugSendButton.performClick(nil)
            check(waitUntil(timeout: 20) { fleet.debugOpenReplyCard == nil }, "\(tag): a delivered reply left the card open", &ok)
            settle(shell)
            check(fleet.debugOpenReplyTaskID == nil && fleet.debugReplyButton(taskID: wait.id)?.title == "Reply"
                    && Toast.debugAnnouncements.count == announced + 1
                    && Toast.debugAnnouncements.last?.contains(FleetReplyOutcome.confirmed.message) == true,
                  "\(tag): delivered left Reply titled \(fleet.debugReplyButton(taskID: wait.id)?.title ?? "nil")", &ok)

            // A send still out when the captain opens another task's reply:
            // its delivery closes only its own card, never the one now open.
            fleet.debugReplyButton(taskID: wait.id)?.performClick(nil)
            settle(shell)
            guard let second = fleet.debugOpenReplyCard else {
                fail("\(tag): Reply did not reopen", &ok)
                continue
            }
            second.debugTextView.insertText("Ship it.", replacementRange: NSRange(location: NSNotFound, length: 0))
            fakeSend(exit: 0, after: 1)
            second.debugSendButton.performClick(nil)
            check(second.debugIsBusy, "\(tag): Send did not start the slow send", &ok)
            fleet.debugReplyButton(taskID: block.id)?.performClick(nil)
            settle(shell)
            let other = fleet.debugOpenReplyCard
            check(waitUntil(timeout: 20) { !second.debugIsBusy }, "\(tag): the slow send never finished", &ok)
            settle(shell)
            check(other != nil && fleet.debugOpenReplyCard === other && fleet.debugOpenReplyTaskID == block.id,
                  "\(tag): an earlier send's delivery closed the reply opened after it", &ok)

            // A blocked task: the amber head, and an unbroken URL that wraps
            // at 1100pt without holding the window wider (gotcha (13)).
            resize(window, width: 1100, shell)
            guard let blocked = fleet.debugOpenReplyCard else {
                fail("\(tag): Reply on the blocked task opened no card", &ok)
                continue
            }
            check(blocked.palette == amberPalette, "\(tag): a blocked task's head is not amber", &ok)
            if let painted = headSample(blocked) {
                let near = distance(painted.sample, toStartOf: amberPalette, in: painted.space)
                let far = distance(painted.sample, toStartOf: accent, in: painted.space)
                check(near < 0.05 && far > 0.08, "\(tag): the amber head's corner is \(painted.sample) (amber \(near), accent \(far))", &ok)
            }
            let url = blocked.debugHeadlineLabel
            let oneLine = url.attributedStringValue.size().width
            let urlRect = url.convert(url.bounds, to: nil)
            check(oneLine > 1100, "fixture: the unbroken note fits on one line (\(oneLine)pt)", &ok)
            check(abs(window.frame.width - 1100) < 0.5 && urlRect.maxX <= (window.contentView?.frame.width ?? 1100) + 0.5
                    && url.bounds.height > 2 * lineHeight && needed(url) <= url.alignmentRect(forFrame: url.frame).height + 1,
                  "\(tag): at 1100pt the window is \(window.frame.width) and the URL ends at \(urlRect.maxX), "
                    + "\(url.bounds.height)pt tall", &ok)
            let floor = HelmSplitPage.floorWidth(of: blocked)
            check(floor > 0 && floor < 420, "\(tag): the card's required floor is \(floor)pt", &ok)

            // Esc, through the window to the well's text view, cancels.
            if let esc = keyEvent(53, "\u{1b}", [], window) { window.sendEvent(esc) }
            settle(shell)
            check(fleet.debugOpenReplyCard == nil && fleet.debugReplyButton(taskID: block.id)?.title == "Reply",
                  "\(tag): Esc did not cancel the reply", &ok)
        }
    }

    // MARK: 5 - the floating bar

    private static func checkTheFloatingBarIsUnchanged(_ ok: inout Bool) {
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        ReviewTourLab.seedDemoHosts(shell.workspace)
        settle(shell)
        for route in [RailDestination.hosts, .poneglyph, .vault, .notebook, .overview, .runbooks] {
            shell.workspace.navigator.show(route)
            settle(shell)
        }
        let hosts = shell.workspace.hostsPanel
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        check(!hosts.drawsSidebarLayout && onScreen(hosts.debugHostsList.card) && !onScreen(hosts.debugHostsTable.card),
              "the floating bar's Hosts page is not its list", &ok)
        check(!shell.debugPoneglyph.drawsSidebarLayout && !shell.debugPoneglyph.debugInspector.isHostedInWorkspaceInspector,
              "the floating bar's Poneglyph moved its inspector out of the page", &ok)
        check(!shell.workspace.vault.drawsSidebarLayout, "the floating bar's Automic Vault switched to tables", &ok)
        check(shell.workspace.notebook.splitPage?.pageForcesCollapse != true,
              "the floating bar's Notebook put its page column away", &ok)
        let fleet = shell.workspace.overview
        check(!fleet.drawsSidebarLayout && fleet.moduleTabNames == ["In flight", "Log"] && !fleet.debugNeedsSectionIsOnNeedsYou,
              "the floating bar's Fleet page grew a Needs you", &ok)
        fleet.revealNeedsYou()
        check(!fleet.debugNeedsYouShowing, "revealNeedsYou switched the floating bar's Fleet page", &ok)
        // CR-1 is the sidebar layout's: the floating bar's dashboard keeps its
        // answer banner and boxed figures, and draws no band.
        shell.workspace.navigator.show(.overview)
        settle(shell)
        let quiet = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [], queuedCount: 1, doneCount: 2,
                                  projectsCount: 3, watcher: WatcherHealth(status: "healthy"))
        fleet.debugRender(snapshot: quiet, mergedPRs: [])
        settle(shell)
        check(fleet.debugCrewBand == nil && fleet.debugDashboardChromeShown.banner && fleet.debugDashboardChromeShown.stats,
              "CR-1: the floating bar's Fleet page drew the band or lost its banner and figures", &ok)
        check(fleet.debugStatTiles.map(\.caption) == ["Working", "Ready to merge", "Queued", "Done today", "Projects",
                                                      "Watcher healthy"],
              "CR-1: the floating bar's figures moved: \(fleet.debugStatTiles.map(\.caption))", &ok)
        check(!(fleet as WorkspaceHeaderLineCollapsing).collapsesEmptyHeaderLine
                && (fleet as WorkspaceHeaderLineCollapsing).drawsSubtitleOnHeaderLine,
              "CR-1: the floating bar's Fleet page gives up a header line", &ok)
        // Its Log keeps the filter over the feed, in the theme's own recipe
        // and with no counts, and draws no band.
        fleet.debugSwitchTab("log")
        settle(shell)
        let logTabs = fleet.debugLogFilters
        check(fleet.debugCrewBand == nil && logTabs.heroInk == nil && logTabs.superview != nil && onScreen(logTabs)
                && pillTitles(logTabs) == ["All", "Merges", "Tasks", "Sync", "Investigations", "Incidents"]
                && fleet.debugLogListShowing
                && !(fleet as WorkspaceHeaderLineCollapsing).collapsesEmptyHeaderLine,
              "CR-1: the floating bar's Log drew the band or changed its filter: \(pillTitles(logTabs))", &ok)
        fleet.debugSwitchTab("overview")
        settle(shell)
        // Review's band is the sidebar layout's too: the floating bar's Review
        // keeps its count line, its boxed figures and its two forge cards.
        OpenPRsSource.debugFetcher = { OpenPRsSource.FetchResult() }
        defer { OpenPRsSource.debugFetcher = nil }
        let review = shell.workspace.review
        shell.workspace.navigator.show(.review)
        settle(shell)
        settleReview(review)
        review.debugRender(reviewFixture())
        settle(shell)
        check(!review.drawsSidebarLayout && review.debugReviewBand == nil && review.debugIsStatsRowVisible
                && review.debugIsBodySubtitleVisible
                && review.debugStatTiles.map(\.caption) == ["Open PRs", "Ready to merge", "Checks running"],
              "CR-1: the floating bar's Review drew the band or lost its line and figures: "
                + "\(review.debugStatTiles.map(\.caption))", &ok)
        check(!review.collapsesEmptyHeaderLine && review.drawsSubtitleOnHeaderLine,
              "CR-1: the floating bar's Review gives up a header line", &ok)
        review.debugRender([])
        settle(shell)
        check(review.debugAreForgeSectionsVisible && review.debugReviewBand == nil,
              "CR-1: the floating bar's empty Review lost its forge cards", &ok)
    }

    /// Found on the way, on the floating bar's Hosts page: after a tab round
    /// trip the column's footer stack took the column's spare height, so its
    /// keychain card rode up under the nav rows (measured 501pt above where it
    /// belongs). See `HelmPageSidebar.setFooter`.
    private static func checkTheHostsFooterStaysDown(_ scratchDirectory: URL, _ ok: inout Bool) {
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        ReviewTourLab.seedDemoHosts(shell.workspace)
        settle(shell)
        let hosts = shell.workspace.hostsPanel
        // Driven through the tour lab's own steps - page tabs, selections and
        // real waits - because the move needed the round trip's animations
        // to run to the end; short settles never produced it.
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = true }
        let roundTrip = """
        theme dusk
        resize 1512x950
        goto hosts
        tab Hosts
        wait 500
        select edge-proxy-01
        wait 300
        goto hosts
        tab Keys
        wait 500
        select ops-ed25519
        wait 300
        goto hosts
        tab Snippets
        wait 500
        select Tail nginx errors
        wait 300
        goto hosts
        tab Hosts
        wait 300
        """
        let parsed = ReviewTourLab.parse(tour: roundTrip)
        check(parsed.errors.isEmpty, "the round trip's steps do not parse: \(parsed.errors)", &ok)
        let log = ReviewTourLab.run(steps: parsed.steps, shell: shell, window: window, outputDirectory: scratchDirectory)
        check(!log.contains { $0.contains("FAILED") }, "a round-trip step failed: \(log.filter { $0.contains("FAILED") })", &ok)
        shell.view.layoutSubtreeIfNeeded()
        // The deterministic half. Before the footer kept its own height, the
        // spare height had two equally cheap homes (the rows' stack and the
        // footer stack), and which one took it depended on the solver's
        // history. With the fix reverted, the frame check below passed three
        // runs in a row on one build of this suite and failed four in a row
        // on the next, whose only change was timing in an earlier case. The
        // ambiguity does not depend on history: both views were flagged on
        // every run without the fix, and neither with it.
        // (`CredentialVaultViewSelfTest` records a `HelmCard` tie this API did
        // not flag, so the frame check stays as well.)
        let footer = hosts.debugKeychainCard.superview
        check(footer?.hasAmbiguousLayout == false && !hosts.debugKeychainCard.hasAmbiguousLayout,
              "the Hosts column's footer has an ambiguous height, so the solver is free to give it the column's "
                + "spare height", &ok)
        let column = hosts.debugSidebar.convert(hosts.debugSidebar.bounds, to: nil)
        let user = hosts.debugUserRow.convert(hosts.debugUserRow.bounds, to: nil)
        let card = hosts.debugKeychainCard.convert(hosts.debugKeychainCard.bounds, to: nil)
        check(abs(user.minY - column.minY) <= 1 && abs(card.minY - (user.maxY + HelmMetrics.s2)) <= 1,
              "after a Hosts tab round trip the column's footer is not at its bottom: the keychain card sits "
                + "\(card.minY - column.minY)pt above the column's foot, its user row \(user.minY - column.minY)pt", &ok)
    }
}

#endif
