// Manjesh Grand Line - native macOS app.
//
// The Section 2 UI bugs from `data/grand-line-e2e-audit/report.md` that are
// small enough not to each want a suite of their own, one case per finding
// id. Run with:
//
//   swift build && FM_RUN_AUDIT_UI_FIXES_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
//   B3  the Health card's footer renders its whole explanation, not `"Copy`
//   B4  a narrow window truncates every nav pill a little, not one entirely
//   B5  the selected space pill follows every navigation, not only a click
//   B6  the lock screen's ribbon is painted on first layout
//   B7  the Schedules row toggle is the app's own themed toggle
//   B8  the Run History sheet re-colours its heading on a theme change
//   B9  Overview's Health note fits; Updates' tiles do not claim a count
//       they do not have yet
//
// Window-backed (every one of these is a real measurement on a real view), so
// this sits in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum AuditUIFixesSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("B3_healthFooterIsNotClippedByAnEmptySpacer", test_b3),
            ("B4_narrowWindowTruncatesEveryPillFairly", test_b4),
            ("B5_selectedSpaceFollowsEveryNavigation", test_b5),
            ("B6_lockRibbonIsPaintedOnFirstLayout", test_b6),
            ("B7_schedulesRowUsesTheAppsOwnToggle", test_b7),
            ("B8_runHistorySheetRecoloursOnThemeChange", test_b8),
            ("B9_healthModuleNoteFits", test_b9_note),
            ("B9_updatesTilesDoNotClaimUncheckedCounts", test_b9_tiles),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "AuditUIFixesSelfTest: all \(cases.count) cases passed"
              : "AuditUIFixesSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func mount(_ view: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Every `NSTextField` under `root`, in tree order.
    private static func labels(in root: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ v: NSView) {
            if let l = v as? NSTextField { found.append(l) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    // MARK: B3

    /// The footer read `Diagnostics` / `"Copy` - one clipped word of a
    /// two-sentence explanation - at every window width and in every theme,
    /// because `descRow` was handed a bare `NSView()` as its trailing view.
    /// That spacer has no intrinsic size, so its `.required` **content**
    /// hugging is a no-op (AGENTS.md gotcha 12), and with the text column
    /// deliberately yielding, `.fill` gave it nearly the whole row: measured
    /// at a 78.5pt label against a 931pt intrinsic width.
    private static func test_b3() -> String? {
        // The real page, not a bare card: the footer's own wrap width is
        // re-derived from the card's real width in `layoutDidChange()`, so a
        // detached card measures a column the shipped page never has.
        let controller = HealthController()
        let window = mount(controller.view, width: 900, height: 700)
        defer { window.contentView = nil }
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()

        // The footer's description is the long one - find it by its own text.
        guard let footer = labels(in: controller.view).first(where: {
            $0.stringValue.contains("copies these rows as text")
        }) else {
            return "the Health footer's explanation is no longer on the card at all"
        }
        let width = footer.frame.width
        let intrinsic = footer.intrinsicContentSize.width
        // It wraps, so it will not be as wide as its one-line intrinsic size -
        // but it must have a real column, not a sliver. The shipped bug was
        // 78.5pt against 931pt.
        guard width > 200 else {
            return "footer label is \(Int(width))pt wide (one-line intrinsic \(Int(intrinsic))pt) - still squeezed by an empty trailing view"
        }
        // And it must actually fit its text somewhere in that column.
        guard footer.frame.height > footer.font.map({ $0.pointSize * 1.5 }) ?? 20 else {
            return "footer label is \(Int(footer.frame.height))pt tall - it is not wrapping to its two sentences"
        }
        return nil
    }

    // MARK: B4

    private static func test_b4() -> String? {
        let bar = DaylightBarController()
        // 900pt is the width the audit measured `engineering`'s label at 4.0pt
        // while its neighbours kept 60-70pt; 1100 is where the captain would
        // actually meet it (this app's own default launch frame used to be
        // 1220).
        for width in [900.0, 1100.0, 1200.0] as [CGFloat] {
            let window = mount(bar.view, width: width, height: 90)
            defer { window.contentView = nil }
            bar.view.layoutSubtreeIfNeeded()
            let widths = bar.debugPillLabelWidths()
            guard !widths.isEmpty else { return "the bar reported no pills" }
            for (space, w) in widths where w < DaylightBarController.pillLabelMinWidth - 0.5 {
                let all = widths.map { "\($0.space.rawValue)=\(Int($0.width))" }.joined(separator: " ")
                return "at \(Int(width))pt, \(space.rawValue)'s label is \(Int(w))pt - below the \(Int(DaylightBarController.pillLabelMinWidth))pt floor (\(all))"
            }
        }
        return nil
    }

    // MARK: B5

    private static func test_b5() -> String? {
        // Pure mapping, deliberately: `AppShellController.show(_:)` mounts
        // every destination, and what this finding is about is the *table*
        // being consulted at all. The wiring itself is a one-line source
        // guard below.
        let expected: [(RailDestination, DaylightSpace?)] = [
            (.schedules, .operations),
            (.health, .operations),
            (.shift, .command),
            (.review, .command),
            (.vault, .stores),
            (.updates, .engineering),
            (.overview, nil),
            (.homeCanvas, nil),
        ]
        for (dest, want) in expected {
            let got = DaylightModule.space(forDestination: dest)
            guard got == want else {
                return "\(dest) maps to \(got.map { $0.rawValue } ?? "nil"), expected \(want.map { $0.rawValue } ?? "nil")"
            }
        }
        guard let dir = SelfTestSources.appSourceDirectory(),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            return nil
        }
        guard shell.contains("DaylightModule.space(forDestination: dest)") else {
            return "AppShellController.show(_:) no longer syncs the selected space - the pill goes stale on every ⌘K / deep-link / module-card navigation again"
        }
        return nil
    }

    // MARK: B6

    private static func test_b6() -> String? {
        let controller = LockScreenController()
        // The shipped failure's own order, which is also the app's: the state
        // is applied while the scene has no resolved bounds yet (at launch the
        // lock screen is built and shown from `AppShellController.loadView`,
        // before the window has been sized), and only then does layout happen.
        // `applyTheme` -> `applyLayerGeometry` therefore ran against a 0x0
        // ribbon and nothing re-ran it - the audit read `(0,0,0,0)` on a fully
        // laid-out 1220x720 first presentation, and `(0,0,420,6)` only after a
        // later resize revived it.
        controller.apply(.locked(subtitle: "Manjesh Grand Line is locked."))
        let window = mount(controller.view, width: 1220, height: 720)
        defer { window.contentView = nil }
        controller.view.layoutSubtreeIfNeeded()

        let ribbon = controller.debugRibbonLayer
        let host = controller.debugRibbonViewFrame
        guard host.width > 1, host.height > 1 else {
            return "the ribbon's host view never got bounds, so this check cannot see the bug"
        }
        guard abs(ribbon.frame.width - host.width) < 0.5,
              abs(ribbon.frame.height - host.height) < 0.5 else {
            return "ribbon layer is \(ribbon.frame) inside a \(host) host on first layout - the ribbon is missing until something else forces a relayout"
        }
        // The audit also saw it drawn with square corners overhanging the
        // card's rounded top corner, so verify the clip that must contain it.
        guard controller.debugCard.layer?.masksToBounds == true else {
            return "the card does not clip its subviews, so the ribbon overhangs its rounded corners"
        }
        guard (controller.debugCard.layer?.cornerRadius ?? 0) > 0 else {
            return "the card has no corner radius, so there is nothing for the ribbon to be clipped to"
        }
        return nil
    }

    // MARK: B7

    private static func test_b7() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("SchedulesCardView.swift"), encoding: .utf8) else {
            return nil
        }
        guard text.contains("let toggle = HelmToggle()") else {
            return "the Schedules row toggle is not `HelmToggle` - it shows system-accent chrome next to otherwise fully themed rows under Daylight/Dusk"
        }
        guard !text.contains("let toggle = NSSwitch()") else {
            return "a raw NSSwitch is back in SchedulesCardView"
        }
        // Settings has used the app's own toggle since Phase 4 slice 6; this
        // page was the one that never followed, so pin that they agree.
        guard let settings = try? String(contentsOf: dir.appendingPathComponent("SettingsController.swift"), encoding: .utf8),
              settings.contains("HelmToggle()") else {
            return "Settings no longer uses HelmToggle either - this comparison has lost its reference point"
        }
        return nil
    }

    // MARK: B8

    private static func test_b8() -> String? {
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        guard let dark = HelmTheme.allThemes.first(where: { $0.mode == .dark }),
              let light = HelmTheme.allThemes.first(where: { $0.mode == .light }) else {
            return "could not find both a dark and a light theme to switch between"
        }

        ThemeManager.shared.setTheme(dark)
        let schedule = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 9, minute: 0))
        let sheet = ScheduleHistoryController(schedule: schedule,
                                              historyStore: ScheduleRunHistoryStore(directory: scratchDir()))
        let window = mount(sheet.view, width: 460, height: 480)
        defer { window.contentView = nil }
        let before = (sheet.debugTitleColor, sheet.debugSubtitleColor)

        // A live theme change while the sheet is open. The rows always
        // rebuilt; the heading was coloured once at build time and never again.
        ThemeManager.shared.setTheme(light)
        let after = (sheet.debugTitleColor, sheet.debugSubtitleColor)

        guard let b0 = before.0, let a0 = after.0, let b1 = before.1, let a1 = after.1 else {
            return "the sheet's heading has no colour at all"
        }
        if same(b0, a0) && same(b1, a1) {
            return "the sheet's title and subtitle kept the old theme's ink across a dark -> light switch"
        }
        return nil
    }

    /// Element-wise, never `HelmContrast.ratio(...) < 1.01` - that compares
    /// *luminance*, so two entirely different hues of similar brightness pass
    /// it. Two suites in this repo have already been caught by that.
    private static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.01
            && abs(x.greenComponent - y.greenComponent) < 0.01
            && abs(x.blueComponent - y.blueComponent) < 0.01
    }

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-audit-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: B9

    /// Overview's Health module truncated its note mid-word ("Everything that
    /// has reported i...") despite free card space: a `.ring` body spends 66pt
    /// of the card's width on the gauge, so its note column is much narrower
    /// than a plain `.note` body's, and two lines were not enough.
    private static func test_b9_note() -> String? {
        let card = HelmModuleCard()
        let content = HelmModuleCard.Content(
            title: "Health",
            subtitle: "background services",
            symbol: DaylightModule.health.symbol,
            hue: DaylightModule.health.opens.domainHue,
            chip: nil,
            body: .ring(value: 5, total: 6, title: "Healthy",
                        note: "All reporting services healthy.")
        )
        card.configure(content)
        // The narrowest real column a canvas card is built at.
        let window = mount(card, width: 300, height: HelmModuleCard.standardHeight)
        defer { window.contentView = nil }
        card.layoutSubtreeIfNeeded()

        guard let note = labels(in: card).first(where: { $0.stringValue.contains("reporting services") }) else {
            return "the ring body's note is not rendered"
        }
        guard note.maximumNumberOfLines >= 3 else {
            return "the ring note is capped at \(note.maximumNumberOfLines) line(s) - the column beside a 66pt gauge needs three"
        }
        // The copy has to fit the lines it is given, or the cap alone changes
        // nothing.
        let manager = NSLayoutManager()
        let storage = NSTextStorage(string: note.stringValue,
                                    attributes: [.font: note.font ?? NSFont.systemFont(ofSize: 11)])
        let container = NSTextContainer(size: NSSize(width: max(1, note.frame.width),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            lines += 1
            index = NSMaxRange(range)
        }
        guard lines <= note.maximumNumberOfLines else {
            return "the note needs \(lines) lines at its real \(Int(note.frame.width))pt column but is capped at \(note.maximumNumberOfLines)"
        }
        return nil
    }

    /// "0 Updates Available" while 13 checks are still running is a confident
    /// claim about an answer the page does not have - the same GL-14 shape as
    /// B1. `setupSummaryLine` already applied this rule to the header; the
    /// tiles never followed.
    private static func test_b9_tiles() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("UpdatesController.swift"), encoding: .utf8) else {
            return nil
        }
        guard text.contains("let pending = rows.contains { $0.status == .checking || $0.status == .updating }"),
              text.contains("(pending || neverChecked) ? unknown") else {
            return "the Updates stat tiles no longer distinguish \"not checked yet\" from a real zero"
        }
        // The "Tools Installed" tile is the catalog's own size and must stay a
        // real number throughout - going unknown there would be its own bug.
        guard text.contains("statTiles[0].value = \"\\(total)\"") else {
            return "the Tools Installed tile stopped reporting the catalog size"
        }
        return nil
    }
}

#endif
