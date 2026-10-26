// Grand Line - native macOS app.
//
// The Termius-style Hosts and Keys work (PR 1 of 3 of the captain's plan),
// mounted in a real off-screen sidebar shell with the tour lab's demo hosts
// and driven through the pages' own controls.
//
//   - X4: the tag chips match any selected tag, or all of them.
//   - H9: the tag chips never run off the filter row; what does not fit is
//     behind a "+N" chip whose menu toggles the same filter.
//   - H3: the find-or-connect bar - its words, and a Connect button that
//     lights up for one host or a typed user@host and runs what Return runs.
//   - H8 and K2: Add Host and New Key are `HelmSplitButton`s in the toolbar,
//     each menu item opening the form it names.
//   - H1, H2, H4, H5, H7 and X2: the hosts as cards by default, a Grid / List
//     switch with one selection between them, a double click that connects,
//     the bolt and pencil on every card, the grid reflowing as the inspector
//     opens at 1512, 1100 and 1100.5 on the pixel grid, the keyboard, the
//     Larger text scale, and the recent row with "last connected".
//   - K1, K3, K4 and K6: the keys as cards, key search, what a key card says,
//     and Touch ID's chip in the Keys row.
//   - H6, H10 and H11: a host is edited in the side panel - no pop-up - with
//     Connect at its foot until something changes, then Cancel and Save
//     Changes; Return saves and Esc cancels; a new host is an empty form
//     there; and leaving unsaved changes asks Save, Discard or Cancel.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
// The arithmetic is asserted headless in `ConnectionsLogicSelfTest`.
//
// Run with:
//   swift build && FM_RUN_CONNECTIONS_CARDS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConnectionsCardsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("connections-cards-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            ReviewTourLab.seedDemoHosts(shell.workspace)
            settle(shell)
            for check in [checkTagMatch, checkTagOverflow, checkFindOrConnect, checkSplitButtons, checkKeyCards,
                          checkHostCards, checkHostCardKeyboard, checkGridReflow, checkRecentHosts,
                          checkHostPanel, checkNewHostPanel, checkUnsavedChanges] {
                var ok = true
                check(shell, window, &ok)
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "ConnectionsCardsSelfTest: all checks passed" : "ConnectionsCardsSelfTest: FAILED")
        return allOK
    }

    // MARK: Harness

    static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    /// Connections › Hosts, showing, with every filter cleared.
    @discardableResult
    static func showHosts(_ shell: MainSplitShellController) -> HostsController {
        shell.workspace.navigator.show(.hosts)
        let hosts = shell.workspace.hostsPanel
        hosts.selectModuleTab(named: "Hosts")
        settle(shell)
        return hosts
    }

    /// Toggle a tag chip through its own target and action.
    static func clickTag(_ tag: String, _ hosts: HostsController) {
        hosts.debugTagChip(tag)?.performClick(nil)
    }

    // MARK: X4

    private static func checkTagMatch(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let control = hosts.debugTagMatchControl
        check(control.isHidden, "X4: the any/all switch shows with no tag selected", &ok)

        clickTag("staging", hosts)
        settle(shell)
        check(control.isHidden, "X4: the any/all switch shows with one tag selected, where it changes nothing", &ok)
        clickTag("db", hosts)
        settle(shell)
        check(!control.isHidden && control.window != nil, "X4: the any/all switch is hidden with two tags selected", &ok)

        control.debugClickTab(id: HostsController.tagMatchAnyID)
        let any = hosts.debugFilteredHostLabels()
        control.debugClickTab(id: HostsController.tagMatchAllID)
        let all = hosts.debugFilteredHostLabels()
        // The fixture's own discriminating power: two hosts carry staging,
        // one of them db as well.
        check(any.count == 2 && any != all, "X4: the fixture cannot tell any from all (\(any) / \(all))", &ok)
        check(Set(any) == ["bastion-stg", "db-replica-eu"], "X4: any of staging and db lists \(any)", &ok)
        check(all == ["db-replica-eu"], "X4: all of staging and db lists \(all)", &ok)
        check(AppSettings.shared.hostTagMatchAll, "X4: choosing All was not remembered", &ok)

        control.debugClickTab(id: HostsController.tagMatchAnyID)
        check(!AppSettings.shared.hostTagMatchAll, "X4: choosing Any was not remembered", &ok)
        clickTag("staging", hosts)
        clickTag("db", hosts)
        settle(shell)
        check(hosts.debugFilteredHostLabels().count == shell.workspace.hostStore.hosts.count,
              "X4: clearing the tags did not bring every host back", &ok)
    }

    // MARK: Real events

    /// A real mouse click at `point` (window coordinates): AppKit's own hit
    /// test picks the view, and that view's `mouseDown` runs - a button's
    /// tracking loop finds the mouse-up already queued
    /// (`BarActiveStateSelfTest.pressAndRelease`'s shape).
    @discardableResult
    static func realClick(at point: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSView? {
        let app = NSApplication.shared
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clickCount,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let root = window.contentView?.superview, let hit = root.hitTest(point),
              let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return nil }
        app.postEvent(up, atStart: true)
        hit.mouseDown(with: down)
        while app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) != nil {}
        return hit
    }

    static func centre(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// A point on a card clear of its icon buttons: over its tile.
    static func cardBody(_ card: NSView) -> NSPoint {
        card.convert(NSPoint(x: 26, y: card.bounds.midY), to: nil)
    }

    // MARK: H1, H2, H4, H5

    private static func checkHostCards(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let grid = hosts.hostsGrid
        // C4: Grid is the default. This suite's preference domain is its own
        // (`AppDefaults.store`), so nothing stored it before this point.
        check(!grid.isHiddenOrHasHiddenAncestor && grid.window != nil, "C4: the host cards are not showing by default", &ok)
        check(hosts.hostsTable.card.isHidden, "C4: the host table shows beside the cards", &ok)
        let keys = grid.debugPlaced.map(\.key)
        check(keys.first == HostsController.firstmateRowKey, "H1: the Firstmate card is not first (\(keys.prefix(2)))", &ok)
        check(Set(keys.dropFirst()) == Set(shell.workspace.hostStore.hosts.map(\.id.uuidString)),
              "H1: the cards are not every saved host", &ok)
        check(grid.debugSectionTitles == ["Observability", "Production", "Staging", "Ungrouped"],
              "H1: the cards are grouped as \(grid.debugSectionTitles)", &ok)
        guard let edge = shell.workspace.hostStore.hosts.first(where: { $0.label == "edge-proxy-01" }),
              let bastion = shell.workspace.hostStore.hosts.first(where: { $0.label == "bastion-stg" }),
              let edgeCard = grid.debugCardView(key: edge.id.uuidString),
              let bastionCard = grid.debugCardView(key: bastion.id.uuidString) else {
            fail("H1: the demo hosts' cards are missing", &ok)
            return
        }
        check(edgeCard.debugTitle == "edge-proxy-01" && edgeCard.debugSubtitle == edge.subtitle,
              "H1: a card reads \(edgeCard.debugTitle) / \(edgeCard.debugSubtitle)", &ok)
        check(bastionCard.debugSubtitle == "ops@bastion.stg.example.test:2222", "H1: a non-default port is missing from \(bastionCard.debugSubtitle)", &ok)
        // Accessibility: one button per card that says what it is, with its
        // icon buttons reachable as its children.
        check(edgeCard.accessibilityRole() == .button, "H1: a card is not a button to VoiceOver", &ok)
        let spoken = edgeCard.accessibilityLabel() ?? ""
        check(spoken.contains("edge-proxy-01") && spoken.contains(edge.subtitle) && spoken.contains("Production"),
              "H1: a card reads \"\(spoken)\" to VoiceOver", &ok)
        let children = (edgeCard.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() }
        check(children == ["Connect to edge-proxy-01", "Edit edge-proxy-01"], "H5: the card's icon buttons read \(children)", &ok)

        // H5 / C5: always there, quiet at rest.
        let buttons = bastionCard.debugActionButtons
        check(buttons.count == 2 && buttons.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && $0.tint == nil },
              "C5: a resting card's bolt and pencil are not both visible at low emphasis", &ok)

        var connects: [UUID?] = []
        var edits: [Host?] = []
        let savedConnect = hosts.onConnect, savedEdit = hosts.onAddOrEdit
        hosts.onConnect = { id, _, _, _, _, _ in connects.append(id) }
        hosts.onAddOrEdit = { edits.append($0) }
        defer { hosts.onConnect = savedConnect; hosts.onAddOrEdit = savedEdit }

        // H4: one real click selects and connects nothing; two connect.
        realClick(at: cardBody(edgeCard), in: window, clickCount: 1)
        settle(shell)
        check(grid.selectedKey == edge.id.uuidString, "H4: a click did not select the card", &ok)
        check(connects.isEmpty, "H4: a single click connected", &ok)
        check(shell.inspector.debugTitle == "edge-proxy-01", "H1: the inspector shows \(shell.inspector.debugTitle)", &ok)
        check(hosts.hostsTable.selectedKey == edge.id.uuidString, "H2: the table did not follow the card's selection", &ok)
        check(edgeCard.debugActionButtons.allSatisfy { $0.tint == .accent }, "C5: a selected card's icons are not at full strength", &ok)
        realClick(at: cardBody(edgeCard), in: window, clickCount: 2)
        check(connects == [edge.id], "H4: a double click connected \(connects)", &ok)

        // H5: the bolt and the pencil, by real clicks.
        connects.removeAll()
        let bolt = realClick(at: centre(of: buttons[0]), in: window)
        check(bolt === buttons[0], "H5: a click on the bolt reached \(String(describing: bolt))", &ok)
        check(connects == [bastion.id], "H5: the bolt connected \(connects)", &ok)
        realClick(at: centre(of: buttons[1]), in: window)
        settle(shell)
        // H6: the pencil edits in the side panel, never a window.
        check(edits.isEmpty && hosts.hostPanelKey == bastion.id.uuidString && shell.inspector.debugTitle == "bastion-stg",
              "H5: the pencil did not open bastion-stg's form in the panel", &ok)

        grid.select(key: edge.id.uuidString)
        settle(shell)
        // H2: List, with the selection carried over, and back.
        hosts.hostsViewModeControl.debugClickTab(id: HostsController.listModeID)
        settle(shell)
        check(!hosts.hostsTable.card.isHidden && grid.isHidden, "H2: List did not swap the cards for the table", &ok)
        check(AppSettings.shared.connectionsShowList, "H2: List was not remembered", &ok)
        check(hosts.hostsTable.selectedKey == edge.id.uuidString && shell.inspector.debugTitle == "edge-proxy-01",
              "H2: the selection did not survive the switch to List", &ok)
        hosts.hostsViewModeControl.debugClickTab(id: HostsController.gridModeID)
        settle(shell)
        check(hosts.hostsTable.card.isHidden && !grid.isHidden && !AppSettings.shared.connectionsShowList,
              "H2: Grid did not come back", &ok)
    }

    private static func checkHostCardKeyboard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let grid = hosts.hostsGrid
        let store = shell.workspace.hostStore
        guard let edge = store.hosts.first(where: { $0.label == "edge-proxy-01" }),
              let card = grid.debugCardView(key: edge.id.uuidString) else {
            fail("keyboard: edge-proxy-01's card is missing", &ok)
            return
        }
        var connects: [UUID?] = []
        var edits: [Host?] = []
        let savedConnect = hosts.onConnect, savedEdit = hosts.onAddOrEdit
        hosts.onConnect = { id, _, _, _, _, _ in connects.append(id) }
        hosts.onAddOrEdit = { edits.append($0) }
        var confirms: [String] = []
        HelmConfirm.responderForTests = { request in confirms.append(request.title); return .cancel }
        defer {
            hosts.onConnect = savedConnect
            hosts.onAddOrEdit = savedEdit
            HelmConfirm.responderForTests = nil
        }
        window.makeFirstResponder(card)
        check(grid.selectedKey == edge.id.uuidString, "keyboard: focusing a card did not select it", &ok)
        card.debugKey(124)
        let right = grid.debugPlaced.firstIndex { $0.key == edge.id.uuidString }.map { grid.debugPlaced[$0 + 1].key }
        check(grid.selectedKey == right, "keyboard: Right did not move to the next card", &ok)
        (window.firstResponder as? HelmGridCardView)?.debugKey(123)
        check(grid.selectedKey == edge.id.uuidString, "keyboard: Left did not come back", &ok)
        card.debugKey(125)
        let below = grid.debugPlaced.first { $0.key == grid.selectedKey }?.frame
        let here = grid.debugPlaced.first { $0.key == edge.id.uuidString }?.frame
        check(below.map { $0.minY > (here?.minY ?? 0) && abs($0.midX - (here?.midX ?? -1)) < 1 } == true,
              "keyboard: Down did not move to the card below", &ok)
        window.makeFirstResponder(card)
        card.debugKey(36, characters: "\r")
        check(connects == [edge.id], "keyboard: Return connected \(connects)", &ok)
        shell.setInspectorShown(false)
        settle(shell)
        card.debugKey(49, characters: " ")
        settle(shell)
        check(!shell.debugInspectorIsCollapsed && shell.inspector.debugTitle == "edge-proxy-01",
              "keyboard: Space did not open the details", &ok)
        card.debugKey(14, characters: "e", modifiers: .command)
        settle(shell)
        check(edits.isEmpty && hosts.hostPanelKey == edge.id.uuidString && hosts.hostPanel != nil,
              "keyboard: ⌘E did not edit in the panel", &ok)
        card.debugKey(51, characters: "\u{7f}")
        check(confirms.last?.contains("edge-proxy-01") == true && store.host(id: edge.id) != nil,
              "keyboard: Delete did not ask first (\(confirms))", &ok)

        // The Larger text scale: taller cards, and a truncated address keeps
        // its whole self in the tooltip.
        let baseHeight = card.frame.height
        ChromeTextScale.shared.setScale(ChromeTextScale.maxScale)
        settle(shell)
        let scaled = grid.debugCardView(key: edge.id.uuidString)
        check((scaled?.frame.height ?? 0) > baseHeight + 1, "Larger text: the card stayed \(baseHeight)pt", &ok)
        check(scaled?.debugSubtitleLabel.toolTip == edge.subtitle, "Larger text: the address has no tooltip", &ok)
        let fits = grid.debugPlaced.allSatisfy { $0.frame.maxX <= grid.debugScroll.contentSize.width + 0.5 }
        check(fits, "Larger text: a card runs past the column", &ok)
        ChromeTextScale.shared.setScale(ChromeTextScale.minScale)
        settle(shell)
    }

    // MARK: H7

    private static func checkGridReflow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let hosts = showHosts(shell)
        let grid = hosts.hostsGrid
        let scale = window.backingScaleFactor
        func checkGeometry(_ label: String) {
            let width = grid.debugScroll.contentSize.width
            let frames = grid.debugPlaced.map(\.frame)
            check(!frames.isEmpty, "H7 \(label): no cards were laid out", &ok)
            check(frames.allSatisfy { $0.minX >= -0.01 && $0.maxX <= width + 0.01 },
                  "H7 \(label): a card runs past the \(width)pt column", &ok)
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] where a.insetBy(dx: 0.5, dy: 0.5).intersects(b) {
                    fail("H7 \(label): two cards overlap (\(a), \(b))", &ok)
                }
            }
            let aligned = frames.allSatisfy { f in
                [f.minX, f.minY, f.width].allSatisfy { abs(HelmCardGrid.pixelAligned($0, scale: scale) - $0) < 0.001 }
            }
            check(aligned, "H7 \(label): a card sits off the \(scale)x pixel grid", &ok)
        }
        for width: CGFloat in [1512, 1100, 1100.5] {
            resize(window, width: width, shell)
            shell.setInspectorShown(false)
            settle(shell)
            let closed = grid.columnCount
            checkGeometry("at \(width), inspector closed")
            guard let first = shell.workspace.hostStore.hosts.first else { return }
            grid.select(key: first.id.uuidString)
            shell.setInspectorShown(true)
            settle(shell)
            checkGeometry("at \(width), inspector open")
            check(!shell.debugInspectorIsCollapsed, "H7 at \(width): the inspector did not open", &ok)
            // The grid follows the column it is given. At 1512 opening the
            // inspector narrows it; at 1100 the shell puts its own sidebar
            // away to make room, so the column barely changes - either way
            // the count is the one the column's real width calls for.
            let open = grid.columnCount
            check(open == HelmCardGrid.plan(width: grid.debugScroll.contentSize.width).columns,
                  "H7 at \(width): \(open) columns in a \(grid.debugScroll.contentSize.width)pt column", &ok)
            if width == 1512 {
                check(open < closed, "H7 at 1512: the grid kept \(closed) columns with the inspector open", &ok)
            }
        }
        resize(window, width: 1512, shell)
    }

    // MARK: H6

    /// Selects `label`'s card through the grid, and returns the host.
    @discardableResult
    static func selectHost(_ label: String, _ hosts: HostsController, _ shell: MainSplitShellController) -> Host? {
        guard let host = shell.workspace.hostStore.hosts.first(where: { $0.label == label }) else { return nil }
        hosts.hostsGrid.select(key: host.id.uuidString)
        settle(shell)
        return host
    }

    private static func checkHostPanel(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let store = shell.workspace.hostStore
        var windowsOpened = 0
        let savedEdit = hosts.onAddOrEdit
        hosts.onAddOrEdit = { _ in windowsOpened += 1 }
        var problems: [String] = []
        HelmConfirm.responderForTests = { request in problems.append(request.title); return .confirm }
        defer { hosts.onAddOrEdit = savedEdit; HelmConfirm.responderForTests = nil }

        guard let edge = selectHost("edge-proxy-01", hosts, shell), let panel = hosts.hostPanel else {
            fail("H6: selecting a host shows no form in the panel", &ok)
            return
        }
        check(shell.inspector.hostedContentView === panel.view && shell.inspector.debugTitle == "edge-proxy-01",
              "H6: the inspector shows \(shell.inspector.debugTitle), not the host's form", &ok)
        check(panel.presentation == .panel && (panel.view as? HelmFormSheet)?.chrome == .panel,
              "H6: the panel's form is not the panel chrome", &ok)
        check(panel.debugFooterTitles == ["Connect", "More actions"], "H6: a clean form's footer is \(panel.debugFooterTitles)", &ok)
        check(panel.debugPanelMenuTitles == ["Duplicate\u{2026}", "Delete\u{2026}"], "H6: the panel's menu is \(panel.debugPanelMenuTitles)", &ok)
        check(panel.debugAdvancedShown && !panel.debugAdvancedRowsHidden,
              "H6: Advanced is collapsed for a host with a startup snippet", &ok)

        // H5's pencil: the form, the keyboard in its name, and no window.
        if let card = hosts.hostsGrid.debugCardView(key: edge.id.uuidString), card.debugActionButtons.count == 2 {
            realClick(at: centre(of: card.debugActionButtons[1]), in: window)
            settle(shell)
        }
        let responder = window.firstResponder
        let editing = responder === panel.debugLabelField
            || ((responder as? NSText)?.delegate as? NSTextField) === panel.debugLabelField
        check(editing, "H5: the pencil did not put the keyboard in the host's name (\(String(describing: responder)))", &ok)
        check(windowsOpened == 0, "H6: editing opened \(windowsOpened) editor window(s)", &ok)

        // C1: a change brings Cancel and Save Changes; Return saves.
        panel.debugType("edge-01b.example.test", into: panel.debugAddressField)
        check(panel.debugIsDirty && panel.debugFooterTitles == ["Cancel", "Save Changes"],
              "C1: an edited form's footer is \(panel.debugFooterTitles)", &ok)
        // A connect stamps the record while the form is open; the save keeps it.
        store.recordConnection(id: edge.id, at: Date(timeIntervalSinceReferenceDate: 800_000_200))
        settle(shell)
        check(hosts.hostPanel === panel && panel.debugIsDirty, "H6: a store change under the form threw its edits away", &ok)
        check(panel.debugCommand(#selector(NSResponder.insertNewline(_:)), in: panel.debugUsernameField),
              "C1: Return in a field did not save", &ok)
        settle(shell)
        let saved = store.host(id: edge.id)
        check(saved?.address == "edge-01b.example.test", "C1: Return saved \(saved?.address ?? "nothing")", &ok)
        check(saved?.lastConnectedAt == Date(timeIntervalSinceReferenceDate: 800_000_200),
              "H6: the save dropped the connect's lastConnectedAt", &ok)
        let after = hosts.hostPanel
        check(after?.debugIsDirty == false && after?.debugFooterTitles == ["Connect", "More actions"],
              "C1: after a save the footer is \(after?.debugFooterTitles ?? [])", &ok)

        // Esc puts the stored host back.
        guard let current = hosts.hostPanel else { return }
        current.debugType("9999", into: current.debugPortField)
        check(current.debugIsDirty, "C1: changing the port did not mark the form changed", &ok)
        check(current.debugCommand(#selector(NSResponder.cancelOperation(_:)), in: current.debugPortField),
              "C1: Esc did not cancel", &ok)
        settle(shell)
        check(store.host(id: edge.id)?.port == 22 && hosts.hostPanel?.debugPortField.stringValue == "22"
                && hosts.hostPanel?.debugIsDirty == false,
              "C1: Esc did not put the stored port back", &ok)

        // GL-08 still refuses a leading dash, and the form keeps its edit.
        guard let guarded = hosts.hostPanel else { return }
        guarded.debugType("-oProxyCommand=touch /tmp/x", into: guarded.debugAddressField)
        problems.removeAll()
        guarded.debugCommand(#selector(NSResponder.insertNewline(_:)), in: guarded.debugAddressField)
        check(problems.first?.contains("Address can't start with") == true, "GL-08: the panel saved a leading dash (\(problems))", &ok)
        check(store.host(id: edge.id)?.address == "edge-01b.example.test" && guarded.debugIsDirty,
              "GL-08: a refused save changed the store or lost the edit", &ok)
        guarded.debugCommand(#selector(NSResponder.cancelOperation(_:)), in: guarded.debugAddressField)
        settle(shell)

        // Advanced is collapsed unless used, and inline forwards save.
        guard let lab = selectHost("lab-box", hosts, shell), let labPanel = hosts.hostPanel else { return }
        check(!labPanel.debugAdvancedShown && labPanel.debugAdvancedRowsHidden, "H6: Advanced is open for a host that uses none of it", &ok)
        labPanel.debugAdvancedToggle.performClick(nil)
        check(labPanel.debugAdvancedShown && !labPanel.debugAdvancedRowsHidden, "H6: Show did not open Advanced", &ok)
        guard let forwards = labPanel.debugInlineForwards else {
            fail("H6: the panel has no inline port forwards", &ok)
            return
        }
        forwards.debugAddButton.performClick(nil)
        guard let row = forwards.debugRows.last else { return fail("H6: Add Forward added no rule", &ok) }
        row.listenField.stringValue = "127.0.0.1:9000"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        row.destinationField.stringValue = "localhost:90"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(labPanel.debugIsDirty, "H6: adding a forward did not mark the form changed", &ok)
        check(labPanel.savePanel(), "H6: the forward did not save", &ok)
        settle(shell)
        let rule = store.host(id: lab.id)?.portForwards.first
        check(rule?.bindAddress == "127.0.0.1" && rule?.listenPort == 9000 && rule?.destHost == "localhost" && rule?.destPort == 90,
              "H6: the inline forward saved as \(String(describing: rule))", &ok)
        check(windowsOpened == 0, "H6: \(windowsOpened) editor window(s) opened", &ok)
    }

    // MARK: H10

    private static func checkNewHostPanel(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let store = shell.workspace.hostStore
        var windowsOpened = 0
        let savedEdit = hosts.onAddOrEdit
        hosts.onAddOrEdit = { _ in windowsOpened += 1 }
        defer { hosts.onAddOrEdit = savedEdit }
        let before = store.hosts.count
        hosts.debugAddHostSplit.mainButton.performClick(nil)
        settle(shell)
        guard let panel = hosts.hostPanel, hosts.hostPanelKey == HostsController.newHostPanelKey else {
            fail("H10: Add Host did not open a new host's form in the panel", &ok)
            return
        }
        check(windowsOpened == 0, "H10: Add Host opened a window", &ok)
        check(!shell.debugInspectorIsCollapsed && shell.inspector.debugTitle == "New Host" && shell.inspector.hostedContentView === panel.view,
              "H10: the panel shows \(shell.inspector.debugTitle)", &ok)
        check(hosts.hostsGrid.selectedKey == nil, "H10: a card stays selected beside a new host's form", &ok)
        check(panel.debugFooterTitles == ["Cancel", "Create Host"], "H10: a new host's footer is \(panel.debugFooterTitles)", &ok)
        check(panel.debugLabelField.stringValue.isEmpty && panel.debugAddressField.stringValue.isEmpty,
              "H10: the new host's form is not empty", &ok)
        panel.debugType("scratch-box", into: panel.debugLabelField)
        panel.debugType("scratch.example.test", into: panel.debugAddressField)
        panel.debugFooterButtons.last?.performClick(nil)
        settle(shell)
        guard let created = store.hosts.first(where: { $0.label == "scratch-box" }) else {
            fail("H10: Create Host saved nothing (\(store.hosts.count) hosts, \(before) before)", &ok)
            return
        }
        check(store.hosts.count == before + 1, "H10: Create Host added \(store.hosts.count - before) hosts", &ok)
        check(hosts.hostsGrid.selectedKey == created.id.uuidString && shell.inspector.debugTitle == "scratch-box"
                && hosts.hostPanel?.debugFooterTitles == ["Connect", "More actions"],
              "H10: after Create the panel shows \(shell.inspector.debugTitle)", &ok)
        // A new host's Cancel closes its form, and saves nothing.
        hosts.newHost()
        settle(shell)
        hosts.hostPanel?.debugType("never-saved", into: hosts.hostPanel!.debugLabelField)
        hosts.hostPanel?.debugFooterButtons.first?.performClick(nil)
        settle(shell)
        check(hosts.hostPanel == nil && !store.hosts.contains { $0.label == "never-saved" },
              "H10: Cancel on a new host left a form or saved it", &ok)
        store.delete(id: created.id)
        settle(shell)
    }

    // MARK: H11

    private static func checkUnsavedChanges(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let store = shell.workspace.hostStore
        var answer = HelmConfirm.Response.cancel
        var asked: [String] = []
        HelmConfirm.responderForTests = { request in asked.append(request.title); return answer }
        defer { HelmConfirm.responderForTests = nil }
        guard let edge = selectHost("edge-proxy-02", hosts, shell),
              let bastion = store.hosts.first(where: { $0.label == "bastion-stg" }),
              let bastionCard = hosts.hostsGrid.debugCardView(key: bastion.id.uuidString),
              let panel = hosts.hostPanel else {
            fail("H11: the fixture hosts are missing", &ok)
            return
        }
        panel.debugType("ops2", into: panel.debugUsernameField)

        // Cancel: nothing moves, nothing is lost.
        answer = .cancel
        realClick(at: cardBody(bastionCard), in: window)
        settle(shell)
        check(asked.last == "Save changes to \u{201C}edge-proxy-02\u{201D}?", "H11: moving away asked \(asked)", &ok)
        check(hosts.hostsGrid.selectedKey == edge.id.uuidString && hosts.hostsTable.selectedKey == edge.id.uuidString,
              "H11: Cancel still moved the selection", &ok)
        check(hosts.hostPanel === panel && panel.debugIsDirty && panel.debugUsernameField.stringValue == "ops2",
              "H11: Cancel lost the edit", &ok)

        // Closing the panel asks too, and Cancel keeps it open.
        shell.setInspectorShown(false)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed && panel.debugIsDirty, "H11: closing the panel did not ask, or lost the edit", &ok)

        // Discard: it moves, and the store never saw the edit.
        answer = .extra
        realClick(at: cardBody(bastionCard), in: window)
        settle(shell)
        check(hosts.hostsGrid.selectedKey == bastion.id.uuidString && store.host(id: edge.id)?.username == "ops",
              "H11: Discard did not move, or saved the edit", &ok)

        // Save: the edit is kept and then it moves.
        guard let bastionPanel = hosts.hostPanel else { return }
        bastionPanel.debugType("deploy", into: bastionPanel.debugUsernameField)
        answer = .confirm
        hosts.hostsGrid.select(key: edge.id.uuidString)
        settle(shell)
        check(store.host(id: bastion.id)?.username == "deploy" && hosts.hostsGrid.selectedKey == edge.id.uuidString,
              "H11: Save did not save before moving", &ok)
        // Starting a new host is moving away too.
        hosts.hostPanel?.debugType("ops3", into: hosts.hostPanel!.debugUsernameField)
        answer = .cancel
        hosts.newHost()
        settle(shell)
        check(hosts.hostPanelKey == edge.id.uuidString && hosts.hostPanel?.debugIsDirty == true,
              "H11: Add Host over unsaved changes did not ask", &ok)
        answer = .extra
        hosts.hostPanel?.cancelPanel()
        settle(shell)
        var restored = bastion
        restored.username = "ops"
        store.update(restored)
        settle(shell)
    }

    // MARK: K1, K3, K4, K6

    private static func checkKeyCards(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        hosts.selectModuleTab(named: "Keys")
        settle(shell)
        defer { hosts.selectModuleTab(named: "Hosts"); settle(shell) }
        let grid = hosts.keysGrid
        let keys = shell.workspace.keyStore.keys
        guard let ops = keys.first(where: { $0.label == "ops-ed25519" }),
              let ci = keys.first(where: { $0.label == "ci-deploy" }) else {
            fail("K1: the demo keys are missing", &ok)
            return
        }
        check(!grid.isHiddenOrHasHiddenAncestor && grid.window != nil && hosts.keysTable.card.isHidden,
              "K1: the keys are not cards by default", &ok)
        check(Set(grid.debugPlaced.map(\.key)) == Set(keys.map(\.id.uuidString)), "K1: the cards are not every saved key", &ok)

        // K4: what a card says.
        guard let opsCard = grid.debugCardView(key: ops.id.uuidString),
              let ciCard = grid.debugCardView(key: ci.id.uuidString) else {
            fail("K1: a key's card is missing", &ok)
            return
        }
        check(opsCard.debugSubtitle.hasPrefix("Ed25519 \u{00B7} SHA256:") && opsCard.debugSubtitle.count < ops.fingerprint.count + 10,
              "K4: the card's subtitle is \(opsCard.debugSubtitle)", &ok)
        let opsUsers = shell.workspace.hostStore.hosts.filter { $0.keyID == ops.id }.count
        let opsBadges = opsCard.debugBadgeTexts
        check(opsBadges.contains { $0.hasPrefix("Used by") && $0.contains("edge-proxy-01") }, "K4: no hosts-using badge on ops (\(opsBadges))", &ok)
        check(opsBadges.contains("Passphrase in the Keychain") && !ciCard.debugBadgeTexts.contains("Passphrase in the Keychain"),
              "K4: the passphrase lock is on the wrong cards", &ok)
        check(opsBadges.contains("Not used to connect yet"), "K4: a key never used does not say so (\(opsBadges))", &ok)
        check((opsCard.accessibilityLabel() ?? "").contains("used by \(opsUsers) hosts"), "K4: VoiceOver reads \(opsCard.accessibilityLabel() ?? "")", &ok)
        shell.workspace.keyStore.recordUse(id: ci.id)
        settle(shell)
        let used = grid.debugCardView(key: ci.id.uuidString)?.debugBadgeTexts ?? []
        check(used.contains { $0.hasPrefix("Last used") }, "K4/K5: a key used just now does not say so (\(used))", &ok)
        var certified = ci
        certified.certificate = "ssh-ed25519-cert-v01@openssh.com AAAAexample fixture"
        shell.workspace.keyStore.update(certified)
        settle(shell)
        check(grid.debugCardView(key: ci.id.uuidString)?.debugBadgeTexts.contains("Has a certificate") == true,
              "K4: a key with a certificate has no seal", &ok)

        // K3: search, by name, type or fingerprint - the cards and the table.
        func search(_ text: String) -> [String] {
            hosts.keySearchField.stringValue = text
            hosts.keySearchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            settle(shell)
            return grid.debugPlaced.compactMap { placed in keys.first { $0.id.uuidString == placed.key }?.label }
        }
        check(search("ci-") == ["ci-deploy"], "K3: searching a name found \(search("ci-"))", &ok)
        check(Set(search("ed25519")) == ["ops-ed25519", "ci-deploy"], "K3: searching a type did not find both keys", &ok)
        check(search("demo0nlyc1") == ["ci-deploy"], "K3: searching a fingerprint found \(search("demo0nlyc1"))", &ok)
        check(hosts.keysTable.debugRows.compactMap(\.key) == [ci.id.uuidString], "K3: the table did not follow the search", &ok)
        check(search("nothing-like-this").isEmpty && grid.debugEmptyState != nil, "K3: no match draws no empty state", &ok)
        _ = search("")

        // K6: Touch ID's reading is a chip in the Keys row, not in a card header.
        check(hosts.keysTouchID.superview === hosts.keysTopRow && hosts.keysTouchID.window != nil,
              "K6: the Touch ID chip is not in the Keys row", &ok)
        check(hosts.keysTouchID.label.stringValue.contains("Touch ID"), "K6: the chip reads \(hosts.keysTouchID.label.stringValue)", &ok)
        check(hosts.keySearchField.window != nil && hosts.keysViewModeControl.window != nil,
              "K3: the Keys row has no search or no Grid / List switch", &ok)
    }

    // MARK: X2

    private static func checkRecentHosts(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let grid = hosts.hostsGrid
        let store = shell.workspace.hostStore
        check(!grid.debugSectionTitles.contains("Recent"), "X2: a recent row shows before anything was connected", &ok)
        guard let grafana = store.hosts.first(where: { $0.label == "grafana" }),
              let lab = store.hosts.first(where: { $0.label == "lab-box" }) else {
            fail("X2: the demo hosts are missing", &ok)
            return
        }
        store.recordConnection(id: lab.id, at: Date().addingTimeInterval(-26 * 3600))
        store.recordConnection(id: grafana.id, at: Date().addingTimeInterval(-2 * 3600))
        settle(shell)
        check(grid.debugSectionTitles.first == "Recent", "X2: the sections are \(grid.debugSectionTitles)", &ok)
        guard let recent = grid.sections.first(where: { $0.title == "Recent" }) else { return }
        check(recent.cards.map(\.title) == ["grafana", "lab-box"], "X2: the recent row is \(recent.cards.map(\.title)), newest first", &ok)
        let detail = grid.debugCardView(key: grafana.id.uuidString)?.debugDetail ?? ""
        check(detail.hasPrefix("Last connected") && detail.contains("2"), "X2: grafana's card reads \"\(detail)\"", &ok)
        let row = hosts.hostsTable.debugRows.first { $0.key == grafana.id.uuidString }
        if case .muted(let text)? = row?.cells["lastConnected"] {
            check(text == detail, "X2: the table's Last connected reads \(text)", &ok)
        } else {
            fail("X2: the table has no Last connected cell for grafana", &ok)
        }
        hosts.debugTypeInSearch("graf")
        check(!grid.debugSectionTitles.contains("Recent"), "X2: the recent row stays while searching", &ok)
        hosts.debugTypeInSearch("")
    }

    // MARK: H3

    private static func checkFindOrConnect(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        // Every connect this check makes lands here, never on a real ssh.
        var connects: [(id: UUID?, label: String, args: [String])] = []
        let savedConnect = hosts.onConnect
        hosts.onConnect = { id, label, args, _, _, _ in connects.append((id, label, args)) }
        defer {
            hosts.onConnect = savedConnect
            hosts.debugTypeInSearch("")
        }
        let button = hosts.debugFindOrConnectButton
        check(hosts.debugSearchPlaceholder == "Find a host or ssh user@hostname",
              "H3: the field reads \"\(hosts.debugSearchPlaceholder)\"", &ok)
        check(button.window != nil && !button.isHiddenOrHasHiddenAncestor, "H3: the Connect button is not on screen", &ok)
        let field = hosts.debugSearchField
        check(button.frame.minX >= field.frame.maxX && abs(button.frame.midY - field.frame.midY) < 2,
              "H3: the Connect button is not beside the field (\(button.frame) vs \(field.frame))", &ok)
        check(field.frame.width > HostsController.sidebarSearchMinimumWidth,
              "H3: the field is squeezed to \(field.frame.width)pt at 1512", &ok)
        check(!button.isEnabled, "H3: Connect is lit with nothing typed", &ok)

        hosts.debugTypeInSearch("edge")
        check(!button.isEnabled, "H3: Connect is lit for a word two hosts match", &ok)
        // Return's own rules are unchanged: a bare word still connects as a
        // hostname, which is what the button deliberately does not offer.
        if case .adHoc? = hosts.quickConnectTarget(for: "edge") {} else {
            fail("H3: Return no longer connects a bare word as a hostname", &ok)
        }

        hosts.debugTypeInSearch("edge-proxy-01")
        check(button.isEnabled && button.toolTip == "Connect to edge-proxy-01",
              "H3: Connect for an exact name reads \(button.isEnabled) \"\(button.toolTip ?? "")\"", &ok)
        button.performClick(nil)
        let edgeID = shell.workspace.hostStore.hosts.first { $0.label == "edge-proxy-01" }?.id
        check(connects.last?.id == edgeID && edgeID != nil, "H3: Connect did not connect the saved host", &ok)

        hosts.debugTypeInSearch("grafa")
        check(button.isEnabled && button.toolTip == "Connect to grafana", "H3: one match does not light Connect", &ok)

        hosts.debugTypeInSearch("ssh deploy@new.example.test:2200")
        check(button.isEnabled, "H3: a typed user@host does not light Connect", &ok)
        button.performClick(nil)
        let last = connects.last
        check(last?.id == nil && last?.args.contains("2200") == true && last?.args.last == "deploy@new.example.test",
              "H3: the ad-hoc connect ran \(String(describing: last?.args))", &ok)
        check(connects.count == 2, "H3: \(connects.count) connects for two clicks", &ok)
    }

    // MARK: H8 and K2

    private static func checkSplitButtons(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let hosts = showHosts(shell)
        let hostSplit = hosts.debugAddHostSplit
        check(shell.toolbar.debugPrimaryAction === hostSplit, "H8: the toolbar's primary action on Hosts is not Add Host's split button", &ok)
        check(hostSplit.window != nil, "H8: the split button is not in the window", &ok)
        check(shell.toolbar.debugPageActions.isEmpty,
              "H8: the toolbar carries \(shell.toolbar.debugPageActions.count) page actions beside the split - a second Add Host", &ok)
        // Two real buttons, each keyboard reachable (reachable by Tab under
        // Full Keyboard Access, which is the system's rule for every button)
        // and named, joined: only
        // the outer corners round.
        let main = hostSplit.mainButton, chevron = hostSplit.menuButton
        check(main.title == "Add Host" && !main.refusesFirstResponder && !chevron.refusesFirstResponder && main.isEnabled && chevron.isEnabled,
              "H8: the halves are not both keyboard-reachable buttons", &ok)
        check(chevron.accessibilityLabel() == "More ways to add a host", "H8: the chevron reads \(chevron.accessibilityLabel() ?? "nothing")", &ok)
        check(main.layer?.maskedCorners == [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                && chevron.layer?.maskedCorners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner],
              "H8: the halves round every corner, so they read as two buttons", &ok)
        check(abs(chevron.frame.minX - main.frame.maxX - HelmSplitButton.dividerWidth) < 0.5,
              "H8: the halves are \(chevron.frame.minX - main.frame.maxX)pt apart", &ok)
        check(hostSplit.debugMenuTitles == ["New Host\u{2026}", "Quick Connect"], "H8: Add Host's menu is \(hostSplit.debugMenuTitles)", &ok)

        var opened: [Host?] = []
        let savedOpen = hosts.onAddOrEdit
        hosts.onAddOrEdit = { opened.append($0) }
        defer { hosts.onAddOrEdit = savedOpen }
        // H10: both open a new host's form in the panel.
        main.performClick(nil)
        check(opened.isEmpty && hosts.hostPanelKey == HostsController.newHostPanelKey,
              "H8: Add Host's main half did not open a new host", &ok)
        hosts.hostPanel?.cancelPanel()
        hostSplit.debugPick("New Host\u{2026}")
        check(opened.isEmpty && hosts.hostPanelKey == HostsController.newHostPanelKey,
              "H8: New Host from the menu did not open a new host", &ok)
        hosts.hostPanel?.cancelPanel()
        hostSplit.debugPick("Quick Connect")
        settle(shell)
        let editor = window.firstResponder as? NSView
        check(editor?.isDescendant(of: hosts.debugSearchField) == true || (editor as? NSText)?.delegate.map { ($0 as? NSView)?.isDescendant(of: hosts.debugSearchField) == true } == true,
              "H8: Quick Connect did not focus the find-or-connect field (\(String(describing: window.firstResponder)))", &ok)
        let overflow = hostSplit.workspaceToolbarMenuItems().map { $0.isSeparatorItem ? "-" : $0.title }
        check(overflow == ["Add Host", "New Host\u{2026}", "Quick Connect"], "H8: the overflow menu form is \(overflow)", &ok)

        // K2: New Key, on the Keys tab.
        hosts.selectModuleTab(named: "Keys")
        settle(shell)
        let keySplit = hosts.debugAddKeySplit
        check(shell.toolbar.debugPrimaryAction === keySplit, "K2: the toolbar's primary action on Keys is not New Key's split button", &ok)
        check(keySplit.debugMenuTitles == ["Generate Ed25519 Key\u{2026}", "Generate RSA 3072 Key\u{2026}", "-",
                                           "Import Key File\u{2026}", "Paste a Key\u{2026}", "-",
                                           "Attach Certificate to Selected Key\u{2026}"],
              "K2: New Key's menu is \(keySplit.debugMenuTitles)", &ok)
        HostsController.suppressesKeyEditorPresentationForTests = true
        defer { HostsController.suppressesKeyEditorPresentationForTests = false }
        func opens(_ title: String) -> KeyEditorController? {
            hosts.lastKeyEditorForTests = nil
            keySplit.debugPick(title)
            let editor = hosts.lastKeyEditorForTests
            _ = editor?.view
            return editor
        }
        let rsa = opens("Generate RSA 3072 Key\u{2026}")
        check(rsa?.preset == .generate(.rsa) && rsa?.debugMode == "generate" && rsa?.debugType == SSHKeyType.rsa.rawValue,
              "K2: Generate RSA opened \(String(describing: rsa?.preset)) in \(rsa?.debugMode ?? "-")/\(rsa?.debugType ?? "-")", &ok)
        let ed = opens("Generate Ed25519 Key\u{2026}")
        check(ed?.debugType == SSHKeyType.ed25519.rawValue, "K2: Generate Ed25519 opened type \(ed?.debugType ?? "-")", &ok)
        let paste = opens("Paste a Key\u{2026}")
        check(paste?.debugMode == "import", "K2: Paste a Key opened in \(paste?.debugMode ?? "-") mode", &ok)
        check(keySplit.debugIsEnabled("Attach Certificate to Selected Key\u{2026}") == false,
              "K2: Attach Certificate is offered with no key selected", &ok)
        guard let ops = shell.workspace.keyStore.keys.first(where: { $0.label == "ops-ed25519" }) else {
            fail("K2: the demo key ops-ed25519 is missing", &ok)
            return
        }
        hosts.debugKeysTable.debugSelect(key: ops.id.uuidString)
        check(keySplit.debugIsEnabled("Attach Certificate to Selected Key\u{2026}") == true,
              "K2: Attach Certificate is not offered with a key selected", &ok)
        let cert = opens("Attach Certificate to Selected Key\u{2026}")
        check(cert?.preset == .certificate, "K2: Attach Certificate opened \(String(describing: cert?.preset))", &ok)
        hosts.debugKeysTable.debugSelect(key: nil)
        hosts.selectModuleTab(named: "Hosts")
        settle(shell)
    }

    // MARK: H9

    private static func checkTagOverflow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let hosts = showHosts(shell)
        let allTags = Set(shell.workspace.hostStore.hosts.flatMap(\.tags)).sorted()
        for width in [1512.0, 1100.0, 1100.5, 960.0] {
            resize(window, width: width, shell)
            let visible = hosts.debugVisibleTags
            let hidden = hosts.debugHiddenTags
            check(visible + hidden == allTags, "H9 at \(width): the chips and +N between them list \(visible + hidden)", &ok)
            // Nothing is cut off: every showing chip ends inside the strip.
            let strip = hosts.debugTagStripWidth
            let used = visible.compactMap { hosts.debugTagChip($0)?.frame.maxX }.max() ?? 0
            check(used <= strip + 0.5, "H9 at \(width): the chips reach \(used)pt in a \(strip)pt strip", &ok)
            let chip = hosts.debugTagOverflowChip
            check(chip.isHidden == hidden.isEmpty, "H9 at \(width): +N's visibility does not match \(hidden.count) hidden tags", &ok)
            if !hidden.isEmpty {
                check(chip.title == "+\(hidden.count)", "H9 at \(width): the chip reads \(chip.title) for \(hidden.count)", &ok)
            }
        }
        // The vacuity guard: at 1100 - the captain's clipped render - the
        // row really is too narrow for every chip.
        resize(window, width: 1100, shell)
        let hidden = hosts.debugHiddenTags
        guard let last = hidden.last else {
            fail("H9: at 1100 every chip fits, so the overflow is never exercised", &ok)
            return
        }
        check(hosts.debugOverflowMenuTitles == hidden, "H9: +N's menu lists \(hosts.debugOverflowMenuTitles)", &ok)
        let before = hosts.debugFilteredHostLabels()
        check(hosts.debugPickOverflowTag(last), "H9: +N's menu has no item for \(last)", &ok)
        settle(shell)
        let after = hosts.debugFilteredHostLabels()
        let carrying = shell.workspace.hostStore.hosts.filter { $0.tags.contains(last) }.map(\.label)
        check(after == carrying && after != before, "H9: picking \(last) from +N filtered to \(after)", &ok)
        check(hosts.debugTagOverflowChip.variant == .primary, "H9: +N does not show that a tag behind it is selected", &ok)
        hosts.debugPickOverflowTag(last)
        settle(shell)
        check(hosts.debugFilteredHostLabels() == before, "H9: picking \(last) again did not clear it", &ok)
    }
}

#endif
