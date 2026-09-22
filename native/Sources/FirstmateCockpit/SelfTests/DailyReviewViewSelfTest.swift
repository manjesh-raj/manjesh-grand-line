// Manjesh Grand Line - native macOS app.
//
// F20's render: the real page mounted in a real `NSWindow`, over scratch
// stores, with the card actually laid out.
//
// **Which page.** `fm/grandline-overview-page-daily-review` gave the daily
// review a destination of its own (`DailyOverviewController`, titled
// "Overview"), which is now the card's primary host - so every case below
// drives that page. Fleet keeps its own copy of the card (the captain asked
// for a new page rather than a move), and `checkFleetStillHostsIt` is the one
// case that mounts `FleetController` instead, so dropping Fleet's copy later
// fails here by name rather than silently.
//
// The mount is written against `DailyReviewHosting`, a test-only protocol over
// the four debug hooks both controllers already had - which is what let the
// whole file move host without rewriting a single assertion.
//
// **Why this is window-backed and separate from `DailyReviewSelfTest`.**
// Everything here is a question about a real layout pass or a real painted
// string: whether the three columns resolve to real, roughly equal widths,
// whether the dividers between them have any height at all, whether the card
// paints what the digest decided, whether it re-themes, and - the one that has
// bitten this app repeatedly - whether a full-width card with equal-width
// column ties can cap the window (AGENTS.md's gotcha (13)). The composer runs
// in CI's *blocking* lane in the sibling suite; this one sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with `FM_RUN_DAILY_REVIEW_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.
//
// Two hermeticity notes:
//
//   - This suite changes the theme, so it captures and restores it
//     (`Phase3PolishSelfTest` fails the run on a suite that does not).
//   - It also writes F20's three `AppSettings` keys, which live in the same
//     real `UserDefaults` domain every other suite reads. They are saved and
//     restored for exactly the reason the theme is - see AGENTS.md's "The
//     self-test suite is not hermetic".

#if FM_SELFTESTS

import AppKit

enum DailyReviewViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let themeBefore = ThemeManager.shared.theme
        let enabledBefore = AppSettings.shared.dailyReviewEnabled
        let calendarBefore = AppSettings.shared.dailyReviewCalendarEnabled
        let dismissedBefore = AppSettings.shared.dailyReviewDismissedDay
        defer {
            ThemeManager.shared.setTheme(themeBefore)
            AppSettings.shared.dailyReviewEnabled = enabledBefore
            AppSettings.shared.dailyReviewCalendarEnabled = calendarBefore
            AppSettings.shared.dailyReviewDismissedDay = dismissedBefore
        }

        withScratchStores { stores in
            checkRendersWhatTheDigestDecided(stores, check: check)
            checkColumnGeometry(stores, check: check)
            checkCannotCapTheWindow(stores, check: check)
            checkThemeRepaint(stores, check: check)
            checkCalendarGapAndButton(stores, check: check)
            checkDismissAndDisable(stores, check: check)
            checkPageEmptyStates(stores, check: check)
            checkFleetStillHostsIt(stores, check: check)
            checkTheShellTreatsOverviewAsATopLevelPage(stores, check: check)
            checkHeaderButtonsAreLabelled(stores, check: check)
        }

        return report(failures)
    }

    // MARK: A mounted page

    struct Stores {
        let shift: ShiftStore
        let sticky: StickyBoardStore
        let reading: ReadingListStore
    }

    /// Mounts the real page in a real off-screen window and hands back its
    /// daily review card, already rendered.
    ///
    /// Deliberately assigns `window.contentView`, not `contentViewController`:
    /// that keeps AppKit's own appearance notifications out of it, so
    /// `viewWillAppear` never fires and this suite never triggers the page's
    /// real fleet refresh (which shells out). The card is rendered explicitly
    /// instead, through the same function that appearance would have called.
    private static func withMountedPage(_ stores: Stores,
                                        calendar: DailyReviewCalendarReading? = nil,
                                        host: (ShiftStore) -> DailyReviewHosting = { DailyOverviewController(shiftStore: $0) },
                                        _ body: (DailyReviewHosting, DailyReviewCard, OffScreenProbeWindow) -> Void) {
        autoreleasepool {
            let controller = host(stores.shift)
            if let calendar { controller.dailyReviewCalendar = calendar }
            controller.debugAttachDailyReviewStores(sticky: stores.sticky, reading: stores.reading)
            let window = OffScreenProbe.window(width: 1300, height: 900,
                                               styleMask: [.titled, .resizable])
            window.contentView = controller.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()
            controller.debugRenderDailyReview()
            controller.view.layoutSubtreeIfNeeded()
            body(controller, controller.debugDailyReviewCard, window)
        }
    }

    // MARK: 1 - the card paints what the composer decided

    private static func checkRendersWhatTheDigestDecided(_ stores: Stores,
                                                         check: (Bool, String) -> Void) {
        AppSettings.shared.dailyReviewEnabled = true
        AppSettings.shared.dailyReviewCalendarEnabled = false
        AppSettings.shared.dailyReviewDismissedDay = nil
        seed(stores)

        withMountedPage(stores) { _, card, _ in
            check(!card.isHidden, "the daily review should be on the page")
            check(!card.debugHeadline.isEmpty, "the card should carry a headline sentence")
            check(card.debugKicker.contains("\u{00B7}"),
                  "the kicker should name the day and the time, got \"\(card.debugKicker)\"")

            let due = card.debugText(inColumn: 0)
            check(due.contains(where: { $0.contains("Renew wildcard TLS certificate") }),
                  "the overdue task should be painted, got \(due)")
            check(due.contains(where: { $0.lowercased().contains("overdue since") }),
                  "and it should say it is late, got \(due)")
            check(due.contains(where: { $0.contains("Ravi on the VPC peering") }),
                  "the pending follow-up should be painted, got \(due)")
            // Assert what is painted, not what was computed: the section head
            // carries the real count.
            check(due.contains(where: { $0.hasPrefix("DUE TODAY") && $0.contains("2") }),
                  "the due section should carry its count, got \(due)")

            let board = card.debugText(inColumn: 2)
            check(board.contains(where: { $0.contains("Ask Ravi about VPC peering") }),
                  "the sticky note should be painted, got \(board)")
            check(board.contains(where: { $0.contains("unread") }),
                  "the reading list line should be painted, got \(board)")
            // GL-14's block, which is the feature's whole point.
            check(board.contains(where: { $0.hasPrefix("NOT AVAILABLE") }),
                  "the Not available block should be painted, got \(board)")
            check(board.contains(where: { $0.hasPrefix("Habits -") }),
                  "and it should name habits as the gap, got \(board)")
            check(board.contains(where: { $0.hasPrefix("Calendar -") }),
                  "and the calendar, which is off, got \(board)")

            check(card.debugStartButtonVisible, "with something overdue, the footer offers to start on it")
            check(card.debugStartButtonTitle.contains("Renew wildcard"),
                  "and names it, got \"\(card.debugStartButtonTitle)\"")
        }
    }

    // MARK: 2 - the columns are really laid out

    private static func checkColumnGeometry(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        withMountedPage(stores) { _, card, _ in
            let widths = card.debugColumns.map { $0.superview?.frame.width ?? 0 }
            check(widths.allSatisfy { $0 > 100 },
                  "every column should have a real laid-out width, got \(widths)")
            let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
            check(spread < 2,
                  "the three columns should be equal width, got \(widths)")

            // The dividers are pinned top and bottom to the row; `.top`
            // alignment alone leaves them zero-height, which is exactly the
            // kind of thing that looks fine in a screenshot of a short card.
            let heights = card.debugColumnDividers.map(\.frame.height)
            check(heights.allSatisfy { $0 > 40 },
                  "each column divider should span its row, got \(heights)")
            check(heights.allSatisfy { abs($0 - (card.debugColumns[0].superview?.frame.height ?? 0)) < 60 },
                  "and should be as tall as the row, not as tall as one label, got \(heights)")
            // The footer's rule is the other axis: 1pt tall, full width.
            check(card.debugFooterDivider.frame.width > 1000,
                  "the footer rule should be full-bleed, got \(card.debugFooterDivider.frame.width)")

            let cardHeight = card.frame.height
            check(cardHeight > 150, "the card should have a real height, got \(cardHeight)")
        }
    }

    // MARK: 3 - a full-width card must not cap the window

    /// AGENTS.md's gotcha (13): any content constraint above priority 500 can
    /// resize the whole window, and this card spans the page and ties three
    /// columns equal. The behavioural half of that rule - a real window,
    /// really shrunk, with the card really on the page.
    private static func checkCannotCapTheWindow(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        withMountedPage(stores) { controller, card, window in
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 760, height: frame.height),
                            display: true)
            controller.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - 760) < 1,
                  "the window should hold 760pt with the daily review on the page, got \(window.frame.width)")
            check(card.frame.width <= 760,
                  "and the card should have yielded rather than overflowed, got \(card.frame.width)")
            let widths = card.debugColumns.map { $0.superview?.frame.width ?? 0 }
            check(widths.allSatisfy { $0 > 10 },
                  "the columns should still be visible at 760pt, got \(widths)")
            // The other axis: nothing on this page may become a height floor
            // on the window either (gotcha (13)).
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 760, height: 520),
                            display: true)
            controller.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.height - 520) < 1,
                  "the window should hold 520pt tall with the review on the page, got \(window.frame.height)")
        }
    }

    // MARK: 4 - it re-themes

    private static func checkThemeRepaint(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        withMountedPage(stores) { controller, card, _ in
            let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight }) ?? ThemeManager.shared.theme
            let legacy = HelmTheme.allThemes.first(where: { !$0.isDaylight }) ?? ThemeManager.shared.theme

            ThemeManager.shared.setTheme(daylight)
            controller.view.layoutSubtreeIfNeeded()
            let daylightDivider = card.debugColumnDividers.first?.layer?.backgroundColor
            let daylightText = card.debugText(inColumn: 0)

            ThemeManager.shared.setTheme(legacy)
            controller.view.layoutSubtreeIfNeeded()
            let legacyDivider = card.debugColumnDividers.first?.layer?.backgroundColor

            check(daylightDivider != nil && legacyDivider != nil,
                  "the dividers should paint a real colour in both registers")
            check(daylightDivider != legacyDivider,
                  "the dividers should repaint when the theme changes")
            // A repaint must not lose content - the rebuild-on-theme path is
            // the one that could silently empty a column.
            check(card.debugText(inColumn: 0) == daylightText,
                  "a theme change must not change what the card says")
        }
    }

    // MARK: 5 - the calendar gap, and the one button that can fix it

    private static func checkCalendarGapAndButton(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        AppSettings.shared.dailyReviewCalendarEnabled = false

        // Askable: the button is offered.
        withMountedPage(stores, calendar: StubCalendar(access: .notDetermined, canPrompt: true)) { _, card, _ in
            check(card.debugCalendarButtonMounted,
                  "a captain who can be asked should be offered the button")
        }

        // Not askable (an unbundled build, or a denied grant): no button, and
        // the gap still states the reason.
        withMountedPage(stores, calendar: StubCalendar(access: .denied, canPrompt: true)) { _, card, _ in
            check(!card.debugCalendarButtonMounted,
                  "a denied grant must not offer a button that cannot change anything")
        }
        withMountedPage(stores, calendar: StubCalendar(access: .notDetermined, canPrompt: false)) { _, card, _ in
            check(!card.debugCalendarButtonMounted,
                  "a build that cannot prompt must not offer the button")
        }

        // Granted and on: real rows, and no gap.
        AppSettings.shared.dailyReviewCalendarEnabled = true
        let stub = StubCalendar(access: .readable, canPrompt: true, events: [
            DailyReviewEventRow(title: "Platform standup", timeText: "10:00", detail: "",
                                colorHex: "6A8DED", isAllDay: false),
            DailyReviewEventRow(title: "RaaS cutover dry run", timeText: "14:30",
                                detail: "6 attendees \u{00B7} Meet", colorHex: "CD8D2E", isAllDay: false),
        ])
        withMountedPage(stores, calendar: stub) { _, card, _ in
            let middle = card.debugText(inColumn: 1)
            check(middle.contains(where: { $0 == "Platform standup" }),
                  "an event should be painted by title, got \(middle)")
            check(middle.contains(where: { $0 == "10:00" }),
                  "with its own time, got \(middle)")
            check(middle.contains(where: { $0.contains("6 attendees") }),
                  "and its detail line, got \(middle)")
            check(!card.debugText(inColumn: 2).contains(where: { $0.hasPrefix("Calendar -") }),
                  "with the calendar readable there should be no calendar gap")
            check(!card.debugCalendarButtonMounted,
                  "and nothing left to connect")
        }
        AppSettings.shared.dailyReviewCalendarEnabled = false
    }

    // MARK: 6 - dismissing, and turning it off

    private static func checkDismissAndDisable(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        AppSettings.shared.dailyReviewEnabled = true
        AppSettings.shared.dailyReviewDismissedDay = nil

        withMountedPage(stores) { controller, card, _ in
            check(!card.isHidden, "the card starts visible")
            card.debugPressDismiss()
            check(card.isHidden, "dismissing hides it")
            check(AppSettings.shared.dailyReviewDismissedDay == MorningBriefing.dayKey(),
                  "and records today, so it stays gone until tomorrow")
            // The real re-render path, not a flag read: a dismissed card must
            // not come back on the next visit to Overview.
            controller.debugRenderDailyReview()
            check(card.isHidden, "and it does not come back on the next appearance")

            // Yesterday's dismissal does not silence today.
            AppSettings.shared.dailyReviewDismissedDay = "2000-01-01"
            controller.debugRenderDailyReview()
            check(!card.isHidden, "a dismissal from another day must not hide today's review")
        }

        AppSettings.shared.dailyReviewDismissedDay = nil
        AppSettings.shared.dailyReviewEnabled = false
        withMountedPage(stores) { _, card, _ in
            check(card.isHidden, "turning the feature off in Settings hides the card")
        }
        AppSettings.shared.dailyReviewEnabled = true
    }

    // MARK: 7 - the page has somewhere to go when the card does not render

    /// A card in a stack can vanish; a destination cannot. Both gated states
    /// (dismissed for the day, turned off in Settings) put a real, laid-out
    /// empty state on the page instead of leaving it blank.
    ///
    /// Discriminating power first: the populated state is asserted to show no
    /// empty state, so "the empty state is showing" cannot pass vacuously
    /// against a page that always shows it.
    private static func checkPageEmptyStates(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        AppSettings.shared.dailyReviewEnabled = true
        AppSettings.shared.dailyReviewDismissedDay = nil

        withMountedPage(stores) { host, card, _ in
            guard let page = host as? DailyOverviewController else {
                check(false, "the default host should be the Overview page")
                return
            }
            check(!card.isHidden && !page.debugEmptyStateIsShowing,
                  "with a review to show, the page shows the card and no empty state")
            check(card.frame.height > 150,
                  "and the card really is laid out on it, got \(card.frame.height)")
            // The card IS the page: full width inside the gutter. The gutter
            // is `DaylightBarController.sideMargin`, not `HelmMetrics.pageGutter`
            // - the bar is a floating panel directly above this card, and 24
            // against its 22 left the two edges 2pt out of line. The captain
            // reported exactly that.
            let expectedWidth = page.view.frame.width - DaylightBarController.sideMargin * 2
            check(abs(card.frame.width - expectedWidth) < 1,
                  "the card should fill the page inside the bar's own margin - expected "
                  + "\(expectedWidth), got \(card.frame.width) on a \(page.view.frame.width)pt page")
            // ...and sizes to its **content** in the other axis.
            //
            // `fm/grandline-overview-layout-fix-gmail-settings` removed the
            // viewport-height minimum this used to assert the opposite of.
            // What that produced, in the captain's own screenshot: a 317pt
            // card stretched to 592pt, its three column rules running down
            // through ~275pt of empty background and its footer parked on the
            // bottom edge of the window.
            //
            // The fixture's discriminating power first (a check that cannot
            // fail is worse than no check): the page has to be genuinely
            // taller than the card, or "the card did not stretch" asserts
            // nothing at all.
            check(page.view.frame.height - card.fittingSize.height > 200,
                  "this fixture only discriminates while the page is much taller than the "
                  + "card - page \(page.view.frame.height), card \(card.fittingSize.height)")
            check(abs(card.frame.height - card.fittingSize.height) < 1,
                  "the card should size to its content, not stretch to the viewport - fitting "
                  + "\(card.fittingSize.height), got \(card.frame.height) on a "
                  + "\(page.view.frame.height)pt page")
            check(page.pageSummary == card.debugHeadline,
                  "the page's own summary should be the headline the card is painting - "
                  + "page says \"\(page.pageSummary ?? "")\", card says \"\(card.debugHeadline)\"")

            card.debugPressDismiss()
            page.debugRenderDailyReview()
            check(card.isHidden, "dismissing hides the card on the page too")
            check(page.debugEmptyStateIsShowing,
                  "and the page says so rather than rendering an empty destination")

            AppSettings.shared.dailyReviewDismissedDay = nil
            AppSettings.shared.dailyReviewEnabled = false
            page.debugRenderDailyReview()
            check(page.debugEmptyStateIsShowing,
                  "turning the feature off leaves the page its own state, not a blank page")
            AppSettings.shared.dailyReviewEnabled = true
        }
        AppSettings.shared.dailyReviewDismissedDay = nil
    }

    // MARK: 9 - the shell treats Overview as a top-level page

    /// `fm/grandline-overview-layout-fix-gmail-settings`, and the half of
    /// this fix no page-level check can see: the *shell's* chrome around the
    /// page.
    ///
    /// The captain's screenshot showed the Overview tab rendering with a back
    /// arrow, a page title and **no tab strip at all**, plus a "SESSIONS /
    /// Prod Bastion" terminal strip above the review card. Both came from the
    /// shell rather than from `DailyOverviewController`:
    ///
    /// - `AppShellController.show` asked `slot.id == .homeCanvas` to decide
    ///   whether the bar keeps its wordmark and space pills. The Overview
    ///   page is opened by a space pill but is not the canvas, so it fell
    ///   through to the drill cluster, which *hides the pills* - a pill that
    ///   hides the pill strip the moment you press it.
    /// - the session strip was gated on "is there a live session" alone, so
    ///   it drew on every destination including this one.
    ///
    /// Measured before the fix, in this exact shape: `drillNavIsHidden =
    /// false`, `pillsAreHidden = true`.
    ///
    /// Mounts a real `AppShellController`, because the property under test is
    /// what `show(_:)` does - a page-level mount cannot reach it.
    private static func checkTheShellTreatsOverviewAsATopLevelPage(
        _ stores: Stores, check: (Bool, String) -> Void) {
        autoreleasepool {
            let window = OffScreenProbe.window(width: 1300, height: 900,
                                               styleMask: [.titled, .resizable])
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            let dictationStore = DictationStore()
            let shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore,
                                            snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                           isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore,
                                             dictationStore: dictationStore),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: stores.shift, dictationStore: dictationStore,
                commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
                makeHostConsole: {
                    ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                      isFirstmateConsole: false)
                })
            window.contentViewController = shell
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
            }

            shell.show(.dailyOverview)
            shell.view.layoutSubtreeIfNeeded()
            check(shell.drillHeaderIsHiddenForTests,
                  "Overview is a top-level page, so the bar should carry no drill cluster")
            check(!shell.barPillsAreHiddenForTests,
                  "and the space pills should still be there - hiding them is what removed "
                  + "the whole tab strip the captain reported missing")
            check(!shell.barWordmarkIsHiddenForTests,
                  "and the wordmark comes back with them")

            // The other direction, so this cannot pass by the bar simply
            // never showing a drill cluster at all.
            shell.show(.logAnalyzer)
            shell.view.layoutSubtreeIfNeeded()
            check(!shell.drillHeaderIsHiddenForTests,
                  "a page reached by drilling in should still get the drill cluster")
            check(shell.barPillsAreHiddenForTests,
                  "and should still trade the pills for it")

            // The session strip. Its fixture needs real discriminating power:
            // with no live session it is hidden everywhere, so the check
            // would pass on a build that never had the fix.
            shell.sessions.register(hostID: UUID(), label: "Prod Bastion",
                                    accentHex: nil, state: .connected)
            shell.show(.console)
            shell.view.layoutSubtreeIfNeeded()
            check(!shell.sessionStripIsHiddenForTests,
                  "the live session really is registered, and the strip really does draw "
                  + "somewhere - without this the Overview check below is vacuous")
            check(shell.sessionStripHeightForTests > 0,
                  "and it reserves real height there, got \(shell.sessionStripHeightForTests)")

            shell.show(.dailyOverview)
            shell.view.layoutSubtreeIfNeeded()
            check(shell.sessionStripIsHiddenForTests,
                  "a terminal session strip does not belong over the daily review")
            check(shell.sessionStripHeightForTests == 0,
                  "and it should reserve no height there either, got "
                  + "\(shell.sessionStripHeightForTests)")
            check(shell.bodyTopInsetForTests == DaylightBarController.reservedTopHeight,
                  "so the page starts immediately under the bar, got "
                  + "\(shell.bodyTopInsetForTests)")
        }
    }

    // MARK: 10 - the header's two buttons read as words

    /// The captain reported "Settings"/"Dismiss" rendering as a gear and an
    /// X. They were two `HelmPageToolbar.iconButton`s; they are labelled
    /// `HelmButton`s now, on the one card both hosts share.
    private static func checkHeaderButtonsAreLabelled(_ stores: Stores,
                                                      check: (Bool, String) -> Void) {
        seed(stores)
        AppSettings.shared.dailyReviewEnabled = true
        AppSettings.shared.dailyReviewDismissedDay = nil
        withMountedPage(stores) { _, card, _ in
            let titles = card.debugHeaderActions.map(\.title)
            check(titles == ["Settings", "Dismiss"],
                  "the header's actions should say what they do, got \(titles)")
            for button in card.debugHeaderActions {
                check(button.frame.width > 40,
                      "and be laid out at a real labelled width, got \(button.frame.width) "
                      + "for \"\(button.title)\"")
                check(button.toolTip?.isEmpty == false,
                      "keeping the tooltip the icon button carried, for \"\(button.title)\"")
            }
        }
    }

    // MARK: 8 - Fleet still hosts its own copy

    /// The captain asked for a **new** page, not a move, so the fleet
    /// dashboard keeps the card it has had since F20 - one card class, one
    /// composer, one dismissal key, two hosts.
    ///
    /// Asserted rather than assumed: if Fleet's copy is ever dropped (a
    /// reasonable later call - see `DailyOverviewController`'s header), this
    /// fails by name and whoever drops it deletes this case deliberately.
    private static func checkFleetStillHostsIt(_ stores: Stores, check: (Bool, String) -> Void) {
        seed(stores)
        AppSettings.shared.dailyReviewEnabled = true
        AppSettings.shared.dailyReviewDismissedDay = nil
        withMountedPage(stores, host: { FleetController(shiftStore: $0) }) { _, card, _ in
            check(!card.isHidden, "the fleet dashboard should still carry the daily review")
            check(!card.debugHeadline.isEmpty, "and it should render a real headline there too")
            check(card.debugText(inColumn: 0).contains(where: { $0.contains("Renew wildcard TLS certificate") }),
                  "and the same overdue task, from the same composer")
        }
    }

    // MARK: Fixtures

    /// A stub calendar. The reason `FleetController.dailyReviewCalendar` is a
    /// settable property: no EventKit call, no permission prompt, and the
    /// captain's own calendar is never read by a test run.
    private final class StubCalendar: DailyReviewCalendarReading {
        let access: DailyReviewCalendarAccess
        let canPrompt: Bool
        private let events: [DailyReviewEventRow]

        init(access: DailyReviewCalendarAccess, canPrompt: Bool,
             events: [DailyReviewEventRow] = []) {
            self.access = access
            self.canPrompt = canPrompt
            self.events = events
        }

        func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
            completion(access)
        }

        func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
            _ = day
            switch access {
            case .readable: return .available(events)
            case .notDetermined: return .unavailable("not connected yet")
            case .denied: return .unavailable("calendar access is turned off for Grand Line")
            case .restricted: return .unavailable("calendar access is restricted on this Mac")
            case .writeOnly: return .unavailable("write-only access cannot read events")
            }
        }
    }

    /// One overdue task, one due later today, one pending follow-up, one
    /// sticky note and two unread links - enough for every column to have
    /// something to say, written through the real stores' own write paths.
    private static func seed(_ stores: Stores) {
        guard stores.shift.activeTasks.isEmpty else { return }
        let now = Date()
        var overdue = ShiftTask.fresh()
        overdue.title = "Renew wildcard TLS certificate"
        overdue.priority = .high
        overdue.dueDate = DailyReviewSelfTest.isoDay(DailyReviewSelfTest.day(-5, from: now))
        stores.shift.addTask(overdue)

        var today = ShiftTask.fresh()
        today.title = "Rotate the prod bastion SSH keys"
        today.priority = .high
        today.dueDate = DailyReviewSelfTest.isoDay(now)
        today.dueTime = "23:30"
        stores.shift.addTask(today)

        var follow = ShiftFollowUp.fresh()
        follow.title = "Ravi on the VPC peering request"
        follow.followUpAt = DailyReviewSelfTest.isoDay(now)
        stores.shift.addFollowUp(follow)

        _ = stores.sticky.addNote(title: "Ask Ravi about VPC peering",
                                  text: "chase the ticket",
                                  color: .yellow, x: 20, y: 20, rotationDegrees: 0)
        _ = stores.reading.add("https://example.com/graceful-node-shutdown")
        _ = stores.reading.add("https://example.com/another-thing")
    }

    private static func withScratchStores(_ body: (Stores) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-review-view-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        // Explicitly-rooted, git-free stores for the two that offer the seam,
        // so this suite can never reach the captain's real clone even if the
        // environment redirect above were ever removed.
        let stores = Stores(shift: ShiftStore(),
                            sticky: StickyBoardStore(root: root.appendingPathComponent("sticky", isDirectory: true)),
                            reading: ReadingListStore(root: root.appendingPathComponent("reading", isDirectory: true)))
        body(stores)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[DailyReviewViewSelfTest] all checks passed")
            return true
        }
        print("[DailyReviewViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

/// The five hooks a page hosting `DailyReviewCard` exposes, so this suite can
/// drive either host with one mount.
///
/// Test-only and declared here rather than in the app: neither controller
/// needs to know the other exists, and a production protocol would be a
/// second, weaker statement of what the two pages share.
protocol DailyReviewHosting: AnyObject {
    var view: NSView { get }
    var dailyReviewCalendar: DailyReviewCalendarReading { get set }
    var debugDailyReviewCard: DailyReviewCard { get }
    func debugRenderDailyReview()
    func debugAttachDailyReviewStores(sticky: StickyBoardStore, reading: ReadingListStore)
}

extension DailyOverviewController: DailyReviewHosting {}
extension FleetController: DailyReviewHosting {}

#endif
