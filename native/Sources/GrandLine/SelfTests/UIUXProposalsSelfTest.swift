// Grand Line - native macOS app.
//
// The 2026-11-17 UI/UX proposals the captain approved (S01, S02, S04 to S18,
// S20, S21, S23 to S27), checked where a check can be made without a window. Each case names its
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

    /// Element-wise colour equality (AGENTS.md: a contrast ratio is not a
    /// colour-equality check).
    static func same(_ a: NSColor, _ b: NSColor, tolerance: Double = 0.004) -> Bool {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) <= tolerance && abs(x.1 - y.1) <= tolerance && abs(x.2 - y.2) <= tolerance
    }
}

#endif
