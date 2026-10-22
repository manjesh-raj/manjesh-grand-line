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
//   3. **Knowledge** has one tree beside Notebook, Runbooks, Postmortems and
//      Docs - not the Reading list - read from the stores, opening an item
//      through its page, with its own search; Notebook puts its column away.
//   4. **Crew › Needs you** is a real tab: the parked tasks and their open
//      decisions, with Reply, an honest summary, and the bell's and Home's
//      ways in.
//   5. **The floating bar is unchanged**: none of the above happens there.
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

        var allOK = true
        do {
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            ReviewTourLab.seedDemoHosts(shell.workspace)
            ReviewTourLab.seedDemoKnowledge(shell.workspace)
            settle(shell)
            for check in [checkConnectionsTables, checkTheInspectorKeepsTheWindow, checkPoneglyphTable,
                          checkAutomicVaultTables, checkKnowledgeTree, checkNeedsYou] {
                var ok = true
                check(shell, window, scratch, &ok)
                allOK = allOK && ok
            }
        }
        do {
            var ok = true
            checkTheFloatingBarIsUnchanged(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "PageRedesignsSelfTest: all checks passed" : "PageRedesignsSelfTest: FAILED")
        return allOK
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
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
        shell.show(.hosts)
        clickTab("Hosts", shell)
        let hosts = shell.workspace.hostsPanel
        check(hosts.drawsSidebarLayout, "Hosts did not switch to the sidebar layout's presentation", &ok)
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
        check(shell.inspector.hostedContentView === hosts.debugInspectorDetail,
              "the inspector is not showing the host's details", &ok)
        check(shell.inspector.debugTitle == "edge-proxy-01", "the inspector is titled \"\(shell.inspector.debugTitle)\"", &ok)
        let fields = hosts.debugInspectorDetail.debugFieldLabels
        for field in ["Environment", "Endpoint", "User", "Credential", "Group", "Tags", "On connect"] {
            check(fields.contains(field), "the host inspector has no \(field) (it has \(fields))", &ok)
        }
        let actions = hosts.debugInspectorDetail.debugActionButtons.map(\.title)
        check(actions == ["Connect", "Edit\u{2026}", "Duplicate\u{2026}", "Delete\u{2026}"],
              "the host inspector's actions are \(actions)", &ok)
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
            check(hosts.debugInspectorDetail.debugFieldLabels.contains("Fingerprint"),
                  "the key inspector has no fingerprint", &ok)
            keysTable.debugSelect(key: nil)
            settle(shell)
        } else {
            fail("the seeded key ops-ed25519 is missing", &ok)
        }
        clickTab("Snippets", shell)
        check(onScreen(hosts.debugSnippetsTable.card), "the snippet table is not on screen on Snippets", &ok)
        check(onScreen(hosts.debugExpansionStrip) && hosts.debugExpansionStrip.style == .strip,
              "the snippet expansion switch is not a strip over the Snippets table", &ok)
        check(hosts.debugSideStackIsHidden, "the floating bar's right column shows on Snippets in the sidebar layout", &ok)
        clickTab("Hosts", shell)
    }

    // MARK: 1b - the inspector never grows the window

    private static func checkTheInspectorKeepsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ scratch: URL, _ ok: inout Bool) {
        resize(window, width: 1100, shell)
        shell.show(.hosts)
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
        shell.show(.logAnalyzer)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector stayed open on Logs", &ok)
        check(shell.debugColumnMinimum == MainSplitShellController.contentMinimum,
              "the column's floor stayed at \(shell.debugColumnMinimum) off Hosts", &ok)
        check(abs(window.frame.width - 1100) < 0.5, "leaving Hosts grew the window to \(window.frame.width)pt", &ok)

        // The captain's choice holds: hidden from the toolbar, a new
        // selection does not reopen it until the button does.
        shell.show(.hosts)
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
        shell.show(.poneglyph)
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
        shell.show(.vault)
        settle(shell)
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

    private static func checkKnowledgeTree(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                           _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.show(.notebook)
        settle(shell)
        let tree = shell.knowledgeTree
        check(shell.debugLeadingColumn === tree.view && onScreen(tree.view),
              "the Knowledge tree is not beside Notebook", &ok)
        check(shell.workspace.notebook.splitPage?.pageForcesCollapse == true,
              "Notebook kept its own page column beside the Knowledge tree", &ok)
        tree.debugReadNow()
        settle(shell)
        let sections = tree.debugSections
        check(sections.map(\.title) == ["Notebook", "Runbooks", "Postmortems", "Docs"],
              "the tree's groups are \(sections.map(\.title))", &ok)
        let notebook = sections.first { $0.title == "Notebook" }?.children ?? []
        check(notebook.contains { $0.title == "Ideas" && $0.kind == .item }
                && notebook.contains { $0.title == "Team" && $0.kind == .folder && $0.children.count == 2 },
              "the Notebook group is \(notebook.map(\.title)), want Ideas and the Team folder of two", &ok)
        let runbooks = sections.first { $0.title == "Runbooks" }?.children.map(\.title) ?? []
        check(Set(runbooks) == ["Rotate a TLS certificate", "Fail over the database"], "the Runbooks group is \(runbooks)", &ok)
        let docs = sections.first { $0.title == "Docs" }?.children ?? []
        check(docs.count == 1 && docs[0].kind == .note && docs[0].title == "Not synced yet",
              "the Docs group says \(docs.map(\.title)) for a playbook that is not synced", &ok)
        check(tree.debugSelectedID?.hasPrefix("notebook:") == true,
              "the tree does not select the page Notebook has open (selected: \(String(describing: tree.debugSelectedID)))", &ok)

        // An item opens its tab and the item, through the page's own path.
        guard let runbook = shell.workspace.docsRunbookStore.listRunbooks().first(where: { $0.title == "Rotate a TLS certificate" })
        else {
            fail("the seeded runbook is missing", &ok)
            return
        }
        let itemID = KnowledgeTreeItem.runbookID(runbook.id)
        check(tree.debugOpen(id: itemID), "the tree has no row for the runbook", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .runbooks, "opening a runbook from the tree did not open Runbooks", &ok)
        check(shell.workspace.runbooks.knowledgeShowingItemID == itemID,
              "opening a runbook from the tree did not open it in the page's editor", &ok)
        check(shell.debugCurrentTab?.name == "Runbooks", "the toolbar does not light Runbooks after the tree opened one", &ok)
        check(shell.debugLeadingColumn === tree.view, "the tree left the column on Runbooks", &ok)

        // Its own search narrows to the matching items.
        tree.debugSetQuery("cert")
        let visible = tree.debugVisibleTitles
        check(visible.contains("Rotate a TLS certificate") && !visible.contains("Fail over the database"),
              "searching \"cert\" shows \(visible)", &ok)
        tree.debugSetQuery("")

        // The Reading list keeps its cards, with no tree.
        shell.show(.readingList)
        settle(shell)
        check(shell.debugLeadingColumn == nil, "the Knowledge tree shows beside the Reading list", &ok)
        shell.show(.docs)
        settle(shell)
        check(shell.debugLeadingColumn === tree.view, "the Knowledge tree is not beside Docs", &ok)
        shell.show(.homeCanvas)
        settle(shell)
        check(shell.debugLeadingColumn == nil, "the Knowledge tree stayed on Home", &ok)
    }

    // MARK: 4 - Crew › Needs you

    private static func checkNeedsYou(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                      _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        check(WorkspaceModule.crew.tabs.first?.name == "Needs you" && WorkspaceModule.crew.tabs.first?.route == .overview,
              "Crew's first tab is not the Fleet page's Needs you", &ok)
        shell.show(.overview)
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

        // Home's fleet row and the bell's entry land on Needs you.
        clickTab("In flight", shell)
        shell.show(.homeCanvas)
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
            shell.show(route)
            settle(shell)
        }
        let hosts = shell.workspace.hostsPanel
        shell.show(.hosts)
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
}

#endif
