// Grand Line - native macOS app.
//
// Health's and Connections' hero columns (H-4 and C-4 on the page-redesign
// board), the half that needs no window:
//
//   - `HealthHeroWords`: every verdict - nothing reported, all healthy, a
//     failing service, a recent failure, some not run yet - with its tone
//     (red only while something fails, dimmed before anything reports), its
//     ring, its four buckets and which pills the foot offers, worst first.
//   - `ConnectionsHeroWords`: an unreadable hosts file, no hosts, no live
//     session, one and several, and the keys clause.
//   - `KeysHeroWords` (the same column on the Keys tab): an unreadable keys
//     file, no keys, Touch ID or not, the last-used key, unused keys, and
//     the in-use ring.
//   - The column's palette, swept over every theme's accent and red and
//     every Home preset: the ink clears the text floor on the bare stops and
//     on a ghost pill's and the field's shade, and the 80% ink of a second
//     line clears it on the stops.
//   - The kit's new options: `HelmCardGrid`'s column cap,
//     `HelmSplitPage.floorWidth`, and `HelmHeroColumn` handing its ink to
//     the controls on it and switching between column and band.
//   - CR-1 Crew band (the hero restyle board): `CrewHeroWords` for Needs you
//     and In flight in every state, the band's kit options (`HelmHeroColumn`
//     1.5.0's status pill, band views and foot rule, `HelmHeroTileGrid.paint`,
//     `HelmKPIStrip`'s inline action column), a real `FleetController` in the
//     sidebar layout drawing the first read, a good read and a failed one with
//     its rows carried, and the band's painted words, pill, tiles and figures
//     clearing their floors on every palette.
//
// The layout in a real shell is `PageHeroColumnsViewSelfTest`.
//
// Run with:
//   swift build && FM_RUN_PAGE_HERO_COLUMNS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum PageHeroColumnsSelfTest {

    static func run() -> Bool {
        var allOK = true
        let checks: [(inout Bool) -> Void] = [
            checkHealthWords,
            checkConnectionsWords,
            checkKeysWords,
            checkTheColumnPaletteClearsTheFloor,
            checkTheGridColumnCap,
            checkTheFloorWidth,
            checkTheColumnInksItsControls,
            checkCrewNeedsYouWords,
            checkCrewInFlightWords,
            checkTheBandsNewOptions,
            checkTheCrewBandOnTheRealPage,
            checkTheCrewBandClearsTheFloorOnEveryPalette,
        ]
        for check in checks {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "PageHeroColumnsSelfTest: all checks passed" : "PageHeroColumnsSelfTest: FAILED")
        return allOK
    }

    private static func ratio(_ value: Double) -> String { String(format: "%.2f", value) }
    private static let now = Date()
    private static func relative(_ date: Date) -> String { "\(Int(now.timeIntervalSince(date) / 60)) minutes ago" }

    // MARK: Health

    private static func entry(_ service: HealthService, success: TimeInterval? = nil, failures: Int = 0,
                              detail: String = "the remote said no") -> ServiceHealthSummary.Entry {
        var state = ServiceHealthState()
        if let success { state.lastSuccess = now.addingTimeInterval(-success) }
        if failures > 0 {
            state.consecutiveFailures = failures
            state.lastFailure = now.addingTimeInterval(-120)
            state.lastFailureDetail = detail
        }
        return .init(service: service, state: state)
    }

    private static func checkHealthWords(_ ok: inout Bool) {
        let none = HealthHeroWords.make(ServiceHealthSummary(), canRetry: { _ in true }, relative: relative)
        check(none.tone == .unknown && none.ring == nil && none.retryable.isEmpty && !none.offersDiagnostics,
              "Health: nothing reported is not the dimmed, ringless, pill-less column", &ok)
        check(none.buckets.map(\.count) == [nil, nil, nil, nil], "Health: nothing reported counts \(none.buckets.map(\.count)), not unknown (GL-14)", &ok)
        check(none.buckets.map(\.bucket) == [.healthy, .degraded, .failing, .notRun],
              "Health: the buckets stack \(none.buckets.map(\.bucket))", &ok)

        let healthy = HealthHeroWords.make(ServiceHealthSummary([entry(.fleetTasks, success: 30),
                                                                 entry(.shiftGitSync, success: 300)]),
                                           canRetry: { _ in true }, relative: relative)
        check(healthy.tone == .accent && healthy.headline == "All 2 background services are healthy.",
              "Health: all healthy reads \"\(healthy.headline)\" in \(healthy.tone)", &ok)
        check(healthy.ring?.healthy == 2 && healthy.ring?.total == 2 && healthy.ringState == .ok,
              "Health: the healthy ring is \(String(describing: healthy.ring))", &ok)
        check(healthy.ringCaption == "services healthy\nlast report 0 minutes ago",
              "Health: the ring caption reads \"\(healthy.ringCaption)\"", &ok)
        check(healthy.buckets.map(\.detail) == ["Fleet task watcher and Tasks git sync", "None", "None", "None"],
              "Health: the bucket lines read \(healthy.buckets.map(\.detail))", &ok)

        let summary = ServiceHealthSummary([
            entry(.backgroundSignals, success: 900, failures: 1, detail: "gh: could not reach api.github.com"),
            entry(.fleetTasks, success: 30),
            entry(.dotfilesAutoSync, success: 7200, failures: 3, detail: "git push was rejected"),
            entry(.scheduledAutomations),
        ])
        let failing = HealthHeroWords.make(summary, canRetry: { $0 != .backgroundSignals }, relative: relative)
        check(failing.tone == .failing, "Health: a failing service leaves the column \(failing.tone), not red", &ok)
        check(failing.headline == "Dotfiles auto-sync has failed 3 runs in a row.",
              "Health: the failing headline reads \"\(failing.headline)\"", &ok)
        check(failing.body == "Last error 2 minutes ago: git push was rejected.",
              "Health: the failing body reads \"\(failing.body)\"", &ok)
        check(failing.ringState == .ok, "Health: a red column's ring arc is \(failing.ringState), not the ink", &ok)
        check(failing.buckets.map(\.count) == [1, 1, 1, 1], "Health: the buckets count \(failing.buckets.map(\.count))", &ok)
        check(failing.retryable == [.dotfilesAutoSync] && failing.offersDiagnostics,
              "Health: the foot offers \(failing.retryable) and diagnostics \(failing.offersDiagnostics)", &ok)
        let both = HealthHeroWords.make(summary, canRetry: { _ in true }, relative: relative)
        check(both.retryable == [.dotfilesAutoSync, .backgroundSignals], "Health: Retry is not worst first (\(both.retryable))", &ok)

        let degraded = HealthHeroWords.make(ServiceHealthSummary([entry(.docsSync, success: 600, failures: 1),
                                                                  entry(.fleetTasks, success: 30)]),
                                            canRetry: { _ in false }, relative: relative)
        check(degraded.tone == .accent && degraded.ringState == .warn,
              "Health: a recent failure is \(degraded.tone) with a \(degraded.ringState) arc, not the accent with amber", &ok)
        check(degraded.headline == "Docs & runbooks sync failed its last run.",
              "Health: the recent-failure headline reads \"\(degraded.headline)\"", &ok)
        check(degraded.body.hasSuffix("Copy diagnostics has the details."),
              "Health: with nothing to retry the body does not point at diagnostics (\"\(degraded.body)\")", &ok)

        let partial = HealthHeroWords.make(ServiceHealthSummary([entry(.fleetTasks, success: 30), entry(.docsSync)]),
                                           canRetry: { _ in true }, relative: relative)
        check(partial.headline == "1 of 2 services are healthy." && partial.body == "Docs & runbooks sync has not run yet.",
              "Health: a not-run service reads \"\(partial.headline)\" / \"\(partial.body)\"", &ok)
        check(HealthHeroWords.names([.fleetTasks, .docsSync, .persistence, .shiftDueItems])
                == "Fleet task watcher, Docs & runbooks sync and 2 more",
              "Health: a long bucket line reads \(HealthHeroWords.names([.fleetTasks, .docsSync, .persistence, .shiftDueItems]))", &ok)
    }

    // MARK: Connections

    private static func checkConnectionsWords(_ ok: inout Bool) {
        func words(readable: Bool = true, hosts: Int = 7, live: [ConnectionsHeroWords.LiveSession] = [],
                   keys: Int = 2, biometry: Bool = true, snippets: Int = 3,
                   last: (String, Date)? = nil) -> ConnectionsHeroWords {
            ConnectionsHeroWords.make(hostsReadable: readable, hostCount: hosts, live: live, keyCount: keys,
                                      biometryAvailable: biometry, snippetCount: snippets,
                                      lastConnected: last.map { (label: $0.0, at: $0.1) }, now: now)
        }
        let unreadable = words(readable: false)
        check(unreadable.isDimmed && unreadable.ring == nil, "Connections: an unreadable hosts file is not dimmed and ringless", &ok)
        let empty = words(hosts: 0, keys: 0)
        check(empty.headline == "No saved hosts yet." && empty.ring == nil,
              "Connections: no hosts reads \"\(empty.headline)\" with ring \(String(describing: empty.ring))", &ok)
        let idle = words(last: ("grafana", now.addingTimeInterval(-3 * 3600)))
        check(idle.headline == "No live session." && idle.body.hasPrefix("Last connected to grafana 3 hours ago."),
              "Connections: no live session reads \"\(idle.headline)\" / \"\(idle.body)\"", &ok)
        check(idle.ring?.online == 0 && idle.ring?.total == 7, "Connections: the idle ring is \(String(describing: idle.ring))", &ok)
        let one = words(live: [.init(label: "bastion-stg", startedAt: now.addingTimeInterval(-42 * 60))])
        check(one.headline == "1 live session, on bastion-stg."
                && one.body == "Open for 42 minutes. 2 keys ready with Touch ID.",
              "Connections: one live session reads \"\(one.headline)\" / \"\(one.body)\"", &ok)
        check(one.ringCaption == "hosts online\n7 saved \u{00B7} 3 snippets", "Connections: the ring caption reads \(one.ringCaption)", &ok)
        let three = words(live: ["a", "b", "c"].map { .init(label: $0, startedAt: now) }, keys: 1, biometry: false)
        check(three.headline == "3 live sessions." && three.body == "a, b and 1 more. 1 key in the Keychain.",
              "Connections: three live sessions read \"\(three.headline)\" / \"\(three.body)\"", &ok)
        check(ConnectionsHeroWords.duration(since: now.addingTimeInterval(-7300), now: now) == "2 hours",
              "Connections: a two-hour session reads \(ConnectionsHeroWords.duration(since: now.addingTimeInterval(-7300), now: now))", &ok)
    }

    // MARK: Keys

    private static func checkKeysWords(_ ok: inout Bool) {
        typealias Key = KeysHeroWords.Key
        func words(readable: Bool = true, keys: [Key], hostsWithAKey: Int = 6, biometry: Bool = true) -> KeysHeroWords {
            KeysHeroWords.make(keysReadable: readable, keys: keys, hostsWithAKey: hostsWithAKey,
                               biometryAvailable: biometry, now: now)
        }
        let ops = Key(label: "ops-ed25519", hostCount: 5, lastUsedAt: now.addingTimeInterval(-3 * 3600))
        let ci = Key(label: "ci-deploy", hostCount: 1, lastUsedAt: nil)
        let spare = Key(label: "spare-rsa", hostCount: 0, lastUsedAt: nil)
        let unreadable = words(readable: false, keys: [ops])
        check(unreadable.isDimmed && unreadable.ring == nil && unreadable.headline == "Saved keys could not be read.",
              "Keys: an unreadable keys file reads \"\(unreadable.headline)\", dimmed \(unreadable.isDimmed) (GL-14)", &ok)
        let empty = words(keys: [])
        check(empty.headline == "No saved keys yet." && empty.ring == nil && !empty.isDimmed,
              "Keys: no keys reads \"\(empty.headline)\" with ring \(String(describing: empty.ring))", &ok)
        let ready = words(keys: [ops, ci])
        check(ready.headline == "Touch ID ready, 2 keys." && ready.body == "ops-ed25519 was used 3 hours ago.",
              "Keys: two keys read \"\(ready.headline)\" / \"\(ready.body)\"", &ok)
        check(ready.ring?.inUse == 2 && ready.ring?.total == 2 && ready.ringCaption == "keys in use\n6 hosts sign in with one",
              "Keys: the ring is \(String(describing: ready.ring)), captioned \(ready.ringCaption)", &ok)
        let noBiometry = words(keys: [ci, spare], hostsWithAKey: 1, biometry: false)
        check(noBiometry.headline == "2 keys in the Keychain."
                && noBiometry.body == "No host has connected with a key yet. 1 key is not used by any host.",
              "Keys: no biometry reads \"\(noBiometry.headline)\" / \"\(noBiometry.body)\"", &ok)
        check(noBiometry.ring?.inUse == 1 && noBiometry.ringCaption.hasSuffix("1 host signs in with one"),
              "Keys: one key in use reads \(String(describing: noBiometry.ring)) / \(noBiometry.ringCaption)", &ok)
        let lone = words(keys: [spare], hostsWithAKey: 0, biometry: false)
        check(lone.headline == "1 key in the Keychain." && lone.body.hasSuffix(" No host uses it yet."),
              "Keys: one unused key reads \"\(lone.headline)\" / \"\(lone.body)\"", &ok)
    }

    // MARK: The palette

    private static func checkTheColumnPaletteClearsTheFloor(_ ok: inout Bool) {
        var seen = Set<String>()
        let themes = (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
        check(themes.count >= 26, "fixture: only \(themes.count) themes - the sweep is not every palette", &ok)
        let quiet = Double(HelmHeroColumn.quietInkAlpha)
        let shades = [Double(HelmButton.heroFillAlpha), Double(HelmButton.heroFillAlpha) + 0.12,
                      Double(HelmSearchField.heroFillAlpha)]
        // The plain rule is what the column could not use: it stops at the
        // floor, so some palette's quiet ink must fail on it, or this sweep
        // proves nothing about the deeper one.
        var plainFails = 0
        var fallbacks: [String] = []
        for theme in themes {
            var tones: [(String, HelmModuleCard.HeroTone)] = [("accent", .init(colour: .themeAccent)),
                                                             ("accent dimmed", .init(colour: .themeAccent, isDimmed: true))]
            let red = HelmContrast.components(HelmTheme.nsColor(HelmTint.critical.hex(in: theme)))
            tones.append(("red", .init(colour: .fixed(red: red.0, green: red.1, blue: red.2))))
            for preset in HomeCardColorPreset.allCases {
                let rgb = HelmContrast.components(HelmTheme.nsColor(preset.hex))
                tones.append((preset.rawValue, .init(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))))
            }
            for (name, tone) in tones {
                let palette = HelmHeroColumn.palette(for: tone, in: theme)
                let tag = "\(theme.id) \(name)"
                let ink = palette.ink
                let lighter = palette.lighterStop
                let darker = palette.start == lighter ? palette.end : palette.start
                // The stop the ink is weakest against.
                let weakest = HelmContrast.ratio(ink, lighter) < HelmContrast.ratio(ink, darker) ? lighter : darker
                let bare = HelmContrast.ratio(ink, weakest)
                let shade = HelmContrast.components(HelmButton.heroShade(for: HelmContrast.color(ink)))
                let onPills = shades.map { HelmContrast.ratio(ink, HelmContrast.mix(shade, weakest, $0)) }
                check(bare >= HelmContrast.textTarget && onPills.allSatisfy { $0 >= HelmContrast.textTarget },
                      "\(tag): the ink measures \(ratio(bare)) bare and \(onPills.map(ratio)) on a pill or the field", &ok)
                if ink == (1, 1, 1) {
                    let quietInk = HelmContrast.ratio(HelmContrast.mix(ink, lighter, quiet), lighter)
                    if quietInk < HelmContrast.textTarget { fallbacks.append("\(tag) \(ratio(quietInk))") }
                }
                let plain = tone.palette(in: theme)
                if plain.ink == (1, 1, 1),
                   HelmContrast.ratio(HelmContrast.mix(plain.ink, plain.lighterStop, quiet), plain.lighterStop) < HelmContrast.textTarget {
                    plainFails += 1
                }
            }
        }
        check(fallbacks.isEmpty, "a second line in 80% ink misses the floor on \(fallbacks)", &ok)
        check(plainFails > 0, "fixture: the plain palette clears 80% ink everywhere - the deeper rule is untested", &ok)
    }

    // MARK: Kit options

    private static func checkTheGridColumnCap(_ ok: inout Bool) {
        let capped = HelmCardGrid(cardHeight: HelmCardGrid.roomyCardHeight,
                                  minimumCardWidth: HelmCardGrid.roomyMinimumCardWidth, maximumColumns: 2)
        let free = HelmCardGrid(cardHeight: HelmCardGrid.roomyCardHeight, minimumCardWidth: HelmCardGrid.roomyMinimumCardWidth)
        let wide: CGFloat = 1200
        check(free.plan(width: wide).columns > 2, "fixture: \(wide)pt fits only \(free.plan(width: wide).columns) cards", &ok)
        let plan = capped.plan(width: wide)
        check(plan.columns == 2 && abs(plan.cardWidth - (wide - HelmCardGrid.spacing) / 2) < 0.5,
              "C-4: a capped grid plans \(plan) at \(wide)pt", &ok)
        check(capped.plan(width: 400).columns == 1, "C-1: a 400pt column does not drop to one card", &ok)
        check(abs(capped.cardHeight - HelmType.scaledRowHeight(98)) < 0.5, "C-1: the roomy card is \(capped.cardHeight)pt", &ok)
        check(HelmCardGrid().minimumCardWidth == HelmCardGrid.minimumCardWidth, "the default grid's card width moved", &ok)
    }

    private static func checkTheFloorWidth(_ ok: inout Bool) {
        let fixed = NSView()
        fixed.translatesAutoresizingMaskIntoConstraints = false
        fixed.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let flexible = NSView()
        flexible.translatesAutoresizingMaskIntoConstraints = false
        let preference = flexible.widthAnchor.constraint(equalToConstant: 400)
        preference.priority = NSLayoutConstraint.Priority(251)
        preference.isActive = true
        let row = NSStackView(views: [fixed, flexible])
        row.spacing = 8
        let fitting = row.fittingSize.width
        let floor = HelmSplitPage.floorWidth(of: row)
        check(fitting > 500, "fixture: the row's fitting width (\(fitting)) ignores its preference", &ok)
        check(abs(floor - 128) < 1, "HelmSplitPage.floorWidth reads \(floor), want the required 128", &ok)
        check(row.constraints.allSatisfy { !($0.firstItem === row && $0.firstAttribute == .width) },
              "HelmSplitPage.floorWidth left its probe on the view", &ok)
    }

    private static func checkTheColumnInksItsControls(_ ok: inout Bool) {
        let column = HelmHeroColumn()
        let pill = HelmButton(title: "Retry", variant: .secondary, size: .small)
        let field = HelmSearchField(placeholder: "user@host", symbol: "bolt.fill")
        let rows = (0..<3).map { HelmHeroRow(leading: .figure("\($0)", quiet: $0 == 0), title: "Row \($0)", subtitle: "detail") }
        column.configure(header: .init(symbol: "server.rack", kicker: "Connections", headline: "Headline", body: "Body",
                                       ring: .init(fraction: 0.5, label: "1/2", caption: "online", spoken: "1 of 2", state: .ok)),
                         sections: [.init(title: "Rows", trailing: "3", views: rows),
                                    .init(title: "Field", trailing: nil, views: [field])],
                         foot: [pill], tone: .init(colour: .themeAccent))
        let ink = column.ink
        check(pill.heroInk == ink && field.heroInk == ink, "the column did not hand its ink to the pill and the field", &ok)
        check(rows.map(\.showsTopRule) == [false, true, true], "a section's rules are \(rows.map(\.showsTopRule))", &ok)
        check(rows.allSatisfy { $0.titleLabel.textColor == ink }, "a row's title is not in the ink", &ok)
        check(pill.superview != nil && column.debugScroll.isHidden == false, "the column layout did not hold its foot", &ok)
        column.setArrangement(.band)
        check(column.arrangement == .band && column.debugScroll.isHidden && pill.superview != nil,
              "the band dropped its foot or kept the scrolling column", &ok)
        check(rows.allSatisfy { $0.superview == nil }, "the band still draws its sections", &ok)
        column.setArrangement(.column)
        check(rows.allSatisfy { $0.superview != nil }, "back in a column the sections did not return", &ok)
        // A pill's own recipe: the ink's wash, never the theme's surface.
        let palette = HelmButton.heroPalette(ink: .white, enabled: true)
        check(palette.label == .white && abs(palette.fill.alphaComponent - HelmButton.heroFillAlpha) < 0.001
                && HelmButton.heroShade(for: .white) == .black,
              "the ghost pill's colours are \(palette)", &ok)
    }

    // MARK: CR-1 - the Crew band

    /// A fixed clock for the words: the board's 11:24 AM read and 11:02 AM
    /// last good read, formatted by a pinned formatter so the words are the
    /// same on every runner.
    private static let crewNow = Date(timeIntervalSince1970: 1_795_000_000)
    private static func crewTime(_ date: Date) -> String {
        date == crewNow ? "11:24 AM" : date == crewNow.addingTimeInterval(-22 * 60) ? "11:02 AM" : "?"
    }

    private static func checkCrewNeedsYouWords(_ ok: inout Bool) {
        typealias Reading = CrewHeroWords.NeedsYouReading
        let earlier = crewNow.addingTimeInterval(-22 * 60)
        let good = Reading(hasRead: true, homeOk: true, readFailed: false, checkedAt: crewNow, readAt: crewNow,
                           waiting: 2, openDecisions: 3, needDecision: 1, blocked: 1)
        let typical = CrewHeroWords.needsYou(good, time: crewTime)
        check(typical.kicker == "Needs you \u{00B7} checked 11:24 AM" && typical.headline == "2 tasks are waiting on you"
                && typical.body == "3 open decisions \u{00B7} 1 waiting on a decision \u{00B7} 1 blocked. The crew is holding for you."
                && typical.tone == .accent && typical.symbol == CrewHeroWords.crewSymbol && !typical.offersSetup,
              "CR-1: Needs you's typical band is \(typical)", &ok)
        check(typical.figures.map(\.caption) == ["Open decisions", "Need a decision", "Blocked"]
                && typical.figures.map(\.value) == ["3", "1", "1"] && typical.figures.allSatisfy { !$0.opensReview },
              "CR-1: Needs you's figures are \(typical.figures)", &ok)
        var one = good
        one.waiting = 1
        one.openDecisions = 1
        one.blocked = 0
        let single = CrewHeroWords.needsYou(one, time: crewTime)
        check(single.headline == "1 task is waiting on you"
                && single.body == "1 open decision \u{00B7} 1 waiting on a decision. The crew is holding for you.",
              "CR-1: one task reads \(single.headline) / \(single.body ?? "-")", &ok)
        var carried = good
        carried.carried = 1
        carried.carriedSince = earlier
        check(CrewHeroWords.needsYou(carried, time: crewTime).body?.hasSuffix(
                " One of them could not be read just now, so it shows as read at 11:02 AM.") == true,
              "CR-1: a carried task is not said", &ok)
        carried.carried = 2
        check(CrewHeroWords.needsYou(carried, time: crewTime).body?.hasSuffix(
                " 2 of them could not be read just now, so they show as read at 11:02 AM.") == true,
              "CR-1: two carried tasks are not said", &ok)

        var empty = good
        empty.waiting = 0
        empty.openDecisions = 0
        empty.needDecision = 0
        empty.blocked = 0
        let calm = CrewHeroWords.needsYou(empty, time: crewTime)
        check(calm.headline == "Nothing needs you" && calm.body == "No crewmate is waiting on a decision, and none is blocked."
                && calm.symbol == CrewHeroWords.calmSymbol && calm.figures.isEmpty && calm.tone == .accent,
              "CR-1: Needs you's empty band is \(calm)", &ok)

        // GL-14: a read that failed is dimmed, says when, and keeps the
        // carried rows' counts - never "nothing needs you".
        var failed = good
        failed.readFailed = true
        failed.readAt = earlier
        let stale = CrewHeroWords.needsYou(failed, time: crewTime)
        check(stale.tone == .dimmed && stale.headline == "Couldn\u{2019}t read the crew\u{2019}s state at 11:24 AM"
                && stale.kicker == "Needs you \u{00B7} last read 11:02 AM"
                && stale.body == "Showing what was read at 11:02 AM: 2 tasks are waiting on you, with 3 open decisions."
                && stale.figures.map(\.value) == ["3", "1", "1"],
              "CR-1: Needs you's failed band is \(stale)", &ok)
        var failedEmpty = empty
        failedEmpty.readFailed = true
        failedEmpty.readAt = earlier
        let staleEmpty = CrewHeroWords.needsYou(failedEmpty, time: crewTime)
        check(staleEmpty.tone == .dimmed && staleEmpty.headline != calm.headline && staleEmpty.figures.isEmpty
                && staleEmpty.body == "Nothing was waiting on you when it was last read, at 11:02 AM.",
              "CR-1: a failed read after an empty one is \(staleEmpty)", &ok)
        var neverRead = failed
        neverRead.readAt = nil
        let blind = CrewHeroWords.needsYou(neverRead, time: crewTime)
        check(blind.tone == .dimmed && blind.body == nil && blind.figures.isEmpty && blind.kicker == "Needs you",
              "CR-1: a first read that failed is \(blind)", &ok)

        var first = good
        first.hasRead = false
        let reading = CrewHeroWords.needsYou(first, time: crewTime)
        check(reading.headline == CrewHeroWords.readingHeadline && reading.figures.isEmpty
                && reading.body == "Nothing is shown until the first read lands." && reading.tone == .accent,
              "CR-1: Needs you before its first read is \(reading)", &ok)
        var home = good
        home.homeOk = false
        let setup = CrewHeroWords.needsYou(home, time: crewTime)
        check(setup.offersSetup && setup.headline == "Grand Line isn\u{2019}t pointed at a firstmate home yet"
                && setup.body == "So the crew\u{2019}s state cannot be read. Checked at 11:24 AM." && setup.figures.isEmpty,
              "CR-1: Needs you without a home is \(setup)", &ok)
    }

    private static func checkCrewInFlightWords(_ ok: inout Bool) {
        let read = CrewHeroWords.InFlightReading(
            hasRead: true, homeOk: true, verdictHeadline: "2 tasks need your call",
            verdictBody: "1 decision waiting \u{00B7} 1 blocked - the crew is holding for you.",
            working: 3, queued: 2, doneToday: 4, projects: 6, ready: .count(2), watcher: "healthy")
        let band = CrewHeroWords.inFlight(read, day: "Tue 24 Nov", time: crewTime)
        check(band.kicker == "In flight \u{00B7} Tue 24 Nov" && band.headline == read.verdictHeadline
                && band.body == read.verdictBody && band.tone == .accent && !band.offersSetup,
              "CR-1: In flight's band is \(band)", &ok)
        check(band.figures.map(\.caption) == ["Working", "Ready to merge", "Queued", "Done today", "Projects", "Watcher healthy"]
                && band.figures.map(\.value) == ["3", "2", "2", "4", "6", "OK"]
                && band.figures.map(\.opensReview) == [false, true, false, false, false, false],
              "CR-1: In flight's figures are \(band.figures)", &ok)
        check(band.status == .init(text: "Watcher healthy", state: .good), "CR-1: the watcher pill is \(String(describing: band.status))", &ok)

        var scanning = read
        scanning.ready = .scanning
        let scan = CrewHeroWords.inFlight(scanning, day: "Tue 24 Nov", time: crewTime)
        check(scan.figures[1] == .init(value: nil, caption: "Scanning PRs", opensReview: true) && scan.tone == .accent,
              "CR-1: a scan in flight reads \(scan.figures[1]) (REL-25: never a zero)", &ok)
        var failed = read
        failed.ready = .failed
        failed.watcher = "stale"
        let partly = CrewHeroWords.inFlight(failed, day: "Tue 24 Nov", time: crewTime)
        check(partly.tone == .dimmed && partly.figures[1] == .init(value: nil, caption: "PRs unavailable", opensReview: true)
                && partly.figures[5] == .init(value: nil, caption: "Watcher stale")
                && partly.status == .init(text: "Watcher stale", state: .warn),
              "CR-1: a failed PR scan with a stale watcher reads \(partly)", &ok)
        // GL-14: a task list that could not be read is not "nothing needs
        // you" - the verdict would be about a list nobody read.
        var unread = read
        unread.tasksRead = false
        unread.checkedAt = crewNow
        let blind = CrewHeroWords.inFlight(unread, day: "Tue 24 Nov", time: crewTime)
        check(blind.tone == .dimmed && blind.headline == "Couldn\u{2019}t read the crew\u{2019}s state at 11:24 AM"
                && blind.figures[0] == .init(value: nil, caption: "Working") && blind.figures[1].value == "2",
              "CR-1: an unread task list reads \(blind)", &ok)
        check(CrewHeroWords.watcherStatus("off") == .init(text: "Watcher off", state: .idle)
                && CrewHeroWords.watcherStatus("") == .init(text: "Watcher off", state: .idle),
              "CR-1: a watcher that is off is not said so", &ok)

        var first = read
        first.hasRead = false
        let reading = CrewHeroWords.inFlight(first, day: "Tue 24 Nov", time: crewTime)
        check(reading.kicker == "In flight" && reading.headline == CrewHeroWords.readingHeadline
                && reading.body == "Loading fleet data\u{2026}" && reading.figures.isEmpty && reading.status == nil,
              "CR-1: In flight before its first read is \(reading)", &ok)
        var home = read
        home.homeOk = false
        let setup = CrewHeroWords.inFlight(home, day: "Tue 24 Nov", time: crewTime)
        check(setup.offersSetup && setup.figures.isEmpty && setup.status == nil && setup.headline == read.verdictHeadline,
              "CR-1: In flight without a home is \(setup)", &ok)
    }

    private static func checkTheBandsNewOptions(_ ok: inout Bool) {
        let theme = ThemeManager.shared.theme
        let column = HelmHeroColumn()
        let tiles = HelmHeroTileGrid()
        let tinted = HelmHeroTile(ringSide: nil)
        tinted.tint = .good
        tinted.configure(label: "Review", text: "2 PRs ready to merge")
        let plain = HelmHeroTile(ringSide: nil)
        plain.configure(label: "Note", text: "A quiet morning")
        tiles.tiles = [tinted, plain]
        let row = HelmHeroRow(leading: .symbol("sun.max"), title: "Morning briefing", subtitle: "Generated 6:58 AM",
                              trailing: HelmButton(title: "", variant: .secondary, size: .small, symbol: "xmark"))
        let strip = HelmKPIStrip(density: .inline)
        strip.configure([.init(.value("3"), caption: "Working"),
                         .init(.value("2"), caption: "Ready to merge", isAction: true, toolTip: "View in Review")],
                        theme: theme)
        let header = HelmHeroColumn.Header(symbol: "person.2.fill", kicker: "In flight", headline: "Headline",
                                           body: "Body", ring: nil, status: .init(text: "Watcher healthy", tint: .good))
        column.configure(header: header, sections: [], foot: [strip], tone: .init(colour: .themeAccent),
                         bandViews: [row, tiles], footRule: true)
        // A column draws none of the band's options.
        check(column.debugStatusPill == nil && column.debugFootRule == nil && row.superview == nil && tiles.superview == nil,
              "1.5.0: a `.column` drew the band's status pill, foot rule or band views", &ok)
        column.setArrangement(.band)
        let palette = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme)
        let ink = HelmContrast.color(palette.ink)
        check(column.debugStatusPill?.debugText == "Watcher healthy" && column.debugFootRule != nil
                && row.superview != nil && tiles.superview != nil,
              "1.5.0: the band dropped its status pill, foot rule or band views", &ok)
        check(strip.heroInk == ink && (row.trailing as? HelmButton)?.heroInk == ink,
              "1.5.0: the band did not hand its ink to the strip and the row's control", &ok)
        let good = HelmHeroSurface.signalColor(tintHex: HelmTint.good.hex(in: theme), on: palette)
        check(tinted.debugDotColor.map(HelmContrast.components).map { abs($0.0 - HelmContrast.components(good).0) < 0.01 } == true
                && plain.debugDotColor == nil && tinted.debugTextLabel.textColor == ink,
              "1.1.0: the grid painted dot \(String(describing: tinted.debugDotColor)) and \(String(describing: plain.debugDotColor))", &ok)
        let wash = HelmHeroCard.tileWash(for: palette)
        check(abs(tinted.normalColor.alphaComponent - CGFloat(wash.alpha)) < 0.001, "1.1.0: the tile's wash is not the card's", &ok)
        check(column.accessibilityLabel() == "In flight. Headline. Body" && column.accessibilityRole() == .group,
              "1.5.0: the band's group reads \(column.accessibilityLabel() ?? "-")", &ok)
        // Without the new options a band is what 1.4.0 drew.
        column.configure(header: .init(symbol: "x", kicker: "k", headline: "h", body: nil, ring: nil), sections: [],
                         foot: [], tone: .init(colour: .themeAccent))
        check(column.debugStatusPill == nil && column.debugFootRule == nil && tiles.superview == nil,
              "1.5.0: a band with no status or band views still drew them", &ok)

        // HelmKPIStrip 1.4.0: an inline action column.
        check(strip.debugActionCell(at: 1) != nil && strip.debugActionCell(at: 0) == nil
                && strip.debugCaptionIsUnderlined(at: 1) && !strip.debugCaptionIsUnderlined(at: 0),
              "1.4.0: the inline strip's action column is missing or the wrong one", &ok)
        if let cell = strip.debugActionCell(at: 1) {
            check(cell.isActivatable && cell.accessibilityLabel() == "Ready to merge, 2" && cell.toolTip == "View in Review"
                    && cell.hoverColor.alphaComponent > 0 && cell.normalColor.alphaComponent == 0,
                  "1.4.0: the action column reads \(cell.accessibilityLabel() ?? "-") with hover \(cell.hoverColor)", &ok)
            // A real click's path: the cell's own click recognizer, its
            // target and its action (NSApp is nil headless, so this sends it
            // the way `NSApp.sendAction` would).
            var pressed: Int?
            strip.onActivate = { pressed = $0 }
            let click = cell.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first
            if let click, let target = click.target as? NSObject, let action = click.action {
                _ = target.perform(action, with: click)
            }
            check(click != nil && pressed == 1, "1.4.0: pressing the action column reported \(String(describing: pressed))", &ok)
        }
        // 1.4.0's fix: a caption wider than its neighbours keeps its column's
        // trailing inset, so it never runs into the hairline after it.
        let packed = HelmKPIStrip(density: .inline)
        packed.configure([.init(.value("3"), caption: "Open decisions"), .init(.value("1"), caption: "Need a decision"),
                          .init(.value("1"), caption: "Blocked")], theme: theme)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        host.addSubview(packed)
        let hug = packed.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([packed.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     packed.topAnchor.constraint(equalTo: host.topAnchor), hug])
        host.layoutSubtreeIfNeeded()
        let insets = packed.debugCaptionLabels.map { label -> CGFloat in
            guard let column = label.superview else { return -1 }
            return column.bounds.width - label.frame.maxX
        }
        check(packed.debugCaptionLabels[1].intrinsicContentSize.width > packed.debugCaptionLabels[0].intrinsicContentSize.width,
              "fixture: \"Need a decision\" is not the widest caption", &ok)
        check(insets.allSatisfy { $0 >= HelmMetrics.s2 - 2.5 }, "1.4.0: a caption's trailing inset is \(insets)", &ok)
        let quiet = HelmKPIStrip(density: .inline)
        quiet.configure([.init(.value("3"), caption: "Working")], theme: theme)
        check(quiet.debugActionCell(at: 0) == nil && !quiet.debugCaptionIsUnderlined(at: 0),
              "1.4.0: a strip with no action item changed", &ok)
    }

    /// The real page: a `FleetController` in the sidebar layout, headless.
    private static func checkTheCrewBandOnTheRealPage(_ ok: inout Bool) {
        let saved = FleetActions.stateDirectoryOverrideForTests
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("crew-band-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer {
            FleetActions.stateDirectoryOverrideForTests = saved
            try? FileManager.default.removeItem(at: state)
        }
        FleetActions.stateDirectoryOverrideForTests = state
        try? "needs-decision [at=1791950800] [key=pick]: Which one?\n"
            .write(to: state.appendingPathComponent("crew-d.status"), atomically: true, encoding: .utf8)

        let fleet = FleetController(shiftStore: ShiftStore())
        _ = fleet.view
        fleet.adoptSidebarLayout()
        // Before the first read: the band says it is reading, with no figures.
        guard let first = fleet.debugCrewBand else {
            fail("CR-1: In flight has no band before its first read", &ok)
            return
        }
        check(first.debugHeadline == CrewHeroWords.readingHeadline && first.debugBody == "Loading fleet data\u{2026}"
                && first.debugFootViews.isEmpty && first.debugStatusPill == nil,
              "CR-1: In flight's first read reads \(first.debugHeadline) / \(first.debugBody ?? "-")", &ok)
        fleet.selectModuleTab(named: "Needs you")
        check(fleet.debugCrewBand?.debugHeadline == CrewHeroWords.readingHeadline && fleet.debugNeedsYouSkeletonShowing,
              "CR-1: Needs you's first read reads \(fleet.debugCrewBand?.debugHeadline ?? "-") without its skeleton", &ok)

        func task(_ id: String, _ status: String) -> FleetTask {
            var task = FleetTask(id: id, repo: "grand-line", kind: "ship", pr: nil)
            task.status = status
            task.state = status == "working" ? "working" : "parked"
            return task
        }
        let tasks = [task("crew-a", "working"), task("crew-d", "needs_decision"), task("crew-e", "blocked")]
        func snapshot(_ tasks: [FleetTask], read: Bool = true) -> FleetSnapshot {
            FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 1, doneCount: 0,
                          projectsCount: 2, watcher: WatcherHealth(status: "healthy"), tasksRead: read)
        }
        fleet.debugRender(snapshot: snapshot(tasks), mergedPRs: [])
        guard let needs = fleet.debugCrewBand else {
            fail("CR-1: Needs you lost its band after a read", &ok)
            return
        }
        check(needs.debugHeadline == "2 tasks are waiting on you"
                && needs.debugBody == "1 open decision \u{00B7} 1 waiting on a decision \u{00B7} 1 blocked. The crew is holding for you."
                && !fleet.debugNeedsYouSkeletonShowing && fleet.debugNeedsRowCount == 2,
              "CR-1: Needs you after a read reads \(needs.debugHeadline) / \(needs.debugBody ?? "-") over \(fleet.debugNeedsRowCount) rows", &ok)
        let theme = ThemeManager.shared.theme
        check(needs.debugPalette == HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme),
              "CR-1: a good read is not on the accent tone", &ok)
        // GL-14: the next read fails - dimmed, with the rows carried.
        fleet.debugRender(snapshot: snapshot([], read: false), mergedPRs: [])
        let dimmed = HelmHeroColumn.palette(for: .init(colour: .themeAccent, isDimmed: true), in: theme)
        check(dimmed != HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme),
              "fixture: the dimmed tone is the accent's own palette", &ok)
        check(fleet.debugCrewBand?.debugPalette == dimmed && fleet.debugNeedsRowCount == 2
                && (fleet.debugCrewBand?.debugHeadline ?? "").hasPrefix("Couldn\u{2019}t read the crew\u{2019}s state at "),
              "CR-1: a failed read drew \(fleet.debugCrewBand?.debugHeadline ?? "-") over \(fleet.debugNeedsRowCount) rows, "
                + "dimmed \(fleet.debugCrewBand?.debugPalette == dimmed)", &ok)
        // The band's time is the page's own clock, as the summary's was.
        let stamp = FleetController.needsYouTimeFormatter.string(from: Date())
        let head = fleet.debugCrewBand?.debugHeadline ?? ""
        check(head.contains(stamp) || head.contains(FleetController.needsYouTimeFormatter.string(from: Date().addingTimeInterval(-60))),
              "CR-1: the failed read's time is not the read's own (\(head), now \(stamp))", &ok)
        // In flight on the same page: the failed read is not "nothing needs
        // you" there either, and a good one is the fleet's verdict.
        fleet.selectModuleTab(named: "In flight")
        check(fleet.debugCrewBand?.debugPalette == dimmed
                && (fleet.debugCrewBand?.debugHeadline ?? "").hasPrefix("Couldn\u{2019}t read the crew\u{2019}s state"),
              "CR-1: In flight over a failed read reads \(fleet.debugCrewBand?.debugHeadline ?? "-")", &ok)
        fleet.debugRender(snapshot: snapshot(tasks), mergedPRs: [])
        check(fleet.debugCrewBand?.debugHeadline == "2 tasks need your call" && fleet.debugCrewBand?.debugStatusPill != nil,
              "CR-1: In flight on a real page reads \(fleet.debugCrewBand?.debugHeadline ?? "-")", &ok)
        fleet.selectModuleTab(named: "Log")
        check(fleet.debugCrewBand == nil && !fleet.collapsesEmptyHeaderLine && fleet.drawsSubtitleOnHeaderLine,
              "CR-1: Log drew the band or gave up its header line before its own band", &ok)
        fleet.selectModuleTab(named: "In flight")
        check(fleet.collapsesEmptyHeaderLine && !fleet.drawsSubtitleOnHeaderLine,
              "CR-1: In flight keeps its header line over the band", &ok)
    }

    private static func composite(_ color: NSColor, over ground: (Double, Double, Double)) -> (Double, Double, Double) {
        let alpha = Double((color.usingColorSpace(.sRGB) ?? color).alphaComponent)
        return HelmContrast.mix(HelmContrast.components(color), ground, alpha)
    }

    /// Every word the band paints, on every palette: the headline and the 80%
    /// second line on the weaker stop, the pill's and the tiles' words on
    /// their washes, the figures' captions in the ink, and the pill's dot at
    /// the non-text floor on both stops - in the accent tone and the dimmed one.
    private static func checkTheCrewBandClearsTheFloorOnEveryPalette(_ ok: inout Bool) {
        var seen = Set<String>()
        let themes = (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
        check(themes.count >= 26, "fixture: only \(themes.count) themes", &ok)
        let column = HelmHeroColumn()
        column.setArrangement(.band)
        let grid = HelmHeroTileGrid()
        let tile = HelmHeroTile(ringSide: nil)
        tile.tint = .warn
        tile.configure(label: "Tasks", text: "3 tasks due or overdue")
        grid.tiles = [tile]
        let strip = HelmKPIStrip(density: .inline)
        strip.configure([.init(.value("2"), caption: "Ready to merge", isAction: true), .init(.unread, caption: "Watcher stale")])
        var failures: [String] = []
        var worst = Double.infinity
        for theme in themes {
            for dimmed in [false, true] {
                let tone = HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: dimmed)
                column.configure(header: .init(symbol: CrewHeroWords.crewSymbol, kicker: "In flight", headline: "2 tasks need your call",
                                               body: "1 decision waiting", ring: nil, status: .init(text: "Watcher stale", tint: .warn)),
                                 sections: [], foot: [strip], tone: tone, bandViews: [grid], footRule: true)
                column.applyTheme(theme)
                guard let palette = column.debugPalette, let pill = column.debugStatusPill else {
                    failures.append("\(theme.id): the band is unpainted")
                    continue
                }
                let tag = "\(theme.id)\(dimmed ? " dimmed" : "")"
                let lighter = palette.lighterStop
                let darker = palette.start == lighter ? palette.end : palette.start
                func floor(_ name: String, _ color: NSColor?, on ground: (Double, Double, Double), _ target: Double) {
                    guard let color else { failures.append("\(tag): \(name) has no colour"); return }
                    let measured = HelmContrast.ratio(composite(color, over: ground), ground)
                    if target == HelmContrast.textTarget { worst = min(worst, measured) }
                    if measured < target { failures.append("\(tag): \(name) \(ratio(measured))") }
                }
                for stop in [lighter, darker] {
                    floor("headline", column.debugHeadlineLabel.textColor, on: stop, HelmContrast.textTarget)
                    floor("body", column.debugBodyLabel.textColor, on: stop, HelmContrast.textTarget)
                    let pillGround = composite(NSColor(cgColor: pill.layer?.backgroundColor ?? .clear) ?? .clear, over: stop)
                    floor("pill words", pill.debugLabel.textColor, on: pillGround, HelmContrast.textTarget)
                    floor("pill dot", pill.debugDotColor, on: stop, HelmContrast.nonTextTarget)
                    let tileGround = composite(tile.normalColor, over: stop)
                    floor("tile words", tile.debugTextLabel.textColor, on: tileGround, HelmContrast.textTarget)
                    floor("tile dot", tile.debugDotColor, on: stop, HelmContrast.nonTextTarget)
                    for (index, label) in strip.debugCaptionLabels.enumerated() {
                        floor("caption \(index)", label.textColor, on: stop, HelmContrast.textTarget)
                    }
                    // A dash is a 19pt figure: the large-text floor.
                    floor("unknown figure", strip.debugValueColors.last ?? nil, on: stop, HelmContrast.nonTextTarget)
                }
            }
        }
        check(failures.isEmpty, "CR-1: the band misses its floor on \(failures.prefix(12))", &ok)
        print("  CR-1 band: weakest text \(ratio(worst)):1 over \(themes.count) palettes, accent and dimmed")
    }
}

#endif
