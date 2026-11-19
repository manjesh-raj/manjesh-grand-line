// Grand Line - native macOS app.
//
// Setup's Sup-1 hero: each sub-page's verdict, the ring, the tiles' figures,
// and `HelmKPIStrip`'s boxed hero tiles (Helm 1.3.0) - the recipe and its
// contrast on every theme and tone. Pure, so it runs headless in CI's
// blocking lane. Where the hero sits on the four pages, what its pills run
// and its three widths are `SidebarRedesignsSelfTest`'s, in a window.
//
// Run with:
//   swift build && FM_RUN_SETUP_HERO_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SetupHeroSelfTest {

    static func run() -> Bool {
        print("== SetupHeroSelfTest ==")
        var allOK = true
        let cases: [(String, (inout Bool) -> Void)] = [
            ("Updates' verdict", checkUpdatesWords),
            ("Setup steps' verdict", checkStepsWords),
            ("Automation's verdict", checkAutomationWords),
            ("GitHub sync's verdict", checkGitHubWords),
            ("an unread reading is a dash and dims the hero (GL-14)", checkUnreadDims),
            ("the ring", checkTheRing),
            ("an idle figure is quiet", checkIdleFigures),
            ("boxed hero tiles: the recipe", checkHeroTileRecipe),
            ("boxed hero tiles: contrast on every theme and tone", checkHeroTileContrast),
            ("the pills mirror the page's own controls", checkThePillsMirror),
        ]
        for (name, body) in cases {
            var ok = true
            autoreleasepool { body(&ok) }
            print("  \(ok ? "OK  " : "FAIL") \(name)")
            allOK = allOK && ok
        }
        print(allOK ? "SetupHeroSelfTest: all checks passed" : "SetupHeroSelfTest: FAILED")
        return allOK
    }

    typealias Counts = BackgroundSignalsPoller.SignalCounts

    private static func tools(total: Int, upToDate: Int, updates: Int) -> Counts {
        var counts = Counts()
        counts.toolsTotal = total
        counts.toolsUpToDate = upToDate
        counts.toolsWithUpdate = updates
        return counts
    }

    /// `behind` is the poller's `forkDrift`, which leaves the diverged forks
    /// out; `forksToSync` adds them back.
    private static func forks(total: Int, checked: Int, behind: Int, diverged: Int = 0) -> Counts {
        var counts = Counts()
        counts.forksTotal = total
        counts.forksChecked = checked
        counts.forkDrift = behind
        counts.forksDiverged = diverged
        return counts
    }

    // MARK: The words

    private static func checkUpdatesWords(_ ok: inout Bool) {
        let now = Date()
        let cases: [(Counts, String, SetupHeroWords.Tone)] = [
            (tools(total: 13, upToDate: 13, updates: 0), "All 13 tools are up to date.", .accent),
            (tools(total: 13, upToDate: 12, updates: 1), "1 tool has an update.", .amber),
            (tools(total: 13, upToDate: 10, updates: 3), "3 tools have an update.", .amber),
            (tools(total: 13, upToDate: 11, updates: 0), "11 of 13 tools are up to date.", .amber),
        ]
        for (counts, want, tone) in cases {
            let words = SetupHeroWords.updates(counts, checkedAt: now.addingTimeInterval(-32), now: now)
            check(words.headline == want && words.tone == tone && !words.isDimmed,
                  "Updates reads \"\(words.headline)\" (\(words.tone)), want \"\(want)\" (\(tone))", &ok)
        }
        let fine = SetupHeroWords.updates(tools(total: 13, upToDate: 13, updates: 0),
                                          checkedAt: now.addingTimeInterval(-32), now: now)
        check(fine.body == "Checked just now. Nothing needs attention.", "the all-clear body reads \(fine.body)", &ok)
        check(fine.kicker == "Setup \u{00B7} This Mac", "the kicker reads \(fine.kicker)", &ok)
        let missing = SetupHeroWords.updates(tools(total: 13, upToDate: 11, updates: 0), checkedAt: nil, now: now)
        check(missing.body.hasPrefix("2 tools could not be checked or are not installed."),
              "two unchecked tools read \(missing.body)", &ok)
    }

    private static func checkStepsWords(_ ok: inout Bool) {
        let all = SetupPipelineProgress(done: 5, checking: 0, failed: 0, total: 5)
        check(SetupHeroWords.steps(all, nextStep: nil).headline == "Every setup step is done.",
              "five of five reads \(SetupHeroWords.steps(all, nextStep: nil).headline)", &ok)
        let some = SetupHeroWords.steps(SetupPipelineProgress(done: 3, checking: 0, failed: 0, total: 5),
                                        nextStep: "Software checklist")
        check(some.headline == "3 of 5 setup steps are done." && some.body.hasPrefix("Next: Software checklist.")
                && some.tone == .accent,
              "three of five reads \"\(some.headline)\" / \"\(some.body)\"", &ok)
        let failed = SetupHeroWords.steps(SetupPipelineProgress(done: 3, checking: 0, failed: 1, total: 5), nextStep: nil)
        check(failed.headline == "A setup step failed." && failed.tone == .red,
              "a failed step reads \"\(failed.headline)\" (\(failed.tone))", &ok)
    }

    private static func checkAutomationWords(_ ok: inout Bool) {
        typealias A = SetupHeroWords.Automation
        let mixed = SetupHeroWords.automation([
            A(name: "Fork sync - all 8 forks", cadence: "Daily at 11:10 AM", isOn: true),
            A(name: "Drift check", cadence: "Nightly at 2:00 AM", isOn: false),
            A(name: "Dotfiles auto-commit", isOn: false),
            A(name: "Reconnecting dropped sessions", isOn: true),
        ])
        check(mixed.headline == "2 automations on, 2 off.", "two of four reads \(mixed.headline)", &ok)
        check(mixed.body == "Fork sync - all 8 forks runs daily at 11:10 AM. Drift check and Dotfiles auto-commit are off.",
              "two of four's body reads \(mixed.body)", &ok)
        check(SetupHeroWords.automation([A(name: "x", isOn: true), A(name: "y", isOn: false),
                                         A(name: "z", isOn: false), A(name: "w", isOn: false)]).headline
                == "1 automation on, 3 off.", "one on is not singular", &ok)
        check(SetupHeroWords.automation([A(name: "x", isOn: false)]).headline == "Every automation is off.",
              "all off is not stated", &ok)
        check(SetupHeroWords.automation([A(name: "x", isOn: true), A(name: "y", isOn: true)]).headline
                == "All 2 automations are on.", "all on is not stated", &ok)
        check(SetupHeroWords.automation([]).headline == "Nothing runs on its own yet.", "no automation is not stated", &ok)
    }

    private static func checkGitHubWords(_ ok: inout Bool) {
        let now = Date()
        let checkedAt = now.addingTimeInterval(-27 * 60)
        let inSync = SetupHeroWords.github(forks(total: 8, checked: 8, behind: 0), configRepo: nil,
                                           checkedAt: checkedAt, ownCommits: [("automic-vault", 6)], now: now)
        check(inSync.headline == "8 forks, all in sync." && inSync.tone == .accent,
              "eight in sync reads \(inSync.headline)", &ok)
        check(inSync.body == "Checked 27 min ago. automic-vault carries 6 commits of its own on top of upstream.",
              "eight in sync's body reads \(inSync.body)", &ok)
        let cases: [(Counts, String, SetupHeroWords.Tone)] = [
            (forks(total: 8, checked: 8, behind: 2), "2 of 8 forks are behind upstream.", .amber),
            (forks(total: 8, checked: 8, behind: 1), "1 fork is behind upstream.", .amber),
            (forks(total: 8, checked: 8, behind: 0, diverged: 1), "1 fork has diverged from upstream.", .red),
            (forks(total: 8, checked: 8, behind: 2, diverged: 1), "3 forks need syncing, 1 diverged.", .red),
            (forks(total: 8, checked: 0, behind: 0), "The forks could not be checked.", .red),
            (forks(total: 8, checked: 5, behind: 0), "5 of 8 forks could be checked.", .amber),
        ]
        for (counts, want, tone) in cases {
            let words = SetupHeroWords.github(counts, configRepo: nil, checkedAt: checkedAt, now: now)
            check(words.headline == want && words.tone == tone,
                  "GitHub sync reads \"\(words.headline)\" (\(words.tone)), want \"\(want)\" (\(tone))", &ok)
        }
        let paused = SetupHeroWords.github(forks(total: 8, checked: 8, behind: 0),
                                           configRepo: ConfigRepoPrivacy.Reading(visibility: .publicRepo, at: now),
                                           checkedAt: checkedAt, now: now)
        check(paused.headline == "Pushing to the config repo is paused." && paused.tone == .red,
              "a public config repo reads \(paused.headline)", &ok)
    }

    private static func checkUnreadDims(_ ok: inout Bool) {
        let updates = SetupHeroWords.updates(Counts(), checkedAt: nil)
        let github = SetupHeroWords.github(Counts(), configRepo: nil, checkedAt: nil)
        let steps = SetupHeroWords.steps(.of([:]), nextStep: nil)
        for (name, words) in [("Updates", updates), ("GitHub sync", github), ("Setup steps", steps)] {
            check(words.isDimmed, "\(name)'s unread verdict is not dimmed", &ok)
            check(!words.headline.contains("0"), "\(name)'s unread verdict states a zero: \(words.headline)", &ok)
        }
        // The dimmed palette is really a different colour, so the flag is not
        // vacuous on screen.
        let theme = HelmTheme.daylight
        let read = SetupHeroRow.palette(for: .init(headline: "", body: "", tone: .accent, isDimmed: false), in: theme)
        let dim = SetupHeroRow.palette(for: .init(headline: "", body: "", tone: .accent, isDimmed: true), in: theme)
        check(read != dim, "a dimmed hero paints the same gradient as a read one", &ok)
        // Every unread tile is a dash with its reason, never a zero.
        let cards = SetupSummary.cards(counts: Counts(), steps: .of([:]), dotfiles: nil, configRepo: nil)
        let items = SetupHeroWords.items(cards)
        check(items.allSatisfy { !$0.reading.isKnown && $0.reading.text { $0 } == HelmReading<String>.dash },
              "an unread tile is not a dash: \(items.map { $0.reading.text { $0 } })", &ok)
        check(items.allSatisfy { if case .failed = $0.reading { return true } else { return false } },
              "an unread tile has no reason for its tooltip", &ok)
    }

    private static func checkTheRing(_ ok: inout Bool) {
        let all = SetupHeroWords.ring(SetupPipelineProgress(done: 5, checking: 0, failed: 0, total: 5))
        check(all.label == "5/5" && all.fraction == 1 && !all.failed, "five of five's ring reads \(all.label)", &ok)
        let checking = SetupHeroWords.ring(SetupPipelineProgress(done: 3, checking: 2, failed: 0, total: 5))
        check(checking.label == HelmReading<String>.dash && checking.fraction == 0,
              "a ring with steps still being checked reads \(checking.label)", &ok)
        check(SetupHeroWords.ring(SetupPipelineProgress(done: 3, checking: 0, failed: 1, total: 5)).failed,
              "a failed step does not mark the ring", &ok)
    }

    private static func checkIdleFigures(_ ok: inout Bool) {
        var counts = tools(total: 13, upToDate: 13, updates: 0)
        counts.forksTotal = 8
        counts.forksChecked = 8
        counts.forkDrift = 0
        let steps = SetupPipelineProgress.of(Dictionary(uniqueKeysWithValues: SetupStepKind.allCases.map { ($0, true) }))
        for (status, quiet) in [(DotfilesAutoSync.Status.off, true), (.noRepo, true), (.synced, false)] {
            let items = SetupHeroWords.items(SetupSummary.cards(counts: counts, steps: steps, dotfiles: status,
                                                                configRepo: nil))
            check((items[3].emphasis == .quiet) == quiet,
                  "dotfiles \(status) is \(items[3].emphasis), want \(quiet ? "quiet" : "not quiet")", &ok)
        }
    }

    // MARK: The tiles

    private static func items() -> [HelmKPIStrip.Item] {
        [.figure("13 / 13", caption: "Tools up to date"),
         .figure("0", caption: "Updates"),
         .figure("Diverged", caption: "Dotfiles", tint: .critical, signals: true),
         HelmKPIStrip.Item(.value("Off"), caption: "Dotfiles", emphasis: .quiet),
         .figure(nil, caption: "GitHub sync", unknownReason: "Not checked yet.")]
    }

    private static func checkHeroTileRecipe(_ ok: inout Bool) {
        let theme = HelmTheme.dusk
        let palette = SetupHeroRow.palette(for: .init(headline: "", body: "", tone: .accent, isDimmed: false), in: theme)
        let ink = HelmContrast.color(palette.ink)
        let strip = HelmKPIStrip(density: .boxed)
        strip.configure(items(), theme: theme)
        strip.frame = NSRect(x: 0, y: 0, width: 640, height: 100)
        let plain = strip.debugCells.map { $0.debugFigureIsAboveCaption }
        check(plain.allSatisfy { !$0 }, "a plain boxed tile puts its figure above its caption", &ok)
        let plainHeight = strip.debugCells.first.map { $0.fittingSize.height } ?? 0

        strip.heroPalette = palette
        strip.heroInk = ink
        strip.layoutSubtreeIfNeeded()
        let cells = strip.debugCells
        check(cells.allSatisfy { $0.debugIsHeroTile && $0.debugFigureIsAboveCaption },
              "a hero tile does not put its figure over its caption", &ok)
        check(cells.allSatisfy { $0.debugCard.layer?.borderWidth == 0 }, "a hero tile keeps the card's border", &ok)
        let fill = cells.first?.debugFillColor.flatMap(NSColor.init(cgColor:))
        check(fill.map { abs($0.alphaComponent - HelmKPIStrip.heroTileFillAlpha) < 0.001 } == true,
              "a hero tile's shade is \(fill.map { "\($0.alphaComponent)" } ?? "missing")", &ok)
        let heroHeight = cells.first.map { $0.fittingSize.height } ?? 0
        check(abs(heroHeight - HelmKPIStrip.heroTileHeight) < 0.5 && heroHeight < plainHeight,
              "a hero tile is \(heroHeight)pt, a plain one \(plainHeight)pt", &ok)
        // A number takes the hero's figure size and a word the smaller one,
        // as the board draws them.
        check(cells[0].debugValuePointSize > cells[3].debugValuePointSize,
              "\"13 / 13\" is \(cells[0].debugValuePointSize)pt beside \"Off\" at \(cells[3].debugValuePointSize)pt", &ok)
        // The ink: a known figure is the ink, a quiet or unknown one dims, a
        // tinted one keeps its signal on the gradient.
        func rgb(_ color: NSColor?) -> (Double, Double, Double)? { color.map(HelmContrast.components) }
        check(cells[0].debugValueColor?.alphaComponent == 1 && rgb(cells[0].debugValueColor).map { same($0, palette.ink) } == true,
              "a known figure is not the ink", &ok)
        check(abs((cells[3].debugValueColor?.alphaComponent ?? 1) - HelmKPIStrip.heroQuietAlpha) < 0.01
                && abs((cells[4].debugValueColor?.alphaComponent ?? 1) - HelmKPIStrip.heroQuietAlpha) < 0.01,
              "a quiet or unknown figure is not the quiet ink", &ok)
        let signal = HelmHeroSurface.signalColor(tintHex: HelmTint.critical.hex(in: theme), on: palette)
        check(rgb(cells[2].debugValueColor).map { same($0, HelmContrast.components(signal)) } == true
                && rgb(cells[2].debugValueColor).map { same($0, palette.ink) } == false,
              "a tinted figure lost its signal on the gradient", &ok)
        check(cells[4].debugValue == HelmReading<String>.dash && cells[4].toolTip == "Not checked yet.",
              "an unknown tile reads \(cells[4].debugValue) with tooltip \(cells[4].toolTip ?? "none")", &ok)
        // Taking the ink away gives the plain tile back.
        strip.heroInk = nil
        check(strip.debugCells.allSatisfy { !$0.debugIsHeroTile && !$0.debugFigureIsAboveCaption },
              "a strip that leaves the hero keeps the hero tile", &ok)
    }

    /// The text floor for the captions and known figures on the tile's
    /// shade, and the large-text floor for quiet and signal figures, on every
    /// theme in every tone the hero takes.
    private static func checkHeroTileContrast(_ ok: inout Bool) {
        var worst = (ratio: Double.infinity, what: "")
        var checked = 0
        for theme in TasksSecretsHeroSelfTest.everyTheme {
            for tone in [SetupHeroWords.Tone.accent, .amber, .red] {
                for dimmed in [false, true] {
                    let words = SetupHeroWords.Words(headline: "", body: "", tone: tone, isDimmed: dimmed)
                    let palette = SetupHeroRow.palette(for: words, in: theme)
                    let ink = HelmContrast.color(palette.ink)
                    let shade = HelmContrast.components(HelmButton.heroShade(for: ink))
                    // The tile composited over the lighter stop, which is
                    // where its words have the least room.
                    let tile = HelmContrast.mix(shade, palette.lighterStop, Double(HelmKPIStrip.heroTileFillAlpha))
                    func over(_ alpha: CGFloat) -> (Double, Double, Double) {
                        HelmContrast.mix(palette.ink, tile, Double(alpha))
                    }
                    let label = "\(theme.id) \(tone)\(dimmed ? " dimmed" : "")"
                    let pairs: [(String, Double, Double)] = [
                        ("figure", HelmContrast.ratio(over(1), tile), HelmContrast.textTarget),
                        ("caption", HelmContrast.ratio(over(HelmKPIStrip.heroCaptionAlpha), tile), HelmContrast.textTarget),
                        ("quiet figure", HelmContrast.ratio(over(HelmKPIStrip.heroQuietAlpha), tile),
                         HelmContrast.nonTextTarget),
                        ("signal figure", HelmContrast.ratio(HelmContrast.components(HelmHeroSurface.signalColor(
                            tintHex: HelmTint.critical.hex(in: theme), on: palette)), tile), HelmContrast.nonTextTarget),
                    ]
                    for (what, ratio, floor) in pairs {
                        checked += 1
                        if ratio - floor < worst.ratio { worst = (ratio - floor, "\(label) \(what) \(ratio)") }
                        check(ratio >= floor - 0.01, "\(label): a hero tile's \(what) measures \(ratio):1, under \(floor)", &ok)
                    }
                }
            }
        }
        check(checked > 100, "the sweep measured \(checked) pairs, so it is vacuous", &ok)
        print("    tightest: \(worst.what)")
    }

    // MARK: The pills

    @objc private final class Target: NSObject {
        var pressed = 0
        @objc func fire(_ sender: Any?) { pressed += 1 }
    }

    private static func checkThePillsMirror(_ ok: inout Bool) {
        let target = Target()
        let source = HelmButton(title: "Sync All", variant: .primary, size: .small, target: target,
                                action: #selector(Target.fire(_:)))
        source.toolTip = "Sync the 2 forks behind upstream."
        let action = SetupHeroRow.Action.mirroring(source)
        check(action.title() == "Sync All" && action.isEnabled() && action.toolTip() == source.toolTip,
              "the pill does not read its control's title, state and tooltip", &ok)
        action.run()
        check(target.pressed == 1, "the pill did not run its control's own action", &ok)
        source.isEnabled = false
        source.title = "Syncing\u{2026}"
        action.run()
        check(target.pressed == 1 && !action.isEnabled() && action.title() == "Syncing\u{2026}",
              "a pill ran a disabled control, or did not follow its words", &ok)
    }

    private static func same(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) < 0.01 && abs(a.1 - b.1) < 0.01 && abs(a.2 - b.2) < 0.01
    }
}

#endif
