// Grand Line - native macOS app.
//
// The feel pass (the Fable second-opinion review's Stage 1, cut to the
// feasibility audit's six items): Home's greeting, briefing hero and KPI
// strip, the sidebar's search pill and the density switch, checked where a
// check needs no window. The Home wiring (the
// hero replacing the briefing card, Customize bringing it back) is measured
// in `MainSplitShellNavigationSelfTest`, which already mounts Home in a real
// window.
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
            ("2 the hero shows every word at every width", checkHeroShowsEverything),
            ("2 the tiles fill the width in balanced rows", checkHeroRows),
            ("2 a tile keeps the hero's contrast in every theme", checkHeroTileContrast),
            ("2 a tile's click goes to its own page", checkHeroTileClicks),
            ("2 Open Needs you only when a task needs the captain", checkHeroNeedsYou),
            ("3 today's task figures", checkTaskCounts),
            ("5 the toolbar tabs are no wider than the control they replaced", checkToolbarTabsWidth),
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
                             tiles: [.init(label: "Overview", text: "Two follow-ups are due.", tint: .warn, isLink: true)],
                             ring: .init(value: 6, total: 8, label: "Health", caption: "services healthy", isLink: true)))
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
            let arc = hero.debugRing?.debugArcColor.flatMap(NSColor.init(cgColor:))
            check(arc.map { HelmContrast.ratio($0, ink) < 1.001 } ?? false, "\(id): the ring's arc is not the ink", &ok)
        }
        check(hero.debugRingShown && hero.debugRing?.centreLabelForTests == "6/8",
              "the ring reads \(hero.debugRing?.centreLabelForTests ?? "nothing")", &ok)
        check(hero.debugActionTitles == ["See Health"], "the hero's actions are \(hero.debugActionTitles)", &ok)
        hero.configure(.init(kicker: "", title: "Not generated yet today", tiles: [], ring: nil))
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
        var record = MorningBriefingRecord(
            day: "2026-11-18", generatedAt: Date(),
            clauses: [BriefingClause(text: "One fleet task needs a decision.", target: .fleet),
                      BriefingClause(text: "Two follow-ups are due.", target: .tasks),
                      BriefingClause(text: "20 tasks finished.", target: .none)],
            isDegraded: false, degradedReason: nil, dismissed: false, sources: ["fleet"], shiftTaskID: nil)
        // No headline (an older record, or the local stat line): the first
        // clause leads and the rest are the tiles.
        let words = HomeBriefingHero.words(record: record, enabled: true, settingsName: "Settings")
        check(words.title == "One fleet task needs a decision."
                && words.facts.map(\.text) == ["Two follow-ups are due.", "20 tasks finished."] && words.note == nil,
              "the hero reads \"\(words.title)\" over \(words.facts.map(\.text))", &ok)
        // H-b: the AI's headline leads and every clause is a tile.
        record.headline = "A decision is waiting"
        let headed = HomeBriefingHero.words(record: record, enabled: true, settingsName: "Settings")
        check(headed.title == "A decision is waiting" && headed.facts.count == 3,
              "with a headline the hero reads \"\(headed.title)\" over \(headed.facts.count) tiles", &ok)
        record.headline = "   "
        check(HomeBriefingHero.words(record: record, enabled: true, settingsName: "Settings").title
                == "One fleet task needs a decision.", "a blank headline replaced the first clause", &ok)
        let off = HomeBriefingHero.words(record: nil, enabled: false, settingsName: "Settings")
        check(off.title == "Morning briefing is off" && (off.note ?? "").contains("Settings") && off.facts.isEmpty,
              "with the briefing off the hero reads \"\(off.title)\"", &ok)
        let pending = HomeBriefingHero.words(record: nil, enabled: true, settingsName: "Settings")
        check(pending.title == "Not generated yet today" && pending.note != nil,
              "before today's briefing the hero reads \"\(pending.title)\"", &ok)

        // A clause's tile: labelled with its page, a dot in its target's hue,
        // and a link only where the clause points somewhere.
        let name: (RailDestination) -> String = { $0 == .overview ? "Overview" : "Tasks" }
        let fleet = HomeBriefingHero.tile(BriefingClause(text: "A.", target: .fleet), pageName: name)
        check(fleet.label == "Overview" && fleet.isLink && fleet.tint == BriefingTarget.fleet.tint,
              "a fleet clause's tile is \(fleet)", &ok)
        let note = HomeBriefingHero.tile(BriefingClause(text: "B.", target: .none), pageName: name)
        check(note.label == "Note" && !note.isLink && note.tint == nil, "a clause pointing nowhere is \(note)", &ok)
        check(HomeBriefingHero.page(of: .tasks) == .shift && HomeBriefingHero.page(of: .none) == nil,
              "a clause's page is not the page its link opens", &ok)
    }

    /// The captain's two defects (fm/grandline-briefing-card): a headline cut
    /// to one line with an ellipsis, and words held in a 560pt column on a
    /// card twice that wide. Measured on the captain's own briefing, at a
    /// narrow, the captain's and a full-screen width.
    private static func checkHeroShowsEverything(_ ok: inout Bool) {
        let headline = "Pull request status is unknown because the scan could not reach the forge."
        let facts = ["20 fleet tasks finished today and 48 are queued.",
                     "No crew is working, and nothing needs a decision or is blocked.",
                     "The watcher is healthy and no personal tasks or follow-ups are due."]
        for width in [600, 975, 1400] as [CGFloat] {
            let hero = HelmHeroCard()
            hero.configure(.init(kicker: "Morning briefing \u{00B7} generated 12:46 PM \u{00B7} 1 source", title: headline,
                                 tiles: facts.map { .init(label: "Overview", text: $0, tint: .warn, isLink: true) },
                                 ring: .init(value: 6, total: 6, label: "Health", caption: "services healthy", isLink: true)))
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            host.addSubview(hero)
            NSLayoutConstraint.activate([
                hero.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                hero.widthAnchor.constraint(equalToConstant: width),
                hero.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
            let column = width - HelmHeroCard.insets.left - HelmHeroCard.insets.right
            let title = hero.debugTitleLabel
            let oneLine = ceil(title.attributedStringValue.size().width)
            // The fixture must be able to fail: at the narrow width the
            // headline cannot fit one line.
            if width == 600 {
                check(oneLine > column, "fixture: the headline fits one line at \(width)pt - the wrap check measures nothing", &ok)
            }
            // A label's frame carries its cell's 2pt padding either side.
            check(abs(title.frame.width - column) <= 4.5,
                  "at \(width)pt the headline is \(title.frame.width)pt wide, want the column's \(column)", &ok)
            let lines = (oneLine / max(1, column)).rounded(.up)
            let lineHeight = ceil(title.font?.boundingRectForFont.height ?? 26)
            check(title.frame.height >= (lines - 1) * lineHeight + lineHeight * 0.8,
                  "at \(width)pt the headline needs \(Int(lines)) lines and is \(title.frame.height)pt tall", &ok)
            check(title.cell?.wraps == true && title.maximumNumberOfLines == 0,
                  "the headline's cell does not wrap, or caps its lines", &ok)
            // Every tile ends inside the card, the rows reach the column's
            // edge, and no sentence is clipped.
            let tiles = hero.debugTiles + [hero.debugRingTile].compactMap { $0 }
            let right = tiles.map { $0.convert($0.bounds, to: hero).maxX }.max() ?? 0
            check(abs(right - (width - HelmHeroCard.insets.right)) < 1.5,
                  "at \(width)pt the tiles end at \(right), want the column's edge \(width - HelmHeroCard.insets.right)", &ok)
            for tile in tiles {
                let text = tile.debugTextLabel
                let needed = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.frame.width, height: 10_000)).height ?? 0
                check(text.frame.height >= needed - 0.5 && text.frame.maxY <= tile.bounds.height + 0.5,
                      "at \(width)pt \"\(text.stringValue.prefix(30))\" is \(text.frame.height)pt tall in a "
                      + "\(tile.bounds.height)pt tile, needs \(needed)", &ok)
                check(tile.convert(tile.bounds, to: hero).maxY <= hero.bounds.height - HelmHeroCard.insets.bottom + 0.5,
                      "at \(width)pt a tile runs past the card's bottom inset", &ok)
            }
        }
    }

    private static func checkHeroRows(_ ok: inout Bool) {
        let rows = { HelmHeroCard.rows(count: $0, width: $1) }
        // Room for four (4 * 200 + 3 * 10 = 830): five tiles are three over
        // two, never four over a lone fifth.
        check(rows(5, 900) == [3, 2], "five tiles at 900pt are \(rows(5, 900))", &ok)
        check(rows(5, 1352) == [5], "five tiles at 1352pt are \(rows(5, 1352))", &ok)
        check(rows(6, 927) == [3, 3], "six tiles at 927pt are \(rows(6, 927))", &ok)
        check(rows(2, 552) == [2], "two tiles at 552pt are \(rows(2, 552))", &ok)
        check(rows(3, 300) == [1, 1, 1], "three tiles at 300pt are \(rows(3, 300))", &ok)
        check(rows(0, 900).isEmpty, "no tiles still makes a row", &ok)
    }

    /// A tile's wash moves away from the ink, so the text inside one never
    /// reads worse than on the gradient - over either stop, in every theme.
    /// And a fact's dot clears the non-text floor on the washed tile.
    private static func checkHeroTileContrast(_ ok: inout Bool) {
        var failures: [String] = []
        for theme in everyTheme {
            let palette = HelmHeroCard.palette(for: theme)
            let wash = HelmHeroCard.tileWash(for: palette)
            for stop in [palette.start, palette.end] {
                let tile = HelmContrast.mix(stop, wash.rgb, wash.alpha)
                let bare = HelmContrast.ratio(palette.ink, stop)
                let washed = HelmContrast.ratio(palette.ink, tile)
                if washed + 0.001 < min(bare, HelmContrast.textTarget) || washed < HelmContrast.textTarget {
                    failures.append("\(theme.id) ink \(String(format: "%.2f", washed)):1 on a tile")
                }
                for tint in [HelmTint.good, .warn, .info, .critical] {
                    let dot = HelmContrast.components(HelmHeroSurface.signalColor(tintHex: tint.hex(in: theme), on: palette))
                    let ratio = HelmContrast.ratio(dot, tile)
                    if ratio < HelmContrast.nonTextTarget - 0.05 {
                        failures.append("\(theme.id) \(tint) dot \(String(format: "%.2f", ratio)):1 on a tile")
                    }
                }
            }
        }
        check(failures.isEmpty, "tiles lose contrast: \(failures.prefix(6).joined(separator: "; "))"
              + (failures.count > 6 ? " and \(failures.count - 6) more" : ""), &ok)
    }

    /// Through the tile's own click recognizer (VoiceOver's press replays
    /// it), so deleting the wiring fails this - not a call to the handler.
    private static func checkHeroTileClicks(_ ok: inout Bool) {
        let hero = HelmHeroCard()
        hero.configure(.init(kicker: "", title: "Two things",
                             tiles: [.init(label: "Review", text: "A.", tint: .good, isLink: true),
                                     .init(label: "Note", text: "B.", tint: nil, isLink: false),
                                     .init(label: "Tasks", text: "C.", tint: .warn, isLink: true)],
                             ring: .init(value: 5, total: 6, label: "Health", caption: "services healthy", isLink: true)))
        var opened: [Int] = []
        var ringOpened = 0
        hero.onActivateTile = { opened.append($0) }
        hero.onActivateRing = { ringOpened += 1 }
        let tiles = hero.debugTiles
        guard tiles.count == 3, let ring = hero.debugRingTile else {
            fail("the hero drew \(tiles.count) tiles and \(hero.debugRingTile == nil ? "no" : "a") ring tile", &ok)
            return
        }
        check(tiles[0].isActivatable && !tiles[1].isActivatable && tiles[2].isActivatable && ring.isActivatable,
              "a tile is clickable where its fact points nowhere, or not where it points somewhere", &ok)
        _ = tiles[2].accessibilityPerformPress()
        _ = tiles[1].accessibilityPerformPress()
        _ = tiles[0].accessibilityPerformPress()
        _ = ring.accessibilityPerformPress()
        check(opened == [2, 0], "pressing the tiles opened \(opened), want [2, 0]", &ok)
        check(ringOpened == 1, "pressing the services tile opened Health \(ringOpened) times", &ok)
        check(tiles[0].debugLabel == "REVIEW" && tiles[0].debugText == "A.", "the first tile reads \(tiles[0].debugLabel ?? "-")", &ok)
        // A new render with the same shape keeps its views (and their hover).
        hero.configure(.init(kicker: "", title: "Two things",
                             tiles: [.init(label: "Review", text: "A2.", tint: .good, isLink: true),
                                     .init(label: "Note", text: "B.", tint: nil, isLink: false),
                                     .init(label: "Tasks", text: "C.", tint: .warn, isLink: true)],
                             ring: .init(value: 6, total: 6, label: "Health", caption: "services healthy", isLink: true)))
        check(hero.debugTiles.first === tiles[0] && hero.debugTiles.first?.debugText == "A2.",
              "a words-only change rebuilt the tiles", &ok)
    }

    private static func checkHeroNeedsYou(_ ok: inout Bool) {
        func task(_ status: String) -> FleetTask {
            var t = FleetTask(id: "t-\(status)", repo: "grand-line", kind: "ship", pr: nil)
            t.status = status
            return t
        }
        let idle = [task("done"), task("queued")]
        // The captain's morning: nothing waiting, and the PR scan failed. The
        // verdict is amber and says nothing known needs them.
        let verdict = FleetGreeting.answer(tasks: idle, prs: .failed("offline"), homeOk: true)
        check(verdict.tint != .good, "fixture: a failed PR scan no longer tints the verdict - the check measures nothing", &ok)
        check(!HomeBriefingHero.offersNeedsYou(crewShown: true, tasks: idle),
              "the hero offers Open Needs you when nothing needs the captain", &ok)
        check(HomeBriefingHero.offersNeedsYou(crewShown: true, tasks: idle + [task("needs_decision")]),
              "a decision waiting does not offer Open Needs you", &ok)
        check(HomeBriefingHero.offersNeedsYou(crewShown: true, tasks: [task("blocked")]),
              "a blocked task does not offer Open Needs you", &ok)
        check(!HomeBriefingHero.offersNeedsYou(crewShown: false, tasks: [task("blocked")]),
              "Open Needs you shows with the crew hidden from Home", &ok)
    }

    // MARK: - Item 3

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

    // MARK: - Item 5

    /// The toolbar has no slack at 1512pt with Larger text (CI measured two
    /// modules' crumbs overflowing when the strip used the kit's own 12pt
    /// pill inset), so the strip may be no wider than the `NSSegmentedControl`
    /// it replaced, for every module's tabs at every text scale.
    private static func checkToolbarTabsWidth(_ ok: inout Bool) {
        let savedScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(savedScale) }
        let sets = WorkspaceModule.allCases.map(\.children).filter { $0.count > 1 }
        check(sets.count >= 3, "fixture: only \(sets.count) modules have tabs - the width check measures little", &ok)
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            for names in sets {
                // Counts on every tab, the widest a label gets.
                let labels = names.map { WorkspaceToolbar.tabLabel($0, count: 22) }
                let strip = HelmSegmentedTabs(items: labels.enumerated().map { .init(id: "\($0.offset)", title: $0.element) },
                                              selected: "0", size: .compact, pillInset: WorkspaceToolbar.tabPillInset,
                                              labelSize: WorkspaceToolbar.tabLabelSize)
                let segmented = NSSegmentedControl()
                segmented.segmentCount = labels.count
                for (index, label) in labels.enumerated() {
                    segmented.setLabel(label, forSegment: index)
                    segmented.setWidth(0, forSegment: index)
                }
                let mine = strip.fittingSize.width
                let system = segmented.fittingSize.width
                // A point per tab: at a 1x backing scale (CI's runner) each
                // pill's width rounds to a whole point on its own, and the
                // strip measured 333pt against 331pt there with a 2x Mac at
                // 325pt. The overrun this guards against was 30 to 70pt.
                check(mine <= system + CGFloat(labels.count),
                      "at \(step.title) text the tabs \(names) are \(mine)pt, wider than the \(system)pt system control", &ok)
            }
        }
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
