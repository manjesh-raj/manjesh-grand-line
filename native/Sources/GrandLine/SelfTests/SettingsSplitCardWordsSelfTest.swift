// Grand Line - native macOS app.
//
// What Settings' split cards say (Set-2), for every page and the states that
// change the words or the colour, plus the two pieces the cards added:
// `HelmHeroColumn`'s panel accessory (1.3.0) and the last-export record.
//
// Headless: the words are pure, the panel is built without a window, and the
// record is a round trip through `AppSettings`. Where the cards sit and what
// their controls do is `SettingsSplitCardsViewSelfTest`.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_SPLIT_CARD_WORDS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsSplitCardWordsSelfTest {

    static func run() -> Bool {
        var ok = true
        checkAppearance(&ok)
        checkTerminal(&ok)
        checkShortcuts(&ok)
        checkCapture(&ok)
        checkMenuBar(&ok)
        checkBriefings(&ok)
        checkIntents(&ok)
        checkSecurity(&ok)
        checkBackup(&ok)
        checkTones(&ok)
        checkPanelAccessory(&ok)
        checkExportRecordRoundTrips(&ok)
        print(ok ? "SettingsSplitCardWordsSelfTest: all checks passed" : "SettingsSplitCardWordsSelfTest: FAILED")
        return ok
    }

    private static func checkAppearance(_ ok: inout Bool) {
        let words = SettingsHeroWords.appearance(
            themeName: "Graphite Dark", isDark: true, followsSystem: false,
            density: .comfortable, profile: .operator,
            terminal: "matches the app (One Dark)")
        check(words.headline == "Graphite Dark is showing.", "Appearance: headline \"\(words.headline)\"", &ok)
        check(words.body == "Dark appearance, comfortable rows and the Operator profile. "
                + "Terminal: matches the app (One Dark).", "Appearance: body \"\(words.body ?? "")\"", &ok)
        check(words.tone == .accent, "Appearance: the panel is not the accent", &ok)
        let following = SettingsHeroWords.appearance(
            themeName: "Daylight", isDark: false, followsSystem: true,
            density: .compact, profile: nil, terminal: "Nord, chosen on the Terminal page")
        check(following.body == "Following macOS, light right now, "
                + "compact rows and a custom sidebar. Terminal: Nord, chosen on the Terminal page.",
              "Appearance: following macOS reads \"\(following.body ?? "")\"", &ok)
        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the panel no longer names one.
        check(!(words.body ?? "").contains("layout") && !(following.body ?? "").contains("layout"),
              "Appearance: the panel still names a window layout", &ok)
    }

    private static func checkTerminal(_ ok: inout Bool) {
        let words = SettingsHeroWords.terminal(scheme: "One Dark", fontSize: 13, scrollbackRows: 10_000,
                                               workingDirectory: "~/manjesh", reconnects: true, trimsBackground: true,
                                               backgroundRows: 2_000)
        check(words.headline == "One Dark, 13 pt, \(SettingsHeroWords.grouped(10_000)) rows.",
              "Terminal: headline \"\(words.headline)\"", &ok)
        check(words.body?.hasPrefix("New Shell and Firstmate tabs start in ~/manjesh and reconnect on their own.") == true,
              "Terminal: body \"\(words.body ?? "")\"", &ok)
        let bare = SettingsHeroWords.terminal(scheme: "Nord", fontSize: 12, scrollbackRows: 500, workingDirectory: nil,
                                              reconnects: false, trimsBackground: false, backgroundRows: 2_000)
        check(bare.body == "New Shell and Firstmate tabs start in your home folder. A dropped connection waits for \u{2318}R. "
                + "Tabs left in the background keep their whole history.",
              "Terminal: with nothing set the body is \"\(bare.body ?? "")\"", &ok)
    }

    private static func checkShortcuts(_ ok: inout Bool) {
        let clean = SettingsHeroWords.shortcuts(total: 47, changed: 0, conflicts: 0)
        check(clean.headline == "47 shortcuts, none changed, no conflicts.", "Shortcuts: \"\(clean.headline)\"", &ok)
        check(clean.tone == .accent, "Shortcuts: a clean table is not the accent", &ok)
        let clash = SettingsHeroWords.shortcuts(total: 47, changed: 2, conflicts: 1)
        check(clash.headline == "47 shortcuts, 2 changed, 1 conflict.", "Shortcuts: \"\(clash.headline)\"", &ok)
        check(clash.tone == .amber, "Shortcuts: a clash does not turn the panel amber", &ok)
        check(SettingsHeroWords.shortcuts(total: 5, changed: 1, conflicts: 3).headline.hasSuffix("3 conflicts."),
              "Shortcuts: three clashes are not plural", &ok)
    }

    private static func checkCapture(_ ok: inout Bool) {
        let granted = SettingsHeroWords.capture(chord: "\u{2325}Space", accessibilityGranted: true, clipboardHistory: false)
        check(granted.headline == "\u{2325}Space works from any app." && granted.tone == .accent,
              "Capture: granted reads \"\(granted.headline)\"", &ok)
        check(granted.body?.contains("nothing reads the clipboard") == true, "Capture: clipboard off is not said", &ok)
        let missing = SettingsHeroWords.capture(chord: "\u{2325}Space", accessibilityGranted: false, clipboardHistory: true)
        check(missing.headline == "\u{2325}Space only works while Grand Line is in front." && missing.tone == .amber,
              "Capture: a missing grant reads \"\(missing.headline)\" in \(missing.tone)", &ok)
    }

    private static func checkMenuBar(_ ok: inout Bool) {
        let window = SettingsHeroWords.menuBar(compactMode: false, hidesDockIcon: false, separateIcons: false,
                                               globalChord: "\u{2303}\u{2325}\u{2318}G")
        check(window.headline == "Window mode, with one menu-bar icon.", "Menu Bar: \"\(window.headline)\"", &ok)
        let three = SettingsHeroWords.menuBar(compactMode: false, hidesDockIcon: false, separateIcons: true,
                                              globalChord: "G")
        check(three.headline == "Window mode, with three menu-bar icons.", "Menu Bar: \"\(three.headline)\"", &ok)
        let compact = SettingsHeroWords.menuBar(compactMode: true, hidesDockIcon: true, separateIcons: true,
                                                globalChord: "G")
        check(compact.headline == "Grand Line lives in the menu bar." && compact.body?.hasPrefix("The Dock icon is hidden.") == true,
              "Menu Bar: compact mode reads \"\(compact.headline)\" / \"\(compact.body ?? "")\"", &ok)
    }

    private static func checkBriefings(_ ok: inout Bool) {
        check(SettingsHeroWords.briefings(enabled: true, place: "Overview").headline == "A briefing opens Overview each morning.",
              "Briefings: the on headline", &ok)
        check(SettingsHeroWords.briefings(enabled: false, place: "Overview").headline == "No morning briefing.",
              "Briefings: the off headline", &ok)
    }

    private static func checkIntents(_ ok: inout Bool) {
        let titles = ["New Task", "New Note", "Ask the Crew"]
        let registered = SettingsHeroWords.intents(titles: titles, registration: .registered, statusText: "x")
        check(registered.headline == "3 actions registered with the system." && registered.tone == .accent,
              "Intents: registered reads \"\(registered.headline)\"", &ok)
        check(registered.body == "New Task, New Note and Ask the Crew appear in Shortcuts, Spotlight and Siri under \u{201C}Grand Line\u{201D}.",
              "Intents: the body is \"\(registered.body ?? "")\"", &ok)
        // GL-14: a list this copy does not publish is not "available".
        let unbundled = SettingsHeroWords.intents(titles: titles, registration: .unbundled, statusText: "Why.")
        check(unbundled.tone == .dimmed && unbundled.body == "Why." && unbundled.headline.contains("not registered"),
              "Intents: an unbundled copy reads \"\(unbundled.headline)\" in \(unbundled.tone)", &ok)
        // The page's own check: a suite is an unbundled binary.
        check(SettingsController.intentRegistration() == .unbundled,
              "Intents: the running test binary reads as \(SettingsController.intentRegistration())", &ok)
    }

    private static func checkSecurity(_ ok: inout Bool) {
        let off = SettingsHeroWords.security(lockEnabled: false, idle: "15 minutes", session: "8 hours", sudo: .enabled,
                                             vaultPlace: "Poneglyph")
        check(off.headline == "No app lock. Touch ID for sudo is on.", "Security: \"\(off.headline)\"", &ok)
        check(off.body?.contains("Turned on, it locks after 15 minutes idle.") == true,
              "Security: the idle timer is not said with the lock off", &ok)
        let on = SettingsHeroWords.security(lockEnabled: true, idle: "5 minutes", session: "8 hours", sudo: .checking,
                                            vaultPlace: "Poneglyph")
        check(on.headline == "Locks after 5 minutes idle.", "Security: while sudo is checking \"\(on.headline)\"", &ok)
        let sudoOff = SettingsHeroWords.security(lockEnabled: true, idle: "5 minutes", session: "8 hours",
                                                 sudo: .notEnabled, vaultPlace: "Poneglyph")
        check(sudoOff.headline.hasSuffix("Touch ID for sudo is off."), "Security: \"\(sudoOff.headline)\"", &ok)
    }

    private static func checkBackup(_ ok: inout Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12)) ?? Date()
        let never = SettingsHeroWords.backup(lastExport: nil, hosts: 7, snippets: 1, now: now, calendar: calendar)
        check(never.headline == "No backup exported from this Mac yet.", "Backup: never reads \"\(never.headline)\"", &ok)
        check(never.body?.hasPrefix("A backup holds 7 hosts, 1 snippet,") == true, "Backup: \"\(never.body ?? "")\"", &ok)
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12)) ?? now
        let record = BackupExportRecord(date: earlier, bytes: 1_843_200, destination: "grand-line-backup.glbackup")
        let words = SettingsHeroWords.backup(lastExport: record, hosts: 7, snippets: 3, now: now, calendar: calendar)
        check(words.headline == "Last export 12 Nov, \(SettingsController.byteText(1_843_200)).",
              "Backup: \"\(words.headline)\"", &ok)
        check(words.body?.hasPrefix("Saved to grand-line-backup.glbackup.") == true, "Backup: \"\(words.body ?? "")\"", &ok)
        check(SettingsHeroWords.day(now, now: now, calendar: calendar) == "today", "Backup: today", &ok)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        check(SettingsHeroWords.day(yesterday, now: now, calendar: calendar) == "yesterday", "Backup: yesterday", &ok)
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2, hour: 12)) ?? now
        check(SettingsHeroWords.day(lastYear, now: now, calendar: calendar) == "2 Mar 2025",
              "Backup: another year reads \(SettingsHeroWords.day(lastYear, now: now, calendar: calendar))", &ok)
    }

    /// Amber is the theme's own amber and dimmed is the accent dimmed, so the
    /// panels go through the same palette rule as every other hero.
    private static func checkTones(_ ok: inout Bool) {
        for theme in HelmTheme.appThemes {
            let accent = SettingsHeroWords(headline: "", body: nil, tone: .accent).heroTone(in: theme)
            check(accent == HelmModuleCard.HeroTone(colour: .themeAccent), "\(theme.name): accent tone \(accent)", &ok)
            let dimmed = SettingsHeroWords(headline: "", body: nil, tone: .dimmed).heroTone(in: theme)
            check(dimmed.isDimmed, "\(theme.name): the dimmed tone is not dimmed", &ok)
            let amber = SettingsHeroWords(headline: "", body: nil, tone: .amber).heroTone(in: theme)
            let want = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            let got = amber.accent(in: theme)
            check(abs(got.0 - want.0) < 0.001 && abs(got.1 - want.1) < 0.001 && abs(got.2 - want.2) < 0.001,
                  "\(theme.name): the amber tone is not the theme's amber", &ok)
            // Every panel's words clear the text floor on its gradient.
            for tone in [accent, dimmed, amber] {
                let palette = HelmHeroColumn.palette(for: tone, in: theme)
                let ratio = min(HelmContrast.ratio(palette.ink, palette.start), HelmContrast.ratio(palette.ink, palette.end))
                check(ratio >= HelmContrast.textTarget - 0.01,
                      "\(theme.name): ink on a \(tone) panel measures \(ratio):1", &ok)
            }
        }
    }

    /// HelmHeroColumn 1.3.0: a `.panel` draws a page's view where its ring
    /// would be, with the caption in the quiet ink; a ring wins; `.band`
    /// draws none.
    private static func checkPanelAccessory(_ ok: inout Bool) {
        autoreleasepool {
            let column = HelmHeroColumn()
            column.setArrangement(.panel)
            let tile = NSView()
            tile.widthAnchor.constraint(equalToConstant: 60).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let header = HelmHeroColumn.Header(symbol: "paintpalette", kicker: "Settings", headline: "Dusk is showing.",
                                               body: nil, ring: nil)
            let accessory = HelmHeroColumn.Accessory(view: tile, caption: "Daylight \u{00B7} Dusk", spoken: "Dusk")
            column.configure(header: header, sections: [], foot: [], tone: .init(colour: .themeAccent),
                             accessory: accessory)
            column.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            column.layoutSubtreeIfNeeded()
            check(tile.isDescendant(of: column), "Accessory: the view is not on the panel", &ok)
            check(tile.accessibilityLabel() == "Dusk", "Accessory: VoiceOver reads \(tile.accessibilityLabel() ?? "nil")", &ok)
            let caption = column.debugAccessoryCaption
            check(caption?.stringValue == "Daylight \u{00B7} Dusk" && caption?.isHidden == false,
                  "Accessory: the caption is \(caption?.stringValue ?? "nil")", &ok)
            if let caption {
                check(TasksSecretsHeroViewSelfTest.isInk(caption.textColor, column.ink,
                                                         alpha: HelmHeroColumn.quietInkAlpha),
                      "Accessory: the caption is not in the quiet ink", &ok)
            }
            // The words stop before the accessory's column.
            let tileFrame = tile.convert(tile.bounds, to: column)
            let headline = column.debugHeadlineLabel.convert(column.debugHeadlineLabel.bounds, to: column)
            check(headline.maxX <= tileFrame.minX, "Accessory: the headline \(headline) runs under the view \(tileFrame)", &ok)

            let ring = HelmHeroColumn.Ring(fraction: 0.5, label: "1/2", caption: nil, spoken: "", state: .ok)
            column.configure(header: .init(symbol: "x", kicker: "", headline: "", body: nil, ring: ring), sections: [],
                             foot: [], tone: .init(colour: .themeAccent), accessory: accessory)
            check(!tile.isDescendant(of: column) && column.debugAccessoryCaption == nil,
                  "Accessory: a ring and the accessory are both drawn", &ok)
            column.setArrangement(.band)
            column.configure(header: header, sections: [], foot: [], tone: .init(colour: .themeAccent), accessory: accessory)
            check(!tile.isDescendant(of: column), "Accessory: a band drew the accessory", &ok)
        }
    }

    private static func checkExportRecordRoundTrips(_ ok: inout Bool) {
        let saved = AppSettings.shared.lastBackupExport
        defer { AppSettings.shared.lastBackupExport = saved }
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: AppSettings.backupExportDidChange, object: nil,
                                                           queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        BackupUI.recordExport(bytes: 4_096, destination: "a.glbackup", at: date)
        check(AppSettings.shared.lastBackupExport == BackupExportRecord(date: date, bytes: 4_096, destination: "a.glbackup"),
              "Backup: the record read back as \(String(describing: AppSettings.shared.lastBackupExport))", &ok)
        check(posted == 1, "Backup: recording an export posted \(posted) notifications", &ok)
        AppSettings.shared.lastBackupExport = nil
        check(AppSettings.shared.lastBackupExport == nil, "Backup: the record does not clear", &ok)
    }
}

#endif
