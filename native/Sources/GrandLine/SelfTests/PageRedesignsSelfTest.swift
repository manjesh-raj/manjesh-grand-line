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
//      ways in.
//   5. **The floating bar is unchanged**: none of the above happens there.
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
                              checkAutomicVaultTables, checkKnowledgeHasNoTree, checkNeedsYou] {
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
        let tabs = shell.toolbar.debugTabs
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return false }
        tabs.selectedSegment = index
        _ = tabs.sendAction(tabs.action, to: tabs.target)
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
        // Return is the captain's own request, so it holds the inspector open
        // (its empty state stays when the selection clears). Back to the
        // launch state, so the lock below measures an inspector its
        // selection opened.
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
        check(onScreen(secrets.card) && onScreen(vault.debugToolsTable.card), "Automic Vault's tables are not on screen", &ok)
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
        check(fleet.debugNeedsYouSummary.hasPrefix("1 task is waiting on you, with 1 open decision."),
              "the summary reads \"\(fleet.debugNeedsYouSummary)\"", &ok)
        check(!fleet.debugNeedsYouEmptyShowing, "Nothing needs you shows beside a parked task", &ok)
        check(fleet.debugNeedsRowCount == 1, "Needs you lists \(fleet.debugNeedsRowCount) rows for one parked task", &ok)
        if let reply = fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID) {
            reply.performClick(nil)
            settle(shell)
            check(fleet.debugOpenReplyTaskID == ReviewTourLab.demoDecisionTaskID && fleet.debugComposerFollowsItsRow(taskID: ReviewTourLab.demoDecisionTaskID),
                  "Reply on Needs you did not open its composer under the row", &ok)
            fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID)?.performClick(nil)
            settle(shell)
        } else {
            fail("Needs you's row has no Reply", &ok)
        }

        // In flight no longer carries the list; its banner still counts it.
        clickTab("In flight", shell)
        check(!fleet.debugNeedsYouShowing && !onScreen(fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID)),
              "In flight still shows the Needs your call list", &ok)

        // Nothing waiting is said plainly, with when it was checked.
        let quiet = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [], queuedCount: 0, doneCount: 0,
                                  projectsCount: 0, watcher: WatcherHealth(status: "healthy"))
        fleet.debugRender(snapshot: quiet, mergedPRs: [])
        clickTab("Needs you", shell)
        check(fleet.debugNeedsYouEmptyShowing && fleet.debugNeedsYouSummary.hasPrefix("Checked at"),
              "with nothing parked Needs you says \"\(fleet.debugNeedsYouSummary)\" and the empty state is "
                + (fleet.debugNeedsYouEmptyShowing ? "shown" : "hidden"), &ok)

        // A read that fails keeps the last good list and says when it was
        // read (GL-14). Needs you never says nothing is waiting over a failed
        // read, and a task it cannot read this time stays listed with its age.
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
        check(fleet.debugNeedsRowCount == 1 && fleet.debugNeedsYouSummary.hasPrefix("1 task is waiting on you"),
              "a parked task reads \(fleet.debugNeedsRowCount) rows and \"\(fleet.debugNeedsYouSummary)\"", &ok)
        fleet.debugRender(snapshot: reading([], listRead: false), mergedPRs: [])
        settle(shell)
        let failed = fleet.debugNeedsYouSummary
        check(fleet.debugNeedsRowCount == 1 && !fleet.debugNeedsYouEmptyShowing
                && failed.hasPrefix("Couldn\u{2019}t read the crew\u{2019}s state at") && failed.contains("Showing what was read at"),
              "after a failed read Needs you lists \(fleet.debugNeedsRowCount) rows and says \"\(failed)\"", &ok)
        var unread = parked
        unread.state = "unknown"
        unread.source = "none"
        unread.status = "unknown"
        fleet.debugRender(snapshot: reading([unread]), mergedPRs: [])
        settle(shell)
        check(fleet.debugNeedsRowCount == 1 && fleet.debugNeedsYouSummary.contains("could not be read just now"),
              "a parked task whose state could not be read reads \(fleet.debugNeedsRowCount) rows and "
                + "\"\(fleet.debugNeedsYouSummary)\"", &ok)
        var working = parked
        working.state = "working"
        working.status = "working"
        fleet.debugRender(snapshot: reading([working]), mergedPRs: [])
        settle(shell)
        check(fleet.debugNeedsRowCount == 0 && fleet.debugNeedsYouEmptyShowing,
              "a task that went back to work is still on Needs you", &ok)
        fleet.debugRender(snapshot: reading([], listRead: false), mergedPRs: [])
        settle(shell)
        check(!fleet.debugNeedsYouEmptyShowing
                && fleet.debugNeedsYouSummary.contains("Nothing was waiting on you when it was last read"),
              "a failed read after an empty one says \"\(fleet.debugNeedsYouSummary)\" with the empty state "
                + (fleet.debugNeedsYouEmptyShowing ? "shown" : "hidden"), &ok)

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
