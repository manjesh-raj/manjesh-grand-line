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
            for check in [checkTagMatch, checkTagOverflow, checkFindOrConnect, checkSplitButtons] {
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
        main.performClick(nil)
        check(opened.count == 1, "H8: Add Host's main half did not open a new host", &ok)
        hostSplit.debugPick("New Host\u{2026}")
        check(opened.count == 2, "H8: New Host from the menu did not open a new host", &ok)
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
