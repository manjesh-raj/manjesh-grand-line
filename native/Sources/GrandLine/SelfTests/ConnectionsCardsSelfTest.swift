// Grand Line - native macOS app.
//
// The Termius-style Hosts and Keys work (PR 1 of 3 of the captain's plan),
// mounted in a real off-screen sidebar shell with the tour lab's demo hosts
// and driven through the pages' own controls.
//
//   - X4: the tag chips match any selected tag, or all of them.
//   - H9: the tag chips never run off the filter row; what does not fit is
//     behind a "+N" chip whose menu toggles the same filter.
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
            for check in [checkTagMatch, checkTagOverflow] {
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
