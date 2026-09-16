// Manjesh Grand Line - native macOS app - self-test.
//
// `fm/grand-line-hosts-page-redesign`: the claims the redesigned Hosts page
// makes that a render cannot check for itself.
//
// The risk in this redesign is the same one the Schedules one carried
// (`SchedulesRedesignSelfTest`): the captain's reference is a standalone HTML
// mockup full of invented demo data - a "Terminal Hub" workspace, a hardcoded
// "100% Keychain protected" metric, a "Recently used" filter, a `⌘⇧P Run
// snippet` shortcut bound to nothing. A panel that renders one of those shapes
// with nothing behind it looks finished and lies. So every check below asserts
// **where a number or an action came from**, not that a view exists:
//
//  - the Workspace tiles read the same three stores the list beside them
//    renders, so the two cannot disagree within a frame;
//  - the Selected panel shows the row that is actually selected *on the tab
//    that is showing*, never a stale selection left on a hidden one;
//  - its buttons run the same closures the row's own buttons do;
//  - the "Online" chip really narrows the list, and is the one of the
//    reference's three filter chips this app can answer at all;
//  - the quick-action grid carries only shortcuts that are really bound, and
//    clicking one does the thing it names.
//
// Plus the two layout properties this page has to keep: it is two columns, and
// neither of them is a window-width floor (gotchas (13)/(14) -
// `AppShellBodyWidthSelfTest` sweeps every destination for exactly that, and
// this suite pins the priority at the source so a failure here names the
// cause).
//
// Window-backed (it mounts the real controller), so it sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS
import AppKit

enum HostsRedesignSelfTest {

    static func run() -> Bool {
        print("== Hosts redesign: two columns, real panels ==")
        var ok = true
        checkTwoColumnLayout(&ok)
        checkTwoColumnLayoutSurvivesUntaggedHosts(&ok)
        checkWorkspaceReadsTheStores(&ok)
        checkDetailFollowsSelectionAndTab(&ok)
        checkDetailActionsAreTheRealOnes(&ok)
        checkEmptyDetailTearsDownItsRows(&ok)
        checkOnlineChipNarrowsTheList(&ok)
        checkQuickActionsAreRealAndWired(&ok)
        checkToolbarShortcutSitsBesideConsole(&ok)
        print(ok ? "\nPASS" : "\nFAIL")
        return ok
    }

    // MARK: Harness

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

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
    /// exactly the case the collapse this file's
    /// `checkTwoColumnLayoutSurvivesUntaggedHosts` guards against cannot
    /// happen in, because the tag strip stays in layout and absorbs the row's
    /// slack. Seeding only tagged hosts is why the original redesign shipped
    /// this bug with a green suite.
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

    /// The row index of `label` in a list, accounting for the pinned
    /// "Firstmate" entry and any group headers.
    private static func row(_ list: HostsListSection, labelled label: String) -> Int? {
        for index in 0..<list.debugRowCount where list.debugAccentRow(index) != nil {
            if let view = list.debugRowView(index), containsLabel(view, label) { return index }
        }
        return nil
    }

    private static func containsLabel(_ view: NSView, _ text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text { return true }
        return view.subviews.contains { containsLabel($0, text) }
    }

    // MARK: Layout

    /// Two columns, and neither is a window floor.
    ///
    /// The width arithmetic is asserted rather than the numbers eyeballed: the
    /// content column has to be *exactly* whatever the page, the gutters and
    /// the fixed side column leave, or the page has quietly stopped filling its
    /// own width - which is the complaint this redesign exists to answer.
    private static func checkTwoColumnLayout(_ ok: inout Bool) {
        print("\n-- two columns, and neither one is a window floor --")
        let (controller, window, _) = page(hosts: [devHost(), prodHost()])
        defer { _ = window }

        let stack = controller.debugSideStack
        let state = controller.debugState()
        let expected = state.rootWidth
            - HelmMetrics.pageGutter * 2
            - HostsSideStack.width
            - HelmMetrics.s4
        if abs(state.hostsCardFrame.width - expected) > 0.5 {
            fail("content column is \(fmt(state.hostsCardFrame.width))pt, want \(fmt(expected))pt "
                 + "(page \(fmt(state.rootWidth)) - gutters - \(fmt(HostsSideStack.width))pt side column)", &ok)
        }
        if abs(stack.frame.width - HostsSideStack.width) > 0.5 {
            fail("side column is \(fmt(stack.frame.width))pt, want \(fmt(HostsSideStack.width))pt", &ok)
        }
        if stack.frame.maxX > state.rootWidth - HelmMetrics.pageGutter + 0.5 {
            fail("side column runs past the page gutter", &ok)
        }

        // gotchas (13)/(14): no constraint on this page may sit at or above
        // `NSLayoutPriorityWindowSizeStayPut` (500), or the page becomes a
        // floor on how narrow the whole window may get - and every destination
        // shares one `bodyContainer`, so it takes the other twenty-six with it.
        let floors = widthConstraintsAtOrAbove(NSLayoutConstraint.Priority(500),
                                               in: controller.view,
                                               matching: [HostsSideStack.width,
                                                          HostsController.contentMinimumWidth])
        if !floors.isEmpty {
            fail("\(floors.count) column constraint(s) at or above windowSizeStayPut: \(floors)", &ok)
        }

        // The page must genuinely hold a narrow window.
        for width in [1016.0, 1100.0] as [CGFloat] {
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 860)
            controller.view.layoutSubtreeIfNeeded()
            if controller.view.fittingSize.width > width {
                fail("at \(fmt(width))pt the page demands \(fmt(controller.view.fittingSize.width))pt", &ok)
            }
        }
        if ok { print("  OK - content + \(fmt(HostsSideStack.width))pt side column tile the page, no window floor") }
    }

    /// The two columns survive a host list with **no tags on any host**.
    ///
    /// This is the captain's own data shape, and it is what
    /// `checkTwoColumnLayout` above cannot see: that case seeds tagged hosts,
    /// so the tag strip stays in layout and quietly absorbs the filter row's
    /// slack. With no tags anywhere, `rebuildTagChips` hides the strip, an
    /// `NSStackView` drops a hidden arranged subview out of layout entirely,
    /// and the row is left holding only the "Online" chip - whose horizontal
    /// hugging is `.required`. The row's width is tied to the search field's
    /// stack, which is pinned to both edges of the tab view, all required, so
    /// that one chip became a required *ceiling* on the whole content column.
    ///
    /// Measured before the fix, at the captain's own 1467pt window: the
    /// content column collapsed to 74pt - the chip - while the side stack took
    /// the remaining 1329pt. No host list, and the rail across the page.
    ///
    /// Asserted as arithmetic rather than against the broken numbers, so the
    /// case states the property (the two columns tile the page) rather than
    /// the symptom.
    private static func checkTwoColumnLayoutSurvivesUntaggedHosts(_ ok: inout Bool) {
        print("\n-- two columns hold when no host carries a tag --")
        let (controller, window, _) = page(hosts: untaggedGroupedHosts(), width: 1467)
        defer { _ = window }
        let state = controller.debugState()
        let stack = controller.debugSideStack

        // The fixture has to genuinely reach the hidden-strip branch, or this
        // case passes without exercising the bug at all.
        guard controller.debugTagStripIsHidden else {
            fail("the tag strip is visible - this fixture no longer reaches the branch it exists for", &ok)
            return
        }

        let expected = state.rootWidth
            - HelmMetrics.pageGutter * 2
            - HelmMetrics.s4
            - HostsSideStack.width
        if abs(state.hostsCardFrame.width - expected) > 0.5 {
            fail("content column is \(fmt(state.hostsCardFrame.width))pt, want \(fmt(expected))pt "
                 + "- an untagged host list collapses the page's primary content", &ok)
        }
        if abs(stack.frame.width - HostsSideStack.width) > 0.5 {
            fail("side column is \(fmt(stack.frame.width))pt, want \(fmt(HostsSideStack.width))pt "
                 + "- the rail has taken the list's width", &ok)
        }
        // Both hosts plus the pinned Firstmate row plus two group headers.
        if state.hostRowCount < 3 {
            fail("the list rendered \(state.hostRowCount) row(s) - the hosts are missing", &ok)
        }
        if ok {
            print("  OK - content \(fmt(state.hostsCardFrame.width))pt + "
                  + "\(fmt(stack.frame.width))pt rail, with the tag strip hidden")
        }
    }

    private static func widthConstraintsAtOrAbove(_ priority: NSLayoutConstraint.Priority,
                                                  in view: NSView,
                                                  matching constants: [CGFloat]) -> [String] {
        var found: [String] = []
        for constraint in view.constraints
        where constraint.priority >= priority
            && constraint.firstAttribute == .width
            && constants.contains(where: { abs($0 - constraint.constant) < 0.5 }) {
            found.append("\(fmt(constraint.constant))pt @ \(constraint.priority.rawValue)")
        }
        for sub in view.subviews {
            found += widthConstraintsAtOrAbove(priority, in: sub, matching: constants)
        }
        return found
    }

    // MARK: Workspace

    /// The four tiles are the three stores plus the session registry, read
    /// where the list is read - never a second count that can drift.
    private static func checkWorkspaceReadsTheStores(_ ok: inout Bool) {
        print("\n-- Workspace counts come from the same stores the list renders --")
        let dev = devHost()
        let key = SSHKey(label: "dev-account", type: .rsa, publicKey: "ssh-rsa AAAA", fingerprint: "SHA256:abc")
        let (controller, window, hostStore) = page(hosts: [dev, prodHost()],
                                                   keys: [key],
                                                   snippets: [Snippet(label: "jump", command: "ssh bastion")],
                                                   live: [dev.id])
        defer { _ = window }

        let metrics = controller.debugSideStack.workspace.debugMetrics
        let expected = [("2", "Hosts"), ("1", "SSH keys"), ("1", "Snippets"), ("1", "Live sessions")]
        for (index, want) in expected.enumerated() {
            guard index < metrics.count else {
                fail("only \(metrics.count) workspace tiles", &ok)
                return
            }
            if metrics[index].value != want.0 || metrics[index].caption != want.1 {
                fail("tile \(index) reads \"\(metrics[index].value) \(metrics[index].caption)\", "
                     + "want \"\(want.0) \(want.1)\"", &ok)
            }
        }

        // A store write has to move the tile, or the panel is a snapshot taken
        // once and never corrected.
        hostStore.add(Host(label: "Third", address: "third.example.com"))
        controller.view.layoutSubtreeIfNeeded()
        let after = controller.debugSideStack.workspace.debugMetrics.first?.value ?? "?"
        if after != "3" { fail("adding a host left the Hosts tile at \(after)", &ok) }

        // The Keychain line is a real `LAContext` probe, so it says one of two
        // things - never the reference's unconditional "Touch ID enabled".
        let status = controller.debugSideStack.workspace.debugStatusText
        if !(status.contains("Touch ID ready") || status.contains("no biometry")) {
            fail("keychain status reads \"\(status)\"", &ok)
        }
        if ok { print("  OK - 2/1/1/1 from the real stores, tiles follow a write, status is a real probe") }
    }

    // MARK: Selected

    /// The panel shows the showing tab's own selection. A selection left on a
    /// hidden tab must never be what it displays - which is the whole reason
    /// `select(tab:)` re-fills it.
    private static func checkDetailFollowsSelectionAndTab(_ ok: inout Bool) {
        print("\n-- Selected follows the selection, and the tab that is showing --")
        let dev = devHost()
        let (controller, window, _) = page(hosts: [dev, prodHost()],
                                           snippets: [Snippet(label: "jump", command: "ssh bastion")])
        defer { _ = window }
        let detail = controller.debugSideStack.detail

        if !detail.debugIsEmpty {
            fail("the panel is populated before anything has been selected", &ok)
        }

        guard let devRow = row(controller.debugList(.hosts), labelled: "DEV Bastion") else {
            fail("no DEV Bastion row", &ok)
            return
        }
        controller.debugList(.hosts).debugSelect(devRow)
        controller.view.layoutSubtreeIfNeeded()

        if detail.debugTitle != "DEV Bastion" {
            fail("panel shows \"\(detail.debugTitle)\", want DEV Bastion", &ok)
        }
        // The endpoint is the saved host's own address, in full - the field
        // failing to render it is the defect Poneglyph was corrected for.
        let fields = Dictionary(detail.debugFields, uniquingKeysWith: { first, _ in first })
        if fields["Endpoint"] != "ec2-44-206-131-135.compute-1.amazonaws.com" {
            fail("Endpoint reads \"\(fields["Endpoint"] ?? "-")\"", &ok)
        }
        if fields["User"] != "centos" { fail("User reads \"\(fields["User"] ?? "-")\"", &ok) }
        if fields["Environment"] != "DEV" { fail("Environment reads \"\(fields["Environment"] ?? "-")\"", &ok) }
        if fields["Credential"] != "ssh agent" { fail("Credential reads \"\(fields["Credential"] ?? "-")\"", &ok) }

        // Switch to a tab whose own list has no selection: the panel must
        // empty rather than keep showing the host behind the hidden tab.
        controller.select(tab: .keys)
        controller.view.layoutSubtreeIfNeeded()
        if !detail.debugIsEmpty {
            fail("switching to Keys left the panel showing \"\(detail.debugTitle)\"", &ok)
        }

        // Switching to a tab that *does* have a selection re-fills from it.
        controller.select(tab: .snippets)
        controller.debugList(.snippets).debugSelect(0)
        controller.view.layoutSubtreeIfNeeded()
        if detail.debugTitle != "jump" {
            fail("Snippets tab panel shows \"\(detail.debugTitle)\", want jump", &ok)
        }
        controller.select(tab: .hosts)
        controller.view.layoutSubtreeIfNeeded()
        if detail.debugTitle != "DEV Bastion" {
            fail("returning to Hosts lost its selection (panel shows \"\(detail.debugTitle)\")", &ok)
        }
        if ok { print("  OK - fields are the saved host's own, and the panel tracks the showing tab") }
    }

    /// The panel's buttons run the page's real closures - the same ones the
    /// row's own buttons run. A panel of inert buttons renders identically.
    private static func checkDetailActionsAreTheRealOnes(_ ok: inout Bool) {
        print("\n-- Selected's buttons are the row's own actions --")
        let (controller, window, _) = page(hosts: [devHost()])
        defer { _ = window }

        var connected: [String] = []
        controller.onConnect = { _, label, _, _, _, _ in connected.append(label) }
        var edited: [String] = []
        controller.onAddOrEdit = { host in edited.append(host?.label ?? "new") }

        guard let devRow = row(controller.debugList(.hosts), labelled: "DEV Bastion") else {
            fail("no DEV Bastion row", &ok)
            return
        }
        controller.debugList(.hosts).debugSelect(devRow)
        controller.view.layoutSubtreeIfNeeded()

        let titles = controller.debugSideStack.detail.debugActionTitles
        guard titles.count == 2, titles.first == "Connect" else {
            fail("panel actions are \(titles), want [Connect, Edit…]", &ok)
            return
        }
        controller.debugSideStack.detail.debugClickAction(0)
        if connected != ["DEV Bastion"] {
            fail("Connect in the panel fired \(connected), want [DEV Bastion]", &ok)
        }
        controller.debugSideStack.detail.debugClickAction(1)
        if edited != ["DEV Bastion"] {
            fail("Edit in the panel fired \(edited), want [DEV Bastion]", &ok)
        }
        if ok { print("  OK - Connect and Edit reach the same closures the row does") }
    }

    /// AGENTS.md gotcha (11): an ordinary hidden `NSView`'s constraints still
    /// participate fully in layout, so the emptied panel has to *tear its rows
    /// down*, not merely hide the view above them. Measured before the fix: an
    /// empty panel stayed 317pt - as tall as whatever had last been selected -
    /// against the 168pt it actually needs.
    private static func checkEmptyDetailTearsDownItsRows(_ ok: inout Bool) {
        print("\n-- an emptied Selected panel collapses (gotcha (11)) --")
        let (controller, window, _) = page(hosts: [devHost()])
        defer { _ = window }

        guard let devRow = row(controller.debugList(.hosts), labelled: "DEV Bastion") else {
            fail("no DEV Bastion row", &ok)
            return
        }
        controller.debugList(.hosts).debugSelect(devRow)
        controller.view.layoutSubtreeIfNeeded()
        let populated = controller.debugSideStack.detail.card.frame.height

        controller.select(tab: .keys)
        controller.view.layoutSubtreeIfNeeded()
        let empty = controller.debugSideStack.detail.card.frame.height

        guard populated > 1, empty > 1 else {
            fail("panel never laid out (populated \(fmt(populated)), empty \(fmt(empty)))", &ok)
            return
        }
        if empty >= populated {
            fail("the emptied panel is \(fmt(empty))pt against \(fmt(populated))pt populated - "
                 + "its hidden rows are still driving the height", &ok)
        }
        if !controller.debugSideStack.detail.debugFields.isEmpty {
            fail("the emptied panel still holds \(controller.debugSideStack.detail.debugFields.count) field row(s)", &ok)
        }
        if ok { print("  OK - \(fmt(populated))pt populated, \(fmt(empty))pt empty, no rows left behind") }
    }

    // MARK: Filters

    /// The reference's filter bar offers three chips; this app can honestly
    /// answer one. It has to really narrow the list - a chip that only lights
    /// up is the "inert control" this brief ruled out.
    private static func checkOnlineChipNarrowsTheList(_ ok: inout Bool) {
        print("\n-- the Online chip really filters, and clears again --")
        let dev = devHost()
        let (controller, window, _) = page(hosts: [dev, prodHost()], live: [dev.id])
        defer { _ = window }

        controller.view.layoutSubtreeIfNeeded()
        let before = controller.debugList(.hosts).debugRowCount
        controller.debugSetOnlineOnly(true)
        controller.view.layoutSubtreeIfNeeded()
        let after = controller.debugList(.hosts).debugRowCount

        if row(controller.debugList(.hosts), labelled: "Prod Bastion") != nil {
            fail("Prod Bastion (no session) survives the Online filter", &ok)
        }
        if row(controller.debugList(.hosts), labelled: "DEV Bastion") == nil {
            fail("DEV Bastion (live) was filtered out by the Online filter", &ok)
        }
        if after >= before {
            fail("Online left the list at \(after) rows, was \(before)", &ok)
        }
        controller.debugSetOnlineOnly(false)
        controller.view.layoutSubtreeIfNeeded()
        if controller.debugList(.hosts).debugRowCount != before {
            fail("clearing Online did not restore the list", &ok)
        }
        if ok { print("  OK - \(before) rows -> \(after) with Online on, and back") }
    }

    // MARK: Quick actions

    /// **The literal list is the check.** These four are the only shortcuts
    /// this app really binds (`main.swift`'s Edit / Hosts / Keys / Snippets
    /// menus); the reference's `⌘ ↵ Connect selected` and `⌘ ⇧ P Run snippet`
    /// are bound to nothing, so they are absent rather than drawn inert.
    /// Deriving this list from the panel would assert nothing - a fifth,
    /// invented entry has to come here and argue for itself.
    private static func checkQuickActionsAreRealAndWired(_ ok: inout Bool) {
        print("\n-- quick actions name real shortcuts, and do what they name --")
        let (controller, window, _) = page(hosts: [devHost()])
        defer { _ = window }

        let panel = controller.debugSideStack.quickActions
        let wantShortcuts = ["\u{2318}K", "\u{2318}\u{2303}N", "\u{2318}\u{21E7}N", "\u{2318}\u{2325}N"]
        let wantTitles = ["Command palette", "Add host", "New key", "New snippet"]
        if panel.debugShortcuts != wantShortcuts {
            fail("shortcuts are \(panel.debugShortcuts), want \(wantShortcuts)", &ok)
        }
        if panel.debugTitles != wantTitles {
            fail("titles are \(panel.debugTitles), want \(wantTitles)", &ok)
        }

        var palette = 0
        controller.onOpenCommandPalette = { palette += 1 }
        var addedHost = 0
        controller.onAddOrEdit = { host in if host == nil { addedHost += 1 } }

        panel.debugClick(0)
        if palette != 1 { fail("⌘K fired \(palette) times, want 1", &ok) }
        panel.debugClick(1)
        if addedHost != 1 { fail("⌘⌃N fired \(addedHost) times, want 1", &ok) }
        if controller.currentTab != .hosts {
            fail("⌘⌃N left the page on the \(controller.currentTab.rawValue) tab", &ok)
        }
        if ok { print("  OK - four real shortcuts, and clicking one runs the action") }
    }

    // MARK: Toolbar

    /// The captain's own placement: "immediately next to the existing
    /// console/terminal icon". Console was the trailing-most icon, so the new
    /// one appends after it - which is also this group's own convention (a new
    /// icon never gets slotted in by topic, because that moves an icon the
    /// captain already has muscle memory for).
    private static func checkToolbarShortcutSitsBesideConsole(_ ok: inout Bool) {
        print("\n-- the toolbar shortcut sits beside the console icon --")
        let bar = DaylightBarController()
        _ = bar.view
        let buttons = bar.debugDestinationButtons()
        let destinations = buttons.map(\.destination)
        guard let consoleIndex = destinations.firstIndex(of: .console),
              let hostsIndex = destinations.firstIndex(of: .hosts) else {
            fail("the bar carries \(destinations.map(\.title)) - no console/hosts pair", &ok)
            return
        }
        if hostsIndex != consoleIndex + 1 {
            fail("Hosts is at \(hostsIndex), console at \(consoleIndex) - they are not adjacent", &ok)
        }
        if hostsIndex != destinations.count - 1 {
            fail("Hosts is not the trailing-most icon (index \(hostsIndex) of \(destinations.count))", &ok)
        }
        // It has to be wired, not merely present: an unwired icon renders
        // identically and does nothing.
        var opened: [RailDestination] = []
        bar.onSelectDestination = { opened.append($0) }
        buttons[hostsIndex].performClick(nil)
        if opened != [.hosts] {
            fail("clicking the Hosts icon opened \(opened.map(\.title))", &ok)
        }
        if ok { print("  OK - Hosts is the last icon, immediately after Console, and navigates") }
    }
}
#endif
