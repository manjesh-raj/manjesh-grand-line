// Grand Line - native macOS app.
//
// The feel pass (the Fable second-opinion review's Stage 1, cut to the
// feasibility audit's six items): Home's greeting, briefing hero and KPI
// strip, the sidebar's search pill and the density switch, checked where a
// check needs no window. The Home wiring (the
// hero replacing the briefing card, Customize bringing it back) is measured
// in `MainSplitShellSelfTest`, which already mounts Home in a real window.
//
// Run with `FM_RUN_FEEL_PASS_TESTS=1 .build/debug/GrandLine`.
//
// Pure logic: no window. Views are laid out on their own. Deliberately NOT in
// `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum FeelPassSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        print("== FeelPassSelfTest ==")
        var allOK = true
        let cases: [(String, (inout Bool) -> Void)] = [
            ("1 the display title is 30pt, tracked, tabular", checkDisplayTitle),
            ("1 the greeting's summary sentence", checkGreetingSentence),
            ("1 the greeting's captain name", checkCaptainName),
            ("2 the hero's ink clears the text floor in every theme", checkHeroPaletteContrast),
            ("2 the hero paints its palette and its ring", checkHeroView),
            ("2 the ring takes a size", checkRingSize),
            ("2 the hero's words come from the briefing", checkHeroWords),
            ("3 the four tiles and where they go", checkKPITiles),
            ("3 an unread figure is a dash, never a zero", checkKPIUnknowns),
            ("3 today's task figures", checkTaskCounts),
            ("4 the search pill's words clear the text floor in every theme", checkSearchPillContrast),
            ("6 density is a factor on every row height", checkDensityRowHeights),
            ("6 changing density re-fires the theme", checkDensityRefires),
        ]
        for (name, body) in cases {
            var ok = true
            autoreleasepool { body(&ok) }
            print("  \(ok ? "OK  " : "FAIL") \(name)")
            allOK = allOK && ok
        }
        print(allOK ? "FeelPassSelfTest: all checks passed" : "FeelPassSelfTest: FAILED")
        return allOK
    }

    /// Every palette the app can show: the app themes and every terminal
    /// scheme, so a hero on any of them is covered.
    private static var everyTheme: [HelmTheme] {
        var seen = Set<String>()
        return (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Item 1

    private static func checkDisplayTitle(_ ok: inout Bool) {
        let font = HelmType.displayTitle()
        check(abs(font.pointSize - HelmType.scaled(30)) < 0.01,
              "the display title is \(font.pointSize)pt, want \(HelmType.scaled(30))", &ok)
        let traits = NSFontManager.shared.traits(of: font)
        check(traits.contains(.boldFontMask), "the display title is not bold", &ok)
        // Tabular numerals: every digit advances the same width.
        let widths = (0...9).map { ("\($0)" as NSString).size(withAttributes: [.font: font]).width }
        check((widths.max() ?? 0) - (widths.min() ?? 0) < 0.01,
              "the display title's digits are not tabular (widths \(widths))", &ok)
        // The fixture's own discriminating power: the plain system face is
        // proportional, so the check above can fail.
        let plain = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
        let plainWidths = (0...9).map { ("\($0)" as NSString).size(withAttributes: [.font: plain]).width }
        check((plainWidths.max() ?? 0) - (plainWidths.min() ?? 0) > 0.01,
              "fixture: the plain face is tabular too - the digit check measures nothing", &ok)
        let kern = HelmType.displayTitleAttributes(color: .black)[.kern] as? CGFloat ?? 0
        check(kern < 0 && abs(kern - (-0.025 * HelmType.scaled(30))) < 0.001,
              "the display title is tracked \(kern), want the prototype's -0.025em", &ok)
    }

    private static func checkGreetingSentence(_ ok: inout Bool) {
        typealias F = HomeGreeting.Facts
        let cases: [(F, String)] = [
            (F(dueToday: nil, overdue: nil, prsReady: nil, servicesFailing: nil), "Your day is still being read."),
            (F(dueToday: 0, overdue: 0, prsReady: 0, servicesFailing: 0), "Nothing is due today."),
            (F(dueToday: 1, overdue: 0, prsReady: nil, servicesFailing: nil), "1 task is due today."),
            (F(dueToday: 2, overdue: 1, prsReady: nil, servicesFailing: 1),
             "2 tasks are due, 1 overdue and 1 service needs a look."),
            (F(dueToday: 0, overdue: 0, fleetNeedsYou: "1 task needs your call", prsReady: 3, servicesFailing: 2),
             "1 task needs your call, 3 PRs are ready to merge and 2 services need a look."),
            (F(dueToday: 0, overdue: 0, fleetNeedsYou: "Crew is waiting.", prsReady: 0, servicesFailing: 0),
             "Crew is waiting."),
        ]
        for (facts, want) in cases {
            let got = HomeGreeting.sentence(facts)
            check(got == want, "the summary for \(facts) reads \"\(got)\", want \"\(want)\"", &ok)
        }
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
        let line = HomeGreeting.summary(F(dueToday: 0, overdue: 0, prsReady: nil, servicesFailing: nil), now: noon)
        check(line.hasPrefix(noon.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ". "),
              "the summary does not open with the date: \"\(line)\"", &ok)
        check(HomeGreeting.title(captain: "Ana", now: noon) == "Good afternoon, Ana",
              "the noon greeting reads \"\(HomeGreeting.title(captain: "Ana", now: noon))\"", &ok)
    }

    private static func checkCaptainName(_ ok: inout Bool) {
        check(HomeGreeting.captainName(fleetCaptain: "Manjesh", fullName: "Someone Else", userName: "x") == "Manjesh",
              "the fleet's captain does not win", &ok)
        check(HomeGreeting.captainName(fleetCaptain: nil, fullName: "Ana Lima", userName: "ana") == "Ana",
              "the full name's first word is not used", &ok)
        check(HomeGreeting.captainName(fleetCaptain: "", fullName: "", userName: "ana") == "ana",
              "the account name is not the last resort", &ok)
    }

    // MARK: - Item 2

    private static func checkHeroPaletteContrast(_ ok: inout Bool) {
        let themes = everyTheme
        check(themes.count >= 26, "fixture: only \(themes.count) themes - the sweep is not every palette", &ok)
        var deepened = 0
        for theme in themes {
            let palette = HelmHeroCard.palette(for: theme)
            let start = HelmContrast.ratio(palette.ink, palette.start)
            let end = HelmContrast.ratio(palette.ink, palette.end)
            check(start >= HelmContrast.textTarget && end >= HelmContrast.textTarget,
                  "\(theme.id): the hero's ink measures \(String(format: "%.2f", start)) and "
                  + "\(String(format: "%.2f", end)) against its two stops", &ok)
            let accent = HelmContrast.components(HelmTheme.nsColor(theme.accentHex))
            if palette.start != HelmContrast.mix((1, 1, 1), accent, HelmHeroCard.startLift) { deepened += 1 }
        }
        // The deepening is what keeps pale accents legible; a sweep where no
        // theme needed it would not show the rule works.
        check(deepened > 0, "fixture: no theme needed its stops deepened - the rule is untested", &ok)
        // And the prototype's own stops where white already clears them.
        let blue = HelmHeroCard.palette(accent: (0.10, 0.30, 0.70))
        check(blue.start == HelmContrast.mix((1, 1, 1), (0.10, 0.30, 0.70), HelmHeroCard.startLift)
                && blue.ink == (1, 1, 1),
              "a dark accent is not drawn on the prototype's own stops in white", &ok)
    }

    private static func checkHeroView(_ ok: inout Bool) {
        let hero = HelmHeroCard()
        hero.frame = NSRect(x: 0, y: 0, width: 1100, height: 220)
        hero.configure(.init(kicker: "Morning briefing", title: "One fleet task needs a decision.",
                             body: "Two follow-ups are due.", ring: .init(value: 6, total: 8, caption: "services healthy")))
        hero.setActions([HelmButton(title: "See Health", variant: .secondary)])
        for id in ["daylight", "dusk", "ember", "contrast-dark"] {
            guard let theme = HelmTheme.appThemes.first(where: { $0.id == id }) else {
                fail("fixture: no \(id) theme", &ok)
                continue
            }
            hero.applyTheme(theme)
            hero.layoutSubtreeIfNeeded()
            let palette = HelmHeroCard.palette(for: theme)
            let ink = HelmContrast.color(palette.ink)
            check(hero.debugTitleColor.map { HelmContrast.ratio($0, ink) < 1.001 } ?? false,
                  "\(id): the title is not painted in the hero's ink", &ok)
            check(hero.debugGradientColors.count == 2, "\(id): the gradient has \(hero.debugGradientColors.count) stops", &ok)
            let arc = hero.debugRing.debugArcColor.flatMap(NSColor.init(cgColor:))
            check(arc.map { HelmContrast.ratio($0, ink) < 1.001 } ?? false, "\(id): the ring's arc is not the ink", &ok)
        }
        check(hero.debugRingShown && hero.debugRing.centreLabelForTests == "6/8",
              "the ring reads \(hero.debugRing.centreLabelForTests)", &ok)
        check(hero.debugActionTitles == ["See Health"], "the hero's actions are \(hero.debugActionTitles)", &ok)
        hero.configure(.init(kicker: "", title: "Not generated yet today", body: "", ring: nil))
        check(!hero.debugRingShown, "a hero with no figure still draws a ring", &ok)
    }

    private static func checkRingSize(_ ok: inout Bool) {
        let plain = HelmRingGauge()
        let hero = HelmRingGauge(side: HelmRingGauge.heroSide)
        plain.layoutSubtreeIfNeeded()
        hero.layoutSubtreeIfNeeded()
        check(plain.diameter == 66 && abs(plain.fittingSize.width - 66) < 0.5,
              "the default ring is \(plain.fittingSize.width)pt, want 66", &ok)
        check(hero.diameter == 86 && abs(hero.fittingSize.width - 86) < 0.5,
              "the hero ring is \(hero.fittingSize.width)pt, want 86", &ok)
    }

    private static func checkHeroWords(_ ok: inout Bool) {
        let record = MorningBriefingRecord(
            day: "2026-11-18", generatedAt: Date(),
            clauses: [BriefingClause(text: "One fleet task needs a decision.", target: .none),
                      BriefingClause(text: "Two follow-ups are due.", target: .none),
                      BriefingClause(text: "20 tasks finished.", target: .none)],
            isDegraded: false, degradedReason: nil, dismissed: false, sources: ["fleet"], shiftTaskID: nil)
        let words = HomeBriefingHero.words(record: record, enabled: true, settingsName: "Settings")
        check(words.title == "One fleet task needs a decision." && words.body == "Two follow-ups are due. 20 tasks finished.",
              "the hero reads \"\(words.title)\" / \"\(words.body)\"", &ok)
        let off = HomeBriefingHero.words(record: nil, enabled: false, settingsName: "Settings")
        check(off.title == "Morning briefing is off" && off.body.contains("Settings"),
              "with the briefing off the hero reads \"\(off.title)\"", &ok)
        let pending = HomeBriefingHero.words(record: nil, enabled: true, settingsName: "Settings")
        check(pending.title == "Not generated yet today", "before today's briefing the hero reads \"\(pending.title)\"", &ok)
    }

    // MARK: - Item 3

    private static func healthSummary(healthy: Int, failing: Int) -> ServiceHealthSummary {
        let services = Array(HealthService.allCases.prefix(healthy + failing))
        let entries = services.enumerated().map { index, service in
            ServiceHealthSummary.Entry(
                service: service,
                state: index < healthy
                    ? ServiceHealthState(lastSuccess: Date())
                    : ServiceHealthState(lastFailure: Date(), lastFailureDetail: "x",
                                         consecutiveFailures: ServiceHealthRegistry.failureThreshold))
        }
        return ServiceHealthSummary(entries)
    }

    private static func checkKPITiles(_ ok: inout Bool) {
        let counts = HomeTaskCounts(tasks: [], followUps: [])
        let tiles = HomeKPITiles.tiles(
            tasks: .init(counts: counts),
            prs: .init(reading: .value(3), open: 22),
            health: healthSummary(healthy: 6, failing: 1),
            claude: .init(week: nil, failure: nil))
        check(tiles.map(\.item.caption) == ["Tasks due today", "PRs ready to merge", "Services healthy", "Claude week"],
              "the tiles are \(tiles.map(\.item.caption))", &ok)
        check(tiles.map(\.opens) == [.shift, .review, .health, .console],
              "the tiles open \(tiles.map(\.opens))", &ok)
        check(tiles.allSatisfy(\.item.isAction), "a tile is not a button", &ok)
        check(tiles[1].item.reading.text { $0 } == "3" && tiles[1].item.detail?.text == "of 22 open",
              "the PR tile reads \(tiles[1].item.reading.text { $0 }) / \(tiles[1].item.detail?.text ?? "")", &ok)
        check(tiles[2].item.reading.text { $0 } == "6 / 7" && tiles[2].item.detail?.text == "1 failing"
                && tiles[2].item.detail?.tint == .critical,
              "the services tile reads \(tiles[2].item.reading.text { $0 }) / \(tiles[2].item.detail?.text ?? "")", &ok)
        // A profile that hides the crew drops both crew tiles.
        let personal = HomeKPITiles.tiles(tasks: .init(counts: counts), prs: nil,
                                          health: healthSummary(healthy: 2, failing: 0), claude: nil)
        check(personal.map(\.opens) == [.shift, .health], "a Personal strip opens \(personal.map(\.opens))", &ok)
    }

    private static func checkKPIUnknowns(_ ok: inout Bool) {
        let tiles = HomeKPITiles.tiles(
            tasks: .init(counts: nil),
            prs: .init(reading: .scanning, open: nil),
            health: ServiceHealthSummary([]),
            claude: .init(week: nil, failure: "quota-axi is not signed in"))
        for tile in tiles {
            check(!tile.item.reading.isKnown && tile.item.reading.text { $0 } != "0",
                  "\(tile.item.caption) shows \(tile.item.reading.text { $0 }) for a figure nobody read", &ok)
        }
        if case .failed(let why) = tiles[3].item.reading {
            check(why == "quota-axi is not signed in", "the Claude tile's reason is \(why)", &ok)
        } else {
            fail("the Claude tile does not carry its failure", &ok)
        }
        let failed = HomeKPITiles.tiles(tasks: nil, prs: .init(reading: .failed("gh timed out"), open: 4),
                                        health: nil, claude: nil)
        check(failed.first?.item.detail?.text == "Could not read the queue",
              "a failed PR scan reads \(failed.first?.item.detail?.text ?? "nothing")", &ok)
    }

    private static func checkTaskCounts(_ ok: inout Bool) {
        // Local noon, `Calendar.current` - AGENTS.md's rule for a day fixture.
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
        func day(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: offset, to: now)!
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
        func task(_ id: String, _ status: ShiftTaskStatus, due: String?, completed: Date? = nil) -> ShiftTask {
            ShiftTask(id: id, title: id, description: "", status: status, priority: .normal, dueDate: due,
                      dueTime: nil, projectID: nil, tags: [], createdAt: "2026-01-01T00:00:00Z",
                      updatedAt: "2026-01-01T00:00:00Z",
                      completedAt: completed.map { ISO8601DateFormatter().string(from: $0) },
                      notes: nil, subtasks: [], hasAttachment: false)
        }
        let tasks = [
            task("late", .todo, due: day(-2)),
            task("today", .inProgress, due: day(0)),
            task("tomorrow", .todo, due: day(1)),
            task("undated", .todo, due: nil),
            task("done", .completed, due: day(0), completed: now.addingTimeInterval(-3600)),
            task("doneYesterday", .completed, due: day(-1), completed: now.addingTimeInterval(-86_400 * 2)),
            task("dropped", .cancelled, due: day(0)),
        ]
        let counts = HomeTaskCounts(tasks: tasks, followUps: [], now: now, calendar: calendar)
        check(counts.due == 2 && counts.overdue == 1 && counts.doneToday == 1,
              "the counts are due \(counts.due), overdue \(counts.overdue), done \(counts.doneToday); want 2, 1, 1", &ok)
    }

    // MARK: - Item 4

    private static func checkSearchPillContrast(_ ok: inout Bool) {
        let pill = WorkspaceSidebarSearchPill()
        for theme in everyTheme {
            pill.applyTheme(theme)
            let label = pill.debugLabelColor ?? .clear
            let worst = min(HelmContrast.ratio(label, pill.debugRestFill), HelmContrast.ratio(label, pill.debugHoverFill))
            check(worst >= HelmContrast.textTarget - 0.01,
                  "\(theme.id): the pill's words measure \(String(format: "%.2f", worst)) on its fill", &ok)
        }
        check(pill.debugHoverFill != pill.debugRestFill, "the pill's hover fill is its resting fill", &ok)
    }

    // MARK: - Item 6

    private static func checkDensityRowHeights(_ ok: inout Bool) {
        let saved = AppSettings.shared.density
        defer { AppSettings.shared.density = saved }
        let scale = ChromeTextScale.shared.scale
        AppSettings.shared.density = .comfortable
        for base: CGFloat in [24, 28, 32, 36] {
            check(HelmType.scaledRowHeight(base) == base * scale,
                  "Comfortable moved a \(base)pt row to \(HelmType.scaledRowHeight(base))", &ok)
        }
        AppSettings.shared.density = .compact
        check(HelmType.scaledRowHeight(36) == (30 * scale).rounded(),
              "Compact draws a 36pt row at \(HelmType.scaledRowHeight(36)), want the prototype's 30", &ok)
        check(HelmType.scaledRowHeight(32) < 32 * scale && HelmType.scaledRowHeight(32) == HelmType.scaledRowHeight(32).rounded(),
              "Compact's 32pt row is \(HelmType.scaledRowHeight(32)) - not shorter, or not a whole point", &ok)
        AppSettings.shared.set(densityRaw: "a-future-density")
        check(AppSettings.shared.density == .comfortable, "an unknown stored density is not read as Comfortable", &ok)
    }

    private static func checkDensityRefires(_ ok: inout Bool) {
        let saved = AppSettings.shared.density
        defer { AppSettings.shared.density = saved }
        AppSettings.shared.density = .comfortable
        var fired = 0
        var heights: [CGFloat] = []
        let token = ThemeManager.shared.observe { _ in
            fired += 1
            heights.append(HelmType.scaledRowHeight(36))
        }
        defer { ThemeManager.shared.unobserve(token) }
        let before = fired
        AppSettings.shared.density = .compact
        check(fired == before + 1, "changing density re-fired the theme \(fired - before) times, want once", &ok)
        check(heights.last.map { $0 < 36 * ChromeTextScale.shared.scale } ?? false,
              "an observer re-reading its row height on the re-fire still read Comfortable", &ok)
        AppSettings.shared.density = .compact
        check(fired == before + 1, "setting the same density again re-fired the theme", &ok)
    }
}

#endif
