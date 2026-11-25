// Grand Line - native macOS app.
//
// The page-level polish findings UXP-01 to UXP-20 of the 2026-10 full review.
// One case (or a few) per finding, each written against what is drawn rather
// than what a helper computed, and each confirmed to fail with its fix
// reverted - the PR that added this file names the injection per case.
//
// Window-backed: every case mounts a real page in an `OffScreenProbe` window,
// and several read resolved geometry from a real layout pass.
//
//   swift build && FM_RUN_PAGE_POLISH_UXP_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum PagePolishUXPSelfTest {

    static func run() -> Bool {
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        let cases: [(String, () -> Bool)] = [
            ("uxp01ReviewKeepsRealCountsOnAPartialFailure", uxp01ReviewKeepsRealCountsOnAPartialFailure),
            ("uxp02ProjectCardsRepaintOnAThemeSwitch", uxp02ProjectCardsRepaintOnAThemeSwitch),
            ("uxp08EveryPageShowsAtMostOnePrimaryButton", uxp08EveryPageShowsAtMostOnePrimaryButton),
            ("uxp08EveryRefreshComesFromTheOneFactory", uxp08EveryRefreshComesFromTheOneFactory),
            ("uxp08RefreshPillWearsTheSecondaryPalette", uxp08RefreshPillWearsTheSecondaryPalette),
            ("uxp13PageEmptyStatesSitInTheMiddleOfTheContentArea", uxp13PageEmptyStatesSitInTheMiddle),
            ("uxp06TheFirstmateHomePathAppearsOnce", uxp06TheFirstmateHomePathAppearsOnce),
            ("uxp10HostsNamesItselfOnceAndKeepsItsEmptyStateNearItsAction", uxp10HostsEmptyStateAndName),
            ("uxp11AnEmptyNotebookShowsOneEmptyState", uxp11AnEmptyNotebookShowsOneEmptyState),
            ("uxp14DevOpsCommandsOpensOnACommand", uxp14DevOpsCommandsOpensOnACommand),
            ("uxp15DocsDrawsNoToolbarOverItsEmptyState", uxp15DocsDrawsNoToolbarOverItsEmptyState),
            ("uxp16DictationResetOnlyOffTheDefaultAndALabelledWordsField", uxp16DictationResetAndPlaceholder),
            ("uxp17OneNamePerLevel", uxp17OneNamePerLevel),
            ("uxp09ReviewForgePlaceholderRowIsTallEnoughToDraw", uxp09ForgePlaceholderRowIsTallEnough),
        ]
        var failed = 0
        for (name, body) in cases {
            let passed = autoreleasepool { body() }
            print(passed ? "PASS \(name)" : "FAIL \(name)")
            if !passed { failed += 1 }
        }
        print(failed == 0
              ? "PagePolishUXPSelfTest: all \(cases.count) cases passed"
              : "PagePolishUXPSelfTest: \(failed)/\(cases.count) cases FAILED")
        return failed == 0
    }

    // MARK: Helpers

    private static func mountReview() -> (window: NSWindow, controller: ReviewController) {
        let controller = ReviewController()
        let window = OffScreenProbe.window(width: 1512, height: 950)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func pr(_ index: Int, forge: String = "github", checks: String = "green") -> MergedPR {
        MergedPR(source: "forge", taskID: nil, repo: "acme/repo-\(index)",
                 url: "https://github.com/acme/repo-\(index)/pull/\(index)", number: index,
                 title: "Change \(index)", checks: checks, forge: forge)
    }

    // MARK: UXP-01

    /// A partial failure found real PRs, so its counts stand - with a tooltip
    /// that says they cover only the repositories that answered.
    private static func uxp01ReviewKeepsRealCountsOnAPartialFailure() -> Bool {
        var ok = true
        let (window, review) = mountReview()
        defer { _ = window }
        review.debugRender([pr(1), pr(2, checks: "pending")],
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["a", "b"]))
        let values = review.debugStatTiles.map(\.value)
        check(values.first == "2", "UXP-01: a partial failure should keep its found count, drew \(values)", &ok)
        check(!review.debugIsFailureStateVisible, "UXP-01: a partial failure is not the total-failure block", &ok)
        check(review.debugStatTileToolTips.allSatisfy { ($0 ?? "").contains("only the repositories") },
              "UXP-01: a partial failure's tiles should say what their counts cover", &ok)
        check(review.drillHeaderSubtitle == "Couldn't reach the forge for 2 repositories.",
              "UXP-01: unexpected partial-failure subtitle \(review.drillHeaderSubtitle ?? "nil")", &ok)
        return ok
    }

    // MARK: UXP-02

    private static func withScratchShiftStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-polish-uxp-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func mountShift(_ store: ShiftStore) -> (window: NSWindow, controller: ShiftController) {
        let controller = ShiftController(store: store)
        let window = OffScreenProbe.window(width: 1512, height: 950)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    /// A project card built under Dusk is repainted when the theme flips to
    /// Daylight, with no data render in between. It used to keep Dusk's
    /// near-white title on Daylight's white card.
    private static func uxp02ProjectCardsRepaintOnAThemeSwitch() -> Bool {
        var ok = true
        guard let dusk = HelmTheme.theme(id: "dusk"), let daylight = HelmTheme.theme(id: "daylight") else {
            fail("UXP-02: the dusk and daylight palettes should exist", &ok)
            return ok
        }
        // The fixture only discriminates if the two inks really differ.
        check(!sameColor(HelmTheme.nsColor(dusk.chromeInkHex), HelmTheme.nsColor(daylight.chromeInkHex)),
              "UXP-02: Dusk's and Daylight's ink should differ, or this case cannot fail", &ok)
        ThemeManager.shared.setTheme(dusk)
        withScratchShiftStore { store in
            var project = ShiftProject.fresh()
            project.name = "Infra hardening"
            store.addProject(project)
            let (window, shift) = mountShift(store)
            defer { _ = window }
            guard let card = shift.debugProjectCards.first else {
                fail("UXP-02: the Tasks page built no project card for a seeded project", &ok)
                return
            }
            check(sameColor(card.debugNameColor, HelmTheme.nsColor(dusk.chromeInkHex)),
                  "UXP-02: the card's title should start in Dusk's ink", &ok)
            ThemeManager.shared.setTheme(daylight)
            check(shift.debugProjectCards.first === card,
                  "UXP-02: a theme switch should repaint the card, not rebuild it (GL-24)", &ok)
            check(sameColor(card.debugNameColor, HelmTheme.nsColor(daylight.chromeInkHex)),
                  "UXP-02: after a switch to Daylight the card's title is still painted "
                  + "\(card.debugNameColor.map { "\($0)" } ?? "nil")", &ok)
        }
        ThemeManager.shared.setTheme(dusk)
        return ok
    }

    // MARK: UXP-03

    // MARK: UXP-18

    private static func seedPlainTasks(_ store: ShiftStore, count: Int) {
        for index in 0..<count {
            var task = ShiftTask.fresh()
            task.title = "Plain task \(index + 1)"
            task.status = .todo
            store.addTask(task)
        }
    }

    // MARK: UXP-08

    /// Every visible `.primary` `HelmButton` in a view tree - what is drawn,
    /// not what a file declares.
    static func visiblePrimaryButtons(in root: NSView) -> [HelmButton] {
        var found: [HelmButton] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue == 0 { return }
            if let button = view as? HelmButton, button.variant == .primary { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// One primary action per surface, on every page, bar included. Vault
    /// showed three filled accent buttons at once (Refresh, Add Secret,
    /// Export Recipe), and Refresh was a filled primary on five pages.
    private static func uxp08EveryPageShowsAtMostOnePrimaryButton() -> Bool {
        var ok = true
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }
        for destination in RailDestination.allCases {
            shell.workspace.navigator.show(destination)
            shell.view.layoutSubtreeIfNeeded()
            let primaries = visiblePrimaryButtons(in: shell.view)
            let titles = primaries.map { $0.title.isEmpty ? ($0.toolTip ?? "(icon)") : $0.title }
            check(primaries.count <= 1,
                  "UXP-08: \(destination.rawValue) shows \(primaries.count) primary buttons at once: \(titles)", &ok)
        }
        return ok
    }

    /// One Refresh treatment: a source that builds its own "Refresh"
    /// `HelmButton` (rather than `HelmButton.refresh`) is how a fifth or sixth
    /// look gets back in.
    private static func uxp08EveryRefreshComesFromTheOneFactory() -> Bool {
        var ok = true
        guard let files = SelfTestSources.appSourceFiles(), !files.isEmpty else {
            fail("UXP-08: could not locate the app sources - this check would silently pass", &ok)
            return ok
        }
        var offenders: [String] = []
        for file in files where !file.path.contains("/SelfTests/") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("HelmButton(title: \"Refresh\"") && !text.contains("static func refresh(size:") {
                offenders.append(file.lastPathComponent)
            }
        }
        check(offenders.isEmpty, "UXP-08: these files build their own Refresh button: \(offenders)", &ok)
        return ok
    }

    /// A refresh pill that is not a page's primary action wears the
    /// secondary button's palette; only an opted-in prominent pill is filled.
    private static func uxp08RefreshPillWearsTheSecondaryPalette() -> Bool {
        var ok = true
        let theme = HelmTheme.theme(id: "daylight") ?? ThemeManager.shared.theme
        let plain = HelmRefreshPill(tooltip: "Re-check")
        plain.applyTheme(theme)
        let secondary = HelmButton.palette(variant: .secondary, tint: nil, theme: theme)
        check(sameColor(plain.normalColor, secondary.fill),
              "UXP-08: a plain refresh pill should be filled like a secondary button", &ok)
        let prominent = HelmRefreshPill(title: "Check all", tooltip: "Check", prominent: true)
        prominent.applyTheme(theme)
        check(sameColor(prominent.normalColor, HelmTheme.nsColor(theme.accentHex)),
              "UXP-08: a prominent pill should keep the accent fill", &ok)
        check(!sameColor(secondary.fill, HelmTheme.nsColor(theme.accentHex)),
              "UXP-08: the secondary fill and the accent should differ, or this case cannot fail", &ok)
        return ok
    }

    // MARK: UXP-13

    /// Every page-level empty state (a `.standard`, unboxed `HelmEmptyState`)
    /// on an empty page has its centre in the middle third of the content
    /// area, and is no wider than `HelmEmptyState.pageMaxWidth`. They used to
    /// sit in five different places: pinned near the top, centred in the
    /// window, top-aligned above a drop zone, centred in a card.
    private static func uxp13PageEmptyStatesSitInTheMiddle() -> Bool {
        var ok = true
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }
        var measured = 0
        for destination in RailDestination.allCases {
            shell.workspace.navigator.show(destination)
            shell.view.layoutSubtreeIfNeeded()
            let body = shell.bodyContainerForTests
            let area = body.convert(body.bounds, to: nil)
            for state in visiblePageEmptyStates(in: body) {
                measured += 1
                let frame = state.convert(state.bounds, to: nil)
                // A page's own content area is the body; its middle third is
                // the band a centred state's midpoint must land in.
                let third = area.height / 3
                let midY = frame.midY
                check(midY >= area.minY + third - 0.5 && midY <= area.maxY - third + 0.5,
                      "UXP-13: \(destination.rawValue)'s empty state is centred at y \(Int(midY)), outside the middle "
                      + "third of its \(Int(area.minY))-\(Int(area.maxY)) content area", &ok)
            }
        }
        check(measured >= 3, "UXP-13: only \(measured) page-level empty states were found - the sweep is vacuous", &ok)
        return ok
    }

    static func visiblePageEmptyStates(in root: NSView) -> [HelmEmptyState] {
        var found: [HelmEmptyState] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue == 0 { return }
            if let state = view as? HelmEmptyState, state.debugIsPageLevel, state.frame.height > 0 {
                found.append(state)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: UXP-06 and UXP-07

    /// The firstmate home's path is printed once on Bootstrap - in the field
    /// where it can be changed - and the step captions and Fleet's setup
    /// banner say the state in words. It used to be on one Bootstrap card
    /// three times and in Fleet's banner besides.
    private static func uxp06TheFirstmateHomePathAppearsOnce() -> Bool {
        var ok = true
        let path = FirstmateHome.root.path
        check(!SetupStepCaption.firstmateHome().contains(path),
              "UXP-06: the firstmate home step's caption prints the path", &ok)
        check(!SetupStepCaption.dotfiles(isLoading: false, repoPath: "/tmp/dotfiles").contains("/tmp/dotfiles"),
              "UXP-06: the dotfiles step's caption prints the repo path its body already shows", &ok)
        check(SetupStepCaption.dotfiles(isLoading: true, repoPath: nil) != "Checking ~/.dotfiles\u{2026}",
              "UXP-07: the dotfiles caption repeats the body's loading line while checking", &ok)
        let banner = FleetGreeting.answer(tasks: [], prs: .value(0), homeOk: false)
        check(!banner.meta.contains(path), "UXP-06: Fleet's finish-setup banner prints the path", &ok)

        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }
        shell.workspace.navigator.show(.bootstrap)
        shell.view.layoutSubtreeIfNeeded()
        let copies = shell.debugBootstrap.debugHomePathCopies
        check(copies == 1, "UXP-06: Bootstrap prints the firstmate home's path \(copies) times, want once", &ok)
        return ok
    }

    // MARK: UXP-04

    // MARK: UXP-10

    /// An empty Hosts list: no card header restating "Hosts", and the empty
    /// state directly under the built-in row with its own Add Host button -
    /// in the table, and over the cards.
    private static func uxp10HostsEmptyStateAndName() -> Bool {
        var ok = true
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-polish-hosts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        defer {
            unsetenv("FM_HOSTS_FILE"); unsetenv("FM_KEYS_FILE"); unsetenv("FM_SNIPPETS_FILE")
            try? FileManager.default.removeItem(at: dir)
        }
        let theme = HelmTheme.theme(id: "dusk") ?? ThemeManager.shared.theme
        ThemeManager.shared.setTheme(theme)
        let hosts = HostsController(hostStore: HostStore(), keyStore: SSHKeyStore(), snippetStore: SnippetStore())
        let window = OffScreenProbe.window(width: 1400, height: 860)
        defer { _ = window }
        window.contentView = hosts.view
        hosts.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        hosts.view.layoutSubtreeIfNeeded()

        let table = hosts.debugHostsTable
        check(table.card.debugHeaderTitle == nil,
              "UXP-10: the hosts card still carries its own header "
              + "\"\(table.card.debugHeaderTitle ?? "")\"", &ok)

        let rows = table.debugRows
        guard let emptyIndex = rows.firstIndex(where: { if case .empty = $0.kind { return true }; return false }) else {
            fail("UXP-10: an empty Hosts list built no empty state", &ok)
            return ok
        }
        check(emptyIndex == 1 && rows.first?.key == HostsController.firstmateRowKey,
              "UXP-10: the empty state should sit directly under the built-in row, not at row \(emptyIndex)", &ok)
        check(rows[emptyIndex].emptyAction?.title == "Add Host", "UXP-10: the empty state should carry its own Add Host", &ok)
        check(hosts.hostsGrid.debugEmptyState != nil, "UXP-10: the host cards show no empty state", &ok)
        return ok
    }

    // MARK: UXP-11

    /// An empty notebook draws one empty state, in the editor, carrying both
    /// actions, and no preview card. It used to draw three at once: the page
    /// column's (with its own New page), the editor's and the preview's.
    private static func uxp11AnEmptyNotebookShowsOneEmptyState() -> Bool {
        var ok = true
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }
        shell.workspace.navigator.show(.notebook)
        shell.view.layoutSubtreeIfNeeded()
        let body = shell.bodyContainerForTests
        var states: [HelmEmptyState] = []
        var newPageButtons = 0
        var sawPreviewTitle = false
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue == 0 { return }
            if let state = view as? HelmEmptyState, state.frame.height > 0 { states.append(state) }
            if let button = view as? NSButton, button.title == "New page" { newPageButtons += 1 }
            if let card = view as? HelmCard, card.debugHeaderTitle == "Preview", card.frame.width > 0 {
                sawPreviewTitle = true
            }
            view.subviews.forEach(walk)
        }
        walk(body)
        check(states.count == 1, "UXP-11: an empty notebook draws \(states.count) empty states, want one", &ok)
        // R2-UX-04: New page is the toolbar's far-right primary, so the one
        // offer is there and the page's body adds none of its own.
        // By identity: below `compactToolbarActionsBelow` the toolbar draws
        // it as its plus alone, so its title is not the test.
        let primary = shell.workspace.notebook.workspacePrimaryAction
        let toolbarOffer = primary != nil && shell.toolbar.debugPrimaryAction === primary
        check(toolbarOffer && newPageButtons == 0,
              "UXP-11: an empty notebook offers New page \(newPageButtons) times in the page and "
                + "\(toolbarOffer ? "once" : "not") in the toolbar, want only the toolbar's", &ok)
        check(!sawPreviewTitle, "UXP-11: the preview card shows with no page to preview", &ok)
        return ok
    }

    // MARK: UXP-14

    /// DevOps Commands opens on a read-only command's detail, not on an
    /// empty detail pane that left most of the window blank.
    private static func uxp14DevOpsCommandsOpensOnACommand() -> Bool {
        var ok = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-polish-commands-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_COMMAND_LIBRARY_DIR", root.path, 1)
        defer {
            unsetenv("FM_COMMAND_LIBRARY_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        let store = CommandLibraryStore()
        let controller = CommandLibraryController(store: store)
        let window = OffScreenProbe.window(width: 1400, height: 860)
        defer { _ = window }
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()
        guard let page = controller.debugPage else {
            fail("UXP-14: could not reach the commands page", &ok)
            return ok
        }
        check(page.debugDetailShowsCommand, "UXP-14: DevOps Commands opened on an empty detail pane", &ok)
        let risk = page.debugSelectedCommandID.flatMap { store.command(id: $0) }?.risk
        check(risk == .readOnly, "UXP-14: the default command should be read-only, got \(String(describing: risk))", &ok)
        return ok
    }

    // MARK: UXP-15 and UXP-16

    /// With no playbook synced, Docs draws its empty state with no toolbar
    /// band of back, forward and reload over it; once one lands, the band
    /// comes back. Runs only against this process's scratch data root.
    private static func uxp15DocsDrawsNoToolbarOverItsEmptyState() -> Bool {
        var ok = true
        // Every self-test process runs with `FM_DOCS_DIR` set - `main.swift`
        // points it at the process's own scratch folder unless a caller (CI's
        // store redirect) already has. The real folder is only ever the
        // unset default, so refuse anything that is not that override.
        let override = ProcessInfo.processInfo.environment["FM_DOCS_DIR"] ?? ""
        guard !override.isEmpty,
              DocsStore.folderURL.standardizedFileURL.path
                == URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL.path else {
            fail("UXP-15: the docs folder \(DocsStore.folderURL.path) is not this process's scratch - "
                 + "refusing to write to it", &ok)
            return ok
        }
        let index = DocsStore.indexURL
        try? FileManager.default.removeItem(at: index)
        defer { try? FileManager.default.removeItem(at: index) }
        let docs = DocsController()
        let window = OffScreenProbe.window(width: 1400, height: 860)
        defer { _ = window }
        window.contentView = docs.view
        docs.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        docs.view.layoutSubtreeIfNeeded()
        check(!DocsStore.isSynced, "UXP-15: the scratch docs folder should start empty", &ok)
        check(!docs.debugToolbarIsShowing, "UXP-15: Docs draws its toolbar over \"Docs not synced yet\"", &ok)

        try? FileManager.default.createDirectory(at: DocsStore.folderURL, withIntermediateDirectories: true)
        try? "<html><body>Playbook</body></html>".write(to: index, atomically: true, encoding: .utf8)
        // Through the real notification, which the center delivers on a later
        // main-queue turn - so pump until it lands, with a bound.
        DocsSyncCenter.notifySynced()
        let deadline = Date().addingTimeInterval(2)
        while !docs.debugToolbarIsShowing, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        docs.view.layoutSubtreeIfNeeded()
        check(docs.debugToolbarIsShowing, "UXP-15: a synced playbook should bring the toolbar back", &ok)
        return ok
    }

    /// Dictation's reset button shows only when the chord is not the
    /// default, and the "Words I use often" well draws its placeholder.
    private static func uxp16DictationResetAndPlaceholder() -> Bool {
        var ok = true
        let saved = AppSettings.shared.dictationShortcut
        defer { AppSettings.shared.dictationShortcut = saved }
        let dictation = DictationController(store: DictationStore())
        let window = OffScreenProbe.window(width: 1400, height: 860)
        defer { _ = window }
        window.contentView = dictation.view
        dictation.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        dictation.debugSetShortcut(.dictationDefault)
        dictation.view.layoutSubtreeIfNeeded()
        check(!dictation.debugShortcutResetIsShowing,
              "UXP-16: the reset button shows while the chord already is the default", &ok)
        var other = KeyChord.dictationDefault
        other.keyCode = other.keyCode == 0 ? 1 : 0
        dictation.debugSetShortcut(other)
        check(other != .dictationDefault, "UXP-16: the fixture's other chord should differ from the default", &ok)
        check(dictation.debugShortcutResetIsShowing,
              "UXP-16: a changed chord should offer the reset back to the default", &ok)
        check(!dictation.debugVocabularyPlaceholder.isEmpty,
              "UXP-16: the \"Words I use often\" field draws no placeholder", &ok)

        // UXP-08 on this page, in the state CI's runner is in: no speech
        // permission and no model. The permission request is the page's one
        // call to action - since Dic-1, Request Access on the amber split
        // card's panel - so no filled button competes with it: the download
        // steps down, and steps back up once the permission is there.
        dictation.debugSetModelState(.notDownloaded)
        dictation.debugSetStatus(.needsSpeechRecognition)
        dictation.view.layoutSubtreeIfNeeded()
        let primaries = visiblePrimaryButtons(in: dictation.view)
        check(primaries.isEmpty,
              "UXP-08: Dictation shows \(primaries.count) primary buttons beside the panel's Request Access: "
              + "\(primaries.map(\.title))", &ok)
        check(dictation.debugHeroCard.panel.debugFootButtons.map(\.title) == ["Request Access"],
              "UXP-08: with a permission missing the panel's pill is "
              + "\(dictation.debugHeroCard.panel.debugFootButtons.map(\.title))", &ok)
        dictation.debugSetStatus(.ready)
        check(dictation.debugModelActionVariant == .primary,
              "UXP-08: with nothing else to ask for, Download Model should be the page's primary", &ok)
        return ok
    }

    // MARK: UXP-17

    /// A name said once per level: Settings' header row does not repeat the
    /// pane its hero names, Sticky Board draws no footer count under a drill
    /// subtitle that already counts, and Schedules calls one state one thing
    /// in its sidebar, its stat strip and its list.
    private static func uxp17OneNamePerLevel() -> Bool {
        var ok = true
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }

        shell.workspace.navigator.show(.settings)
        shell.view.layoutSubtreeIfNeeded()
        let settings = shell.settingsForTests
        let pane = settings.debugSelectedCategory.title
        check(!settings.debugToolbarTexts.contains(pane),
              "UXP-17: Settings' header row repeats the pane name \"\(pane)\" its hero already shows", &ok)

        shell.workspace.navigator.show(.stickyBoard)
        shell.view.layoutSubtreeIfNeeded()
        if let sticky = shell.destinationViewIfMountedForTests(.stickyBoard) {
            var labels: [String] = []
            func walk(_ view: NSView) {
                if view.isHidden { return }
                if let label = view as? NSTextField { labels.append(label.stringValue) }
                if view is NSScrollView { return }
                view.subviews.forEach(walk)
            }
            walk(sticky)
            check(!labels.contains(where: { $0.hasSuffix(" notes") || $0 == "1 note" }),
                  "UXP-17: Sticky Board draws a note count on the page as well as in its drill subtitle", &ok)
        } else {
            fail("UXP-17: Sticky Board did not mount", &ok)
        }

        shell.workspace.navigator.show(.schedules)
        shell.view.layoutSubtreeIfNeeded()
        let schedules = shell.debugSchedules
        let group = SchedulesCardView.Group.needsYou.title
        check(SchedulesCardView.StatusFilter.needsYou.title == group,
              "UXP-17: Schedules' sidebar says \"\(SchedulesCardView.StatusFilter.needsYou.title)\" where its list "
              + "says \"\(group)\"", &ok)
        check(schedules.debugStatCaptions.contains(group),
              "UXP-17: Schedules' stat strip reads \(schedules.debugStatCaptions), not the list's \"\(group)\"", &ok)
        return ok
    }

    // MARK: UXP-09

    /// The placeholder row of an empty or unavailable forge list is as tall
    /// as the table, so its glyph and words are drawn inside the box.
    private static func uxp09ForgePlaceholderRowIsTallEnough() -> Bool {
        var ok = true
        let (window, review) = mountReview()
        defer { _ = window }
        review.debugRender([pr(1, forge: "bitbucket")],
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["a"]))
        let height = review.debugGithubPlaceholderRowHeight
        check(height >= ReviewPRListView.emptyRowHeight - 0.5,
              "UXP-09: the empty GitHub list's placeholder row is \(height)pt in a "
              + "\(ReviewPRListView.emptyRowHeight)pt table", &ok)
        return ok
    }
}

#endif
