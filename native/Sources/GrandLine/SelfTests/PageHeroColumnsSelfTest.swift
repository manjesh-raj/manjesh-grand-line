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
}

#endif
