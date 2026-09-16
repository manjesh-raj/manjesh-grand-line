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
        print("== Hosts redesign: three columns, real panels ==")
        var ok = true
        checkThreeColumnLayout(&ok)
        checkTwoColumnLayoutSurvivesUntaggedHosts(&ok)
        checkWorkspaceReadsTheStores(&ok)
        checkDetailFollowsSelectionAndTab(&ok)
        checkDetailActionsAreTheRealOnes(&ok)
        checkEmptyDetailTearsDownItsRows(&ok)
        checkOnlineChipNarrowsTheList(&ok)
        checkQuickActionsAreRealAndWired(&ok)
        checkToolbarShortcutSitsBesideConsole(&ok)
        checkSidebarIsComposedFromTheReference(&ok)
        checkSidebarAndTabsAreOneMechanism(&ok)
        checkSidebarCountsComeFromTheStores(&ok)
        checkKeychainCardReadsRealState(&ok)
        checkToolsRowsAreWiredToRealDestinations(&ok)
        checkUserRowIsRealAndWired(&ok)
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
    /// **Inverted, not deleted, when `fm/grand-line-hosts-sidebar-restore` put
    /// the nav column back.** This used to assert two columns, because
    /// `fm/grand-line-hosts-page-redesign` had scoped a `HelmPageSidebar` out
    /// by name; the captain used what that shipped, put it beside his own
    /// reference and asked for the column back. So the shape being asserted
    /// moved, and the guarantees around it did not: three fixed-or-flexible
    /// columns that tile the page exactly, and not one of them a window floor.
    /// Re-adding the column has to come here and read why it went, which is
    /// this codebase's own convention for an assertion that has become a
    /// record of an overturned decision.
    private static func checkThreeColumnLayout(_ ok: inout Bool) {
        print("\n-- three columns, and none of them is a window floor --")
        let (controller, window, _) = page(hosts: [devHost(), prodHost()])
        defer { _ = window }

        let stack = controller.debugSideStack
        let state = controller.debugState()
        guard let nav = findSidebar(in: controller.view) else {
            fail("no HelmPageSidebar in the page - the nav column is missing", &ok)
            return
        }
        let expected = state.rootWidth
            - HelmMetrics.pageGutter * 2
            - HelmPageSidebar.width
            - HelmMetrics.s4
            - HostsSideStack.width
            - HelmMetrics.s4
        if abs(state.hostsCardFrame.width - expected) > 0.5 {
            fail("content column is \(fmt(state.hostsCardFrame.width))pt, want \(fmt(expected))pt "
                 + "(page \(fmt(state.rootWidth)) - gutters - \(fmt(HelmPageSidebar.width))pt nav "
                 + "- \(fmt(HostsSideStack.width))pt side column)", &ok)
        }
        if abs(nav.frame.width - HelmPageSidebar.width) > 0.5 {
            fail("nav column is \(fmt(nav.frame.width))pt, want \(fmt(HelmPageSidebar.width))pt", &ok)
        }
        if abs(nav.frame.minX - HelmMetrics.pageGutter) > 0.5 {
            fail("nav column starts at \(fmt(nav.frame.minX))pt, want the page gutter", &ok)
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
                                                          HelmPageSidebar.width,
                                                          HostsController.contentMinimumWidth])
        if !floors.isEmpty {
            fail("\(floors.count) column constraint(s) at or above windowSizeStayPut: \(floors)", &ok)
        }

        // **The page must genuinely hold a narrow window**, and the way that
        // is measured moved with the third column.
        //
        // This used to read `view.fittingSize.width <= width`. That is a
        // page's *preferred* width, not a floor - every column here is pinned
        // at `HelmDaylightPriority.contentTie` (499), below
        // `NSLayoutPriorityWindowSizeStayPut`, so all three yield before the
        // window has to - and a three-column page legitimately prefers more
        // than 1016pt while still resolving correctly at it. Measured: the
        // preference is a flat 1198.5 at every swept width while the three
        // columns tile 1016 exactly. Asserting the preference would therefore
        // have failed for a page that is behaving perfectly, so what is
        // asserted instead is the thing that was ever really meant - that at a
        // narrow window the three columns still tile the page with nothing
        // overflowing it. The *window* half of the same guarantee is
        // `AppShellBodyWidthSelfTest`, which sweeps every destination.
        for width in [1016.0, 1100.0, 1900.0] as [CGFloat] {
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 860)
            controller.view.layoutSubtreeIfNeeded()
            let s = controller.debugState()
            guard let nav = findSidebar(in: controller.view) else { continue }
            let tiled = HelmMetrics.pageGutter + nav.frame.width + HelmMetrics.s4
                + s.hostsCardFrame.width + HelmMetrics.s4
                + controller.debugSideStack.frame.width + HelmMetrics.pageGutter
            if abs(tiled - width) > 0.5 {
                fail("at \(fmt(width))pt the three columns tile \(fmt(tiled))pt "
                     + "(nav \(fmt(nav.frame.width)) + content \(fmt(s.hostsCardFrame.width)) "
                     + "+ side \(fmt(controller.debugSideStack.frame.width)))", &ok)
            }
            if s.hostsCardFrame.width < 1 {
                fail("at \(fmt(width))pt the content column collapsed", &ok)
            }
        }
        if ok {
            print("  OK - \(fmt(HelmPageSidebar.width))pt nav + content + "
                  + "\(fmt(HostsSideStack.width))pt side column tile the page, no window floor")
        }
    }

    /// The real page's own nav column, found by walking the tree rather than
    /// asked for through an accessor - so a column that exists but was never
    /// added to the view hierarchy fails here rather than passing.
    static func findSidebar(in view: NSView) -> HelmPageSidebar? {
        if let nav = view as? HelmPageSidebar { return nav }
        for child in view.subviews {
            if let found = findSidebar(in: child) { return found }
        }
        return nil
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
        print("\n-- the columns hold when no host carries a tag --")
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
            - HelmMetrics.s4
            - HelmPageSidebar.width
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
    // MARK: - The nav column (fm/grand-line-hosts-sidebar-restore)

    /// The captain's reference draws four things in this column, and each one
    /// is checked for **where it came from**, not that a view exists - the same
    /// standard the panels on the other side of the page are held to, and the
    /// reason it matters here is that the reference itself is full of invented
    /// data (a hardcoded 68% keychain bar, a decorative user row).
    private static func checkSidebarIsComposedFromTheReference(_ ok: inout Bool) {
        print("\n-- the nav column is present, panelled, and grouped as the reference groups it --")
        let (controller, window, _) = page(hosts: [devHost(), prodHost()])
        defer { _ = window }
        guard let nav = findSidebar(in: controller.view) else {
            fail("no HelmPageSidebar in the real page's view tree", &ok)
            return
        }
        // Genuinely rendered, not merely constructed: the bug this restores
        // from was that the column was never built at all, and a check that
        // only asked the controller for its property would pass for a column
        // that never reached the tree.
        if nav.isHidden || nav.alphaValue < 0.99 || nav.frame.width < 1 || nav.frame.height < 1 {
            fail("the nav column is in the tree but not rendered: hidden=\(nav.isHidden) "
                 + "alpha=\(nav.alphaValue) frame=\(nav.frame)", &ok)
        }
        if nav.debugHeaders != ["Workspace", "Tools"] {
            fail("section headers are \(nav.debugHeaders), want [Workspace, Tools]", &ok)
        }
        if nav.debugRowTitles != ["Hosts", "SSH Keys", "Snippets", "Activity", "Commands"] {
            fail("rows are \(nav.debugRowTitles)", &ok)
        }
        // WORKSPACE narrows the list; TOOLS leaves it alone. A TOOLS row that
        // latched selected would claim the list had been filtered to something
        // (`HelmPageSidebar.RowKind`).
        if nav.debugRowKinds != ["filter", "filter", "filter", "action", "action"] {
            fail("row kinds are \(nav.debugRowKinds) - a TOOLS row must not latch", &ok)
        }
        if !nav.debugSurfaceIsPanel { fail("the column is not a panel surface", &ok) }
        if !nav.debugHasCountBadges { fail("the WORKSPACE counts are not badges", &ok) }
        if !nav.debugHasFooter { fail("the column has no footer (keychain card + user row)", &ok) }
        // The footer is bottom-anchored, which is the whole reason this page
        // pins the column's bottom with a required `==` rather than the `<=`
        // Poneglyph and Schedules use.
        let card = controller.debugKeychainCard
        let user = controller.debugUserRow
        let cardInNav = card.convert(card.bounds, to: nav)
        let userInNav = user.convert(user.bounds, to: nav)
        // `HelmPageSidebar` is a plain `NSView`, which is **not flipped** - so
        // y grows upward and the visually-lower user row has the *smaller*
        // origin. Writing these two the flipped way round is what a first pass
        // here did, and it fails against a column that is laid out correctly.
        if nav.isFlipped {
            fail("the nav column became flipped - the geometry below reads the wrong way round", &ok)
        }
        if cardInNav.minY < userInNav.maxY - 0.5 {
            fail("the keychain card does not sit above the user row "
                 + "(card minY \(fmt(cardInNav.minY)), user maxY \(fmt(userInNav.maxY)))", &ok)
        }
        let bottomGap = userInNav.minY
        if bottomGap < -0.5 || bottomGap > HelmPageSidebar.Metrics.panelInset + 0.5 {
            fail("the footer sits \(fmt(bottomGap))pt off the column's bottom - it is not anchored there", &ok)
        }
        if ok { print("  OK - WORKSPACE(3) over TOOLS(2), panelled, badged, with a bottom-anchored footer") }
    }

    /// The tab strip stays (the captain's own target screenshot shows both), so
    /// the two controls have to be **one mechanism** - which is the thing
    /// `fm/grand-line-hosts-page-redesign` was right to worry about when it
    /// scoped a column out, and the thing that makes keeping both safe.
    private static func checkSidebarAndTabsAreOneMechanism(_ ok: inout Bool) {
        print("\n-- the nav column and the tab strip are one mechanism --")
        let (controller, window, _) = page(hosts: [devHost()])
        defer { _ = window }
        guard let nav = findSidebar(in: controller.view) else {
            fail("no nav column", &ok); return
        }
        if nav.selection != HostsTab.hosts.rawValue {
            fail("the column opens on \(nav.selection ?? "nil"), want hosts", &ok)
        }
        nav.debugClickRow(1)
        if controller.currentTab != .keys {
            fail("clicking SSH Keys left the page on \(controller.currentTab)", &ok)
        }
        controller.select(tab: .snippets)
        if nav.selection != HostsTab.snippets.rawValue {
            fail("switching to Snippets left the column on \(nav.selection ?? "nil")", &ok)
        }
        // A TOOLS row navigates away; it must move neither the tab nor the
        // selection under it.
        var activity = 0
        controller.onOpenActivity = { activity += 1 }
        nav.debugClickRow(3)
        if activity != 1 { fail("the Activity row fired \(activity) time(s)", &ok) }
        if controller.currentTab != .snippets {
            fail("the Activity row changed the tab to \(controller.currentTab)", &ok)
        }
        if nav.selection != HostsTab.snippets.rawValue {
            fail("the Activity row moved the selection to \(nav.selection ?? "nil")", &ok)
        }
        if ok { print("  OK - either control moves both, and a TOOLS row moves neither") }
    }

    private static func checkSidebarCountsComeFromTheStores(_ ok: inout Bool) {
        print("\n-- the nav counts are the stores' own, and follow a write --")
        let (controller, window, hostStore) = page(hosts: [devHost()],
                                                   keys: [navKey("work"), navKey("legacy")],
                                                   snippets: [navSnippet("tail")])
        defer { _ = window }
        guard let nav = findSidebar(in: controller.view) else { fail("no nav column", &ok); return }
        let want = [HostsTab.hosts.rawValue: "1", HostsTab.keys.rawValue: "2",
                    HostsTab.snippets.rawValue: "1"]
        for (id, value) in want where nav.debugCounts[id] != value {
            fail("\(id) reads \(nav.debugCounts[id] ?? "nil"), want \(value)", &ok)
        }
        // Read off the rendered labels and then driven by a real store write -
        // a check that re-derived the number would agree with itself forever.
        hostStore.add(prodHost())
        if nav.debugCounts[HostsTab.hosts.rawValue] != "2" {
            fail("after adding a host the count reads "
                 + "\(nav.debugCounts[HostsTab.hosts.rawValue] ?? "nil"), want 2", &ok)
        }
        if ok { print("  OK - 1/2/1 from the real stores, and the host count follows a write") }
    }

    /// The reference's bar is a hardcoded 68%. This one is a real fraction of
    /// the saved fleet, and a fleet with nothing in it reports none rather than
    /// implying 0% (GL-14).
    private static func checkKeychainCardReadsRealState(_ ok: inout Bool) {
        print("\n-- the keychain card is real state, never the reference's demo numbers --")
        var managed = devHost()
        let k = navKey("work")
        managed.keyID = k.id
        let (controller, window, _) = page(hosts: [managed, prodHost()], keys: [k, navKey("legacy")])
        defer { _ = window }
        let card = controller.debugKeychainCard
        if card.debugVerdict != "Protected" {
            fail("verdict is \(card.debugVerdict) with two keys saved", &ok)
        }
        if !card.debugDetail.hasPrefix("2 keys") {
            fail("detail is \(card.debugDetail) - the key count is not the store's", &ok)
        }
        if abs(card.debugFraction - 0.5) > 0.001 {
            fail("the bar reads \(card.debugFraction), want 0.5 (1 of 2 hosts on a managed key)", &ok)
        }
        if card.debugDetail.contains("Touch ID") != CredentialVaultKeyStore.biometryAvailable {
            fail("the biometry line does not match the real probe "
                 + "(\(CredentialVaultKeyStore.biometryAvailable))", &ok)
        }

        let (empty, emptyWindow, _) = page()
        defer { _ = emptyWindow }
        if empty.debugKeychainCard.debugVerdict != "Empty" {
            fail("an empty keychain reads \(empty.debugKeychainCard.debugVerdict)", &ok)
        }
        if empty.debugKeychainCard.debugFraction != 0 {
            fail("a fleet with no hosts reports a fraction of "
                 + "\(empty.debugKeychainCard.debugFraction)", &ok)
        }
        if ok { print("  OK - Protected/2 keys/0.5 from the stores, and no fabricated fraction when empty") }
    }

    /// A nav row that opens nothing is a control that lies about what it does -
    /// which is why the reference's other sidebar entries are absent here
    /// rather than drawn inert, exactly as `CredentialVaultSidebar` and
    /// `SchedulesController` each decided for their own reference's extras.
    private static func checkToolsRowsAreWiredToRealDestinations(_ ok: inout Bool) {
        print("\n-- both TOOLS rows open something that really exists --")
        let (controller, window, _) = page()
        defer { _ = window }
        guard let nav = findSidebar(in: controller.view) else { fail("no nav column", &ok); return }
        var activity = 0, commands = 0
        controller.onOpenActivity = { activity += 1 }
        controller.onOpenCommands = { commands += 1 }
        nav.debugClickRow(3)
        nav.debugClickRow(4)
        if activity != 1 { fail("Activity fired \(activity) time(s)", &ok) }
        if commands != 1 { fail("Commands fired \(commands) time(s)", &ok) }
        if ok { print("  OK - Activity and Commands each reach their forwarded closure") }
    }

    private static func checkUserRowIsRealAndWired(_ ok: inout Bool) {
        print("\n-- the user row is the real account, and its menu does what it names --")
        let (controller, window, _) = page()
        defer { _ = window }
        let row = controller.debugUserRow
        let expected = HostsUserRow.currentUserName()
        if row.debugName != expected {
            fail("the row reads \(row.debugName), want the real account name \(expected)", &ok)
        }
        if row.debugName.isEmpty { fail("the account name is empty", &ok) }
        if row.debugInitial != String(expected.prefix(1)).uppercased() {
            fail("the avatar initial is \(row.debugInitial)", &ok)
        }
        var settings = 0, logout = 0
        controller.onOpenSettings = { settings += 1 }
        controller.onLogout = { logout += 1 }
        row.debugPickSettings()
        row.debugPickLogout()
        if settings != 1 { fail("Settings fired \(settings) time(s)", &ok) }
        if logout != 1 { fail("Log Out fired \(logout) time(s)", &ok) }
        if ok { print("  OK - \(expected) from NSFullUserName(), with both menu items wired") }
    }

    private static func navKey(_ label: String) -> SSHKey {
        SSHKey(label: label, type: .ed25519, publicKey: "ssh-ed25519 AAAA",
               fingerprint: "SHA256:\(label)")
    }

    private static func navSnippet(_ label: String) -> Snippet {
        Snippet(label: label, command: "echo \(label)")
    }
}
#endif
