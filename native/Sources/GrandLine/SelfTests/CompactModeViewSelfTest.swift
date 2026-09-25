// Grand Line - native macOS app.
//
// F22's **window-backed** half: the real `CompactModePopoverController`
// mounted in a real `NSWindow`, laid out at its real 330pt, with its tabs
// clicked, its capture line submitted and its colours read back out of a real
// render.
//
// **This suite is in `NEEDS_SESSION`**, and per AGENTS.md that classification
// is operative rather than decorative. What is here needs a window: a
// `HelmSegmentedTabs` pill's real click path, whether exactly one of four
// panes is actually laid out, whether the card really holds one fixed size
// across all four tabs, and whether an overdue row's checkbox is painted a
// different colour from a later one. Everything that is a *rule* - the
// policy, the chord, the derivation - is `CompactModeSelfTest` and guards
// CI's blocking lane.
//
// ## The two cases this file exists for
//
//   * `checkExactlyOnePaneIsEverLaidOut`. All four tabs are arranged
//     subviews from the start and exactly one is unhidden, which is the
//     mechanism AGENTS.md gotcha (11) names as the *one* exception to "a
//     hidden view still participates in layout". If that ever regresses to
//     four plain hidden `NSView`s, all four tabs' content stacks up inside
//     the body region at once and nothing else in the app would notice.
//   * `checkThePopoverIsOneFixedSizeOnEveryTab`. The card used to report the
//     active tab's own fitting height, so it changed shape under the
//     captain's hand on every tab switch. See `docs/history/40-menu-bar-mode.md`.
//   * `checkTheEmbeddedPanesAreTheRealControllers`. The Vault and Crew tabs
//     host `PoneglyphMenuBarPopoverController` and
//     `StrawHatMenuBarPopoverController` themselves - the whole point of the
//     reviewed mockup's four tabs - and a future "simplification" into
//     lookalike panes would pass every other check in both suites.
//
// Hermeticity: the suite changes the theme, so it saves and restores
// `ThemeManager.shared.theme` (AGENTS.md's most-repeated operational lesson,
// and `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` fails the run without
// the capture). It builds no store - every pane is handed a snapshot.
//
// `FM_RUN_COMPACT_MODE_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CompactModeViewSelfTest {

    /// `NSApplication.shared`, never `NSApp`.
    ///
    /// AGENTS.md's own trap, hit while writing this file: `NSApp` is nil in a
    /// headless suite *and* is an implicitly-unwrapped `NSApplication!`, so
    /// touching it crashes rather than failing - which reads as a broken
    /// suite rather than a broken assertion. `NSApplication.shared` is what
    /// brings the instance into existence, which is why every other
    /// window-backed suite here spells it that way.
    private static func prepareApp() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private static let todayFixture = CompactTodayDigest(
        rows: [
            CompactTaskRow(id: "overdue", title: "Renew wildcard TLS certificate",
                           detail: "overdue \u{00B7} 16 Sep", urgency: .overdue),
            CompactTaskRow(id: "today", title: "Rotate the prod bastion SSH keys",
                           detail: "due today \u{00B7} High", urgency: .today),
            CompactTaskRow(id: "later", title: "Review OTel collector Helm values",
                           detail: "tomorrow", urgency: .later),
        ],
        overdueCount: 1,
        focusChip: "17:24 focus",
        followUpChip: "2 follow-ups")

    private static let notesFixture = [
        CompactNoteRow(id: "n1", title: "Ask about the invoice fee", detail: "call the bank",
                       color: .yellow),
        CompactNoteRow(id: "n2", title: "Trip", detail: "2 of 3 done", color: .pink),
    ]

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        prepareApp()
        // Saved and restored around the whole run - persisting a theme
        // selection is correct behaviour for the app, so the fix belongs at
        // the test rather than at the write site.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        checkTheChromeIsTheMockupsChrome(check)
        checkExactlyOnePaneIsEverLaidOut(check)
        checkClickingATabReallySwitchesIt(check)
        checkTheEmbeddedPanesAreTheRealControllers(check)
        checkTheCaptureLineOnlyExistsWhereItCanWrite(check)
        checkAFiledCaptureClearsAndARefusalDoesNot(check)
        checkThePopoverIsOneFixedSizeOnEveryTab(check)
        checkTheChromeDoesNotMoveBetweenTabs(check)
        checkATallTabScrollsRatherThanGrows(check)
        checkUrgencyIsPaintedNotJustStated(check)
        checkTheChipsClearTheContrastFloor(check)
        checkEmptyStatesAppearRatherThanBlankRows(check)
        checkClickingARowReachesTheStore(check)
        checkTheSettingsCardCarriesAllThreeToggles(check)
        checkTheModeTransitionDoesTheFourThings(check)
        checkTheWindowIsHiddenOnlyOnTheWayIn(check)
        checkAWindowIsHiddenWhenTheModeIsAlreadyOnAtLaunch(check)
        checkTheMainWindowIsNotReleasedWhenClosed(check)
        checkLeavingTheModeTurnsItOff(check)
        checkTheLockRefusesThePopover(check)
        checkLockedShowsAnUnlockFormInsteadOfTabs(check)
        checkIconClickedShowsTheLockFormRatherThanRefusing(check)

        print(ok ? "CompactModeViewSelfTest: OK" : "CompactModeViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Harness

    /// One popover content controller, in a real window, laid out at its own
    /// 330pt.
    ///
    /// `autoreleasepool` is mandatory around AppKit construct/teardown in a
    /// headless suite - nothing turns the run loop, so removed views are never
    /// drained and a healthy view reads as a leak.
    private static func mounted(theme: HelmTheme? = nil,
                                filer: CaptureFiler = .unwired,
                                body: (CompactModePopoverController, NSWindow) -> Void) {
        autoreleasepool {
            if let theme { ThemeManager.shared.setTheme(theme) }
            let current = ThemeManager.shared.theme
            let controller = CompactModePopoverController()
            controller.todayProvider = { todayFixture }
            controller.notesProvider = { notesFixture }
            controller.vaultCodesProvider = { [] }
            controller.vaultUnlockedProvider = { false }
            controller.captureFiler = filer

            // `OffScreenProbe.window(...)`, never a hand-rolled `NSWindow` - a
            // hand-rolled one is *not* off-screen whatever origin it is given,
            // and these were caught live on the captain's own display.
            let window = OffScreenProbe.window(width: CompactModePopoverController.width + 40,
                                               height: 620)
            window.contentViewController = controller
            controller.applyTheme(current)
            controller.prepareToShow()
            controller.view.layoutSubtreeIfNeeded()
            body(controller, window)
            window.contentViewController = nil
            window.close()
        }
    }

    private static func lightTheme() -> HelmTheme {
        HelmTheme.allThemes.first { $0.mode == .light } ?? ThemeManager.shared.theme
    }

    private static func darkTheme() -> HelmTheme {
        // Dusk is the app's own default, so it is the register the captain
        // actually sees.
        HelmTheme.allThemes.first { $0.id == "dusk" }
            ?? HelmTheme.allThemes.first { $0.mode == .dark }
            ?? ThemeManager.shared.theme
    }

    /// A filer that records what it was asked to file and answers however the
    /// case needs - the seam `CaptureFiler` exists for.
    private final class RecordingFiler {
        private(set) var filed: [(CaptureDestination, CaptureDraft)] = []
        var outcome: (CaptureDestination) -> CaptureFilingOutcome = { .filed($0) }

        var filer: CaptureFiler {
            CaptureFiler { [self] destination, draft in
                filed.append((destination, draft))
                return outcome(destination)
            }
        }
    }

    // MARK: Cases

    private static func checkTheChromeIsTheMockupsChrome(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            check(abs(controller.view.frame.width - CompactModePopoverController.width) < 0.5,
                  "the popover lays out at the reviewed mockup's 330pt - got "
                      + "\(controller.view.frame.width)")
            let labels = allSubviews(of: controller.view).compactMap { $0 as? NSTextField }
                .map { $0.stringValue }
            check(labels.contains("Grand Line"),
                  "the header names the app, which in compact mode is all the branding there is")
            check(labels.contains("compact mode"),
                  "and says which mode this is - the mockup's own caption")
            check(controller.debugSelectedTab == .today,
                  "Today is the tab the popover opens on")
            let titles = allSubviews(of: controller.debugTabs).compactMap { $0 as? NSTextField }
                .map { $0.stringValue }
            for tab in CompactModeTab.allCases {
                check(titles.contains(tab.title),
                      "the segmented header carries a real \(tab.title) pill - the mockup's "
                          + "judgment call is four tabs, not a menu")
            }
            // The mockup's four equal full-width segments. Measured rather
            // than assumed, because getting this by pinning both edges of a
            // `.gravityAreas` stack is gotcha (10) - leftover width resolved
            // by Auto Layout's tie-breaking, which drifts with no code
            // change. `HelmSegmentedTabs(equalWidths:)` is the explicit
            // distribution that makes it deterministic.
            let pills = controller.debugTabs.debugPillsForAccessibilityTests()
            check(pills.count == CompactModeTab.allCases.count,
                  "four pills - got \(pills.count)")
            let widths = pills.map { $0.frame.width }
            check(widths.allSatisfy { $0 > 1 },
                  "every pill has a real laid-out width, or the equality below is vacuous - got "
                      + "\(widths)")
            if let first = widths.first {
                check(widths.allSatisfy { abs($0 - first) < 1 },
                      "and all four are equal, which is what `equalWidths` buys - got \(widths)")
            }
            let strip = controller.debugTabs.frame.width
            check(strip > CompactModePopoverController.width * 0.85,
                  "and the strip spans the popover rather than sitting narrow and left-aligned - "
                      + "got \(strip) of \(CompactModePopoverController.width)")

            check(controller.debugOpenWindowButton.title == "Open full window",
                  "the footer's way out of the mode is a real button - got "
                      + "\(controller.debugOpenWindowButton.title)")
        }
    }

    private static func checkExactlyOnePaneIsEverLaidOut(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            for tab in CompactModeTab.allCases {
                controller.select(tab)
                controller.view.layoutSubtreeIfNeeded()
                check(controller.debugVisiblePaneCount == 1,
                      "on \(tab.title), exactly one of the four panes is unhidden - got "
                          + "\(controller.debugVisiblePaneCount). All four are arranged subviews "
                          + "from the start, and a hidden arranged subview of an `NSStackView` is "
                          + "gotcha (11)'s one named exception to \"a hidden view still "
                          + "participates in layout\"")
            }
        }
    }

    private static func checkClickingATabReallySwitchesIt(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            // The real click path through the real component, not
            // `select(_:)` - a pill whose gesture recogniser was never wired
            // would pass a `select` test perfectly.
            controller.debugTabs.debugClickTab(id: CompactModeTab.notes.rawValue)
            controller.view.layoutSubtreeIfNeeded()
            check(controller.debugSelectedTab == .notes,
                  "clicking the Notes pill switches the tab - got \(controller.debugSelectedTab)")
            check(controller.debugNotesPane.debugRowTitles == notesFixture.map { $0.title },
                  "and the Notes pane rendered the rows it was handed - got "
                      + "\(controller.debugNotesPane.debugRowTitles)")
            controller.debugTabs.debugClickTab(id: CompactModeTab.today.rawValue)
            controller.view.layoutSubtreeIfNeeded()
            check(controller.debugSelectedTab == .today,
                  "and back again")
        }
    }

    private static func checkTheEmbeddedPanesAreTheRealControllers(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            // **The type itself is the guarantee, and it is enforced at
            // compile time**: `vaultPane` is declared
            // `PoneglyphMenuBarPopoverController` and `crewPane`
            // `StrawHatMenuBarPopoverController`, so swapping either for a
            // lookalike is a change that stops this file compiling. A runtime
            // `is` check here would be exactly the vacuous assertion
            // AGENTS.md warns about - the compiler says so out loud ("'is'
            // test is always true"), and CI fails the build on any warning.
            // So what is asserted below is the *observable* half a lookalike
            // could get wrong: the real controller's own locked-state copy,
            // its child-controller hosting, its suppressed header and its
            // width.
            check(controller.children.contains(controller.vaultPane)
                      && controller.children.contains(controller.crewPane),
                  "and both are hosted as real child view controllers, so AppKit drives their "
                      + "lifecycle rather than the popover having to imitate it")
            // Their own headers are suppressed, or the popover shows three
            // titles at once.
            controller.select(.vault)
            controller.view.layoutSubtreeIfNeeded()
            let vaultLabels = allSubviews(of: controller.vaultPane.view)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.stringValue }
            // The real controller's own GL-14 wording for a locked vault. A
            // lookalike pane would have to reproduce this string to pass,
            // which is the point.
            check(vaultLabels.contains(where: { $0.hasPrefix("Poneglyph is locked.") }),
                  "the Vault tab renders `PoneglyphMenuBarPopoverController`'s own locked-vault "
                      + "state - the countdown rings, the copy flash and this copy are that "
                      + "file's, not a reimplementation. Visible labels: \(vaultLabels)")
            check(!vaultLabels.contains("Poneglyph"),
                  "the embedded vault pane hides its own header - the popover already says "
                      + "\"Grand Line\", and two titles is the thing merging these was meant to "
                      + "avoid. Visible labels: \(vaultLabels)")
            check(abs(controller.vaultPane.view.frame.width - CompactModePopoverController.width) < 0.5,
                  "the embedded pane lays out at the popover's width rather than its own 300 - a "
                      + "required 300 inside a 330pt popover is a constraint conflict, and per "
                      + "gotcha (13) a required content width over priority 500 is a window-size "
                      + "cap. Got \(controller.vaultPane.view.frame.width)")
        }
    }

    private static func checkTheCaptureLineOnlyExistsWhereItCanWrite(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            for tab in CompactModeTab.allCases {
                controller.select(tab)
                controller.view.layoutSubtreeIfNeeded()
                let expectHidden = tab.captureDestination == nil
                check(controller.debugCaptureRowIsHidden == expectHidden,
                      "on \(tab.title) the capture line should be "
                          + (expectHidden ? "hidden" : "showing")
                          + " - the Vault takes no typed credential material and the Crew pane "
                          + "already owns an ask field")
                if !expectHidden {
                    check(controller.debugCaptureField.placeholderString == tab.capturePlaceholder,
                          "and its placeholder names what return will actually do on \(tab.title) - "
                              + "got \(controller.debugCaptureField.placeholderString ?? "nil")")
                }
            }
        }
    }

    private static func checkAFiledCaptureClearsAndARefusalDoesNot(_ check: (Bool, String) -> Void) {
        let recorder = RecordingFiler()
        mounted(filer: recorder.filer) { controller, _ in
            controller.select(.notes)
            controller.debugCaptureField.stringValue = "call the bank about the fee"
            controller.debugSubmitCapture()
            check(recorder.filed.count == 1 && recorder.filed.first?.0 == .sticky,
                  "a capture typed on the Notes tab files a sticky note through the same "
                      + "`CaptureFiler` \u{2325}Space uses - got \(recorder.filed.map { $0.0 })")
            check(recorder.filed.first?.1.title == "call the bank about the fee",
                  "and the draft carries what was typed - got \(recorder.filed.first?.1.title ?? "nil")")
            check(controller.debugCaptureField.stringValue.isEmpty,
                  "a filed capture clears the field, so a second one does not append to the first")
            check(controller.debugCaptureNotice == nil,
                  "and says nothing - the row appearing is the confirmation")

            controller.select(.today)
            check(controller.debugCaptureField.stringValue.isEmpty,
                  "switching tabs clears the field, so text meant for a note is never filed as a task")

            recorder.outcome = { _ in .refused("Capture isn\u{2019}t wired to the app yet.") }
            controller.debugCaptureField.stringValue = "renew the cert tomorrow"
            controller.debugSubmitCapture()
            check(controller.debugCaptureField.stringValue == "renew the cert tomorrow",
                  "a refused capture keeps the typed text - losing a capture to a failure is the "
                      + "one outcome \u{2325}Space's own panel refuses to allow, and this is the "
                      + "same rule. Got \(controller.debugCaptureField.stringValue)")
            check(controller.debugCaptureNotice?.isEmpty == false,
                  "and the reason is shown rather than swallowed - `CaptureFilingOutcome.refused` "
                      + "carries it precisely so nothing drops it")

            let before = recorder.filed.count
            controller.debugCaptureField.stringValue = "   \n  "
            controller.debugSubmitCapture()
            check(recorder.filed.count == before,
                  "whitespace alone files nothing")
        }
    }

    /// **The regression this branch exists for.**
    ///
    /// The popover used to report `view.fittingSize.height`, so its frame was
    /// whatever the active tab's content happened to want - four different
    /// cards for one surface, which is what the captain reported. Both
    /// themes, because a Daylight restyle changes row metrics and a fix that
    /// only holds in Dusk is not a fix.
    ///
    /// The first check is the one that stops this passing vacuously: the four
    /// tabs' *content* has to really differ in natural height, or "the outer
    /// frame is the same on all four" is a statement about nothing.
    private static func checkThePopoverIsOneFixedSizeOnEveryTab(_ check: (Bool, String) -> Void) {
        for theme in [lightTheme(), darkTheme()] {
            mounted(theme: theme) { controller, _ in
                var reported: [CompactModeTab: NSSize] = [:]
                var outer: [CompactModeTab: NSSize] = [:]
                var content: [CompactModeTab: CGFloat] = [:]
                for tab in CompactModeTab.allCases {
                    var size = NSSize.zero
                    controller.onSizeChanged = { size = $0 }
                    controller.select(tab)
                    controller.debugRenderPane()
                    controller.view.layoutSubtreeIfNeeded()
                    reported[tab] = size
                    outer[tab] = controller.view.frame.size
                    content[tab] = controller.debugBodyScroll.documentView?.fittingSize.height ?? 0
                }
                controller.onSizeChanged = nil

                let naturalHeights = Set(content.values.map { ($0 * 2).rounded() })
                check(naturalHeights.count > 1,
                      "\(theme.name): the four tabs' own content really is different heights, or "
                          + "the equality below asserts nothing - got \(content)")
                check(content.values.allSatisfy { $0 > 1 },
                      "\(theme.name): and every tab lays out real content - a zero would make the "
                          + "fixed frame trivially true. Got \(content)")

                let expected = CompactModePopoverController.contentSize
                for tab in CompactModeTab.allCases {
                    let got = reported[tab] ?? .zero
                    check(abs(got.width - expected.width) < 0.5
                              && abs(got.height - expected.height) < 0.5,
                          "\(theme.name): the \(tab.title) tab reports the popover's one fixed "
                              + "content size \(expected) - got \(got)")
                    let laid = outer[tab] ?? .zero
                    check(abs(laid.width - expected.width) < 0.5
                              && abs(laid.height - expected.height) < 0.5,
                          "\(theme.name): and really lays out at it - got \(laid)")
                }
            }
        }
    }

    /// The half the captain actually sees: the tab strip and the footer at
    /// the same coordinates on every tab. An outer frame that matched while
    /// the chrome inside it slid around would still read as the same bug.
    private static func checkTheChromeDoesNotMoveBetweenTabs(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            var frames: [CompactModeTab: [String: NSRect]] = [:]
            for tab in CompactModeTab.allCases {
                controller.select(tab)
                controller.debugRenderPane()
                controller.view.layoutSubtreeIfNeeded()
                frames[tab] = controller.debugChromeFrames
            }
            guard let reference = frames[.today] else { return }
            check(reference.values.allSatisfy { $0.width > 1 && $0.height > 1 },
                  "every piece of chrome is really laid out, or the comparison below is vacuous - "
                      + "got \(reference)")
            // The body region itself is allowed to change - Vault and Crew
            // take no capture line, so it grows into that row's space. The
            // header, the tab strip and the footer are not.
            for key in ["header", "tabs", "footer"] {
                for tab in CompactModeTab.allCases where tab != .today {
                    let a = reference[key] ?? .zero
                    let b = frames[tab]?[key] ?? .zero
                    check(abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
                              && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5,
                          "the \(key) sits at the same place on Today and on \(tab.title) - "
                              + "got \(a) and \(b)")
                }
            }
        }
    }

    /// A tab taller than the fixed region scrolls inside it. This is the case
    /// the old "size to the content" shape handled by growing the card, so it
    /// is the one a fixed size could have broken by clipping instead.
    private static func checkATallTabScrollsRatherThanGrows(_ check: (Bool, String) -> Void) {
        let crowded = CompactTodayDigest(
            rows: (0..<CompactModeDigest.maxRows).map {
                CompactTaskRow(id: "t\($0)",
                               title: "A task with a title long enough to wrap onto a second line "
                                   + "in a 330pt popover, number \($0)",
                               detail: "overdue \u{00B7} 16 Sep", urgency: .overdue)
            },
            overdueCount: CompactModeDigest.maxRows,
            focusChip: "17:24 focus",
            followUpChip: "2 follow-ups")

        mounted { controller, _ in
            controller.todayProvider = { crowded }
            controller.select(.notes)
            controller.select(.today)
            controller.debugRenderPane()
            controller.view.layoutSubtreeIfNeeded()

            let scroll = controller.debugBodyScroll
            let documentHeight = scroll.documentView?.fittingSize.height ?? 0
            let viewport = scroll.contentView.bounds.height
            check(documentHeight > viewport,
                  "the crowded fixture really does overflow the fixed body region, or this case "
                      + "proves nothing - document \(documentHeight) against viewport \(viewport)")
            check(abs(controller.view.frame.height - CompactModePopoverController.height) < 0.5,
                  "and the popover is still its one fixed height rather than having grown to fit - "
                      + "got \(controller.view.frame.height)")
            check(scroll.contentView.bounds.origin.y < 0.5,
                  "and the overflowing tab opens at its top rather than mid-content - got "
                      + "\(scroll.contentView.bounds.origin.y)")
        }
    }

    private static func checkUrgencyIsPaintedNotJustStated(_ check: (Bool, String) -> Void) {
        for theme in [lightTheme(), darkTheme()] {
            mounted(theme: theme) { controller, _ in
                controller.select(.today)
                controller.view.layoutSubtreeIfNeeded()
                let rows = controller.debugTodayPane.debugRows
                check(rows.count == todayFixture.rows.count,
                      "\(theme.name): the Today pane renders one row per task - got \(rows.count)")
                guard rows.count == 3 else { return }
                let overdue = rows[0]
                let dueToday = rows[1]
                let later = rows[2]
                check(overdue.debugUrgency == .overdue && later.debugUrgency == .later,
                      "\(theme.name): the fixture must really carry different urgencies, or the "
                          + "colour comparison below cannot fail")

                // Element-wise components, never `HelmContrast.ratio(a, b) <
                // 1.01` - that compares relative *luminance*, so two
                // different hues of similar brightness pass it as "equal"
                // (AGENTS.md's own note).
                let a = HelmContrast.components(overdue.debugCheckboxBorderColor)
                let b = HelmContrast.components(later.debugCheckboxBorderColor)
                let c = HelmContrast.components(dueToday.debugCheckboxBorderColor)
                check(!componentsMatch(a, b),
                      "\(theme.name): an overdue row's checkbox must not be painted the same "
                          + "colour as one due later - the urgency is the whole point of the row. "
                          + "Got \(a) vs \(b)")
                check(!componentsMatch(c, b),
                      "\(theme.name): nor a row due today - got \(c) vs \(b)")
                check(!componentsMatch(a, c),
                      "\(theme.name): overdue and due-today are different states and read "
                          + "differently (GL-14) - got \(a) vs \(c)")

                // GL-16: never colour alone. The caption says it in words too.
                check(overdue.debugDetail.contains("overdue"),
                      "\(theme.name): and the overdue row says so in words, so the state survives "
                          + "for anyone who cannot see the hue - got \(overdue.debugDetail)")

                let ink = HelmTheme.nsColor(theme.chromeInkHex)
                check(componentsMatch(HelmContrast.components(overdue.debugCheckboxBorderColor),
                                      HelmContrast.components(ink)) == false,
                      "\(theme.name): the overdue border is a real hue, not page ink")
            }
        }
    }

    private static func checkTheChipsClearTheContrastFloor(_ check: (Bool, String) -> Void) {
        for theme in [lightTheme(), darkTheme()] {
            mounted(theme: theme) { controller, _ in
                controller.select(.today)
                controller.view.layoutSubtreeIfNeeded()
                check(!controller.debugTodayPane.debugChipsAreHidden,
                      "\(theme.name): the fixture supplies both chips, so they must be showing - "
                          + "otherwise the contrast check below is vacuous")
                check(controller.debugTodayPane.debugChipTexts == ["17:24 focus", "2 follow-ups"],
                      "\(theme.name): both chips render what they were handed - got "
                          + "\(controller.debugTodayPane.debugChipTexts)")
                let chips = allSubviews(of: controller.debugTodayPane).compactMap { $0 as? CompactChip }
                    .filter { !$0.isHidden }
                check(chips.count == 2,
                      "\(theme.name): two chips - got \(chips.count)")
                for chip in chips {
                    let ratio = HelmContrast.ratio(HelmContrast.components(chip.debugTextColor),
                                                   HelmContrast.components(chip.debugFillColor))
                    check(ratio >= HelmContrast.textTarget - 0.01,
                          "\(theme.name): \"\(chip.debugText)\" is text on a tinted fill, so it has "
                              + "to clear \(HelmContrast.textTarget):1 - a `HelmTint` hue is safe "
                              + "as a fill and is NOT automatically safe as text. Got "
                              + String(format: "%.2f", ratio))
                }
            }
        }
    }

    private static func checkEmptyStatesAppearRatherThanBlankRows(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let controller = CompactModePopoverController()
            controller.todayProvider = { .empty }
            controller.notesProvider = { [] }
            controller.vaultCodesProvider = { [] }
            controller.vaultUnlockedProvider = { false }
            let window = OffScreenProbe.window(width: CompactModePopoverController.width + 40,
                                               height: 480)
            window.contentViewController = controller
            controller.applyTheme(ThemeManager.shared.theme)
            controller.prepareToShow()
            controller.view.layoutSubtreeIfNeeded()

            check(!controller.debugTodayPane.debugEmptyStateIsHidden,
                  "nothing due shows a real empty state, not an empty stack")
            check(controller.debugTodayPane.debugRowTitles.isEmpty,
                  "and no rows")
            check(controller.debugTodayPane.debugChipsAreHidden,
                  "and no chips - the divider under them would otherwise be a rule under nothing")

            controller.select(.notes)
            controller.view.layoutSubtreeIfNeeded()
            check(!controller.debugNotesPane.debugEmptyStateIsHidden,
                  "an empty Sticky Board shows an empty state too")

            window.contentViewController = nil
            window.close()
        }
    }

    private static func checkClickingARowReachesTheStore(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            var completed: [(String, Bool)] = []
            var revealed: [String] = []
            var dismissals = 0
            controller.onSetTaskCompleted = { completed.append(($0, $1)) }
            controller.onRevealNote = { revealed.append($0) }
            controller.onDismiss = { dismissals += 1 }

            controller.select(.today)
            controller.view.layoutSubtreeIfNeeded()
            controller.debugTodayPane.debugRows.first?.debugClick()
            check(completed.count == 1 && completed.first?.0 == "overdue" && completed.first?.1 == true,
                  "clicking a task row's checkbox completes that task through the shared store - "
                      + "got \(completed)")

            controller.select(.notes)
            controller.view.layoutSubtreeIfNeeded()
            controller.debugNotesPane.debugRows.first?.debugClick()
            check(revealed == ["n1"],
                  "clicking a note row opens the board on that note rather than just on the board - "
                      + "got \(revealed)")
            check(dismissals >= 1,
                  "and closes the popover, since the window it just navigated is now the surface")

            // GL-16: the row is a `HoverHighlightView`, so the role, label,
            // focus ring and keyboard press all come from that one component.
            let rows = controller.debugNotesPane.debugRows
            check(rows.allSatisfy { $0.isActivatable },
                  "every row announces itself as activatable, which is what gives it a focus ring "
                      + "and a keyboard press")
            check(rows.allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false },
                  "and carries a real accessibility label")
        }
    }

    private static func checkTheSettingsCardCarriesAllThreeToggles(_ check: (Bool, String) -> Void) {
        // The mode's discoverable home. Mounted rather than grepped: a card
        // that is built but never added to `cardsInOrder` renders nowhere,
        // and a source guard would not notice.
        autoreleasepool {
            let saved = (AppSettings.shared.compactModeEnabled,
                         AppSettings.shared.compactModeHidesDockIcon,
                         AppSettings.shared.compactModeBadgesOverdueCount)
            defer {
                AppSettings.shared.compactModeEnabled = saved.0
                AppSettings.shared.compactModeHidesDockIcon = saved.1
                AppSettings.shared.compactModeBadgesOverdueCount = saved.2
            }

            let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                              snippetStore: SnippetStore(),
                                              dictationStore: DictationStore())
            let window = OffScreenProbe.window(width: 1000, height: 800)
            window.contentViewController = settings
            settings.view.layoutSubtreeIfNeeded()
            // `fm/grandline-settings-page-sidebar-redesign` made Settings a
            // master/detail page, and compact mode's discoverable home is now
            // the "Menu bar" category rather than a card somewhere down one
            // long scroll. Driven through the sidebar's own row handler, so
            // this also asserts the row exists and reaches the pane - a
            // stronger claim than the tree walk alone made.
            settings.debugSidebar.debugClickRow(id: SettingsController.Category.menuBar.rawValue)
            settings.view.layoutSubtreeIfNeeded()
            check(settings.debugSelectedCategory == .menuBar,
                  "the \"Menu bar\" sidebar row reaches compact mode's own pane")

            let labels = allSubviews(of: settings.view).compactMap { $0 as? NSTextField }
                .map { $0.stringValue }
            // The copy is the captain's own reference's now
            // (`fm/grandline-settings-page-redesign`), which renamed two of
            // these three rows. "Compact mode" is a section heading beside the
            // group rather than a card header title, and it is still a real
            // rendered label on the page - which is what this case has always
            // asserted.
            check(labels.contains("Compact mode"),
                  "Settings carries a real \"Compact mode\" section - the mode's discoverable home")
            check(labels.contains("Live in the menu bar"),
                  "with the master switch's own row")
            check(labels.contains("Hide the Dock icon"),
                  "the Dock-icon row")
            check(labels.contains("Show the overdue count on the icon"),
                  "and the badge row - the reference's own three")
            check(settings.debugToggles.count >= 6,
                  "and three more `HelmToggle`s than the page had before - got "
                      + "\(settings.debugToggles.count)")

            // The toggles really write, rather than only looking like they do.
            var callbacks = 0
            settings.onCompactModeSettingsChanged = { callbacks += 1 }
            AppSettings.shared.compactModeEnabled = false
            // The real activation path, the way `DaylightDrillPageSlice6SelfTest`
            // already drives this control - `HelmToggle` renders a pill on
            // Daylight and a stock `NSSwitch` elsewhere, and the accessibility
            // press is the one entry point both branches share.
            _ = settings.debugCompactModeSwitch.accessibilityPerformPress()
            check(settings.debugCompactModeSwitch.isOn,
                  "pressing the master switch turns it on")
            check(AppSettings.shared.compactModeEnabled == settings.debugCompactModeSwitch.isOn,
                  "and persists it, or the mode would not survive a relaunch - switch is "
                      + "\(settings.debugCompactModeSwitch.isOn), setting is "
                      + "\(AppSettings.shared.compactModeEnabled)")
            check(callbacks == 1,
                  "and tells the app exactly once, so `CompactModeController.refresh()` applies all "
                      + "three settings together rather than three partial times - got \(callbacks)")

            window.contentViewController = nil
            window.close()
        }
    }

    // MARK: The mode transition, against the real controller

    /// One real `CompactModeController`, with the three real settings and the
    /// process's own activation policy saved and restored around it.
    ///
    /// The controller reads `AppSettings.shared` (not an injected store) on
    /// every `refresh()`, because that is the behaviour being asserted - the
    /// settings are the input to the transition. So this saves and restores
    /// the captain's real three rather than pretending otherwise, which is
    /// the same honest choice every suite here makes around
    /// `AppSettings.uiTextScale`.
    private static func withController(
        _ body: (CompactModeController, _ setMode: (Bool, Bool) -> Void) -> Void
    ) {
        autoreleasepool {
            let saved = (AppSettings.shared.compactModeEnabled,
                         AppSettings.shared.compactModeHidesDockIcon,
                         AppSettings.shared.compactModeBadgesOverdueCount)
            let savedPolicy = NSApplication.shared.activationPolicy()
            defer {
                AppSettings.shared.compactModeEnabled = saved.0
                AppSettings.shared.compactModeHidesDockIcon = saved.1
                AppSettings.shared.compactModeBadgesOverdueCount = saved.2
                NSApplication.shared.setActivationPolicy(savedPolicy)
            }
            AppSettings.shared.compactModeEnabled = false
            AppSettings.shared.compactModeHidesDockIcon = false
            AppSettings.shared.compactModeBadgesOverdueCount = false

            let content = CompactModePopoverController()
            content.todayProvider = { todayFixture }
            content.notesProvider = { notesFixture }
            content.vaultCodesProvider = { [] }
            content.vaultUnlockedProvider = { false }
            let controller = CompactModeController(content: content)
            controller.overdueCountProvider = { todayFixture.overdueCount }
            body(controller) { enabled, hidesDock in
                AppSettings.shared.compactModeEnabled = enabled
                AppSettings.shared.compactModeHidesDockIcon = hidesDock
                controller.refresh()
            }
        }
    }

    private static func checkTheModeTransitionDoesTheFourThings(_ check: (Bool, String) -> Void) {
        withController { controller, setMode in
            var perFeatureVisible: [Bool] = []
            controller.perFeatureStatusItemVisibility = { perFeatureVisible.append($0) }

            setMode(false, false)
            check(!controller.debugStatusItemIsVisible,
                  "with the mode off, the merged status item is not in the menu bar")
            check(perFeatureVisible.last == true,
                  "and the three items it merges are - got \(String(describing: perFeatureVisible.last))")
            check(!controller.debugHotkeyIsInstalled,
                  "\u{2303}\u{2325}G is not installed while there is no popover for it to open - a "
                      + "monitor nothing can reach is exactly what `snippetExpansionEnabled`'s own "
                      + "note refuses to leave installed and ignored")
            check(NSApplication.shared.activationPolicy() == .regular,
                  "and the app is a regular, Dock-visible app")

            setMode(true, true)
            check(controller.debugStatusItemIsVisible,
                  "with the mode on, the merged status item appears")
            check(perFeatureVisible.last == false,
                  "the three it merges are hidden - four items where one contains the other three "
                      + "is the state the mockup rules out")
            check(controller.debugHotkeyIsInstalled,
                  "the hotkey is installed")
            check(NSApplication.shared.activationPolicy() == .accessory,
                  "and with the Dock switch on too, the app runs as a menu-bar accessory")

            setMode(false, true)
            check(!controller.debugStatusItemIsVisible && perFeatureVisible.last == true,
                  "turning the mode off puts the three items back and hides the merged one")
            check(!controller.debugHotkeyIsInstalled,
                  "and tears the hotkey monitor down rather than leaving it installed")
            check(NSApplication.shared.activationPolicy() == .regular,
                  "and restores the Dock icon even though the Dock switch is still on - which is "
                      + "the thing that stops the captain being left with no way back to the window")
        }
    }

    private static func checkTheWindowIsHiddenOnlyOnTheWayIn(_ check: (Bool, String) -> Void) {
        withController { controller, setMode in
            var hides = 0
            controller.onHideMainWindow = { hides += 1 }

            setMode(false, false)
            check(hides == 0, "a refresh with the mode off never hides the window")

            setMode(true, false)
            check(hides == 1, "switching the mode on hides the main window once - got \(hides)")

            // The badge toggle is the realistic case: it calls `refresh()`
            // with the mode already on, and must not re-hide a window the
            // captain has deliberately brought back with "Open full window"
            // (which leaves the mode on).
            AppSettings.shared.compactModeBadgesOverdueCount = true
            controller.refresh()
            controller.refresh()
            check(hides == 1,
                  "and a later refresh while already in the mode does NOT hide it again - got "
                      + "\(hides). Otherwise flipping the badge switch would close a window the "
                      + "captain had just reopened")
        }
    }


    /// **Review bug B8**, the stale window at launch.
    ///
    /// `refresh()` hides the window only on the transition `!previous.isEnabled`,
    /// and `policy` was seeded with `.current()` - so on a session that starts
    /// with compact mode already on, `previous` and `policy` were identical on
    /// the very first refresh and the transition never happened. Every other
    /// part of the mode came up correctly (the merged status item, the hotkey,
    /// the activation policy); only the one thing the mode is *for* did not.
    ///
    /// Deliberately constructs its own controller rather than using
    /// `withController`, because that harness forces the settings off before
    /// constructing one - which is the launch this bug does **not** affect.
    /// The setting has to already be on when the controller is born.
    private static func checkAWindowIsHiddenWhenTheModeIsAlreadyOnAtLaunch(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let saved = (AppSettings.shared.compactModeEnabled,
                         AppSettings.shared.compactModeHidesDockIcon,
                         AppSettings.shared.compactModeBadgesOverdueCount)
            let savedPolicy = NSApplication.shared.activationPolicy()
            defer {
                AppSettings.shared.compactModeEnabled = saved.0
                AppSettings.shared.compactModeHidesDockIcon = saved.1
                AppSettings.shared.compactModeBadgesOverdueCount = saved.2
                NSApplication.shared.setActivationPolicy(savedPolicy)
            }

            // The captain left the mode on last session. This is what launch
            // reads, before any controller exists.
            AppSettings.shared.compactModeEnabled = true
            AppSettings.shared.compactModeHidesDockIcon = false
            AppSettings.shared.compactModeBadgesOverdueCount = false

            let content = CompactModePopoverController()
            content.todayProvider = { todayFixture }
            content.notesProvider = { notesFixture }
            content.vaultCodesProvider = { [] }
            content.vaultUnlockedProvider = { false }
            let controller = CompactModeController(content: content)
            var hides = 0
            controller.onHideMainWindow = { hides += 1 }

            // `main.swift`'s launch order: build the window, order it front,
            // then one `refresh()`.
            controller.refresh()
            check(hides == 1,
                  "a session that starts with compact mode already on must hide the main window on "
                  + "its first refresh - it hid \(hides) time(s), so the captain gets a full window "
                  + "with the mode otherwise fully engaged (B8)")
            check(controller.policy.isEnabled,
                  "and the policy really is enabled, or the check above is vacuous")
            check(controller.debugStatusItemIsVisible,
                  "and the rest of the mode came up too, which is what made this easy to miss")

            // The gate it must not break: a second refresh while already in
            // the mode does not re-hide a window brought back with "Open full
            // window".
            controller.refresh()
            check(hides == 1,
                  "and a later refresh while already in the mode does not hide it again - got \(hides)")
        }
    }

    /// B8's second half: the main window must refuse to be released when
    /// closed.
    ///
    /// In compact mode `applicationShouldTerminateAfterLastWindowClosed` is
    /// `false`, so the red button closes the main window while the process
    /// keeps running - and with the AppKit default (`true` for a window built
    /// with `init(contentRect:)`) that *releases* a window `AppDelegate.window`,
    /// the resize observers, `FullScreenMenuBarFill` and
    /// `WindowChromeFusion`'s cluster cache all still hold. Reproduced live on
    /// this branch with an env-gated probe: the unfixed binary exited 139
    /// (SIGSEGV) on the first access to `self.window` after `performClose`.
    ///
    /// A source guard, because the crash is a use-after-free in `main.swift`'s
    /// own window and `AppDelegate` cannot be constructed headlessly (`NSApp`
    /// is nil - AGENTS.md's own rule). Scoped to the window's construction so
    /// the host editor's identical line two hundred lines below cannot satisfy
    /// it.
    private static func checkTheMainWindowIsNotReleasedWhenClosed(_ check: (Bool, String) -> Void) {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8)
        else {
            check(false, "main.swift could not be read, so this guard checked nothing")
            return
        }
        guard let start = text.range(of: "window = NSWindow(") else {
            check(false, "main.swift no longer builds its window the way this guard expects")
            return
        }
        guard let end = text.range(of: "window.contentViewController = appShell", range: start.upperBound..<text.endIndex) else {
            check(false, "could not find the end of the window's construction")
            return
        }
        let construction = String(text[start.upperBound..<end.lowerBound])
        // Discriminating power: the extracted region has to be the real one.
        check(construction.contains("WindowChromeFusion.apply(to: window)"),
              "the extracted window construction does not look like the real one")
        check(construction.contains("window.isReleasedWhenClosed = false"),
              "the main window must set isReleasedWhenClosed = false. In compact mode the red "
              + "button closes it without quitting, and AppDelegate.window still points at it (B8)")
    }

    private static func checkLeavingTheModeTurnsItOff(_ check: (Bool, String) -> Void) {
        withController { controller, setMode in
            setMode(true, true)
            check(AppSettings.shared.compactModeEnabled,
                  "in the mode, before leaving it")
            controller.exitCompactMode()
            check(!AppSettings.shared.compactModeEnabled,
                  "\"Open full window\" writes the setting off rather than only raising the "
                      + "window - a mode you can leave but which is still on next launch is not a "
                      + "mode anyone can get out of")
            check(NSApplication.shared.activationPolicy() == .regular,
                  "and the activation policy is back to `.regular` BEFORE the caller raises the "
                      + "window - a `.accessory` app cannot show a regular window, so raising it "
                      + "first would silently do nothing")
            check(!controller.debugStatusItemIsVisible,
                  "and the merged status item is gone")
        }
    }

    private static func checkTheLockRefusesThePopover(_ check: (Bool, String) -> Void) {
        withController { controller, setMode in
            let wasLocked = AppLockGate.shared.isLocked
            defer { AppLockGate.shared.setLocked(wasLocked) }
            AppLockGate.shared.setLocked(false)
            AppSettings.shared.compactModeBadgesOverdueCount = true
            // Through `refresh()`, because that is what re-reads the settings
            // into the controller's cached policy - setting the key alone
            // leaves it stale, which is correct behaviour (Settings calls
            // `refresh()` on every one of its three toggles) and was worth
            // finding out here rather than in the app.
            setMode(true, false)
            controller.debugRefreshStatusItemTitle()

            // The badge half needs a real status-bar button, which a headless
            // process that never runs `NSApp.run()` is not guaranteed - so it
            // is asserted when there is one and SKIPPED LOUDLY when there is
            // not, rather than quietly passing. `CompactModePolicy`'s own
            // `statusItemTitle` (including its locked case) is asserted
            // unconditionally in `CompactModeSelfTest`; what is proven here is
            // the *wiring* - that the lock observer really re-derives it.
            if controller.debugHasStatusButton {
                let unlockedTitle = controller.debugStatusItemTitle
                check(unlockedTitle == " 1",
                      "unlocked and badging, the status item reports the one overdue task in the "
                          + "fixture - got \"\(unlockedTitle)\". Without this the locked check "
                          + "below would be vacuous")
                AppLockGate.shared.setLocked(true)
                check(controller.debugStatusItemTitle.isEmpty,
                      "and the badge clears immediately on the lock transition rather than on the "
                          + "next open - got \"\(controller.debugStatusItemTitle)\"")
            } else {
                SelfTestAssertions.reportPass(
                    "skipped the status-item badge assertions: this process got no status-bar "
                        + "button (no `NSApp.run()`), so they would be vacuous. "
                        + "`CompactModeSelfTest` asserts the title function itself")
                AppLockGate.shared.setLocked(true)
            }

            check(!AppLockGate.shared.allows(.compactModePopover),
                  "GL-09: locked, the gate refuses the compact popover - which in this mode is the "
                      + "whole of the app, since there is no window for the lock overlay to cover")
            check(!controller.debugPopover.isShown,
                  "and no popover is left on screen above the overlay")
        }
    }

    /// The compact-mode lock deadlock's content half: `prepareToShowLocked()`
    /// must show `lockPane` and touch no data-bearing pane or provider, and a
    /// successful `onAttempt` must transition the popover to the real tabs.
    ///
    /// This is the regression test for the captain's own report - before this
    /// fix, a locked compact-mode app had no in-popover path back to unlocked
    /// at all. Reverting `CompactModePopoverController.prepareToShowLocked()`
    /// to a no-op (leaving `renderPane()`'s ordinary unlocked content in
    /// place) makes `debugIsLocked`/`debugTabsRowIsHidden` below fail - the
    /// case actually caught the regression, confirmed by reverting and
    /// restoring it in the same working session (see this PR's description
    /// for the transcript).
    private static func checkLockedShowsAnUnlockFormInsteadOfTabs(_ check: (Bool, String) -> Void) {
        mounted { controller, _ in
            var providerCalls = 0
            controller.todayProvider = { providerCalls += 1; return todayFixture }
            controller.notesProvider = { providerCalls += 1; return notesFixture }
            // Reset after `mounted`'s own unlocked `prepareToShow()` already
            // read the fixtures once for the initial render.
            providerCalls = 0

            controller.prepareToShowLocked()
            controller.view.layoutSubtreeIfNeeded()

            check(controller.debugIsLocked, "the content must know it is showing the lock form")
            check(controller.debugTabsRowIsHidden,
                  "the tab strip must be hidden - there is nothing to switch between while locked")
            check(controller.debugCaptureRowIsHidden,
                  "the capture line must be hidden - nothing may be filed while locked")
            check(!controller.debugLockPane.isHidden, "the lock pane itself must be showing")
            check(controller.debugTodayPane.isHidden && controller.debugNotesPane.isHidden,
                  "neither data pane may be visible while locked - GL-09's whole point")
            check(providerCalls == 0,
                  "prepareToShowLocked() must read no data provider at all - a captain's tasks or "
                      + "notes must never be touched before the password check below succeeds, got "
                      + "\(providerCalls) provider calls")

            var attempts: [String] = []
            var lastCompletion: ((Bool) -> Void)?
            controller.onAttemptUnlock = { password, completion in
                attempts.append(password)
                lastCompletion = completion
            }

            controller.debugLockPane.debugSubmit("wrong")
            check(attempts == ["wrong"], "submitting calls the wired unlock closure with the typed "
                      + "password - got \(attempts)")
            lastCompletion?(false)
            check(controller.debugLockPane.debugErrorLabelText != nil,
                  "a rejected password must say so, mirroring the real lock screen's own error label")
            check(controller.debugIsLocked,
                  "a rejected password must not leave the locked content - got debugIsLocked == false")

            controller.debugLockPane.debugSubmit("correct")
            check(attempts == ["wrong", "correct"], "and a second attempt is a second real call - got \(attempts)")
            lastCompletion?(true)
            controller.view.layoutSubtreeIfNeeded()

            check(!controller.debugIsLocked,
                  "a successful unlock must transition the popover out of the locked content")
            check(!controller.debugTabsRowIsHidden,
                  "...and back to the real tab strip")
            check(controller.debugLockPane.isHidden,
                  "...with the lock pane itself now hidden")
            check(!controller.debugTodayPane.isHidden,
                  "...showing the tab the popover was already on (Today) - not a second, blank open")
        }
    }

    /// `CompactModeController.prepareContentToShow()` - the decision
    /// `iconClicked()` makes before ever touching `popover.show()` (which a
    /// headless process cannot safely drive through a status item that may
    /// have no real window - `debugPrepareContentToShow()`'s own header).
    ///
    /// This is the controller-side half of the same regression: the old
    /// `iconClicked()` refused outright while locked and never touched
    /// `content` at all, so `content.debugIsLocked` stayed `false` and the
    /// captain got a beep. Reverting `prepareContentToShow()` to that old
    /// shape makes the `debugIsLocked` check below fail.
    private static func checkIconClickedShowsTheLockFormRatherThanRefusing(_ check: (Bool, String) -> Void) {
        withController { controller, setMode in
            let wasLocked = AppLockGate.shared.isLocked
            defer { AppLockGate.shared.setLocked(wasLocked) }
            setMode(true, false)

            AppLockGate.shared.setLocked(true)
            let unlockedWhileLocked = controller.debugPrepareContentToShow()
            check(!unlockedWhileLocked,
                  "locked, the decision must report that it did NOT prepare the real content")
            check(controller.debugContent.debugIsLocked,
                  "...and the content must actually be showing its own lock form - this is the "
                      + "captain's exact report: before this fix, a locked click touched `content` "
                      + "not at all and only played a system beep")

            AppLockGate.shared.setLocked(false)
            let unlockedWhileUnlocked = controller.debugPrepareContentToShow()
            check(unlockedWhileUnlocked,
                  "unlocked, the decision must report that it DID prepare the real content")
            check(!controller.debugContent.debugIsLocked,
                  "...and the content must be back to its ordinary tabs")
        }
    }

    // MARK: Helpers

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Element-wise colour equality. Deliberately not a contrast ratio: see
    /// `checkUrgencyIsPaintedNotJustStated` for why that is not a colour
    /// check.
    private static func componentsMatch(_ a: (r: Double, g: Double, b: Double),
                                        _ b: (r: Double, g: Double, b: Double)) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }
}

#endif
