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
//   - CR-1 on Crew › Log: `CrewHeroWords.log` in every state (first read,
//     typical, one event, quiet since yesterday or longer, empty, a log file
//     or a month of Shift's activity that could not be read, and both), the
//     filter's segments and which counts are unknown, and a real
//     `FleetController` on scratch stores reading a real log, filtering it,
//     and going dimmed over a month of activity it could not read. The
//     floating bar's Log keeps its filter in the list's column with no
//     counts. The filter's chosen and unchosen words clear the floor on
//     every palette, on both tones.
//   - CR-1 on Crew › Review: `CrewHeroWords.review` in every state (first
//     read, typical, busy, empty, a scan that reached nothing, a partial one
//     with its pull requests kept), a real `ReviewController` in the sidebar
//     layout drawing them with its ring, its dimmed failed read and Show
//     folder path, and the same page in the floating bar drawing no band. The
//     ring's arc and label clear their floors on every palette too.
//   - RP-2 Question head (the same board): `ReplyHeroWords` for a decision,
//     several, a block and a task with none on record, with the whole note
//     kept. The `FleetReplyCard` head's painted words, glyph and × clear
//     their floors on every palette in both tones. A real `FleetController`
//     in the sidebar layout turns the row into the card and keeps what was
//     typed across a refresh, while the floating bar keeps its composer.
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
            checkSnippetsWords,
            checkTheColumnPaletteClearsTheFloor,
            checkTheGridColumnCap,
            checkTheFloorWidth,
            checkTheColumnInksItsControls,
            checkCrewNeedsYouWords,
            checkCrewInFlightWords,
            checkTheBandsNewOptions,
            checkTheCrewBandOnTheRealPage,
            checkCrewReviewWords,
            checkTheReviewBandOnTheRealPage,
            checkCrewLogWords,
            checkTheLogBandOnTheRealPage,
            checkTheCrewBandClearsTheFloorOnEveryPalette,
            checkReplyHeadWords,
            checkTheReplyHeadClearsTheFloorOnEveryPalette,
            checkTheReplyCardOnTheRealPage,
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

    /// UI-10 of full review 4: the Snippets tab's column speaks for
    /// snippets, never for hosts, and says the switch's state in the strip's
    /// own words.
    private static func checkSnippetsWords(_ ok: inout Bool) {
        func snippet(_ label: String, _ trigger: String, _ scope: SnippetScope) -> Snippet {
            var snippet = Snippet(label: label, command: "echo \(label)")
            snippet.trigger = trigger
            snippet.scope = scope
            return snippet
        }
        let three = [snippet("Warm up sudo", "", .consoleOnly), snippet("Tail nginx errors", "nginxerr", .consoleOnly),
                     snippet("Disk usage by folder", "duh", .systemWide)]
        let words = SnippetsHeroWords.make(snippetsReadable: true, snippets: three, enabled: false, trusted: false,
                                           armed: false)
        check(words.headline == "3 snippets, 1 expands everywhere.", "UI-10: the headline reads \(words.headline)", &ok)
        check(words.body == "Type a trigger such as ;duh in any app.", "UI-10: the body reads \(words.body)", &ok)
        check(words.status == "Turned off" && !words.statusOK, "UI-10: an off switch reads \(words.status)", &ok)
        for text in [words.headline, words.body] {
            check(!text.lowercased().contains("host"), "UI-10: the Snippets column talks about hosts: \(text)", &ok)
        }
        let armed = SnippetsHeroWords.make(snippetsReadable: true, snippets: three, enabled: true, trusted: true,
                                           armed: true)
        check(armed.status == "Granted \u{00b7} 2 triggers armed" && armed.statusOK,
              "UI-10: an armed switch reads \(armed.status)", &ok)
        check(SnippetsHeroWords.listed(three, limit: 3).map(\.label) == ["Disk usage by folder", "Tail nginx errors"],
              "UI-10: the column lists \(SnippetsHeroWords.listed(three, limit: 3).map(\.label))", &ok)
        let consoleOnly = SnippetsHeroWords.make(snippetsReadable: true, snippets: Array(three.prefix(2)),
                                                 enabled: true, trusted: true, armed: true)
        check(consoleOnly.headline == "2 snippets, 1 with a trigger."
                && consoleOnly.body == "Type a trigger such as ;nginxerr in the Console.",
              "UI-10: Console-only triggers read \(consoleOnly.headline) / \(consoleOnly.body)", &ok)
        let none = SnippetsHeroWords.make(snippetsReadable: true, snippets: [], enabled: false, trusted: true, armed: false)
        check(none.headline == "No snippets yet." && !none.isDimmed, "UI-10: no snippets reads \(none.headline)", &ok)
        let unreadable = SnippetsHeroWords.make(snippetsReadable: false, snippets: [], enabled: false, trusted: true,
                                                armed: false)
        check(unreadable.isDimmed && unreadable.headline != none.headline,
              "UI-10: an unreadable file reads like an empty one (GL-14)", &ok)
    }

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
        // UX-06: the door follows the decision, not the words.
        check(!band.opensNeedsYou, "UX-06: In flight offers Open Needs you with nothing waiting on the captain", &ok)
        var deciding = read
        deciding.needingCaptain = 2
        check(CrewHeroWords.inFlight(deciding, day: "Tue 24 Nov", time: crewTime).opensNeedsYou,
              "UX-06: In flight's headline is about two decisions and offers no Open Needs you", &ok)
        var blindDeciding = deciding
        blindDeciding.tasksRead = false
        check(!CrewHeroWords.inFlight(blindDeciding, day: "Tue 24 Nov", time: crewTime).opensNeedsYou,
              "UX-06: an unread task list still offers Open Needs you", &ok)

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
        check(fleet.debugCrewBand?.debugKicker.hasPrefix("Log") == true && fleet.collapsesEmptyHeaderLine
                && !fleet.drawsSubtitleOnHeaderLine,
              "CR-1: Log drew no band of its own or kept its header line", &ok)
        fleet.selectModuleTab(named: "In flight")
        check(fleet.collapsesEmptyHeaderLine && !fleet.drawsSubtitleOnHeaderLine,
              "CR-1: In flight keeps its header line over the band", &ok)
    }

    // MARK: CR-1 on Log

    /// A pinned clock for Log's words, in the board's format, so a time a
    /// fixture made reads the same on every runner.
    private static let logClock: (Date) -> String = { date in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// The board's log as a read at 11:24 AM local: five events today, three
    /// yesterday, two three days back. Local days, because "today" is the
    /// captain's (`FleetLogFeed.dayLabel` reads `Calendar.current`).
    private static func boardLog() -> (read: FleetLogFeed.Read, at: (Int, Int, Int) -> Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: crewNow)
        let at: (Int, Int, Int) -> Date = { day, hour, minute in
            calendar.date(byAdding: .minute, value: hour * 60 + minute,
                          to: calendar.date(byAdding: .day, value: day, to: today)!)!
        }
        let events = [FleetLogEvent(date: at(0, 10, 32), kind: .merge, title: "Merged PR #630"),
                      FleetLogEvent(date: at(0, 10, 5), kind: .task, title: "Completed a task"),
                      FleetLogEvent(date: at(0, 9, 41), kind: .investigation, title: "Saved investigation"),
                      FleetLogEvent(date: at(0, 9, 12), kind: .incident, title: "Ended incident INC-7"),
                      FleetLogEvent(date: at(0, 8, 34), kind: .incident, title: "Started incident INC-7"),
                      FleetLogEvent(date: at(-1, 18, 18), kind: .merge, title: "Merged PR #629"),
                      FleetLogEvent(date: at(-1, 16, 2), kind: .sync, title: "Shift sync conflict resolved"),
                      FleetLogEvent(date: at(-1, 14, 47), kind: .task, title: "Completed another"),
                      FleetLogEvent(date: at(-3, 11, 20), kind: .merge, title: "Merged PR #628"),
                      FleetLogEvent(date: at(-3, 9, 3), kind: .task, title: "Completed the weekly review")]
        return (FleetLogFeed.Read(events: events, readAt: at(0, 11, 24)), at)
    }

    /// CR-1 on Log: the board's words in every state the tab can be in.
    private static func checkCrewLogWords(_ ok: inout Bool) {
        typealias Reading = CrewHeroWords.LogReading
        let (board, at) = boardLog()
        let first = CrewHeroWords.log(Reading(), day: "Tue 24 Nov", time: logClock)
        check(first.kicker == "Log" && first.headline == "Reading the log\u{2026}" && first.body == nil
                && first.filter.isEmpty && first.figures.isEmpty && first.tone == .accent
                && first.symbol == CrewHeroWords.logSymbol,
              "CR-1: Log before its first read is \(first)", &ok)

        let typical = CrewHeroWords.log(Reading(board), day: "Tue 24 Nov", time: logClock)
        check(typical.kicker == "Log \u{00B7} Tue 24 Nov" && typical.headline == "5 events today"
                && typical.body == "1 merge \u{00B7} 1 task update \u{00B7} 1 investigation saved \u{00B7} 2 incident updates. "
                    + "Latest at 10:32 AM."
                && typical.tone == .accent && typical.symbol == CrewHeroWords.logSymbol && typical.figures.isEmpty
                && !typical.offersSetup && typical.status == nil && typical.ring == nil,
              "CR-1: Log's typical band is \(typical)", &ok)
        check(typical.filter.map(\.label) == ["All\u{2002}10", "Merges\u{2002}3", "Tasks\u{2002}3", "Sync\u{2002}1",
                                              "Investigations\u{2002}1", "Incidents\u{2002}2"]
                && typical.filter.map(\.kind) == [nil, .merge, .task, .sync, .investigation, .incident],
              "CR-1: Log's filter is \(typical.filter.map(\.label))", &ok)
        // The band's segments are the floating bar's, in its order.
        check(typical.filter.map(\.title) == FleetLogListView.filterItems.map(\.title)
                && typical.filter.map { $0.kind?.rawValue ?? FleetLogListView.allFilterID }
                    == FleetLogListView.filterItems.map(\.id),
              "CR-1: the band's segments are not the floating bar's", &ok)

        // Plurals, one at a time and two at a time.
        func read(_ events: [FleetLogEvent], log: Bool = false, activity: Bool = false) -> Reading {
            Reading(FleetLogFeed.Read(events: events, logUnreadable: log, activityUnreadable: activity,
                                      readAt: board.readAt))
        }
        let one = CrewHeroWords.log(read([FleetLogEvent(date: at(0, 9, 0), kind: .sync, title: "s")]),
                                    day: "Tue 24 Nov", time: logClock)
        check(one.headline == "1 event today" && one.body == "1 sync fix. Latest at 9:00 AM.",
              "CR-1: one event reads \(one.headline) / \(one.body ?? "-")", &ok)
        let pairs = [FleetLogEventKind.merge, .task, .investigation, .incident, .sync].flatMap { kind in
            [FleetLogEvent(date: at(0, 9, 0), kind: kind, title: "a"), FleetLogEvent(date: at(0, 8, 0), kind: kind, title: "b")]
        }
        let two = CrewHeroWords.log(read(pairs), day: "Tue 24 Nov", time: logClock)
        check(two.headline == "10 events today"
                && two.body == "2 merges \u{00B7} 2 task updates \u{00B7} 2 investigations saved \u{00B7} 2 incident updates "
                    + "\u{00B7} 2 sync fixes. Latest at 9:00 AM.",
              "CR-1: two of each read \(two.body ?? "-")", &ok)

        // Nothing today: when the last event was, said as the feed says the day.
        let quiet = CrewHeroWords.log(read(Array(board.events.dropFirst(5))), day: "Tue 24 Nov", time: logClock)
        check(quiet.headline == "Quiet so far today" && quiet.body == "The last event was yesterday at 6:18 PM."
                && quiet.tone == .accent && quiet.filter.first?.label == "All\u{2002}5",
              "CR-1: a quiet day reads \(quiet.headline) / \(quiet.body ?? "-")", &ok)
        let older = CrewHeroWords.log(read(Array(board.events.suffix(2))), day: "Tue 24 Nov", time: logClock)
        let label = FleetLogFeed.dayLabel(for: at(-3, 11, 20), reference: board.readAt)
        check(label != "Yesterday" && older.body == "The last event was on \(label) at 11:20 AM.",
              "CR-1: a quiet few days read \(older.body ?? "-")", &ok)

        let empty = CrewHeroWords.log(read([]), day: "Tue 24 Nov", time: logClock)
        check(empty.kicker == "Log" && empty.headline == "Nothing logged yet" && empty.body == CrewHeroWords.emptyLogBody
                && empty.symbol == CrewHeroWords.calmSymbol && empty.filter.isEmpty && empty.tone == .accent,
              "CR-1: Log's empty band is \(empty)", &ok)

        // GL-14: a log file that could not be read is not an empty log.
        let blind = CrewHeroWords.log(read([], log: true), day: "Tue 24 Nov", time: logClock)
        check(blind.tone == .dimmed && blind.headline == "Couldn\u{2019}t read the log at 11:24 AM"
                && blind.body == "Merges, sync fixes, investigations and incidents could not be read, so no count is shown."
                && blind.filter.isEmpty && blind.kicker == "Log \u{00B7} Tue 24 Nov" && blind.headline != empty.headline,
              "CR-1: an unreadable log file over nothing else is \(blind)", &ok)
        // The task updates Shift's activity holds are still read and counted.
        let tasks = board.events.filter { $0.kind == .task }
        let partly = CrewHeroWords.log(read(tasks, log: true), day: "Tue 24 Nov", time: logClock)
        check(partly.tone == .dimmed && partly.headline == "Couldn\u{2019}t read all of the log at 11:24 AM"
                && partly.body == "Showing the 3 events that could be read, 1 today. "
                    + "Merges, sync fixes, investigations and incidents could not be read, so they are not counted."
                && partly.filter.map(\.count) == [nil, nil, 3, nil, nil, nil]
                && partly.filter.map(\.label) == ["All", "Merges", "Tasks\u{2002}3", "Sync", "Investigations", "Incidents"],
              "CR-1: an unreadable log file over Shift's tasks is \(partly)", &ok)
        let noTasks = CrewHeroWords.log(read(board.events.filter { $0.kind != .task }, activity: true),
                                        day: "Tue 24 Nov", time: logClock)
        check(noTasks.tone == .dimmed && noTasks.headline == "Couldn\u{2019}t read all of the log at 11:24 AM"
                && (noTasks.body ?? "").hasSuffix("Some task updates could not be read, so they are not counted.")
                && noTasks.filter.map(\.count) == [nil, 3, nil, 1, 1, 2],
              "CR-1: a month of activity that could not be read is \(noTasks)", &ok)
        let both = CrewHeroWords.log(read([FleetLogEvent(date: at(-1, 9, 0), kind: .merge, title: "m")],
                                          log: true, activity: true), day: "Tue 24 Nov", time: logClock)
        check(both.body == "Showing the 1 event that could be read, none today. Merges, sync fixes, investigations, "
                + "incidents and some task updates could not be read, so they are not counted."
                && both.filter.allSatisfy { $0.count == nil },
              "CR-1: both halves unreadable read \(both.body ?? "-")", &ok)

        // The list's own empty state under a kind that could not be read.
        let partlyRead = read(tasks, log: true)
        let merges = CrewHeroWords.logListUnknown(partlyRead, kind: .merge, time: logClock)
        check(merges?.title == "Couldn\u{2019}t read the log"
                && merges?.body == "Merges could not be read at 11:24 AM, so none are shown."
                && CrewHeroWords.logListUnknown(partlyRead, kind: .task, time: logClock) == nil
                && CrewHeroWords.logListUnknown(partlyRead, kind: nil, time: logClock)?.body
                    == "The log could not be read at 11:24 AM, so none are shown."
                && CrewHeroWords.logListUnknown(Reading(board), kind: .merge, time: logClock) == nil
                && CrewHeroWords.logListUnknown(Reading(), kind: .merge, time: logClock) == nil,
              "CR-1: the list under an unknown kind says \(String(describing: merges))", &ok)
    }

    /// The real page: a `FleetController` on scratch stores, headless, in the
    /// sidebar layout and in the floating bar's.
    private static func checkTheLogBandOnTheRealPage(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("crew-log-band-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let shiftRoot = scratch.appendingPathComponent("shift", isDirectory: true)
        try? FileManager.default.createDirectory(at: shiftRoot, withIntermediateDirectories: true)
        let savedShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", shiftRoot.path, 1)
        defer {
            if let savedShift { setenv("FM_SHIFT_DIR", savedShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }
        let shift = ShiftStore()
        let task = ShiftTask(id: "task-log-1", title: "Rotate the staging certificate", description: "",
                             status: .todo, priority: .normal, dueDate: nil, dueTime: nil, projectID: nil,
                             tags: [], createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                             completedAt: nil, notes: nil, subtasks: [], hasAttachment: false)
        shift.addTask(task)
        shift.setTaskCompleted(id: task.id, completed: true)
        let log = FleetLogStore(directory: scratch.appendingPathComponent("log", isDirectory: true))
        log.append(FleetLogEvent(date: Date(), kind: .merge, title: "Merged PR #630"))
        let fixture = FleetLogFeed.read(store: log, shift: shift)
        check(fixture.events.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.merge, .task, .task]
                && Calendar.current.isDateInToday(fixture.events.last?.date ?? .distantPast),
              "fixture: the scratch log reads \(fixture.events.map(\.kind))", &ok)

        let fleet = FleetController(shiftStore: shift, logStore: log)
        _ = fleet.view
        fleet.selectModuleTab(named: "Log")
        guard let logBand = fleet.debugCrewBand else {
            fail("CR-1: Log opens on no band", &ok)
            return
        }
        let tabs = fleet.debugLogFilters
        func titles() -> [String] {
            tabs.debugPillsForAccessibilityTests().map { $0.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "" }
        }
        check(logBand.debugHeadline == "3 events today"
                && (logBand.debugBody ?? "").hasPrefix("1 merge \u{00B7} 2 task updates. Latest at ")
                && fleet.collapsesEmptyHeaderLine && !fleet.drawsSubtitleOnHeaderLine
                && logBand.debugFootViews.first === tabs && tabs.heroInk == logBand.ink,
              "CR-1: Log on a real page reads \(logBand.debugHeadline) / \(logBand.debugBody ?? "-")", &ok)
        check(titles() == ["All\u{2002}3", "Merges\u{2002}1", "Tasks\u{2002}2", "Sync\u{2002}0",
                           "Investigations\u{2002}0", "Incidents\u{2002}0"],
              "CR-1: the real filter reads \(titles())", &ok)
        // The filter on the band filters the feed under it, as it always did.
        check(fleet.debugLogList.debugRowCount == 4 && fleet.debugLogListShowing,
              "CR-1: the feed under the band has \(fleet.debugLogList.debugRowCount) rows", &ok)
        tabs.debugClickTab(id: "merge")
        check(fleet.debugLogList.debugRowCount == 2 && tabs.selected == "merge" && fleet.debugCrewBand === logBand
                && logBand.debugHeadline == "3 events today",
              "CR-1: Merges on the band left \(fleet.debugLogList.debugRowCount) rows", &ok)
        tabs.debugClickTab(id: "all")

        // GL-14: a month of Shift's activity that is there and cannot be
        // read. Dimmed, the time said, Tasks without a count, the rest kept.
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.calendar = calendar
        formatter.timeZone = TimeZone.current
        let lastMonth = formatter.string(from: calendar.date(byAdding: .month, value: -1, to: Date())!)
        let activity = shiftRoot.appendingPathComponent("activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: activity, withIntermediateDirectories: true)
        try? "- not\n- a mapping\n".write(to: activity.appendingPathComponent("\(lastMonth).yaml"),
                                         atomically: true, encoding: .utf8)
        fleet.selectModuleTab(named: "In flight")
        fleet.selectModuleTab(named: "Log")
        let dimmed = HelmHeroColumn.palette(for: .init(colour: .themeAccent, isDimmed: true), in: ThemeManager.shared.theme)
        check(logBand.debugPalette == dimmed && logBand.debugHeadline.hasPrefix("Couldn\u{2019}t read all of the log at ")
                && (logBand.debugBody ?? "").hasPrefix("Showing the 3 events that could be read, 3 today. ")
                && titles() == ["All", "Merges\u{2002}1", "Tasks", "Sync\u{2002}0", "Investigations\u{2002}0", "Incidents\u{2002}0"]
                && fleet.debugLogList.debugRowCount == 4,
              "CR-1: an unreadable month drew \(logBand.debugHeadline) with \(titles()), "
                + "dimmed \(logBand.debugPalette == dimmed)", &ok)
        try? FileManager.default.removeItem(at: activity.appendingPathComponent("\(lastMonth).yaml"))
        fleet.selectModuleTab(named: "Log")
        check(logBand.debugPalette != dimmed && logBand.debugHeadline == "3 events today",
              "CR-1: the band stayed dimmed once the month could be read", &ok)
    }

    /// CR-1 on Review: the board's words in every state the page can be in.
    private static func checkCrewReviewWords(_ ok: inout Bool) {
        typealias Reading = CrewHeroWords.ReviewReading
        let earlier = crewNow.addingTimeInterval(-22 * 60)
        let first = CrewHeroWords.review(Reading(hasRead: false), time: crewTime)
        check(first.kicker == "Review" && first.headline == "Checking your projects\u{2026}"
                && first.body == "Reading open pull requests from every clone in your firstmate home."
                && first.figures.isEmpty && first.ring == nil && first.tone == .accent
                && first.symbol == CrewHeroWords.reviewSymbol,
              "CR-1: Review before its first scan is \(first)", &ok)

        let typical = Reading(hasRead: true, checkedAt: crewNow, cleanReadAt: crewNow, github: 7, bitbucket: 2,
                              ready: 2, running: 3, failing: 1)
        let band = CrewHeroWords.review(typical, time: crewTime)
        check(band.kicker == "Review \u{00B7} 9 open \u{00B7} checked 11:24 AM"
                && band.headline == "2 pull requests are ready to merge"
                && band.body == "3 with checks running \u{00B7} 1 failing \u{00B7} across GitHub and Bitbucket."
                && band.tone == .accent && !band.offersFolderPath && !band.offersSetup && band.status == nil,
              "CR-1: Review's typical band is \(band)", &ok)
        check(band.figures.map(\.caption) == ["Open PRs", "Ready to merge", "Checks running", "Checks failing"]
                && band.figures.map(\.value) == ["9", "2", "3", "1"] && band.figures.allSatisfy { !$0.opensReview },
              "CR-1: Review's figures are \(band.figures)", &ok)
        if let ring = band.ring {
            check(ring.label == "2/9" && abs(ring.fraction - 2.0 / 9.0) < 0.0001 && ring.caption == "ready"
                    && ring.spoken == "2 of 9 open pull requests ready to merge",
                  "CR-1: Review's ring is \(ring)", &ok)
        } else {
            fail("CR-1: Review's typical band has no ring", &ok)
        }
        var one = typical
        one.ready = 1
        one.running = 0
        one.failing = 0
        one.bitbucket = 0
        let single = CrewHeroWords.review(one, time: crewTime)
        check(single.headline == "1 pull request is ready to merge"
                && single.body == "No checks running or failing \u{00B7} on GitHub." && single.ring?.label == "1/7",
              "CR-1: one ready PR on GitHub reads \(single.headline) / \(single.body ?? "-")", &ok)
        var none = typical
        none.ready = 0
        check(CrewHeroWords.review(none, time: crewTime).headline == "No pull requests are ready to merge"
                && CrewHeroWords.review(none, time: crewTime).ring?.fraction == 0,
              "CR-1: no ready PR reads \(CrewHeroWords.review(none, time: crewTime).headline)", &ok)
        var stray = Reading(hasRead: true, checkedAt: crewNow, other: 2)
        check(CrewHeroWords.forgePlace(stray) == "on no known forge", "CR-1: task PRs on no forge are \(CrewHeroWords.forgePlace(stray))", &ok)
        stray.github = 1
        stray.bitbucket = 1
        check(CrewHeroWords.forgePlace(stray) == "across GitHub, Bitbucket and elsewhere",
              "CR-1: three kinds of forge read \(CrewHeroWords.forgePlace(stray))", &ok)

        let empty = CrewHeroWords.review(Reading(hasRead: true, checkedAt: crewNow, cleanReadAt: crewNow), time: crewTime)
        check(empty.symbol == CrewHeroWords.calmSymbol && empty.kicker == "Review \u{00B7} checked 11:24 AM"
                && empty.headline == "No open pull requests right now"
                && empty.body == "Every clone was read. Nothing is waiting on a review or a merge."
                && empty.figures.isEmpty && empty.ring == nil && empty.tone == .accent,
              "CR-1: Review's empty band is \(empty)", &ok)

        // GL-14: a scan that reached nothing is dimmed, says when it tried and
        // when it last read everything, and draws no count at all.
        let unread = Reading(hasRead: true, checkedAt: crewNow, cleanReadAt: earlier,
                             failure: "Couldn't read your projects", failureIsTotal: true)
        let blind = CrewHeroWords.review(unread, time: crewTime)
        check(blind.tone == .dimmed && blind.headline == "Couldn\u{2019}t read your projects at 11:24 AM"
                && blind.kicker == "Review \u{00B7} last read 11:02 AM"
                && blind.body == "Open pull requests are read from the clones in your firstmate home\u{2019}s projects folder. "
                    + "None could be read, so no count is shown."
                && blind.figures.isEmpty && blind.ring == nil && blind.offersFolderPath,
              "CR-1: Review over an unreadable projects folder is \(blind)", &ok)
        var never = unread
        never.cleanReadAt = nil
        check(CrewHeroWords.review(never, time: crewTime).kicker == "Review",
              "CR-1: a first scan that failed claims a last read: \(CrewHeroWords.review(never, time: crewTime).kicker)", &ok)
        // A scan that missed some forges keeps what it found, dimmed and said.
        var partial = typical
        partial.bitbucket = 0
        partial.failure = "Couldn't reach the forge for 2 repositories."
        partial.cleanReadAt = earlier
        let kept = CrewHeroWords.review(partial, time: crewTime)
        check(kept.tone == .dimmed && kept.headline == "Couldn\u{2019}t reach the forge for 2 repositories at 11:24 AM"
                && kept.body == "Showing the 7 pull requests found in the repositories that answered, 2 ready to merge. "
                    + "The others are not counted."
                && kept.figures.map(\.value) == ["7", "2", "3", "1"] && kept.ring?.label == "2/7" && !kept.offersFolderPath,
              "CR-1: a partial scan with PRs is \(kept)", &ok)
        var partialEmpty = Reading(hasRead: true, checkedAt: crewNow, failure: "Couldn't reach the forge for grand-line.")
        partialEmpty.cleanReadAt = nil
        let gap = CrewHeroWords.review(partialEmpty, time: crewTime)
        check(gap.tone == .dimmed && gap.figures.isEmpty && gap.ring == nil
                && gap.headline == "Couldn\u{2019}t reach the forge for grand-line at 11:24 AM"
                && (gap.body ?? "").hasSuffix("so no count is shown."),
              "CR-1: a partial scan that found nothing is \(gap)", &ok)
        // Task-tracked PRs survive an unreadable projects folder: counted,
        // said to be only those, and the folder path still offered.
        var tracked = unread
        tracked.github = 2
        tracked.ready = 1
        let tasks = CrewHeroWords.review(tracked, time: crewTime)
        check(tasks.tone == .dimmed && tasks.offersFolderPath && tasks.figures.map(\.value) == ["2", "1", "0", "0"]
                && tasks.body == "Showing the 2 pull requests your crew\u{2019}s tasks point at, 1 ready to merge. "
                    + "Your clones could not be read, so theirs are not counted.",
              "CR-1: task PRs over an unreadable folder are \(tasks)", &ok)
    }

    /// The real page: a `ReviewController`, headless.
    private static func checkTheReviewBandOnTheRealPage(_ ok: inout Bool) {
        func pr(_ n: Int, _ forge: String, _ checks: String, task: String? = nil) -> MergedPR {
            MergedPR(source: task == nil ? "forge" : "work", taskID: task, repo: "grand-line",
                     url: "https://\(forge == "github" ? "github.com" : "bitbucket.org")/o/grand-line/pull/\(n)",
                     number: n, title: "PR \(n)", checks: checks, forge: forge)
        }
        let prs = [pr(1, "github", "green", task: "crew-a"), pr(2, "github", "green", task: "crew-b"),
                   pr(3, "github", "pending"), pr(4, "github", "red"), pr(5, "bitbucket", "green")]
        let theme = ThemeManager.shared.theme
        let dimmed = HelmHeroColumn.palette(for: .init(colour: .themeAccent, isDimmed: true), in: theme)
        let accent = HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: theme)
        check(dimmed != accent, "fixture: the dimmed tone is the accent's own palette", &ok)

        let review = ReviewController()
        _ = review.view
        guard let first = review.debugReviewBand else {
            fail("CR-1: Review has no band before its first scan", &ok)
            return
        }
        check(first.debugHeadline == "Checking your projects\u{2026}" && first.debugFootViews.isEmpty
                && review.debugIsLoadingSkeletonVisible && !review.debugIsLoadingLabelVisible
                && review.collapsesEmptyHeaderLine && !review.drawsSubtitleOnHeaderLine,
              "CR-1: Review's first scan reads \(first.debugHeadline) with skeleton \(review.debugIsLoadingSkeletonVisible)", &ok)

        review.debugRender(prs)
        let stamp = CrewBand.time(Date())
        check(first.debugHeadline == "2 pull requests are ready to merge"
                && first.debugBody == "1 with checks running \u{00B7} 1 failing \u{00B7} across GitHub and Bitbucket."
                && (first.debugKicker.contains(stamp) || first.debugKicker.contains(CrewBand.time(Date().addingTimeInterval(-60))))
                && first.debugPalette == accent,
              "CR-1: Review after a scan reads \(first.debugKicker) / \(first.debugHeadline) / \(first.debugBody ?? "-")", &ok)
        let strip = review.debugBandFigures
        check(first.debugFootViews.first === strip && zip(strip.debugValues, strip.debugCaptions).map { "\($0) \($1)" }
                == ["5 Open PRs", "2 Ready to merge", "1 Checks running", "1 Checks failing"]
                && (0..<4).allSatisfy { strip.debugActionCell(at: $0) == nil },
              "CR-1: Review's figures are \(strip.debugValues) \(strip.debugCaptions)", &ok)
        check(first.debugRing?.centreLabelForTests == "2/5" && abs((first.debugRing?.fractionForTests ?? 0) - 0.4) < 0.001,
              "CR-1: Review's ring reads \(first.debugRing?.centreLabelForTests ?? "nothing")", &ok)
        check(!review.debugIsStatsRowVisible && !review.debugIsBodySubtitleVisible && review.debugAreForgeSectionsVisible
                && review.debugGithubRowCount == 4 && review.debugBitbucketRowCount == 1,
              "CR-1: Review kept its boxed figures or count line, or lost its forge cards", &ok)

        // GL-14: a scan that reached nothing is dimmed, says when, counts
        // nothing, and offers the folder path on the band.
        review.debugRender([], scan: OpenPRsSource.FetchResult(projectsUnreadable: true))
        check(first.debugPalette == dimmed && first.debugHeadline.hasPrefix("Couldn\u{2019}t read your projects at ")
                && first.debugKicker.hasPrefix("Review \u{00B7} last read ")
                && first.debugFootViews.count == 1 && first.debugFootViews.first === review.debugBandFolderButton
                && first.debugRing == nil && !review.debugAreForgeSectionsVisible && !review.debugIsFailureStateVisible,
              "CR-1: an unreadable projects folder drew \(first.debugHeadline) with foot \(first.debugFootViews), "
                + "dimmed \(first.debugPalette == dimmed)", &ok)
        review.debugBandFolderButton.performClick(nil)
        check(first.debugBandViews.first === review.debugBandFolderRow
                && review.debugBandFolderRow.subtitleLabel.stringValue == FirstmateHome.projects.path
                && review.debugBandFolderButton.title == "Hide folder path",
              "CR-1: Show folder path did not show the path on the band", &ok)
        review.debugBandFolderButton.performClick(nil)
        check(first.debugBandViews.isEmpty && review.debugBandFolderButton.title == "Show folder path",
              "CR-1: Hide folder path left the path on the band", &ok)

        // A partial scan keeps the pull requests it found, under them.
        review.debugRender(Array(prs.prefix(4)),
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["pramata-status", "pramata-hive"]))
        check(first.debugPalette == dimmed && first.debugHeadline.hasPrefix("Couldn\u{2019}t reach the forge for 2 repositories at ")
                && strip.debugValues == ["4", "2", "1", "1"] && review.debugGithubRowCount == 4
                && review.debugAreForgeSectionsVisible && first.debugRing != nil,
              "CR-1: a partial scan drew \(first.debugHeadline) over \(review.debugGithubRowCount) rows", &ok)

        // A clean scan with nothing open: the band is the empty state.
        review.debugRender([])
        check(first.debugHeadline == "No open pull requests right now" && first.debugFootViews.isEmpty
                && first.debugRing == nil && first.debugPalette == accent && !review.debugAreForgeSectionsVisible,
              "CR-1: an empty Review drew \(first.debugHeadline) and forge cards \(review.debugAreForgeSectionsVisible)", &ok)
    }

    // MARK: RP-2 Question head

    private static func decision(_ key: String, _ note: String, verb: String = "needs-decision") -> FleetDecision {
        FleetDecision(key: key, verb: verb, note: note)
    }

    private static func checkReplyHeadWords(_ ok: inout Bool) {
        let note = "Which design to build for the notifications panel: N-1, N-2, N-3, N-4, or none yet"
        let one = ReplyHeroWords.head(taskID: "task-142", repo: "grand-line", status: "needs_decision",
                                      detail: "waiting on the captain", source: "crew",
                                      decisions: [decision("board-review", note)])
        check(one == ReplyHeroWords.Head(symbol: "exclamationmark.triangle",
                                         kicker: "Needs decision \u{00B7} task-142", headline: note,
                                         detail: "grand-line \u{00B7} needs-decision \u{201C}board-review\u{201D}",
                                         tone: .accent, groupLabel: "Answer task-142"),
              "RP-2: one open decision reads \(one)", &ok)
        // Several: the newest note is the question, and every key is named.
        let two = ReplyHeroWords.head(taskID: "task-142", repo: "grand-line", status: "needs_decision", detail: "",
                                      source: "crew", decisions: [decision("helm-bump", "Bump Helm?"),
                                                                  decision("board-review", note)])
        check(two.headline == note && two.detail == "grand-line \u{00B7} 2 open decisions: helm-bump, board-review",
              "RP-2: two open decisions read \(two.headline) / \(two.detail)", &ok)
        // A block: the amber tone, the row's own kicker and the octagon.
        let blocked = ReplyHeroWords.head(taskID: "alerts", repo: "pramata-status", status: "blocked", detail: "",
                                          source: "crew", decisions: [decision("default", "CI needs a secret", verb: "blocked")])
        check(blocked.tone == .amber && blocked.kicker == "Blocked \u{00B7} alerts" && blocked.symbol == "xmark.octagon"
                && blocked.detail == "pramata-status \u{00B7} blocked \u{201C}default\u{201D}",
              "RP-2: a blocked task reads \(blocked)", &ok)
        // Nothing on record: the row's own fallbacks, never invented words,
        // and the id where there is no repo.
        let none = ReplyHeroWords.head(taskID: "t-9", repo: nil, status: "needs_decision", detail: "waiting on the captain",
                                       source: "crew", decisions: [])
        check(none.headline == "waiting on the captain" && none.detail == "t-9",
              "RP-2: a task with no decision on record reads \(none.headline) / \(none.detail)", &ok)
        check(ReplyHeroWords.question(decisions: [], detail: "", source: "watcher") == "source: watcher"
                && ReplyHeroWords.question(decisions: [decision("k", "")], detail: "d", source: "s") == "d",
              "RP-2: the question's fallbacks are not the row's", &ok)
        // Never clipped: the whole note, however long, with its URL.
        let long = LayoutStabilitySelfTest.unbrokenNote + " " + ReviewTourLab.demoDecisionNote
        let kept = ReplyHeroWords.head(taskID: "t", repo: "r", status: "needs_decision", detail: "", source: "s",
                                       decisions: [decision("k", long)])
        check(kept.headline == long && long.count > 600, "RP-2: a \(long.count)-character note did not survive whole", &ok)
        // The caption is today's, word for word, in all three cases.
        let base = "Sent as a reply into the firstmate session for this crew, same as answering in a terminal."
        check(ReplyHeroWords.caption(decisions: []) == base
                && ReplyHeroWords.caption(decisions: [decision("board-review", note)])
                    == base + " Closes the open needs-decision \u{201C}board-review\u{201D}."
                && ReplyHeroWords.caption(decisions: [decision("a", "x"), decision("b", "y")])
                    == base + " 2 decisions are open on this task, so none is closed automatically - resolve the right one from the crew's session.",
              "RP-2: the caption is not today's", &ok)
        check(ReplyHeroWords.kicker(taskID: "x", blocked: false) == "Needs decision \u{00B7} x"
                && ReplyHeroWords.symbol(blocked: true) == "xmark.octagon.fill"
                && ReplyHeroWords.placeholder == "Type your answer\u{2026}" && ReplyHeroWords.sendTitle == "Send",
              "RP-2: the row's words moved and changed", &ok)
        for name in ["exclamationmark.triangle", "xmark.octagon", "xmark", "paperplane.fill"] {
            check(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                  "RP-2: SF Symbol \(name) does not resolve", &ok)
        }
    }

    /// The card's head, painted on every palette in both tones: the headline
    /// in the ink and the kicker and second line at 80% on both stops, the
    /// tile's glyph at the non-text floor on both, and the ×'s ink on its
    /// shade. The status and caption are measured on the card's own fill.
    private static func checkTheReplyHeadClearsTheFloorOnEveryPalette(_ ok: inout Bool) {
        var seen = Set<String>()
        let themes = (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
        check(themes.count >= 26, "fixture: only \(themes.count) themes", &ok)
        var failures: [String] = []
        var worst = Double.infinity
        var amberDiffers = 0
        for tone in [ReplyHeroWords.Tone.accent, .amber] {
            let head = ReplyHeroWords.Head(symbol: ReplyHeroWords.tileSymbol(blocked: tone == .amber), kicker: "Needs decision \u{00B7} t",
                                           headline: "Which one?", detail: "repo \u{00B7} 2 open decisions: a, b",
                                           tone: tone, groupLabel: "Answer t")
            let card = FleetReplyCard(head: head, caption: ReplyHeroWords.caption(decisions: []),
                                      closeButton: HelmButton(symbol: "xmark", variant: .quiet, size: .small))
            for theme in themes {
                card.applyTheme(theme)
                guard let palette = card.palette, let glyph = card.debugGlyphColor else {
                    failures.append("\(theme.id): the head is unpainted")
                    continue
                }
                if tone == .amber, palette != FleetReplyCard.palette(for: .accent, in: theme) { amberDiffers += 1 }
                let tag = "\(theme.id) \(tone)"
                let darker = palette.start == palette.lighterStop ? palette.end : palette.start
                func floor(_ name: String, _ color: NSColor?, on ground: (Double, Double, Double), _ target: Double) {
                    guard let color else { failures.append("\(tag): \(name) has no colour"); return }
                    let measured = HelmContrast.ratio(composite(color, over: ground), ground)
                    if target == HelmContrast.textTarget { worst = min(worst, measured) }
                    if measured < target { failures.append("\(tag): \(name) \(ratio(measured))") }
                }
                let kicker = card.debugKickerLabel.attributedStringValue
                    .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                for stop in [palette.lighterStop, darker] {
                    floor("headline", card.debugHeadlineLabel.textColor, on: stop, HelmContrast.textTarget)
                    floor("second line", card.debugDetailLabel.textColor, on: stop, HelmContrast.textTarget)
                    floor("kicker", kicker, on: stop, HelmContrast.textTarget)
                    floor("glyph", glyph, on: stop, HelmContrast.nonTextTarget)
                    let ink = HelmContrast.color(palette.ink)
                    let shade = HelmButton.heroPalette(ink: ink, enabled: true)
                    floor("\u{00D7}", shade.label, on: composite(shade.fill, over: stop), HelmContrast.nonTextTarget)
                }
                let cardFill = HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex))
                floor("caption", card.debugCaptionLabel.textColor, on: cardFill, HelmContrast.textTarget)
                for tint in [HelmTint.warn, .critical] {
                    card.setStatus("status", tint: tint)
                    floor("\(tint) status", card.debugStatusLabel.textColor, on: cardFill, HelmContrast.textTarget)
                }
                card.setStatus(nil, tint: nil)
            }
        }
        // The fixture's own power: the amber tone is a palette of its own.
        check(amberDiffers >= themes.count - 2, "fixture: the amber head matched the accent's on \(themes.count - amberDiffers) themes", &ok)
        check(failures.isEmpty, "RP-2: the head misses its floor on \(failures.prefix(12))", &ok)
        print("  RP-2 head: weakest text \(ratio(worst)):1 over \(themes.count) palettes, accent and amber")
    }

    /// A real `FleetController` in the sidebar layout, with no window: Reply
    /// turns its row into the card, and what is typed survives a refresh. The
    /// floating bar's dashboard, the same controller never adopting the
    /// layout, still opens today's composer under the row.
    private static func checkTheReplyCardOnTheRealPage(_ ok: inout Bool) {
        let saved = FleetActions.stateDirectoryOverrideForTests
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-card-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer {
            FleetActions.stateDirectoryOverrideForTests = saved
            try? FileManager.default.removeItem(at: state)
        }
        FleetActions.stateDirectoryOverrideForTests = state
        let note = "Which design to build for the notifications panel: N-1, N-2, N-3, N-4, or none yet"
        try? "needs-decision [at=1791950800] [key=helm-bump]: Bump Helm?\nneeds-decision [at=1791950801] [key=board-review]: \(note)\n"
            .write(to: state.appendingPathComponent("rp-wait.status"), atomically: true, encoding: .utf8)
        func task(_ id: String, _ status: String) -> FleetTask {
            var task = FleetTask(id: id, repo: "grand-line", kind: "ship", pr: nil)
            task.status = status
            task.state = "parked"
            return task
        }
        let tasks = [task("rp-wait", "needs_decision"), task("rp-block", "blocked")]
        func snapshot(_ tasks: [FleetTask]) -> FleetSnapshot {
            FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: 0, doneCount: 0,
                          projectsCount: 1, watcher: WatcherHealth(status: "healthy"))
        }

        let fleet = FleetController(shiftStore: ShiftStore())
        _ = fleet.view
        fleet.selectModuleTab(named: "Needs you")
        fleet.debugRender(snapshot: snapshot(tasks), mergedPRs: [])
        guard let reply = fleet.debugReplyButton(taskID: "rp-wait") else {
            fail("RP-2: Needs you's row has no Reply", &ok)
            return
        }
        reply.performClick(nil)
        guard let card = fleet.debugOpenReplyCard else {
            fail("RP-2: Reply on Needs you opened no card (composer \(String(describing: fleet.debugOpenReplyComposerView)))", &ok)
            return
        }
        check(fleet.debugCardTakesItsRowsPlace(taskID: "rp-wait", at: 0) && fleet.debugNeedsRowCount == 1,
              "RP-2: the card is not in its row's place (\(fleet.debugNeedsRowCount) rows left)", &ok)
        check(card.head == ReplyHeroWords.head(taskID: "rp-wait", repo: "grand-line", status: "needs_decision", detail: "",
                                               source: "none", decisions: FleetActions.openDecisions(taskID: "rp-wait"))
                && card.head.headline == note && card.debugHeadlineLabel.stringValue == note
                && card.debugKickerLabel.stringValue == "NEEDS DECISION \u{00B7} RP-WAIT"
                && card.debugDetailLabel.stringValue == "grand-line \u{00B7} 2 open decisions: helm-bump, board-review"
                && card.debugCaptionLabel.stringValue.hasSuffix("so none is closed automatically - resolve the right one from the crew's session."),
              "RP-2: the card reads \(card.debugKickerLabel.stringValue) / \(card.debugHeadlineLabel.stringValue) / "
                + "\(card.debugDetailLabel.stringValue)", &ok)
        check(fleet.debugReplyButton(taskID: "rp-wait") === card.debugCloseButton
                && card.debugCloseButton.accessibilityLabel() == "Cancel",
              "RP-2: the head's \u{00D7} is not the row's Cancel", &ok)
        check(card.accessibilityRole() == .group && card.accessibilityLabel() == "Answer rp-wait"
                && card.debugWell.debugHintLabel.isHidden,
              "RP-2: the card is not one group named for its task with a hint-free well", &ok)
        check(card.palette == HelmHeroColumn.palette(for: .init(colour: .themeAccent), in: ThemeManager.shared.theme),
              "RP-2: a waiting task's head is not on the quiet-ink accent palette", &ok)

        // Typed through the text system, then a refresh that moves the list.
        card.debugTextView.insertText("Go with N-1.", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(card.debugSendButton.isEnabled, "RP-2: typing did not enable Send", &ok)
        fleet.debugRender(snapshot: snapshot([task("rp-new", "needs_decision")] + tasks), mergedPRs: [])
        check(fleet.debugOpenReplyCard === card && card.text == "Go with N-1."
                && fleet.debugCardTakesItsRowsPlace(taskID: "rp-wait", at: 1),
              "RP-2: a refresh lost the card, its text or its place (\(fleet.debugOpenReplyCard?.text ?? "no card"))", &ok)

        // The head's × closes it, and the row comes back with its Reply.
        card.debugCloseButton.performClick(nil)
        check(fleet.debugOpenReplyCard == nil && fleet.debugNeedsRowCount == 3
                && fleet.debugReplyButton(taskID: "rp-wait")?.title == "Reply",
              "RP-2: the \u{00D7} left \(fleet.debugNeedsRowCount) rows and a Reply titled \(fleet.debugReplyButton(taskID: "rp-wait")?.title ?? "nil")", &ok)

        // A blocked task opens on the amber head.
        fleet.debugReplyButton(taskID: "rp-block")?.performClick(nil)
        let warn = HelmContrast.components(HelmTheme.nsColor(ThemeManager.shared.theme.ansiHex[3]))
        check(fleet.debugOpenReplyCard?.head.tone == .amber
                && fleet.debugOpenReplyCard?.palette == HelmHeroColumn.palette(
                    for: .init(colour: .fixed(red: warn.0, green: warn.1, blue: warn.2)), in: ThemeManager.shared.theme),
              "RP-2: a blocked task's head is not amber", &ok)
        fleet.debugReplyButton(taskID: "rp-block")?.performClick(nil)
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
        // Review's band: the ring of ready over open, the folder path's row.
        let ringed = HelmHeroColumn()
        ringed.setArrangement(.band)
        let review = CrewHeroWords.review(.init(hasRead: true, github: 9, ready: 2, running: 3, failing: 1), time: crewTime)
        let pathRow = HelmHeroRow(leading: .symbol("folder"), title: "Projects folder", subtitle: "/a/projects",
                                  subtitleIsCode: true)
        // Log's band: the filter on its foot, the second segment chosen.
        let logged = HelmHeroColumn()
        logged.setArrangement(.band)
        let filter = HelmSegmentedTabs(items: FleetLogListView.filterItems, selected: "merge", size: .compact)
        filter.setTitle("Merges\u{2002}3", forID: "merge")
        var failures: [String] = []
        var worst = Double.infinity
        for theme in themes {
            for dimmed in [false, true] {
                let tone = HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: dimmed)
                column.configure(header: .init(symbol: CrewHeroWords.crewSymbol, kicker: "In flight", headline: "2 tasks need your call",
                                               body: "1 decision waiting", ring: nil, status: .init(text: "Watcher stale", tint: .warn)),
                                 sections: [], foot: [strip], tone: tone, bandViews: [grid], footRule: true)
                column.applyTheme(theme)
                ringed.configure(header: .init(symbol: review.symbol, kicker: review.kicker, headline: review.headline,
                                               body: review.body, ring: CrewBand.ring(review.ring)),
                                 sections: [], foot: [], tone: tone, bandViews: [pathRow])
                ringed.applyTheme(theme)
                logged.configure(header: .init(symbol: CrewHeroWords.logSymbol, kicker: "Log", headline: "5 events today",
                                               body: "1 merge", ring: nil),
                                 sections: [], foot: [filter], tone: tone, footRule: true)
                logged.applyTheme(theme)
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
                    // Review: the ring's arc and its centre label, and the
                    // folder path's row, on the same palette.
                    if let ring = ringed.debugRing, ringed.debugPalette == palette {
                        floor("ring arc", ring.debugArcColor.flatMap { NSColor(cgColor: $0) }, on: stop, HelmContrast.nonTextTarget)
                        floor("ring label", ring.labelColorOverride, on: stop, HelmContrast.textTarget)
                    } else {
                        failures.append("\(tag): Review's band has no ring on its palette")
                    }
                    floor("path title", pathRow.titleLabel.textColor, on: stop, HelmContrast.textTarget)
                    floor("path", pathRow.subtitleLabel.textColor, on: stop, HelmContrast.textTarget)
                    // Log: an unchosen segment's words on its shade over the
                    // gradient, and its hairline.
                    if logged.debugPalette == palette, filter.heroInk != nil {
                        let colors = filter.debugPillLabelColors
                        let fills = filter.debugPillFills
                        for index in [0, 2] where colors.indices.contains(index) && fills.indices.contains(index) {
                            floor("filter words \(index)", colors[index], on: composite(fills[index], over: stop),
                                  HelmContrast.textTarget)
                        }
                    } else {
                        failures.append("\(tag): Log's filter is not in the band's ink")
                    }
                }
                // The chosen segment's words on the solid ink.
                if let ink = filter.heroInk, filter.debugPillLabelColors.indices.contains(1) {
                    floor("chosen filter words", filter.debugPillLabelColors[1], on: HelmContrast.components(ink),
                          HelmContrast.textTarget)
                }
            }
        }
        check(failures.isEmpty, "CR-1: the band misses its floor on \(failures.prefix(12))", &ok)
        print("  CR-1 band: weakest text \(ratio(worst)):1 over \(themes.count) palettes, accent and dimmed")
    }
}

#endif
