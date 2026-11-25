// Grand Line - native macOS app - self-test.
//
// `fm/grand-line-hosts-page-redesign`: the claims the redesigned Hosts page
// makes that a render cannot check for itself.
//
// The risk in this redesign is the same one the Schedules one carried
// (`SchedulesRedesignSelfTest`): the captain's reference is a standalone HTML
// mockup full of invented demo data - a "Terminal Hub" workspace, a hardcoded
// "100% Keychain protected" metric, a "Recently used" filter, a `⌘⇧P Run
// snippet` shortcut bound to nothing. A control that renders one of those
// shapes with nothing behind it looks finished and lies. So every check below
// asserts **where a number came from**, not that a view exists:
//
//  - the page's counts (the toolbar tabs' and the All / Online segments')
//    read the same stores the table renders, so the two cannot disagree
//    within a frame, and Touch ID's reading is the real probe;
//  - the Online filter really narrows the list, and is the one of the
//    reference's three filter chips this app can answer at all.
//
// Plus the one layout property this page has to keep: an untagged host list
// does not collapse the content column.
//
// P-03 of the 2026-11-25 review removed the page's floating-bar presentation
// (its nav column, keychain card, user row, Workspace panel and side
// column), and the cases that measured only those went with it.
//
// Window-backed (it mounts the real controller), so it sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS
import AppKit

enum HostsRedesignSelfTest {

    static func run() -> Bool {
        print("== Hosts redesign: real counts, a real filter, a column that holds ==")
        var ok = true
        checkTheListSurvivesUntaggedHosts(&ok)
        checkCountsReadTheStores(&ok)
        checkOnlineFilterNarrowsTheList(&ok)
        print(ok ? "\nPASS" : "\nFAIL")
        return ok
    }

    // MARK: Harness

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// A fresh page over scratch stores, mounted in an off-screen window.
    ///
    /// Built by `OffScreenProbe.window(...)` and never made key: this machine
    /// may be running the captain's own instance, and a suite must never put a
    /// window on their screen or take their focus. Note the parking is the
    /// window type's own doing - an `x: -20_000` handed to `NSWindow.init` is
    /// discarded by AppKit, which is how this used to leak.
    private static func page(hosts: [Host] = [],
                             keys: [SSHKey] = [],
                             snippets: [Snippet] = [],
                             live: Set<UUID> = [],
                             width: CGFloat = 1400) -> (HostsController, NSWindow, HostStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-redesign-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)

        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        for host in hosts { hostStore.add(host) }
        for key in keys { keyStore.add(key) }
        for snippet in snippets { snippetStore.add(snippet) }

        let controller = HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore)
        controller.liveSession = { id in
            guard live.contains(id) else { return nil }
            return HostSession(hostID: id, label: "live", accentHex: nil,
                               startedAt: Date().addingTimeInterval(-600), state: .connected)
        }
        let window = OffScreenProbe.window(width: width, height: 860)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 860)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window, hostStore)
    }

    private static func devHost(_ label: String = "DEV Bastion") -> Host {
        var host = Host(label: label, address: "ec2-44-206-131-135.compute-1.amazonaws.com")
        host.username = "centos"
        host.tags = ["DEV"]
        host.accentHex = "#E6A72B"
        return host
    }

    /// The captain's own two hosts, in the shape his real `hosts.json` holds
    /// them: an environment recorded in `group`, and **no tags at all**.
    ///
    /// That shape is the whole point of the fixture. Every other case here
    /// seeds `devHost()`/`prodHost()`, which carry tags - and a tagged host is
    /// exactly the case the collapse `checkTheListSurvivesUntaggedHosts`
    /// guards against cannot happen in, because the tag strip stays in layout
    /// and absorbs the row's slack. Seeding only tagged hosts is why the
    /// original redesign shipped this bug with a green suite.
    private static func untaggedGroupedHosts() -> [Host] {
        var dev = Host(label: "DEV Bastion", address: "ec2-44-206-131-135.compute-1.amazonaws.com")
        dev.username = "centos"
        dev.group = "DEV"
        var prod = Host(label: "Prod Bastion", address: "ec2-3-208-58-234.compute-1.amazonaws.com")
        prod.username = "ec2-user"
        prod.group = "Prod"
        return [dev, prod]
    }

    private static func prodHost() -> Host {
        var host = Host(label: "Prod Bastion", address: "ec2-3-208-58-234.compute-1.amazonaws.com")
        host.username = "ec2-user"
        host.tags = ["PROD"]
        return host
    }

    private static func key(_ label: String) -> SSHKey {
        SSHKey(label: label, type: .ed25519, publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:\(label)")
    }

    /// The saved hosts' rows in the host table, by title, as the page
    /// rendered them - the built-in Firstmate row and group headers left out.
    private static func hostRowKeys(_ controller: HostsController) -> [String] {
        controller.debugHostsTable.debugRows.compactMap(\.key).filter { $0 != HostsController.firstmateRowKey }
    }

    /// The All / Online segments' labels, read off the pills themselves.
    private static func segmentTitles(_ controller: HostsController) -> [String] {
        controller.debugOnlineFilter.workspaceToolbarMenuItems().map(\.title)
    }

    // MARK: Layout

    /// The host list holds the content column with **no tags on any host**.
    ///
    /// This is the captain's own data shape. With no tags anywhere,
    /// `rebuildTagChips` hides the tag strip, an `NSStackView` drops a hidden
    /// arranged subview out of layout entirely, and the filter row loses the
    /// member that used to absorb its slack. Before the row gained its
    /// always-present spacer, the one control left in it hugged at
    /// `.required`, and since the row is pinned to both edges of the tab view,
    /// that control became a required *ceiling* on the whole content column.
    ///
    /// Measured before that fix, at the captain's own 1467pt window: the
    /// content column collapsed to 74pt. No host list.
    ///
    /// Asserted as arithmetic rather than against the broken numbers, so the
    /// case states the property (the cards and the table span the page from
    /// the hero column to the gutter) rather than the symptom.
    private static func checkTheListSurvivesUntaggedHosts(_ ok: inout Bool) {
        print("\n-- the host list holds its column when no host carries a tag --")
        let (controller, window, _) = page(hosts: untaggedGroupedHosts(), width: 1467)
        defer { _ = window }

        // The fixture has to genuinely reach the hidden-strip branch, or this
        // case passes without exercising the bug at all.
        guard controller.debugTagStripIsHidden else {
            fail("the tag strip is visible - this fixture no longer reaches the branch it exists for", &ok)
            return
        }
        guard controller.heroColumnShowing, let hero = controller.heroColumn else {
            fail("the hero column is not showing at 1467pt - the expected width below would be wrong", &ok)
            return
        }

        // Nothing is selected, so the inspector is closed and the list should
        // hold the page's whole content width: from `s5` past the hero column
        // to the page gutter.
        let root = controller.view
        let heroFrame = hero.convert(hero.bounds, to: root)
        let expected = root.bounds.width - HelmMetrics.pageGutter - (heroFrame.maxX + HelmMetrics.s5)
        let grid = controller.hostsGrid.convert(controller.hostsGrid.bounds, to: root)
        let card = controller.debugHostsTable.card.convert(controller.debugHostsTable.card.bounds, to: root)
        if abs(grid.width - expected) > 0.5 {
            fail("the host cards are \(fmt(grid.width))pt wide, want \(fmt(expected))pt "
                 + "- an untagged host list collapses the page's primary content", &ok)
        }
        if abs(card.width - expected) > 0.5 {
            fail("the host table is \(fmt(card.width))pt wide, want \(fmt(expected))pt", &ok)
        }
        let rows = hostRowKeys(controller)
        if rows.count != 2 {
            fail("the table lists \(rows.count) saved host(s), want both - the hosts are missing", &ok)
        }
        if ok {
            print("  OK - cards and table \(fmt(grid.width))pt beside a \(fmt(heroFrame.width))pt hero column, "
                  + "with the tag strip hidden")
        }
    }

    // MARK: Counts

    /// The toolbar tabs' counts and the All / Online segments are the three
    /// stores plus the session registry, read where the table is read - never
    /// a second count that can drift - and a store write moves them.
    private static func checkCountsReadTheStores(_ ok: inout Bool) {
        print("\n-- the counts come from the same stores the table renders --")
        let dev = devHost()
        let (controller, window, hostStore) = page(hosts: [dev, prodHost()],
                                                   keys: [key("dev-account")],
                                                   snippets: [Snippet(label: "jump", command: "ssh bastion")],
                                                   live: [dev.id])
        defer { _ = window }

        let counts = controller.moduleTabCounts
        if counts != ["Hosts": 2, "Keys": 1, "Snippets": 1] {
            fail("the toolbar's tab counts are \(counts), want Hosts 2, Keys 1, Snippets 1", &ok)
        }
        let segments = segmentTitles(controller)
        if segments != ["All\u{2002}2", "Online\u{2002}1"] {
            fail("the All / Online segments read \(segments), want All 2 and Online 1", &ok)
        }

        // A store write has to move the counts, or they are a snapshot taken
        // once and never corrected.
        hostStore.add(Host(label: "Third", address: "third.example.com"))
        controller.view.layoutSubtreeIfNeeded()
        if controller.moduleTabCounts["Hosts"] != 3 {
            fail("adding a host left the Hosts tab's count at \(controller.moduleTabCounts["Hosts"] ?? -1)", &ok)
        }
        if segmentTitles(controller).first != "All\u{2002}3" {
            fail("adding a host left the All segment at \(segmentTitles(controller).first ?? "nil")", &ok)
        }

        // The Keys row's Touch ID line is a real `LAContext` probe, so it says
        // one of two things - never the reference's unconditional "Touch ID
        // enabled" - and in the one wording the key form uses too.
        let touchID = controller.debugKeysTouchID.label.stringValue
        let phrase = HostsController.biometryPhrase(CredentialVaultKeyStore.biometryAvailable, capitalized: true)
        if touchID != phrase {
            fail("the Keys row's Touch ID reads \"\(touchID)\", want the probe's \"\(phrase)\"", &ok)
        }
        if ok { print("  OK - 2/1/1 and All 2 / Online 1 from the real stores, both follow a write, Touch ID is the probe") }
    }

    // MARK: Filters

    /// The reference's filter bar offers three chips; this app can honestly
    /// answer one. It has to really narrow the list - a filter that only lights
    /// up is the "inert control" this brief ruled out.
    private static func checkOnlineFilterNarrowsTheList(_ ok: inout Bool) {
        print("\n-- the Online filter really filters, and clears again --")
        let dev = devHost()
        let prod = prodHost()
        let (controller, window, _) = page(hosts: [dev, prod], live: [dev.id])
        defer { _ = window }

        let before = hostRowKeys(controller)
        guard before.count == 2 else {
            fail("the table lists \(before.count) host(s) before filtering, want 2 - the check would be vacuous", &ok)
            return
        }
        controller.debugOnlineFilter.debugClickTab(id: HostsController.onlineFilterID)
        controller.view.layoutSubtreeIfNeeded()
        let after = hostRowKeys(controller)
        if after != [dev.id.uuidString] {
            fail("Online lists \(after), want only DEV Bastion's live session", &ok)
        }
        if !controller.onlineOnly {
            fail("clicking Online did not turn the filter on", &ok)
        }
        controller.debugOnlineFilter.debugClickTab(id: HostsController.allFilterID)
        controller.view.layoutSubtreeIfNeeded()
        if hostRowKeys(controller) != before {
            fail("All did not restore the list: \(hostRowKeys(controller))", &ok)
        }
        if ok { print("  OK - \(before.count) rows -> \(after.count) with Online on, and back") }
    }
}
#endif
