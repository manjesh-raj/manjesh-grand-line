// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 5**'s own suite: the two destinations §7 puts
// after Console/Hosts/Health in that half of the table - Docs and Dictation.
//
// `fm/grandline-docs-split-runbooks-postmortems` later promoted Docs' own
// Runbooks and Postmortems tabs into their own top-level destinations
// (`RunbooksController`/`PostmortemsController`) - the checks below were
// updated in place to exercise those two controllers directly rather than
// `DocsController`'s former `debugSelectTab(...)` API, which no longer
// exists. Docs itself is Playbook-only now.
//
// What each case protects, and why it is worth a test rather than a
// read-through:
//
//   1. **Every page really reached the drill header** (§6.4). The seam is a
//      protocol conformance, and a missing one is invisible: the header just
//      renders the static per-area line with an empty trailing slot, which
//      looks like a design choice. Runbooks is the one worth pinning
//      hardest - its cluster changes with whether the runbook editor is
//      open, so this asserts the same button instance moves in and out
//      rather than a copy being built, and that the editor really does empty
//      the cluster. Postmortems has no page-level action at all.
//   2. **Neither page renders an in-page hero any more** (§6.4). Walked over
//      the real view tree, because the failure mode is a duplicate title one
//      row apart - and Dictation additionally lost a whole header row whose
//      only contents were a subtitle and the Refresh button that is now in the
//      cluster, so this also asserts Refresh exists exactly once.
//   3. **A runbook plate is a plate, not a navigating module** (§7's
//      "non-navigating version with Open buttons"). Measured, not eyeballed:
//      the ribbon carries two stops, the Open button is real and fires the
//      caller's own closure, and the delete glyph is pinned to the card's own
//      trailing corner rather than laid out after a title of unknown length -
//      which is the exact bug `fm/grandline-docs-runbook-delete-icon-corner`
//      fixed on the card this replaces, and the easiest thing to reintroduce
//      by dropping the plate's constraints into a stack.
//   4. **One plate chrome recipe per theme.** Radius, fill and depth all come
//      from the shared helpers (`HelmCard.applyCardSurface` / `.elevation`),
//      which branch Daylight vs. the other twelve internally - so the check is
//      that the plate *uses* them rather than re-deriving a value: §6.1's
//      radius on Daylight (and one that is genuinely in §2.6's closed set, the
//      rule `checkDaylightRadiiScale` enforces), the shared card radius
//      elsewhere, and the card surface's own fill in both. Note this
//      deliberately does NOT assert "shadow only on Daylight": `elevation`
//      defines a real second level for every palette and `HelmModuleCard`
//      already casts one everywhere, so a plate matching its sibling is
//      consistency, not a leak.
//   5. **D2's headline instance: the vocabulary field is a chips-in-a-well,
//      and it writes through to the real store.** This is the defect the
//      original audit named first, so it is driven end to end on the real page
//      - type, Return, Backspace - and checked against a real `DictationStore`
//      on scratch disk. A well that renders correctly but no longer *saves*
//      would look completely fine.
//   6. **A history row carries no fabricated signal.** §6.5 rows paint a
//      semantic accent, and a past transcription has no state - so the row's
//      tint must stay `.neutral`. Getting this wrong puts a red or amber alert
//      bar on every row of a benign list in the twelve palettes that resolve
//      those tints literally, which is a real regression and not a style
//      preference.
//   7. **The playbook web view is untouched inside its card** (§7). The card
//      is new; the web view still fills it edge to edge, which is what
//      "untouched" has to mean geometrically.
//   8. **No new window-width floor.** Both pages gained constraints inside
//      `bodyContainer` - Docs a card and a plate grid, Dictation a two-column
//      `.fillEqually` row - and AGENTS.md gotcha (13) is this codebase's most
//      expensive recurring bug. `AppShellBodyWidthSelfTest` is the broad
//      sweep; this is the local one for the two pages just touched.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE5_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice5SelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, checkHeroTitlesAreGone,
                      checkRunbookPlates, checkPlateChromePerTheme,
                      checkVocabularyChipsInWell, checkHistoryRowSignal,
                      checkPlaybookCard, checkNoWindowWidthFloor] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSlice5SelfTest: all checks passed"
                    : "DaylightDrillPageSlice5SelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylight: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static var otherTheme: HelmTheme {
        HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    /// Scratch directories, so nothing here can reach the captain's real
    /// runbooks, vocabulary or dictation history. `DocsController` builds its
    /// own `DocsRunbookStore` internally, which is why this goes through the
    /// env override rather than injection.
    private static func scratchRoot(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-slice5-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func scratchDocsStore() -> DocsRunbookStore {
        setenv("FM_DOCS_RUNBOOKS_DIR", scratchRoot("docs").path, 1)
        return DocsRunbookStore()
    }

    /// `fm/grandline-docs-split-runbooks-postmortems` split the Runbooks and
    /// Postmortems tabs out of `DocsController` into their own destinations
    /// (`RunbooksController`/`PostmortemsController`), each constructing its
    /// own `DocsRunbookStore()` the same way `DocsController` used to -
    /// `scratchDocsStore()` above must be called (setting `FM_DOCS_RUNBOOKS_DIR`)
    /// before either is instantiated, exactly as it always had to be before
    /// constructing the old combined `DocsController`.

    private static func scratchDictationStore() -> DictationStore {
        setenv("FM_DICTATION_DIR", scratchRoot("dictation").path, 1)
        return DictationStore()
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func labels(in view: NSView, atLeast points: CGFloat) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, (label.font?.pointSize ?? 0) >= points,
           !label.stringValue.isEmpty, !label.isHidden {
            found.append(label)
        }
        for sub in view.subviews { found += labels(in: sub, atLeast: points) }
        return found
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += descendants(type, in: sub) }
        return found
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// Component-wise, deliberately **not** `HelmContrast.ratio(a, b) < 1.01`:
    /// that compares relative *luminance*, so two entirely different hues of
    /// similar brightness pass it - the trap slice 2's own header documents,
    /// and one this suite walked straight into on its first regression
    /// injection (a `.critical` bar was reported as matching both `.critical`
    /// *and* `.warn`, because those two hues sit at a similar brightness).
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    // MARK: 1. Both pages reached the drill header (§6.4)

    private static func checkDrillConformances(_ ok: inout Bool) {
        print("\n-- §6.4: Docs / Runbooks / Postmortems / Dictation carry live drill headers --")

        let docs = DocsController()
        let docsWindow = mount(docs)
        defer { _ = docsWindow }

        // Docs is Playbook-only now (`fm/grandline-docs-split-runbooks-
        // postmortems`): one page-level action, and a subtitle reporting the
        // real sync state rather than claiming an offline copy.
        guard docs.drillHeaderActions.count == 1 else {
            print("  FAIL Docs hoists \(docs.drillHeaderActions.count) actions, want 1")
            ok = false
            return
        }
        guard let playbookSubtitle = docs.drillHeaderSubtitle, !playbookSubtitle.isEmpty else {
            print("  FAIL Docs reports no drill subtitle")
            ok = false
            return
        }
        if DocsStore.isSynced != playbookSubtitle.contains("offline copy") {
            print("  FAIL Docs' subtitle disagrees with DocsStore.isSynced "
                  + "(synced=\(DocsStore.isSynced), subtitle=\"\(playbookSubtitle)\")")
            ok = false
        }

        // Runbooks: the count comes from the grid the page is actually
        // rendering, so the header cannot disagree with the list below it.
        let docsStore = scratchDocsStore()
        docsStore.createRunbook(title: "Rotate the bastion key", content: "# Rotate the bastion key\n")
        docsStore.createRunbook(title: "Drain a node", content: "# Drain a node\n")

        let runbooksPage = RunbooksController()
        let runbooksWindow = mount(runbooksPage)
        defer { _ = runbooksWindow }
        runbooksPage.debugReloadRunbooks()

        guard let runbookSubtitle = runbooksPage.drillHeaderSubtitle, runbookSubtitle.contains("2 runbooks") else {
            print("  FAIL Runbooks subtitle does not report 2 runbooks (\(runbooksPage.drillHeaderSubtitle ?? "nil"))")
            ok = false
            return
        }
        guard runbooksPage.drillHeaderActions.count == 1,
              let newButton = runbooksPage.drillHeaderActions[0] as? NSButton, newButton.title == "New Runbook" else {
            print("  FAIL Runbooks does not hoist a titled New Runbook action")
            ok = false
            return
        }
        // Re-read, not rebuilt: a fresh instance per read would silently drop
        // the target and tooltip the page set on it.
        if runbooksPage.drillHeaderActions.first !== newButton {
            print("  FAIL Runbooks rebuilds its New Runbook button on every read of drillHeaderActions")
            ok = false
        }

        // The editor empties the cluster: "New Runbook" beside a form already
        // creating one is a second, competing action.
        runbooksPage.debugBeginNewRunbook()
        if !runbooksPage.drillHeaderActions.isEmpty {
            print("  FAIL Runbooks still hoists \(runbooksPage.drillHeaderActions.count) action(s) with the runbook editor open")
            ok = false
        }
        runbooksPage.debugCancelRunbookEditor()
        if runbooksPage.drillHeaderActions.count != 1 {
            print("  FAIL Runbooks does not restore its cluster after the runbook editor closes")
            ok = false
        }

        // Postmortems has no page-level action at all (generation happens in
        // SRE Lead / the Log Analyzer).
        let postmortemsPage = PostmortemsController()
        let postmortemsWindow = mount(postmortemsPage)
        defer { _ = postmortemsWindow }
        if !postmortemsPage.drillHeaderActions.isEmpty {
            print("  FAIL Postmortems invented \(postmortemsPage.drillHeaderActions.count) action(s)")
            ok = false
        }

        // Dictation: one page-level action, and a subtitle built from the
        // status it was handed plus the two store counts it already renders.
        let dictationStore = scratchDictationStore()
        dictationStore.addVocabularyWord("herdr")
        let dictation = DictationController(store: dictationStore)
        let dictationWindow = mount(dictation)
        defer { _ = dictationWindow }
        dictation.debugRenderVocabulary()

        guard dictation.drillHeaderActions.count == 1,
              dictation.drillHeaderActions[0] is NSButton else {
            print("  FAIL Dictation hoists \(dictation.drillHeaderActions.count) actions, want 1 button")
            ok = false
            return
        }
        dictation.debugSetStatus(.ready)
        guard let subtitle = dictation.drillHeaderSubtitle else {
            print("  FAIL Dictation reports no drill subtitle")
            ok = false
            return
        }
        for expected in [DictationStatus.ready.title, "1 word", "0 dictations"] {
            if !subtitle.contains(expected) {
                print("  FAIL Dictation's subtitle is missing \"\(expected)\": \"\(subtitle)\"")
                ok = false
            }
        }
        // A missing permission must not be rounded up to "Ready".
        dictation.debugSetStatus(.needsMicrophone)
        if let denied = dictation.drillHeaderSubtitle,
           !denied.contains(DictationStatus.needsMicrophone.title) {
            print("  FAIL Dictation's subtitle hides a missing permission: \"\(denied)\"")
            ok = false
        }
        if ok { print("  OK - both pages report live subtitles and stable action clusters") }
    }

    // MARK: 2. No in-page heroes left (§6.4)

    private static func checkHeroTitlesAreGone(_ ok: inout Bool) {
        print("\n-- §6.4: no in-page hero titles on Docs / Runbooks / Postmortems / Dictation --")
        // The drill header's own title is 26pt, so anything at or above 20pt
        // inside a page body is a second title competing with it.
        let heroFloor: CGFloat = 20
        _ = scratchDocsStore()
        let dictationStore = scratchDictationStore()
        let pages: [(String, NSViewController)] = [
            ("Docs", DocsController()),
            ("Runbooks", RunbooksController()),
            ("Postmortems", PostmortemsController()),
            ("Dictation", DictationController(store: dictationStore)),
        ]
        var clean = true
        for (name, page) in pages {
            let window = mount(page)
            defer { _ = window }
            let heroes = labels(in: page.view, atLeast: heroFloor)
            if !heroes.isEmpty {
                print("  FAIL \(name) still renders \(heroes.count) hero-sized label(s): "
                      + heroes.map { "\"\($0.stringValue)\" @\(fmt($0.font?.pointSize ?? 0))" }
                          .joined(separator: ", "))
                ok = false
                clean = false
            }
        }

        // Dictation's whole in-page header row is gone, so its Refresh glyph
        // must exist exactly once: in the cluster, not also in the body.
        let dictation = DictationController(store: dictationStore)
        let window = mount(dictation)
        defer { _ = window }
        guard let refresh = dictation.drillHeaderActions.first else {
            print("  FAIL Dictation hoists no action to compare against")
            ok = false
            return
        }
        let inBody = descendants(HelmButton.self, in: dictation.view).filter { $0 === refresh }
        if !inBody.isEmpty {
            print("  FAIL Dictation renders its Refresh button in the page body as well as the cluster")
            ok = false
            clean = false
        }
        if clean { print("  OK - both page bodies are free of hero titles and duplicated actions") }
    }

    // MARK: 3. A plate is a plate, not a navigating module (§7)

    private static func checkRunbookPlates(_ ok: inout Bool) {
        print("\n-- §7: runbook grid renders module-style plates with Open buttons --")
        let store = scratchDocsStore()
        store.createRunbook(title: "Identifying Unhealthy / NotReady Nodes",
                            content: "# Identifying Unhealthy / NotReady Nodes\n\n```\nkubectl get nodes\n```\n")
        let runbooksPage = RunbooksController()
        let window = mount(runbooksPage)
        defer { _ = window }
        runbooksPage.debugReloadRunbooks()
        runbooksPage.view.layoutSubtreeIfNeeded()

        guard let plate = runbooksPage.debugRunbookPlates.first else {
            print("  FAIL Runbooks rendered no plates")
            ok = false
            return
        }
        runbooksPage.view.layoutSubtreeIfNeeded()
        let anatomy = plate.anatomyForTests

        if !anatomy.hasRibbon || anatomy.ribbonStopCount != 2 {
            print("  FAIL plate ribbon: attached=\(anatomy.hasRibbon) stops=\(anatomy.ribbonStopCount), want attached with 2")
            ok = false
        }
        if abs(anatomy.ribbonHeight - HelmPlateCard.ribbonHeight) > 0.5 {
            print("  FAIL plate ribbon height \(fmt(anatomy.ribbonHeight)), want \(fmt(HelmPlateCard.ribbonHeight))")
            ok = false
        }
        if anatomy.openButtonTitle != "Open" {
            print("  FAIL plate's action reads \"\(anatomy.openButtonTitle)\", want \"Open\"")
            ok = false
        }
        if !anatomy.deleteVisible {
            print("  FAIL a runbook plate hides its delete action")
            ok = false
        }
        if abs(anatomy.resolvedHeight - HelmPlateCard.height) > 0.5 {
            print("  FAIL plate resolved to \(fmt(anatomy.resolvedHeight)), want \(fmt(HelmPlateCard.height))")
            ok = false
        }

        // The delete glyph is pinned to the card's own trailing corner. A
        // stack-laid-out trailing control drifts with the leading content's
        // width, which is the bug this plate's constraints exist to avoid - so
        // compare against the *card*, not against the Open button.
        let cardWidth = plate.frame.width
        let trailingGap = cardWidth - anatomy.deleteButtonFrame.maxX
        let expectedGap = HelmPlateCard.horizontalInset
        if abs(trailingGap - expectedGap) > 1.5 {
            print("  FAIL plate's delete glyph sits \(fmt(trailingGap))pt from the trailing edge, "
                  + "want \(fmt(expectedGap)) - it is drifting with the title rather than pinned")
            ok = false
        }
        if anatomy.openButtonFrame.minX > anatomy.deleteButtonFrame.minX {
            print("  FAIL plate's Open button is not leading its delete glyph")
            ok = false
        }
        if anatomy.titleMaxLines != HelmPlateCard.maximumTitleLines {
            print("  FAIL plate title allows \(anatomy.titleMaxLines) lines, want \(HelmPlateCard.maximumTitleLines)")
            ok = false
        }

        // Open really opens. The plate is "non-navigating" in the sense that it
        // does not swallow the whole surface as one destination jump - but its
        // Open button must reach the caller's own closure.
        var opened = 0
        let probe = HelmPlateCard()
        probe.configure(.init(title: "Probe", subtitle: "sub", symbol: "doc.text",
                             hue: .blue, onOpen: { opened += 1 }))
        probe.debugActivateOpen()
        if opened != 1 {
            print("  FAIL plate's Open fired \(opened) times, want exactly 1")
            ok = false
        }
        var deleted = 0
        let deletable = HelmPlateCard()
        deletable.configure(.init(title: "Probe", subtitle: "sub", symbol: "doc.text",
                                  hue: .blue, onOpen: {}, onDelete: { deleted += 1 }))
        deletable.debugActivateDelete()
        if deleted != 1 {
            print("  FAIL plate's delete fired \(deleted) times, want exactly 1")
            ok = false
        }
        if !deletable.anatomyForTests.deleteVisible {
            print("  FAIL a plate given onDelete hides its delete glyph")
            ok = false
        }
        if HelmPlateCard().anatomyForTests.deleteVisible {
            print("  FAIL a plate with no onDelete still shows a delete glyph")
            ok = false
        }
        if ok { print("  OK - plates carry a ribbon, an Open button and a corner-pinned delete") }
    }

    // MARK: 4. The plate's chrome per theme (no shadow leak)

    private static func checkPlateChromePerTheme(_ ok: inout Bool) {
        print("\n-- §6.1 / §2.5: plate chrome resolves per theme from the shared helpers --")
        var clean = true
        for theme in HelmTheme.allThemes {
            let plate = HelmPlateCard()
            plate.configure(.init(title: "Runbook", subtitle: "Kubernetes \u{00B7} 3 steps",
                                  symbol: "doc.text", hue: .blue, onOpen: {}))
            plate.frame = NSRect(x: 0, y: 0, width: 300, height: HelmPlateCard.height)
            plate.applyTheme(theme)
            plate.layoutSubtreeIfNeeded()
            let a = plate.anatomyForTests

            let wantRadius = HelmPlateCard.cornerRadius(for: theme)
            if abs(a.cornerRadius - wantRadius) > 0.5 {
                print("  FAIL \(theme.id): plate radius \(fmt(a.cornerRadius)), want \(fmt(wantRadius))")
                ok = false
                clean = false
            }
            // A radius outside §2.6's closed set is a new value nobody agreed
            // to - the same rule `checkDaylightRadiiScale` enforces.
            if theme.isDaylight, !HelmMetrics.daylightRadii.contains(a.cornerRadius) {
                print("  FAIL \(theme.id): plate radius \(fmt(a.cornerRadius)) is not in the Daylight scale")
                ok = false
                clean = false
            }
            if a.shadowOpacity <= 0 {
                print("  FAIL \(theme.id): plate casts no shadow at all")
                ok = false
                clean = false
            }
            let wantFill = HelmTheme.nsColor(theme.chromeBackgroundHex)
            guard let fill = a.cardFill else {
                print("  FAIL \(theme.id): plate has no resolved fill")
                ok = false
                clean = false
                continue
            }
            if !sameColor(fill, wantFill) {
                print("  FAIL \(theme.id): plate fill \(fill) is not the shared card surface \(wantFill)")
                ok = false
                clean = false
            }
        }
        if clean { print("  OK - one plate recipe per theme across all \(HelmTheme.allThemes.count) palettes") }
    }

    // MARK: 5. D2: chips-in-a-well, writing through to the real store

    private static func checkVocabularyChipsInWell(_ ok: inout Bool) {
        print("\n-- §6.9 / D2: Dictation's vocabulary is a chips-in-a-well that saves --")
        let store = scratchDictationStore()
        store.addVocabularyWord("herdr")
        let dictation = DictationController(store: store)
        let window = mount(dictation)
        defer { _ = window }
        dictation.debugRenderVocabulary()

        let well = dictation.debugVocabularyInput
        if well.tokens != store.vocabulary {
            print("  FAIL the well was not seeded from the store: \(well.tokens) vs \(store.vocabulary)")
            ok = false
        }
        if well.chipCountForTests != store.vocabulary.count {
            print("  FAIL the well renders \(well.chipCountForTests) chips for \(store.vocabulary.count) words")
            ok = false
        }
        if well.domainHue != RailDestination.dictation.domainHue {
            print("  FAIL the well's focus hue is \(String(describing: well.domainHue)), "
                  + "want \(RailDestination.dictation.domainHue)")
            ok = false
        }

        // Type + Return commits a token AND writes it through to disk.
        well.debugType("kubectl")
        well.debugPressReturn()
        if !well.editorTextForTests.isEmpty {
            print("  FAIL the editor kept \"\(well.editorTextForTests)\" after Return")
            ok = false
        }
        if !store.vocabulary.contains("kubectl") {
            print("  FAIL committing a token did not reach the store: \(store.vocabulary)")
            ok = false
        }
        if !DictationStore().vocabulary.contains("kubectl") {
            print("  FAIL the committed token did not survive a reload from disk")
            ok = false
        }

        // Backspace on an empty editor pops the last token, and that removal
        // reaches the store too.
        let before = store.vocabulary
        well.debugPressBackspace()
        let after = store.vocabulary
        if after.count != before.count - 1 {
            print("  FAIL Backspace on an empty editor did not remove a word (\(before) -> \(after))")
            ok = false
        }
        if after.contains("kubectl") {
            print("  FAIL Backspace removed the wrong word: \(after)")
            ok = false
        }

        // Typed-but-uncommitted text is never a token, and never a word.
        well.debugType("half-typed")
        if store.vocabulary.contains("half-typed") {
            print("  FAIL uncommitted editor text was saved as a word")
            ok = false
        }

        // A store-side change re-seeds the well without looping back into a
        // write (the render -> setTokens -> onTokensChanged cycle).
        let countBefore = store.vocabulary.count
        store.addVocabularyWord("bastion")
        dictation.debugRenderVocabulary()
        if !well.tokens.contains("bastion") {
            print("  FAIL a store-side add did not re-seed the well: \(well.tokens)")
            ok = false
        }
        if store.vocabulary.count != countBefore + 1 {
            print("  FAIL re-seeding the well mutated the store (\(countBefore) -> \(store.vocabulary.count))")
            ok = false
        }

        // The raw trio this replaces is gone from the page - a source guard,
        // because a leftover field could sit hidden and still be the thing the
        // captain's next edit reaches.
        let source = SelfTestSources.appSourceDirectory()?
            .appendingPathComponent("DictationController.swift")
        if let source, let text = try? String(contentsOf: source, encoding: .utf8) {
            for banned in ["ChipFlowView()", "vocabularyInputField", "vocabularyAddButton"] {
                if text.contains(banned) {
                    print("  FAIL DictationController still references \(banned) - D2's raw trio is back")
                    ok = false
                }
            }
        } else {
            print("  NOTE could not read DictationController.swift; source guard skipped")
        }
        if ok { print("  OK - one well, tokens inside it, every edit reaching the store") }
    }

    // MARK: 6. A history row carries no fabricated signal (§6.5)

    private static func checkHistoryRowSignal(_ ok: inout Bool) {
        print("\n-- §6.5 / §7: history rows are accent rows with no invented state --")
        let store = scratchDictationStore()
        store.recordHistory(text: "Deploy the preprod bastion change", durationSeconds: 4.5, date: Date())
        let dictation = DictationController(store: store)
        let window = mount(dictation)
        defer { _ = window }
        dictation.debugHistoryList.setEntries(store.history)

        guard let rowView = dictation.debugHistoryList.debugRowView(at: 0) else {
            print("  FAIL the history table built no row view")
            ok = false
            return
        }
        let rows = descendants(HelmAccentRow.self, in: rowView)
        guard let row = rows.first, rows.count == 1 else {
            print("  FAIL a history cell holds \(rows.count) HelmAccentRows, want exactly 1")
            ok = false
            return
        }
        row.applyTheme(daylight)
        rowView.frame = NSRect(x: 0, y: 0, width: 520, height: DictationHistoryListView.rowHeight)
        rowView.layoutSubtreeIfNeeded()

        let geometry = row.debugGeometry()
        // The load-bearing assertion: neutral, not a semantic hue. `.critical`
        // or `.warn` here would paint an alert bar on every row of a benign
        // list in the twelve palettes that resolve those tints literally.
        let neutral = HelmTheme.nsColor(HelmTint.neutral.hex(in: daylight))
        if !sameColor(geometry.barColor, neutral) {
            print("  FAIL a history row's accent bar is not the neutral tint "
                  + "(\(String(describing: geometry.barColor)) vs \(neutral)) - a past "
                  + "transcription has no state to signal, and a semantic hue here reads as "
                  + "an alert on every row of a benign list")
            ok = false
        }
        for badHue in [HelmTint.critical, .warn, .good] {
            let bad = HelmTheme.nsColor(badHue.hex(in: daylight))
            if sameColor(bad, neutral) { continue }
            if sameColor(geometry.barColor, bad) {
                print("  FAIL a history row paints its accent bar with the \(badHue) tint")
                ok = false
            }
        }
        if geometry.barFrame.height <= 0 || row.frame.width <= 0 {
            print("  FAIL the history row resolved to an empty frame "
                  + "(row \(row.frame), bar \(geometry.barFrame))")
            ok = false
        }
        // The row must fit the height the table gives it, or the card clips.
        let fitting = row.fittingSize.height
        if fitting > DictationHistoryListView.rowHeight {
            print("  FAIL a history row needs \(fmt(fitting))pt but the table gives it "
                  + "\(fmt(DictationHistoryListView.rowHeight))pt")
            ok = false
        }
        // The delete action survived the restyle.
        let buttons = descendants(HelmButton.self, in: rowView)
        if buttons.isEmpty {
            print("  FAIL the restyled history row lost its delete action")
            ok = false
        }
        if ok { print("  OK - history rows are §6.5 rows, neutral-tinted, delete intact") }
    }

    // MARK: 7. The playbook web view, untouched inside its card (§7)

    private static func checkPlaybookCard(_ ok: inout Bool) {
        print("\n-- §7: the playbook web view sits inside a radius-16 card --")
        let docs = DocsController()
        let window = mount(docs)
        defer { _ = window }
        docs.view.layoutSubtreeIfNeeded()

        let card = docs.debugPlaybookCard
        let web = docs.debugWebView
        if card.frame.width <= 0 || card.frame.height <= 0 {
            print("  FAIL the playbook card resolved to an empty frame \(card.frame)")
            ok = false
            return
        }
        for theme in [daylight, otherTheme] {
            HelmCard.applyCardSurface(to: card, theme: theme,
                                      cornerRadius: HelmMetrics.rCard,
                                      daylightRadius: HelmMetrics.dSurface)
            let want = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rCard
            let got = card.layer?.cornerRadius ?? 0
            if abs(got - want) > 0.5 {
                print("  FAIL \(theme.id): playbook card radius \(fmt(got)), want \(fmt(want))")
                ok = false
            }
        }
        if card.layer?.masksToBounds != true {
            print("  FAIL the playbook card does not clip, so its radius is invisible")
            ok = false
        }
        // "Untouched" has to mean geometrically untouched: the web view still
        // fills its container edge to edge.
        if web.superview !== card {
            print("  FAIL the web view is not a child of the playbook card")
            ok = false
            return
        }
        if abs(web.frame.width - card.frame.width) > 0.5 || abs(web.frame.height - card.frame.height) > 0.5 {
            print("  FAIL the web view \(web.frame.size) does not fill its card \(card.frame.size)")
            ok = false
        }
        if ok { print("  OK - card clips at the right radius, web view fills it") }
    }

    // MARK: 8. No new window-width floor (AGENTS.md gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): none of these pages cap the window --")
        let docsStore = scratchDocsStore()
        for i in 1...6 {
            docsStore.createRunbook(title: "Runbook number \(i) with a deliberately long title",
                                    content: "# Runbook \(i)\n")
        }
        for i in 1...3 {
            docsStore.createPostmortem(title: "Postmortem number \(i) with a deliberately long title",
                                       content: "# Postmortem \(i)\n\n## Root Cause\nA long root cause line.\n")
        }
        let dictationStore = scratchDictationStore()
        for word in ["herdr", "kubectl", "bastion", "preprod", "automic-vault"] {
            dictationStore.addVocabularyWord(word)
        }
        dictationStore.recordHistory(text: String(repeating: "a long transcription ", count: 12),
                                     durationSeconds: 30, date: Date())

        func floor(of controller: NSViewController, label: String, reload: (() -> Void)? = nil) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            reload?()
            for width in [1400.0, 1100.0, 900.0] as [CGFloat] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 820), display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                if window.frame.width > width + 0.5 {
                    print("  FAIL \(label) capped the window at "
                          + "\(fmt(window.frame.width)) when asked for \(fmt(width))")
                    ok = false
                }
            }
            window.contentViewController = nil
        }

        floor(of: DocsController(), label: "Docs")
        let runbooksPage = RunbooksController()
        floor(of: runbooksPage, label: "Runbooks", reload: { runbooksPage.debugReloadRunbooks() })
        let postmortemsPage = PostmortemsController()
        floor(of: postmortemsPage, label: "Postmortems", reload: { postmortemsPage.debugReloadPostmortems() })
        floor(of: DictationController(store: dictationStore), label: "Dictation")
        if ok { print("  OK - every page tracks the window down to 900pt") }
    }
}

#endif
