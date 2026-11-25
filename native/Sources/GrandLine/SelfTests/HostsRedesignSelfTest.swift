// Grand Line - native macOS app - self-test.
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
        checkTwoColumnLayoutSurvivesUntaggedHosts(&ok)
        checkWorkspaceReadsTheStores(&ok)
        checkOnlineChipNarrowsTheList(&ok)
        checkSidebarIsComposedFromTheReference(&ok)
        checkWorkspacePanelCountsComeFromTheStores(&ok)
        checkKeychainCardReadsRealState(&ok)
        checkToolsRowsAreWiredToRealDestinations(&ok)
        checkUserRowIsRealAndWired(&ok)
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

    /// The real page's own nav column, found by walking the tree rather than
    /// asked for through an accessor - so a column that exists but was never
    /// added to the view hierarchy fails here rather than passing.
    /// Every view under `view`, including `view` itself - for a check whose
    /// subject is the *absence* of something (UI1's deleted tab strip).
    static func everyView(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { everyView(in: $0) }
    }

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

        // UI-50: nothing is selected, so the inspector is hidden and the list
        // should hold the page's whole content width.
        let expected = state.rootWidth
            - HelmMetrics.pageGutter * 2
            - HelmMetrics.s4
            - HelmPageSidebar.width
        if abs(state.hostsCardFrame.width - expected) > 0.5 {
            fail("content column is \(fmt(state.hostsCardFrame.width))pt, want \(fmt(expected))pt "
                 + "- an untagged host list collapses the page's primary content", &ok)
        }
        if !stack.isHidden {
            fail("the inspector column shows with nothing selected", &ok)
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

    /// Every **hand-declared** width constraint in the page at or above
    /// `priority` whose constant is one of the column widths.
    ///
    /// `type(of:) == NSLayoutConstraint.self` is doing real work and must not
    /// be dropped: AppKit puts two kinds of *required* width constraint on
    /// ordinary views that nobody in this app wrote, and both are ordinary
    /// layout, not a window floor.
    ///
    ///   - `NSContentSizeLayoutConstraint` - a label's own intrinsic content
    ///     width, i.e. how wide that string happens to render;
    ///   - `NSAutoresizingMaskLayoutConstraint` - on AppKit's private
    ///     `NSTextFieldSimpleLabel` subview inside every `NSTextField`.
    ///
    /// Without the filter this check matched a *label whose text measured
    /// 208pt*, and it did exactly that: it passed on a developer machine with
    /// the nearest such label at 211.5pt and failed on a CI runner - whose
    /// font metrics differ by a couple of points - reporting
    /// `208.0pt @ 1000.0` for a `HelmToggleRow` subtitle. Three more labels
    /// measure within 4pt of `contentMinimumWidth`, so this was a coin flip on
    /// any page text change, not a property of the layout. The page itself was
    /// correct in both runs; only the sweep was wrong.
    private static func widthConstraintsAtOrAbove(_ priority: NSLayoutConstraint.Priority,
                                                  in view: NSView,
                                                  matching constants: [CGFloat]) -> [String] {
        var found: [String] = []
        for constraint in view.constraints
        where constraint.priority >= priority
            && type(of: constraint) == NSLayoutConstraint.self
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

        let metrics = controller.debugWorkspacePanel.debugMetrics
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
        let after = controller.debugWorkspacePanel.debugMetrics.first?.value ?? "?"
        if after != "3" { fail("adding a host left the Hosts tile at \(after)", &ok) }

        // The Keychain line is a real `LAContext` probe, so it says one of two
        // things - never the reference's unconditional "Touch ID enabled".
        //
        // **Case-insensitive, and UI1 is why.** The panel's line is a sentence
        // of its own and the sidebar footer's is the tail of one, so the two
        // differ in exactly one letter; comparing case-sensitively here failed
        // on CI (a runner has no biometry, so it takes the branch this Mac
        // never does) while passing on every developer machine with Touch ID.
        // The property is which *fact* is stated, not how it is capitalised.
        let status = controller.debugWorkspacePanel.debugStatusText
        if !(status.localizedCaseInsensitiveContains("Touch ID ready")
             || status.localizedCaseInsensitiveContains("no biometry")) {
            fail("keychain status reads \"\(status)\"", &ok)
        }
        // UI1: the page states this fact twice - here and in the sidebar's
        // footer card - and it used to state it in two vocabularies ("Touch ID
        // enabled" against "Touch ID ready"). One function owns the wording
        // now, so the two must agree, and this is what fails if a future edit
        // gives one of them its own words back.
        let footer = controller.debugKeychainCard.debugDetail
        let phrase = HostsKeychainCard.biometryPhrase(CredentialVaultKeyStore.biometryAvailable)
        if !footer.localizedCaseInsensitiveContains(phrase)
            || !status.localizedCaseInsensitiveContains(phrase) {
            fail("the two keychain lines disagree: panel \"\(status)\" vs footer "
                 + "\"\(footer)\" (both should carry \"\(phrase)\")", &ok)
        }
        if ok { print("  OK - 2/1/1/1 from the real stores, tiles follow a write, status is a real probe") }
    }

    // MARK: Selected

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

    // MARK: Toolbar

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
        // UI-45: one sidebar shape across the app - the plain surface the
        // Tasks sidebar uses. A boxed nav panel was a second bordered surface
        // beside the page's own cards.
        if nav.debugSurfaceIsPanel { fail("the column is boxed again - UI-45 puts every sidebar on the plain surface", &ok) }
        // Review #3's UI1 inverted this one. It used to assert the WORKSPACE
        // rows *were* badged; the badge was the fourth statement of the same
        // number on one screen (this row, the card header, the drill subtitle
        // and the Workspace panel's inventory tile), and the finding's remedy
        // is one authoritative statement per concern. The count lives on the
        // panel now - `checkWorkspacePanelCountsComeFromTheStores` below - and
        // these rows are navigation.
        if nav.debugCounts.values.contains(where: { !$0.isEmpty }) {
            fail("the WORKSPACE rows still carry counts: \(nav.debugCounts)", &ok)
        }
        if nav.debugHasCountBadges {
            fail("the column still builds count badges - with no counts to show they are "
                 + "empty pills", &ok)
        }
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
        if ok { print("  OK - WORKSPACE(3) over TOOLS(2), panelled, uncounted, with a bottom-anchored footer") }
    }

    /// UI1 moved this page's counts to one place. This is that place.
    ///
    /// Same shape as the sidebar-badge check it replaces, and for the same
    /// reason: read off the *rendered* tiles, then drive a real store write -
    /// a check that re-derived the number from the store would agree with
    /// itself forever.
    private static func checkWorkspacePanelCountsComeFromTheStores(_ ok: inout Bool) {
        print("\n-- the Workspace panel's counts are the stores' own, and follow a write --")
        let (controller, window, hostStore) = page(hosts: [devHost()],
                                                   keys: [navKey("work"), navKey("legacy")],
                                                   snippets: [navSnippet("tail")])
        defer { _ = window }
        let tiles = controller.debugWorkspacePanel.debugMetrics
        guard tiles.count >= 3 else {
            fail("the Workspace panel renders \(tiles.count) tiles, want at least 3", &ok); return
        }
        let want = ["1", "2", "1"]
        for (index, value) in want.enumerated() where tiles[index].value != value {
            fail("the \(tiles[index].caption) tile reads \(tiles[index].value), want \(value)", &ok)
        }
        hostStore.add(prodHost())
        let after = controller.debugWorkspacePanel.debugMetrics
        if after.first?.value != "2" {
            fail("after adding a host the Hosts tile reads \(after.first?.value ?? "nil"), want 2", &ok)
        }
        // The other three places that used to state this number must stay
        // quiet, or the finding is only half fixed. The card header is the one
        // of them this suite can read directly.
        if controller.debugHostsTitle.contains("(") {
            fail("the Hosts card header is \(controller.debugHostsTitle) - UI1 took the count off it", &ok)
        }
        if ok { print("  OK - 1/2/1 from the real stores, the Hosts tile follows a write, "
                      + "and the card header states no count") }
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
