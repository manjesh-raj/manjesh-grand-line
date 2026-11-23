// Grand Line - native macOS app.
//
// The 2026-11-17 UI/UX proposals the captain approved (S01 to S18, S20 to
// S27), checked where a check can be made without a window. Each case names its
// proposal. The window-backed halves (geometry that needs a real layout pass
// in a real window) live in the existing window suites that already measure
// those pages.
//
// Run with `FM_RUN_UIUX_PROPOSALS_TESTS=1 .build/debug/GrandLine`.
//
// Pure logic: no window. Views are laid out on their own. Deliberately NOT in
// `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Yaml

enum UIUXProposalsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        print("== UIUXProposalsSelfTest ==")
        var allOK = true
        let cases: [(String, (inout Bool) -> Void)] = [
            ("S11 one verdict per card", checkTheHealthCardHasOneVerdict),
            ("S10 the briefing reads as prose", checkTheBriefingIsInk),
            ("S04 one page-sidebar surface", checkOneSidebarSurface),
            ("S13 project colours are a stored identity", checkProjectHuesAreIdentity),
            ("S12 one glyph per meaning", checkOneGlyphPerMeaning),
            ("S17 one notice recipe", checkOneNoticeRecipe),
            ("S15 one card header recipe", checkOneCardHeaderRecipe),
            ("S14 one number recipe", checkOneNumberRecipe),
            ("S16 one filter row", checkOneFilterRow),
            ("S25 welcome choice cards and tiles", checkWelcomeChoiceCards),
            ("S26 theme tiles show the pair", checkThemeTilesShowThePair),
            ("S18 loading states for the web islands", checkIslandLoaders),
            ("S23 Kubernetes shows its shape", checkKubernetesShowsItsShape),
            ("S24 GitHub sync rows say what to do", checkGitHubSyncRowsSayWhatToDo),
            ("S20 28pt icon targets", checkIconTargets),
            ("S21 page-tab chords", checkPageTabChords),
            ("S27 the inspector's crew panel", checkInspectorCrewPanel),
            ("S22 an empty state follows the theme", checkEmptyStateFollowsTheTheme),
            ("S03 one page frame", checkOnePageFrame),
        ]
        for (name, body) in cases {
            var ok = true
            autoreleasepool { body(&ok) }
            print("  \(ok ? "OK  " : "FAIL") \(name)")
            allOK = allOK && ok
        }
        print(allOK ? "UIUXProposalsSelfTest: all checks passed" : "UIUXProposalsSelfTest: FAILED")
        return allOK
    }

    // MARK: - S11

    /// The Home Health card with one failing service: the title says
    /// "1 failing" in the failing colour, the arc takes the same colour, and
    /// there is no header pill saying it a third time. An all-healthy card
    /// keeps the card's own hue and ink title.
    private static func checkTheHealthCardHasOneVerdict(_ ok: inout Bool) {
        func state(_ bucket: ServiceHealthSummary.Bucket) -> ServiceHealthState {
            var s = ServiceHealthState()
            switch bucket {
            case .healthy: s.lastSuccess = Date()
            case .degraded: s.lastSuccess = Date(); s.lastFailure = Date(); s.consecutiveFailures = 1
                s.lastFailureDetail = "x"
            case .failing: s.lastFailure = Date(); s.consecutiveFailures = ServiceHealthRegistry.failureThreshold
                s.lastFailureDetail = "x"
            case .notRun: break
            }
            return s
        }
        let failing = ServiceHealthSummary([
            .init(service: .backgroundSignals, state: state(.healthy)),
            .init(service: .persistence, state: state(.healthy)),
            .init(service: .docsSync, state: state(.failing)),
            .init(service: .scheduledAutomations, state: state(.notRun)),
        ])
        guard failing.failing == 1, failing.healthy == 2, failing.notRun == 1 else {
            fail("S11: the fixture does not hold 2 healthy, 1 failing, 1 not run (\(failing.spoken))", &ok)
            return
        }
        check(failing.headline == .failing, "S11: the headline of a summary with a failure is failing", &ok)

        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            let summary = HomeCanvasController.healthRingSummary(failing)
            let card = HelmModuleCard()
            card.configure(.init(title: "Health", subtitle: "background services", symbol: "heart.fill", hue: .green,
                                 body: .ring(value: summary.value, total: summary.total, title: summary.title,
                                             note: summary.note, tint: summary.tint)))
            card.frame = NSRect(x: 0, y: 0, width: 380, height: 230)
            card.applyTheme(theme)
            card.layoutSubtreeIfNeeded()
            let critical = HelmTheme.nsColor(HelmTint.critical.hex(in: theme))
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let expectedTitle = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                               over: surface, theme: theme)
            guard let title = card.debugRingTitle, let arc = card.debugRingGauge?.debugArcColor else {
                fail("S11 \(theme.id): the ring has no tinted title or arc", &ok)
                continue
            }
            check(title.text == "1 failing", "S11 \(theme.id): the title is the verdict, got \"\(title.text)\"", &ok)
            check(title.color.map { same($0, expectedTitle) } == true,
                  "S11 \(theme.id): the title is painted in the failing colour", &ok)
            check(same(NSColor(cgColor: arc) ?? .clear, critical),
                  "S11 \(theme.id): the arc takes the failing colour, not the card's green", &ok)
            check(card.anatomyForTests.chipText == nil,
                  "S11 \(theme.id): no header pill repeats the verdict, got \"\(card.anatomyForTests.chipText ?? "")\"", &ok)

            // Discriminating power: an all-healthy card paints the card's
            // own green arc and an ink title, so the two readings really differ.
            let well = ServiceHealthSummary([.init(service: .persistence, state: state(.healthy))])
            let wellSummary = HomeCanvasController.healthRingSummary(well)
            let calm = HelmModuleCard()
            calm.configure(.init(title: "Health", subtitle: "background services", symbol: "heart.fill", hue: .green,
                                 body: .ring(value: wellSummary.value, total: wellSummary.total,
                                             title: wellSummary.title, note: wellSummary.note, tint: wellSummary.tint)))
            calm.applyTheme(theme)
            check(calm.debugRingTitle == nil && wellSummary.title == "Healthy",
                  "S11 \(theme.id): a healthy card keeps an ink title", &ok)
            let green = HelmDomainHue.green.baseColor(in: theme)
            check(calm.debugRingGauge?.debugArcColor.flatMap { NSColor(cgColor: $0) }.map { same($0, green) } == true,
                  "S11 \(theme.id): a healthy card keeps the card's green arc", &ok)
            check(!same(green, critical), "S11 \(theme.id): the fixture's two colours really differ", &ok)
        }
    }

    // MARK: - S10

    /// The briefing's linked clauses are ink with a leading dot each; only a
    /// bad state word ("overdue") keeps a colour. Before S10 every linked
    /// clause was painted in its target's hue, which is what this fails on.
    private static func checkTheBriefingIsInk(_ ok: inout Bool) {
        let clauses = [
            BriefingClause(text: "One fleet task needs a decision.", target: .fleet),
            BriefingClause(text: "Two personal follow-ups are due or overdue.", target: .tasks),
            BriefingClause(text: "3 PRs ready to merge.", target: .review),
            BriefingClause(text: "Plain words.", target: .none),
        ]
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            let paragraph = BriefingParagraphView()
            paragraph.render(clauses, separator: " ", theme: theme)
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let overdue = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                         over: surface, theme: theme)
            let warn = HelmContrast.legibleTintedText(tintHex: HelmTint.warn.hex(in: theme), over: surface, theme: theme)
            check(!same(ink, warn) && !same(ink, overdue), "S10 \(theme.id): the fixture's colours really differ", &ok)
            let runs = paragraph.debugRuns
            check(runs.filter(\.isDot).count == 3, "S10 \(theme.id): one dot per linked clause, got \(runs.filter(\.isDot).count)", &ok)
            for run in runs where !run.isDot && !run.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if run.text.lowercased() == "overdue" {
                    check(run.color.map { same($0, overdue) } == true,
                          "S10 \(theme.id): \"overdue\" keeps its state colour", &ok)
                } else if clauses.contains(where: { $0.text.contains(run.text) }) {
                    check(run.color.map { same($0, ink) } == true,
                          "S10 \(theme.id): \"\(run.text)\" is ink, not its target's hue", &ok)
                }
            }
            check(paragraph.debugPlainText == clauses.map(\.text).joined(separator: " "),
                  "S10 \(theme.id): the paragraph still reads as its clauses: \(paragraph.debugPlainText)", &ok)
        }
    }

    // MARK: - S04

    /// The band is the default surface and paints Settings' two colours; the
    /// pages the proposal moved hold their column in it; Tasks, Hosts and
    /// Poneglyph keep the plain column on purpose.
    private static func checkOneSidebarSurface(_ ok: inout Bool) {
        check(HelmPageSidebar().debugSurface == .band, "S04: a new page sidebar is a band by default", &ok)
        check(HelmPageSidebar.bandPaneWidth == HelmPageSidebar.width + 2 * HelmMetrics.pageGutter,
              "S04: the band is the column plus a gutter either side", &ok)
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            let band = HelmPageSidebar.Band()
            band.applyTheme(theme)
            check(band.debugFill.map { same($0, HelmTheme.sidePanelFill(theme)) } == true
                    && band.debugEdge.map { same($0, HelmTheme.sidePanelEdge(theme)) } == true,
                  "S04 \(theme.id): the band paints the side-panel fill and edge", &ok)
            check(!same(HelmTheme.sidePanelFill(theme), HelmTheme.nsColor(theme.backgroundHex)),
                  "S04 \(theme.id): the band really differs from the page ground", &ok)
        }
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return
        }
        func source(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        for page in ["SchedulesController.swift", "ReadingListController.swift", "NotebookController.swift"] {
            let text = source(page)
            check(!text.isEmpty, "S04: read \(page)", &ok)
            check(text.contains("surface: .sidePanel") && text.contains("HelmPageSidebar.bandInsets"),
                  "S04: \(page) holds its column in the band", &ok)
        }
        check(source("CommandLibraryController.swift").contains("HelmPageSidebar.Band()"),
              "S04: Commands' column sits on the band", &ok)
        let workbench = source("CodePreviewWorkbench.swift")
        check(workbench.contains("HelmPageSidebar.Band()") && !workbench.contains("quickActionsCard"),
              "S04: Code's snippets and quick actions are one band, not two cards", &ok)
        for page in ["ShiftController.swift", "HostsController.swift", "CredentialVaultSidebar.swift"] {
            check(source(page).contains("HelmPageSidebar(surface: .plain)"), "S04: \(page) keeps its plain column", &ok)
        }
    }

    // MARK: - S12

    /// No symbol is bound to two roles, the two suns are apart, and the
    /// Notebook's daily note and the theme toggle read the table.
    private static func checkOneGlyphPerMeaning(_ ok: inout Bool) {
        let names = HelmSymbol.Role.table.map(\.name)
        let doubled = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        check(doubled.isEmpty, "S12: no symbol name is bound to two roles (\(doubled))", &ok)
        check(Set(HelmSymbol.Role.table.map(\.role)) == Set(HelmSymbol.Role.allCases),
              "S12: every role has exactly one row in the table", &ok)
        // The guard's own power: a table with a doubled name is caught.
        let fixture = [("a", "sun.max"), ("b", "sun.max")]
        check(Dictionary(grouping: fixture.map(\.1), by: { $0 }).contains { $0.value.count > 1 },
              "S12: the doubled-name check can fail", &ok)
        check(HelmSymbol.Role.dailyNote.name != HelmSymbol.Role.themeLight.name,
              "S12: Today's note and the light theme toggle draw different glyphs", &ok)
        for role in HelmSymbol.Role.allCases {
            check(NSImage(systemSymbolName: role.name, accessibilityDescription: nil) != nil,
                  "S12: \(role) resolves to a real symbol (\(role.name))", &ok)
        }
        check(DaylightThemeToggleButton.lightSymbol == HelmSymbol.Role.themeLight.name
                && DaylightThemeToggleButton.darkSymbol == HelmSymbol.Role.themeDark.name,
              "S12: the theme toggle reads its glyphs from the role table", &ok)
        guard sourcesAvailable else { print("  SKIP: S12 source half, no app sources"); return }
        let notebook = source("NotebookController.swift")
        check(!notebook.contains("\"sun.max\""), "S12: the Notebook draws no literal sun", &ok)
        check(notebook.contains("HelmSymbol.Role.dailyNote.name"), "S12: the Notebook's daily note reads the role", &ok)
    }

    // MARK: - S17

    /// An informational notice has no edge and a warning or a failure has
    /// one in its own hue; the kicker, title, body and actions are what was
    /// asked; a dismiss hides the notice and tells the caller; and the four
    /// pages that drew their own banner now use this one.
    private static func checkOneNoticeRecipe(_ ok: inout Bool) {
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            for tint in [HelmTint.info, .accent, .good, .warn, .critical] {
                let notice = HelmNotice(actions: [HelmButton(title: "Do it", variant: .secondary, size: .small)])
                notice.frame = NSRect(x: 0, y: 0, width: 720, height: 90)
                notice.configure(.init(tint: tint, symbol: "lightbulb", kicker: "Things you can do",
                                       title: "A title", body: "A body sentence."), theme: theme)
                notice.layoutSubtreeIfNeeded()
                check(notice.debugHasEdge == HelmNotice.hasEdge(tint),
                      "S17 \(theme.id): a \(tint) notice \(HelmNotice.hasEdge(tint) ? "carries" : "has no") edge", &ok)
                if HelmNotice.hasEdge(tint), let edge = notice.card.debugAttentionEdgeColor {
                    check(same(edge, HelmTheme.nsColor(tint.hex(in: theme))),
                          "S17 \(theme.id): the \(tint) edge is painted in its own hue", &ok)
                }
            }
        }
        check(!HelmNotice.hasEdge(.info) && HelmNotice.hasEdge(.warn) && HelmNotice.hasEdge(.critical),
              "S17: the edge rule's fixture differs between info and warn", &ok)
        let notice = HelmNotice(dismissTitle: "Hide tips")
        var dismissed = false
        notice.onDismiss = { dismissed = true }
        notice.configure(.init(tint: .info, symbol: "lightbulb", kicker: "Day 1 of 7", title: "T", body: nil),
                         theme: .daylight)
        check(notice.debugKicker == "DAY 1 OF 7" && notice.debugTitle == "T" && notice.debugBody.isEmpty,
              "S17: the kicker is uppercased and an absent body draws nothing", &ok)
        check(notice.debugActionTitles == ["Hide tips"], "S17: a dismissible notice shows its dismiss", &ok)
        notice.debugDismiss()
        check(notice.isHidden && dismissed, "S17: the dismiss hides the notice and tells the caller", &ok)

        guard sourcesAvailable else { print("  SKIP: S17 source half, no app sources"); return }
        for page in ["HomeCanvasController.swift", "VaultController.swift", "GitHubSyncController.swift",
                     "FleetController.swift"] {
            check(source(page).contains("HelmNotice("), "S17: \(page) draws its notice with HelmNotice", &ok)
        }
        check(!source("SetupSummary.swift").contains("class SetupPausedPushNotice"),
              "S17: GitHub sync's private notice card is gone", &ok)
        check(!source("VaultController.swift").contains("attentionBanner.layer?.backgroundColor"),
              "S17: Secrets' filled amber band is gone", &ok)
        check(!source("HomeCanvasController.swift").contains("tipRow = HelmAccentRow"),
              "S17: Home's tip is no longer an edged accent row", &ok)
    }

    // MARK: - S15

    /// A `.card` header is a 26pt tile, a title, a subtitle, a count badge
    /// and the trailing action; Dictation's cards use it; and no card is
    /// handed a bare label for a header any more.
    private static func checkOneCardHeaderRecipe(_ ok: inout Bool) {
        let header = HelmSectionHeader(size: .card)
        let action = HelmButton(title: "Request access", variant: .primary, size: .small)
        header.configure(leading: .tile(symbol: "mic.fill", tint: .accent), title: "Status", count: "3",
                         subline: "Whether dictation can hear you")
        header.setActions([action])
        check(HelmSectionHeader.tileSide(for: .card) == HelmMetrics.tileSmall && HelmMetrics.tileSmall == 26,
              "S15: a card header's tile is the kit's 26pt small tile", &ok)
        check(header.debugTileVisible && header.debugSubline == "Whether dictation can hear you",
              "S15: the card header draws its tile and its subtitle", &ok)
        check(header.debugCountBadgeText == "3", "S15: the count is a HelmCountBadge", &ok)
        check(header.debugActions.contains { $0 === action }, "S15: the card's action sits in the trailing slot", &ok)
        header.configure(leading: .tile(symbol: "mic.fill", tint: .accent), title: "Status")
        check(header.debugCountBadgeText == nil && header.debugSubline.isEmpty,
              "S15: no count and no subtitle draw nothing (GL-14: no zero standing in)", &ok)
        let card = HelmCard()
        card.setHeader(header)
        check(header.superview != nil, "S15: HelmCard takes a section header as its header", &ok)

        guard sourcesAvailable, let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: S15 source half, no app sources")
            return
        }
        let dictation = source("DictationController.swift")
        // Dic-1 folded Status, Shortcut, Cleanup and the engine into the split
        // card, so Words and Recent are the two cards left.
        check(dictation.components(separatedBy: "= HelmSectionHeader(size: .card)").count - 1 == 2,
              "S15: Dictation's two cards each build a .card header", &ok)
        // The guard: `setHeader(` handed a label, anywhere in the app.
        let pattern = try? NSRegularExpression(pattern: #"\.setHeader\(\w*[Ll]abel\)"#)
        func offenders(_ text: String) -> Int {
            pattern?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        }
        check(offenders("panel.setHeader(sectionLabel)") == 1, "S15: the bare-label guard can fail", &ok)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let bad = names.filter { $0.hasSuffix(".swift") && offenders(source($0)) > 0 }
        check(bad.isEmpty, "S15: no card is handed a bare label as its header (\(bad))", &ok)
    }

    // MARK: - S14

    /// Both densities draw an unknown as a dash, colour a figure only when it
    /// is not the default, and the boxed one puts each figure on the card
    /// surface. The two retired stat components are gone from the app.
    private static func checkOneNumberRecipe(_ ok: inout Bool) {
        let items: [HelmKPIStrip.Item] = [
            .figure(nil, caption: "Working", unknownReason: "no firstmate home"),
            .figure("0", caption: "Failing", tint: .critical, signals: false),
            .figure("2", caption: "Overdue", tint: .critical, signals: true),
        ]
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            let inline = HelmKPIStrip(density: .inline)
            inline.configure(items, theme: theme)
            let boxed = HelmKPIStrip(density: .boxed)
            boxed.configure(items, theme: theme)
            check(inline.debugValues == ["\u{2014}", "0", "2"] && boxed.debugCells.map(\.debugValue) == inline.debugValues,
                  "S14 \(theme.id): both densities draw the same figures, an unknown as a dash", &ok)
            check(boxed.debugCells.first?.toolTip == "no firstmate home",
                  "S14 \(theme.id): an unknown's reason is the cell's tooltip", &ok)
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let red = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), overAnyOf: [surface],
                                                    theme: theme)
            check(!same(ink, red), "S14 \(theme.id): the tint fixture differs from ink", &ok)
            if boxed.debugCells.count == 3, let zero = boxed.debugCells[1].debugValueColor,
               let two = boxed.debugCells[2].debugValueColor {
                check(same(zero, ink), "S14 \(theme.id): a zero failing count stays ink", &ok)
                check(same(two, red), "S14 \(theme.id): two overdue is the corrected red", &ok)
            } else {
                fail("S14 \(theme.id): the boxed strip drew \(boxed.debugCells.count) cells", &ok)
            }
            check(inline.debugCells.isEmpty && inline.debugSeparatorCount == 2,
                  "S14 \(theme.id): inline keeps its hairlines and draws no boxes", &ok)
        }

        guard sourcesAvailable, let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: S14 source half, no app sources")
            return
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".swift") }
        check(!names.contains("HelmMetricCard.swift"), "S14: HelmMetricCard.swift is deleted", &ok)
        // Code, not comments: a comment naming the retired components is history.
        let pattern = try? NSRegularExpression(pattern: #"\b(HelmStatTile|HelmMetricCard|HelmMetricRow)\s*[(.\]:]"#)
        func uses(_ text: String) -> Int {
            let code = text.split(separator: "\n").map { line -> Substring in
                guard let r = line.range(of: "//") else { return line }
                return line[..<r.lowerBound]
            }.joined(separator: "\n")
            return pattern?.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? 0
        }
        check(uses("let tile = HelmStatTile(symbol: \"x\")") == 1, "S14: the retired-component guard can fail", &ok)
        let offenders = names.filter { uses(source($0)) > 0 }
        check(offenders.isEmpty, "S14: no app source uses HelmStatTile or HelmMetricCard (\(offenders))", &ok)
        // Health left this list with H-4 of the page-redesign board: its
        // summary is the hero column's four buckets (`HealthHeroWords`).
        // Setup's five figures are still a boxed strip, as the hero tiles of
        // Sup-1's hero (`SetupHeroRow`).
        for page in ["FleetController.swift", "ReviewController.swift", "SetupHeroRow.swift",
                     "LogAnalyzerController.swift", "ShiftController.swift"] {
            check(source(page).contains("HelmKPIStrip(density: .boxed)"), "S14: \(page) draws its summary row boxed", &ok)
        }
    }

    // MARK: - S16

    /// The bar lays its slots out in the declared order, folds everything but
    /// the scope into "Filter · n" when the slots do not fit, keeps a view the
    /// page hid hidden either way, and the list pages build their row with it.
    private static func checkOneFilterRow(_ ok: inout Bool) {
        let scope = HelmSegmentedTabs(items: [.init(id: "all", title: "All tasks"), .init(id: "due", title: "Due today")],
                                      selected: "all", size: .compact)
        let popup = HelmPopUpButton()
        popup.addItems(withTitles: ["All projects", "Infra hardening"])
        let chip = HelmButton(title: "Follow-ups", variant: .quiet, size: .small)
        let search = HelmSearchField(placeholder: "Find")
        search.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let sort = HelmPopUpButton()
        sort.addItems(withTitles: ["Due date"])
        let bar = HelmFilterBar(scope: scope, popups: [popup], chips: [chip], search: search, trailing: [sort])
        var active = 2
        bar.activeFilterCount = { active }
        let order = bar.debugRowOrder.filter { $0 !== bar.filterButton }
        check(order.count == 5 && order[0] === scope && order[1] === popup && order[2] === chip && order[3] === search
                && order[4] === sort, "S16: the slots are in the declared order", &ok)

        bar.fit(width: 2000)
        check(!bar.debugIsCollapsed && !bar.debugFilterButtonShown && !popup.isHidden && !sort.isHidden,
              "S16: a wide bar shows every slot and no Filter button", &ok)
        check(bar.expandedWidth > 300 && bar.expandedWidth < 2000, "S16: the fixture's needed width is between the two widths", &ok)
        bar.fit(width: 300)
        check(bar.debugIsCollapsed && bar.debugFilterButtonShown && popup.isHidden && chip.isHidden && search.isHidden
                && sort.isHidden && !scope.isHidden,
              "S16: a narrow bar folds everything but the scope into the Filter button", &ok)
        check(bar.debugFilterButtonTitle == "Filter \u{00B7} 2", "S16: the button counts the active filters", &ok)
        active = 0
        bar.refreshFilterButtonTitle()
        check(bar.debugFilterButtonTitle == "Filter", "S16: no active filter reads plain Filter", &ok)

        bar.setPageHidden(chip, true)
        bar.fit(width: 2000)
        check(!bar.debugIsCollapsed && chip.isHidden && !popup.isHidden,
              "S16: a view the page hid stays hidden when the bar unfolds", &ok)
        let fixedWidth = HelmFilterBar(scope: scope)
        fixedWidth.collapseWidth = 900
        fixedWidth.fit(width: 899)
        check(!fixedWidth.debugFilterButtonShown, "S16: a bar with nothing to fold never shows the Filter button", &ok)

        guard sourcesAvailable else { print("  SKIP: S16 source half, no app sources"); return }
        // Tasks left this list with Tf-2 of the five-screen redesign: its
        // filters are the band's figures and pills, and the calendar head's
        // menus (Cf-4), so it builds no filter row at all.
        for page in ["UpdatesController.swift", "LogAnalyzerController.swift", "CredentialVaultController.swift"] {
            check(source(page).contains("HelmFilterBar("), "S16: \(page) builds its filter row with HelmFilterBar", &ok)
        }
        check(source("ShiftController+Calendar.swift").contains("HelmPopUpButton()"),
              "S16: Calendar's Colour by is a pop-up in the trailing slot", &ok)
    }

    // MARK: - S25

    /// The profile step is two equal choice cards with the description inside,
    /// the look step is Settings' seven family tiles, and the sheet is as tall
    /// as its content.
    private static func checkWelcomeChoiceCards(_ ok: inout Bool) {
        let previousHidden = AppSettings.shared.hiddenModules
        defer { AppSettings.shared.hiddenModules = previousHidden }
        let sheet = WelcomeSheetController()
        sheet.loadView()
        let cards = sheet.debugProfileCards
        check(cards.count == WorkspaceProfile.allCases.count, "S25: one choice card per profile", &ok)
        check(cards.map(\.debugTitle) == WorkspaceProfile.allCases.map(\.title)
                && cards.map(\.debugBody) == WorkspaceProfile.allCases.map(\.summary),
              "S25: each card carries its profile's title and description", &ok)
        sheet.debugPickProfile(.personal)
        check(cards.filter(\.isSelected).count == 1 && cards.first(where: \.isSelected)?.debugTitle == WorkspaceProfile.personal.title,
              "S25: picking Personal selects exactly that card", &ok)
        check(cards.allSatisfy { $0.debugBorderWidth == ($0.isSelected ? HelmChoiceCard.ringWidth : 1) },
              "S25: only the chosen card wears the ring", &ok)
        sheet.debugProfileCards.first?.debugKey(124)
        check(sheet.debugProfileCards.last?.isSelected == true, "S25: the right arrow moves the choice to the next card", &ok)
        check(sheet.debugThemeCards.count == AppThemeFamily.members(of: .classic).count,
              "S25: the look step shows the seven family tiles", &ok)
        check(sheet.preferredContentSize.height > 200 && sheet.preferredContentSize.height < 470,
              "S25: the sheet hugs its content (\(sheet.preferredContentSize.height)pt, was a fixed 470)", &ok)
        check(abs(sheet.view.frame.height - sheet.preferredContentSize.height) < 0.5,
              "S25: the sheet's frame is its content's height", &ok)
    }

    // MARK: - S26

    /// A family tile draws both registers and names them once; a terminal
    /// scheme card is still one theme.
    private static func checkThemeTilesShowThePair(_ ok: inout Bool) {
        for family in AppThemeFamily.allCases {
            let card = SettingsThemeCard.family(family, mode: .light, isActive: true)
            let light = family.register(.light), dark = family.register(.dark)
            check(card.pair?.light.id == light.id && card.pair?.dark.id == dark.id,
                  "S26: \(family.title)'s tile carries both registers", &ok)
            let caption = card.nameLabel.stringValue
            check(!caption.hasPrefix("Light:") && !caption.hasPrefix("Dark:") && caption.hasPrefix(light.name)
                    && (caption.contains(dark.name) || dark.name.hasPrefix(light.name)),
                  "S26: \(family.title)'s caption names the pair (\(caption))", &ok)
            check(card.detailLabel.isHidden, "S26: \(family.title)'s tile has no second \"Light:\" line", &ok)
        }
        check(SettingsThemeCard.pairCaption(light: "High Contrast", dark: "High Contrast Dark") == "High Contrast \u{00B7} Dark"
                && SettingsThemeCard.pairCaption(light: "Daylight", dark: "Dusk") == "Daylight \u{00B7} Dusk",
              "S26: the caption names the pair once without repeating the family word", &ok)
        let scheme = SettingsThemeCard(theme: .dusk, isActive: false, kind: .terminal)
        check(scheme.pair == nil, "S26: a terminal scheme card is still one theme", &ok)
    }

    // MARK: - S18

    /// Each island shape draws bars that fill its bounds, the list shows the
    /// loading phrase and says where to look after five seconds, and the
    /// three islands use it instead of an empty state.
    private static func checkIslandLoaders(_ ok: inout Bool) {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        for shape in [HelmSkeletonRow.Shape.editor, .canvas, .monthGrid] {
            let path = HelmSkeletonRow.islandPath(shape, in: bounds, flipped: false)
            check(path != nil && !(path?.isEmpty ?? true), "S18: the \(shape) shape draws bars", &ok)
            if let box = path?.boundingBoxOfPath {
                check(box.width > bounds.width * 0.6 && box.height > bounds.height * 0.6,
                      "S18: the \(shape) shape fills its island (\(box.size))", &ok)
            }
        }
        check(HelmSkeletonRow.islandPath(.row, in: bounds, flipped: false) == nil, "S18: a row draws no island path", &ok)
        let list = HelmSkeletonList(island: .editor, caption: "Loading Monaco from this machine")
        check(list.debugIslandShape == .editor && list.debugCaption == "Loading Monaco from this machine",
              "S18: the loader carries its shape and its phrase", &ok)
        check(!list.debugStillLoadingShown, "S18: the still-loading line waits", &ok)
        list.debugFireStillLoading()
        check(list.debugStillLoadingShown, "S18: after the wait the still-loading line shows", &ok)

        guard sourcesAvailable else { print("  SKIP: S18 source half, no app sources"); return }
        check(!source("CodePreviewController.swift").contains("Starting the editor")
                && source("CodePreviewController.swift").contains("showLoading(island: .editor"),
              "S18: Code loads behind the editor skeleton, not an empty state", &ok)
        check(!source("WhiteboardController.swift").contains("Starting the canvas")
                && source("WhiteboardController.swift").contains("showLoading(island: .canvas"),
              "S18: the Whiteboard loads behind the canvas skeleton", &ok)
        check(source("ShiftCalendarViews.swift").contains("HelmSkeletonList(island: .monthGrid"),
              "S18: the Calendar loads behind the month skeleton", &ok)
    }

    // MARK: - S23

    /// Before a feed tab exists the page shows the Pods table's header and
    /// skeleton rows, naming the namespace; the session card's explanation
    /// is one line.
    private static func checkKubernetesShowsItsShape(_ ok: inout Bool) {
        guard sourcesAvailable else { print("  SKIP: S23, no app sources"); return }
        let page = source("KubernetesController.swift"), render = source("KubernetesController+Render.swift")
        check(page.contains("HelmSkeletonList(rows: 4)") && page.contains("titleLabel: NSTextField(labelWithString: \"Pods\")"),
              "S23: the pending table is the Pods header over skeleton rows", &ok)
        check(render.contains("pendingTablePreview.isHidden = !(hasScope && !ready)"),
              "S23: the skeleton shows exactly while a scope has no feed tab", &ok)
        check(render.contains("appears once a feed tab is logged in"), "S23: its header names the namespace", &ok)
        check(!page.contains("Typing into the feed tab yourself pauses automated commands until it goes quiet again.\")"),
              "S23: the session card's explanation is shorter, keeping the pause warning", &ok)
    }

    // MARK: - S24

    /// gh's failure cases map to what failed, why and what to do, never the
    /// raw command, and every case ends in a next step.
    private static func checkGitHubSyncRowsSayWhatToDo(_ ok: inout Bool) {
        let cases: [(String, String)] = [
            ("gh api repos/manjesh-raj/treehouse failed: To get started with GitHub CLI, please run: gh auth login", "gh is not signed in"),
            ("gh: command not found", "gh is not installed"),
            ("HTTP 403: API rate limit exceeded", "rate limit"),
            ("gh api repos/x/y failed: HTTP 404: Not Found", "does not know this repository"),
            ("error connecting to api.github.com: dial tcp: lookup api.github.com: no such host - could not resolve host", "could not reach github.com"),
            ("gh api repos/x/y failed", "no answer from gh"),
        ]
        for (detail, why) in cases {
            let explained = GitHubSyncController.failureExplanation(detail: detail, syncing: false)
            check(explained.whatFailed == "Couldn't reach GitHub" && explained.why.contains(why),
                  "S24: \"\(detail.prefix(40))\" explains as \(explained.why)", &ok)
            check(explained.whatToDo.hasSuffix("Check again") && !explained.sentence.contains("gh api"),
                  "S24: the row says what to do and never prints the command", &ok)
        }
        check(GitHubSyncController.failureExplanation(detail: "x", syncing: true).whatFailed == "Couldn't sync with upstream",
              "S24: a failed sync says so", &ok)
        check(ScheduleFailureExplanation(whatFailed: "A", why: "B", whatToDo: "C").sentence == "A \u{00B7} B \u{00B7} C",
              "S24: the three parts read as one line", &ok)
    }

    // MARK: - S20

    /// A glyph-only button is a 28pt target with a hover fill, a focus ring
    /// and one label for tooltip and VoiceOver; card actions, the inspector
    /// close and the lane "+" use it; a bare `.imageOnly` button outside the
    /// kit says why it is exempt.
    private static func checkIconTargets(_ ok: inout Bool) {
        let button = HelmIconButton(symbol: "bolt.fill", label: "Connect to grafana")
        button.layoutSubtreeIfNeeded()
        check(button.fittingSize.width >= HelmIconButton.minimumSide && button.fittingSize.height >= HelmIconButton.minimumSide,
              "S20: the target is at least 28pt square (\(button.fittingSize))", &ok)
        check(button.toolTip == "Connect to grafana" && button.accessibilityLabel() == "Connect to grafana",
              "S20: one label is the tooltip and what VoiceOver reads", &ok)
        check(button.focusRingType == .exterior, "S20: keyboard focus draws an exterior ring (GL-16)", &ok)
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            button.applyTheme(theme)
            button.debugHover(false)
            check((button.debugHoverFill?.alphaComponent ?? 0) == 0, "S20 \(theme.id): invisible at rest", &ok)
            button.debugHover(true)
            check(button.debugHoverFill.map { same($0, HelmField.fill(theme)) } ?? false,
                  "S20 \(theme.id): the hover fill is the inset field fill", &ok)
        }
        let grid = HelmGridCardView(frame: .zero)
        var card = HelmCardGrid.Card(key: "h", symbol: "server.rack", tint: .accent, tintHex: nil, title: "grafana",
                                     subtitle: "ops@grafana", accessibilityLabel: "grafana")
        card.actions = [.init(symbol: "bolt.fill", label: "Connect", run: {}),
                        .init(symbol: "pencil", label: "Edit", run: {})]
        grid.configure(card, theme: .daylight)
        check(grid.debugActionButtons.count == 2, "S20: a host card's two actions are icon targets", &ok)

        guard sourcesAvailable, let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: S20 source half, no app sources")
            return
        }
        check(source("WorkspaceInspector.swift").contains("HelmIconButton(symbol: \"xmark\""),
              "S20: the inspector close is an icon target", &ok)
        check(source("ShiftBoardViews.swift").contains("HelmIconButton(symbol: \"plus\""), "S20: the lane + is an icon target", &ok)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Helm") }
        var bare: [String] = []
        for name in names {
            for line in source(name).split(separator: "\n") where line.contains("imagePosition = .imageOnly")
                && !line.contains("HelmIconButton-exempt:") {
                bare.append(name)
            }
        }
        check(bare.isEmpty, "S20: no bare glyph-only NSButton outside the kit without a reason (\(bare))", &ok)
    }

    // MARK: - S21

    /// ⌘⇧[ and ] are in the Go menu, ⌃1 to ⌃9 pick a tab by number from
    /// hidden rows, and ⌘/ on Tasks lists both.
    private static func checkPageTabChords(_ ok: inout Bool) {
        let menu = AppDelegate().buildMenu(installing: false)
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        let numbered = items.filter { $0.action == #selector(WorkspaceShellController.selectModuleTabByNumber(_:)) }
        check(numbered.map(\.keyEquivalent) == (1...9).map(String.init)
                && numbered.allSatisfy { $0.keyEquivalentModifierMask == [.control] && $0.isHidden
                    && $0.allowsKeyEquivalentWhenHidden },
              "S21: ⌃1 to ⌃9 are hidden Go menu rows (\(numbered.map(\.keyEquivalent)))", &ok)
        check(numbered.map(\.tag) == Array(1...9), "S21: each row carries its tab number", &ok)
        check(items.contains { $0.action == #selector(WorkspaceShellController.selectNextModuleTab(_:)) && $0.keyEquivalent == "}" }
                && items.contains { $0.action == #selector(WorkspaceShellController.selectPreviousModuleTab(_:)) && $0.keyEquivalent == "{" },
              "S21: Previous and Next Tab are ⌘⇧[ and ⌘⇧]", &ok)
        let sections = PageShortcuts.sections(module: .tasks, route: .shift, layout: .sidebar, settings: .shared)
        let page = sections.first?.entries ?? []
        let names = WorkspaceModule.tasks.tabs.map(\.name)
        check(page.contains { $0.title == "Previous or next tab" }, "S21: ⌘/ on Tasks lists the tab chords", &ok)
        check(page.contains { $0.keys.first == "\u{2303}" && $0.title == names.joined(separator: " \u{00B7} ") },
              "S21: ⌘/ on Tasks lists ⌃1 to ⌃\(names.count) by tab name", &ok)
    }

    // MARK: - S27

    /// The context chip names exactly what is sent, a question goes out with
    /// the page and its summary through the shell's one crew ask (stubbed
    /// here: no test reaches the real `claude` CLI or the network), the panel
    /// is Operator-only, and a Personal install gets the page's shortcuts.
    private static func checkInspectorCrewPanel(_ ok: inout Bool) {
        let context = WorkspaceInspectorCrewPanel.PageContext(module: .tasks, summary: "7 open \u{00B7} 1 overdue")
        check(WorkspaceInspectorCrewPanel.contextLine(context) == "About Tasks \u{00B7} 7 open \u{00B7} 1 overdue",
              "S27: the chip names the page and its summary line", &ok)
        check(WorkspaceInspectorCrewPanel.question("Plan my week", context: context)
                == "About the Tasks page (7 open \u{00B7} 1 overdue): Plan my week",
              "S27: the question carries exactly the chip's context", &ok)
        check(WorkspaceInspectorCrewPanel.suggestedAsks(for: .tasks).count == 3
                && WorkspaceInspectorCrewPanel.suggestedAsks(for: .dictation).isEmpty,
              "S27: three suggested asks where the table has a row, none elsewhere", &ok)

        let previous = AppSettings.shared.hiddenModules
        defer { AppSettings.shared.hiddenModules = previous }
        AppSettings.shared.setProfile(.operator)
        let panel = WorkspaceInspectorCrewPanel()
        var sent: [String] = []
        panel.onAsk = { text, completion in
            sent.append(text)
            completion(.failure(StrawHatError(message: "stubbed in the self-test")))
        }
        var continued = false
        panel.onContinueInCrew = { continued = true }
        panel.setContext(context)
        _ = panel.view
        check(panel.debugCrewShown && panel.paneTitle == "Ask the crew", "S27: Operator sees the crew panel", &ok)
        check(panel.debugContextChip == WorkspaceInspectorCrewPanel.contextLine(context),
              "S27: the visible chip says what context is sent (\(panel.debugContextChip))", &ok)
        check(panel.debugAskTitles == WorkspaceInspectorCrewPanel.suggestedAsks(for: .tasks),
              "S27: the panel offers Tasks' three asks", &ok)
        panel.debugTapAsk(0)
        check(sent == [WorkspaceInspectorCrewPanel.question(WorkspaceInspectorCrewPanel.suggestedAsks(for: .tasks)[0],
                                                             context: context)],
              "S27: a suggested ask goes out once, with the page's context, through the shell's ask (\(sent))", &ok)
        check(panel.debugCrew.openFullChatTitle == "Continue in Crew", "S27: the panel offers Continue in Crew", &ok)
        panel.debugCrew.onOpenFullChat?()
        check(continued, "S27: Continue in Crew reaches the shell", &ok)

        AppSettings.shared.setProfile(.personal)
        let personal = WorkspaceInspectorCrewPanel()
        personal.setContext(context)
        _ = personal.view
        check(!personal.debugCrewShown && personal.debugPersonalRowCount > 0 && personal.paneTitle == "On Tasks",
              "S27: a Personal install gets the page's shortcuts, not the crew", &ok)

        guard sourcesAvailable else { print("  SKIP: S27 source half, no app sources"); return }
        // Code only: the header names `ClaudeOneShot` to say it is untouched.
        let file = source("WorkspaceInspectorCrewPanel.swift").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        check(!file.contains("ClaudeOneShot") && file.contains("StrawHatMenuBarPopoverController("),
              "S27: the panel reuses the crew's own composer and never runs claude itself", &ok)
        check(source("MainSplitShellController.swift").contains("askCrewFromMenuBar(text"),
              "S27: the shell routes the panel's ask into the one crew conversation", &ok)
        check(!source("WorkspaceInspector.swift").contains("modulesWithDetails"),
              "S27: the hard-coded list of modules with details is retired", &ok)
    }

    // MARK: - S13

    /// Project colours come from the categorical ramp, never a theme's status
    /// tokens; a new project takes the first free hue and keeps it on disk; a
    /// record written before the field existed still decodes (GL-01) and
    /// falls back to the hash.
    private static func checkProjectHuesAreIdentity(_ ok: inout Bool) {
        let identity = Set(ShiftProjectPalette.hues.map { $0.categoricalHex.uppercased() })
        check(identity.count == ShiftProjectPalette.hues.count, "S13: the identity hues are all distinct", &ok)
        for theme in HelmTheme.appThemes {
            let status = [HelmTint.critical, .warn].map { $0.hex(in: theme).uppercased() }
            check(identity.isDisjoint(with: status),
                  "S13: \(theme.id): no project hue is the theme's overdue red or warning amber", &ok)
        }

        // Three projects, three colours, in the documented order.
        var projects: [ShiftProject] = []
        for name in ["Infra hardening", "Release 4.20", "SRE hiring"] {
            var p = ShiftProject.fresh()
            p.name = name
            p.hue = ShiftProjectPalette.firstFreeHue(among: projects)
            projects.append(p)
        }
        check(projects.compactMap(\.hue) == [.blue, .teal, .violet],
              "S13: three new projects take blue, teal and violet, got \(projects.compactMap(\.hue))", &ok)
        // A legacy project (no stored hue) still counts as wearing its fallback.
        var legacy = ShiftProject.fresh()
        legacy.id = "legacy-project"
        let legacyHue = ShiftProjectPalette.fallbackHue(forProjectID: legacy.id)
        check(ShiftProjectPalette.firstFreeHue(among: [legacy]) != legacyHue,
              "S13: a new project never repeats a legacy project's fallback hue while one is free", &ok)

        // The YAML round trip, and a record with no `hue` key.
        var stored = ShiftProject.fresh()
        stored.hue = .rose
        check(ShiftYaml.project(from: ShiftYaml.toYaml(stored))?.hue == .rose, "S13: the hue round-trips through YAML", &ok)
        var withoutKey = YamlOrderedMap()
        withoutKey[.string("id", quoted: .double)] = .string("old", quoted: .double)
        withoutKey[.string("name", quoted: .double)] = .string("Old project", quoted: .double)
        let decoded = ShiftYaml.project(from: .dictionary(withoutKey))
        check(decoded != nil && decoded?.hue == nil, "S13: a record written before the field decodes with no hue", &ok)
        check(ShiftProjectPalette.hue(for: decoded) == ShiftProjectPalette.fallbackHue(forProjectID: "old"),
              "S13: a record with no stored hue resolves through the hash fallback", &ok)

        // The store assigns on create, through its real API, in a scratch root.
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiux-s13-\(UUID().uuidString)")
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let store = ShiftStore()
        for name in ["One", "Two", "Three"] {
            var p = ShiftProject.fresh()
            p.name = name
            store.addProject(p)
        }
        let hues = store.projects.filter { ["One", "Two", "Three"].contains($0.name) }.compactMap(\.hue)
        check(Set(hues).count == 3, "S13: the store gives three new projects three different hues, got \(hues)", &ok)
        let reread = ShiftStore()
        check(reread.projects.compactMap(\.hue) == store.projects.compactMap(\.hue),
              "S13: the assigned hues are stored on disk, not recomputed", &ok)
    }

    // MARK: - Helpers

    /// An app source file's text, or "" when the sources are not beside the
    /// binary. Callers that depend on it check `sourcesAvailable` first.
    static func source(_ name: String) -> String {
        guard let dir = SelfTestSources.appSourceDirectory() else { return "" }
        return (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    static var sourcesAvailable: Bool { SelfTestSources.appSourceDirectory() != nil }

    /// Element-wise colour equality (AGENTS.md: a contrast ratio is not a
    /// colour-equality check).
    static func same(_ a: NSColor, _ b: NSColor, tolerance: Double = 0.004) -> Bool {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) <= tolerance && abs(x.1 - y.1) <= tolerance && abs(x.2 - y.2) <= tolerance
    }

    // MARK: - S22

    /// The inspector's "Nothing selected" kept the theme it was built under:
    /// `HelmEmptyState` applied the theme once at `init`, and a host that
    /// did not pass a change on (the inspector) left it there. Under Daylight
    /// that was Dusk's near-white ink, the pale title. The component follows
    /// the theme itself now, so a state built under one register and shown
    /// under the other takes the new register's ink and muted ink with no
    /// help from its host. The window-backed half, in the real inspector,
    /// is `MainSplitShellPanesSelfTest.checkTheInspectorEmptyStateFollowsTheTheme`.
    private static func checkEmptyStateFollowsTheTheme(_ ok: inout Bool) {
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        func same(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a else { return false }
            let x = HelmContrast.components(a), y = HelmContrast.components(b)
            return abs(x.0 - y.0) <= 0.02 && abs(x.1 - y.1) <= 0.02 && abs(x.2 - y.2) <= 0.02
        }
        check(!same(HelmTheme.nsColor(HelmTheme.daylight.chromeInkHex), HelmTheme.nsColor(HelmTheme.dusk.chromeInkHex)),
              "S22: Daylight's and Dusk's ink are too close for this check to fail", &ok)
        for (from, to) in [(HelmTheme.dusk, HelmTheme.daylight), (HelmTheme.daylight, HelmTheme.dusk)] {
            ThemeManager.shared.setTheme(from)
            let empty = HelmEmptyState(symbol: "sidebar.right", title: "Nothing selected",
                                       body: "Pick something on this page to see it here.", size: .standard)
            ThemeManager.shared.setTheme(to)
            check(same(empty.debugTitleLabel.textColor, HelmTheme.nsColor(to.chromeInkHex)),
                  "S22: an empty state built under \(from.id) kept its title colour under \(to.id)", &ok)
            check(same(empty.debugBodyLabel.textColor, HelmTheme.mutedInk(to)),
                  "S22: an empty state built under \(from.id) kept its body colour under \(to.id)", &ok)
        }
    }


    // MARK: - S03

    /// The page frame's headless half: the tokens add up, the header line
    /// keeps its slot when it says nothing, a scrolling page's first block
    /// lands on the line, and the pages that moved onto `HelmPageScaffold`
    /// keep no frame of their own. Where every page actually starts, in the
    /// real shell, is `MainSplitShellPanesSelfTest.checkEveryPageStartsAtOneHeight`.
    private static func checkOnePageFrame(_ ok: inout Bool) {
        check(HelmMetrics.pageContentTop - HelmMetrics.pageHeaderLine == HelmMetrics.pageContentInset
                && HelmMetrics.pageContentInset > 0,
              "S03: the page frame's tokens do not add up", &ok)

        // The header line: one height, empty or not.
        let header = WorkspaceModuleHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        for (title, subtitle) in [("Health", "3 services · all healthy"), ("Health", ""), (nil as String?, "")] {
            header.configure(title: title, subtitle: subtitle)
            host.layoutSubtreeIfNeeded()
            check(!header.isHidden && abs(header.frame.height - HelmMetrics.pageHeaderLine) < 0.5,
                  "S03: the header line is \(header.isHidden ? "hidden" : "\(header.frame.height)pt") for title \(title ?? "nil"), subtitle \"\(subtitle)\"",
                  &ok)
        }

        // A scrolling page: its first block on the line, at the gutter.
        let scaffold = HelmPageScaffold()
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scaffold.install(in: page)
        let block = NSView()
        block.heightAnchor.constraint(equalToConstant: 80).isActive = true
        scaffold.addContent(block)
        page.layoutSubtreeIfNeeded()
        let frame = block.convert(block.bounds, to: scaffold.documentView)
        check(abs(frame.minY - HelmMetrics.pageContentInset) < 0.5 && abs(frame.minX - HelmMetrics.pageGutter) < 0.5,
              "S03: the scaffold's first block sits at \(frame.origin), want (\(HelmMetrics.pageGutter), \(HelmMetrics.pageContentInset))",
              &ok)
        check(abs(frame.width - (scaffold.scrollView.contentView.bounds.width - 2 * HelmMetrics.pageGutter)) < 0.5,
              "S03: the scaffold's block is \(frame.width)pt wide, not the column", &ok)
        // A top slot takes the line, and the content scrolls under it.
        let slot = NSView()
        slot.heightAnchor.constraint(equalToConstant: 30).isActive = true
        scaffold.setTopSlot(slot)
        page.layoutSubtreeIfNeeded()
        let slotTop = scaffold.isFlipped ? slot.frame.minY : scaffold.bounds.height - slot.frame.maxY
        let scrollTop = scaffold.isFlipped ? scaffold.scrollView.frame.minY
            : scaffold.bounds.height - scaffold.scrollView.frame.maxY
        check(abs(slotTop - HelmMetrics.pageContentInset) < 0.5 && abs(scrollTop - (slotTop + 30)) < 0.5,
              "S03: the scaffold's top slot sits \(slotTop)pt down with the content from \(scrollTop)pt, want the line and under it",
              &ok)

        // The pages that moved over keep no private frame: no scroll view or
        // flipped document of their own for the page, and no top constant.
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("  SKIP S03 source guard: the app's sources were not found")
            return
        }
        let moved = ["HealthController", "ToolsController", "UpdatesController", "BootstrapController",
                     "AutomationController", "GitHubSyncController", "DictationController", "ReviewController",
                     "FleetController", "VaultController", "LogAnalyzerController", "SchedulesController",
                     "CommandLibraryController"]
        for name in moved {
            guard let text = try? String(contentsOf: root.appendingPathComponent("\(name).swift"), encoding: .utf8) else {
                fail("S03: \(name).swift could not be read", &ok)
                continue
            }
            check(text.contains("HelmPageScaffold("), "S03: \(name) does not use HelmPageScaffold", &ok)
            check(!text.contains("private let scroll = NSScrollView()") && !text.contains("let content = FlippedView()"),
                  "S03: \(name) builds its own page scroll view or document again", &ok)
        }
    }

}

#endif
