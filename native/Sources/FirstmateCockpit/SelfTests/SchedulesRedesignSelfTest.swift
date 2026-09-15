// Manjesh Grand Line - native macOS app - self-test.
//
// `fm/grand-line-schedules-page-redesign`: the claims the redesigned Schedules
// page makes that a render cannot check for itself.
//
// The redesign's whole risk is **honesty**, not layout. Both captain-supplied
// references are standalone HTML mockups carrying fabricated demo data - a
// fictional schedule, a hardcoded 24-run chart, an invented activity feed -
// and the brief's instruction was to wire each piece to whatever real history
// the app already tracks or scope it out, never to pad a shape with
// placeholders. A page that fabricates renders perfectly and looks right,
// which is precisely why every check below asserts *where a number came from*
// rather than that a view exists:
//
//  - a schedule with nothing on record draws no bars, not a grey run of them;
//  - the "runs last 7 days" tile, the chart and the feed all come from the one
//    real `ScheduleRunHistoryStore` read, so they cannot disagree with each
//    other or with the rows;
//  - the "Review" hand-off only appears where a run genuinely surfaced
//    something, and lands on the page that owns that action;
//  - and the pre-existing behaviour the brief said to preserve - the toggle,
//    the overflow menu - still works through the real handlers.
//
// Window-backed (it mounts the real controller), so it sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS
import AppKit

enum SchedulesRedesignSelfTest {

    static func run() -> Bool {
        print("== Schedules redesign: real data, honest empties ==")
        var ok = true
        checkDailyBuckets(&ok)
        checkSparklineNeverFabricates(&ok)
        checkGrouping(&ok)
        checkSearch(&ok)
        checkTilesAndPanelsMatchTheRows(&ok)
        checkReviewHandOff(&ok)
        checkTogglePreserved(&ok)
        checkSidebarShape(&ok)
        checkSidebarFiltersNarrowTheList(&ok)
        checkSidebarCountsFollowTheSearch(&ok)
        checkRunHistoryIsAnActionNotAFilter(&ok)
        checkRowsUseTheFullWidth(&ok)
        print(ok ? "\nPASS" : "\nFAIL")
        return ok
    }

    // MARK: Harness

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedules-redesign-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store of its own per case, so one case's schedules cannot leak into
    /// the next. `FM_SCHEDULE_HISTORY_DIR` is already redirected process-wide
    /// by `main.swift`'s `#if FM_SELFTESTS` block, so `ScheduleRunHistoryStore.shared`
    /// never reaches the captain's real log here.
    private static func scratchStore() -> ScheduleStore {
        setenv("FM_SCHEDULES_FILE", scratchDir().appendingPathComponent("schedules.json").path, 1)
        return ScheduleStore()
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func entry(_ scheduleID: UUID,
                              _ verdict: ScheduleRunVerdict,
                              daysAgo: Int,
                              summary: String = "recorded") -> ScheduleRunHistoryEntry {
        ScheduleRunHistoryEntry(
            scheduleID: scheduleID,
            at: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            verdict: verdict,
            summary: summary,
            actionTitle: "Fork sync")
    }

    // MARK: 1 - the chart's arithmetic

    private static func checkDailyBuckets(_ ok: inout Bool) {
        print("\n-- the 7-day chart buckets real runs, and keeps empty days --")
        let id = UUID()
        let entries = [
            entry(id, .clean, daysAgo: 0),
            entry(id, .changed, daysAgo: 0),
            entry(id, .clean, daysAgo: 2),
            // Past the store's own retention window: it could only reach the
            // chart through a caller that skipped `allEntries`' pruning, and it
            // must not silently become an 8th column.
            entry(id, .clean, daysAgo: 30),
        ]
        let buckets = ScheduleRunStats.dailyBuckets(entries: entries)

        if buckets.count != ScheduleRunStats.dayCount {
            print("  FAIL \(buckets.count) buckets, expected \(ScheduleRunStats.dayCount)")
            ok = false
        }
        // Oldest first, so the chart reads into today.
        if buckets.last?.isToday != true || buckets.dropLast().contains(where: \.isToday) {
            print("  FAIL exactly the last bucket must be today")
            ok = false
        }
        guard let today = buckets.last else { print("  FAIL no buckets"); ok = false; return }
        if today.total != 2 || today.needsAttention != 1 {
            print("  FAIL today: \(today.total) runs / \(today.needsAttention) needing you, expected 2 / 1")
            ok = false
        }
        // An empty day is a real signal ("nothing ran on Tuesday") - dropping
        // it would silently compress the axis.
        let empties = buckets.filter { $0.total == 0 }.count
        if empties != ScheduleRunStats.dayCount - 2 {
            print("  FAIL \(empties) empty days kept, expected \(ScheduleRunStats.dayCount - 2)")
            ok = false
        }
        // The 30-day-old entry belongs to no bucket in the window.
        if buckets.map(\.total).reduce(0, +) != 3 {
            print("  FAIL an out-of-window run leaked into the chart")
            ok = false
        }
        if ok { print("  OK - \(buckets.count) days, today last, empty days kept, nothing out of window") }
    }

    // MARK: 2 - the sparkline never invents a bar

    private static func checkSparklineNeverFabricates(_ ok: inout Bool) {
        print("\n-- the sparkline draws recorded runs only --")
        let id = UUID()
        let spark = ScheduleRunSparkline()

        // Nothing on record at all: the reference labels this strip "LAST 14
        // RUNS", and the honest answer here is no bars whatsoever.
        spark.setRuns([], fallback: nil, slots: 5, theme: ThemeManager.shared.theme)
        if spark.debugBarCount != 0 {
            print("  FAIL a never-run schedule drew \(spark.debugBarCount) bar(s)")
            ok = false
        }

        // `lastRun` with an empty store is a *real* completed run, not a
        // stand-in - see `ScheduleRunSparkline.setRuns`'s `fallback` parameter.
        spark.setRuns([], fallback: ScheduleRunRecord(verdict: .changed, summary: "2 forks", at: Date()),
                      slots: 5, theme: ThemeManager.shared.theme)
        if spark.debugBarCount != 1 {
            print("  FAIL a schedule with only `lastRun` drew \(spark.debugBarCount) bars, expected 1")
            ok = false
        }

        // Real history: one bar per real entry, never padded up to `slots`.
        let three = (0..<3).map { entry(id, .clean, daysAgo: $0) }
        spark.setRuns(three, fallback: nil, slots: ScheduleRunSparkline.maxBars,
                      theme: ThemeManager.shared.theme)
        if spark.debugBarCount != 3 {
            print("  FAIL 3 recorded runs drew \(spark.debugBarCount) bars")
            ok = false
        }
        if spark.debugReservedWidth != ScheduleRunSparkline.width(forSlots: ScheduleRunSparkline.maxBars) {
            print("  FAIL the reserved width must be the shared slot count, not this row's own")
            ok = false
        }

        // And capped rather than drawing one sliver per run forever.
        let many = (0..<40).map { entry(id, .clean, daysAgo: $0 % 7) }
        spark.setRuns(many, fallback: nil, slots: ScheduleRunSparkline.maxBars,
                      theme: ThemeManager.shared.theme)
        if spark.debugBarCount != ScheduleRunSparkline.maxBars {
            print("  FAIL 40 runs drew \(spark.debugBarCount) bars, expected the \(ScheduleRunSparkline.maxBars) cap")
            ok = false
        }
        // A cap that is not stated reads as "that is all there is".
        if spark.toolTip?.contains("of 40 runs") != true {
            print("  FAIL the cap is silent: tooltip = \(spark.toolTip ?? "nil")")
            ok = false
        }

        // Zero shared slots collapses the view on every row at once, so a
        // history-free app has no dead gap.
        spark.setRuns([], fallback: nil, slots: 0, theme: ThemeManager.shared.theme)
        if !spark.isHidden || spark.debugReservedWidth != 0 {
            print("  FAIL zero slots must collapse the sparkline")
            ok = false
        }
        if ok { print("  OK - 0 / 1 / 3 / capped-at-\(ScheduleRunSparkline.maxBars), and the cap is stated") }
    }

    // MARK: 3 - grouping

    private static func checkGrouping(_ ok: inout Bool) {
        print("\n-- status groups, and where a never-run schedule belongs --")
        let now = Date()
        let cases: [(String, AutomationSchedule, SchedulesCardView.Group)] = [
            ("never run", AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0)),
             .healthy),
            ("clean", AutomationSchedule(action: .toolUpdateCheck, cadence: .daily(hour: 9, minute: 0),
                                         lastRun: ScheduleRunRecord(verdict: .clean, summary: "up to date", at: now)),
             .healthy),
            ("changed", AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10),
                                           lastRun: ScheduleRunRecord(verdict: .changed, summary: "2 forks", at: now)),
             .needsYou),
            ("failed", AutomationSchedule(action: .vaultRecipeExport, cadence: .daily(hour: 4, minute: 0),
                                          lastRun: ScheduleRunRecord(verdict: .failed, summary: "gh auth", at: now)),
             .needsYou),
            // Paused wins over the verdict: a schedule that will not run again
            // is not waiting on the captain.
            ("paused with a changed run",
             AutomationSchedule(action: .configBackupExport, cadence: .daily(hour: 5, minute: 0),
                                isEnabled: false,
                                lastRun: ScheduleRunRecord(verdict: .changed, summary: "pushed", at: now)),
             .paused),
        ]
        for (label, schedule, expected) in cases {
            let got = SchedulesCardView.group(for: schedule)
            if got != expected {
                print("  FAIL \(label) grouped as \(got), expected \(expected)")
                ok = false
            }
        }
        if ok { print("  OK - never-run counts as healthy, paused beats its own last verdict") }
    }

    // MARK: 4 - search

    private static func checkSearch(_ ok: inout Bool) {
        print("\n-- search covers what the row actually shows --")
        let schedule = AutomationSchedule(action: .forkSync,
                                          cadence: .daily(hour: 11, minute: 10),
                                          lastRun: ScheduleRunRecord(verdict: .changed,
                                                                     summary: "2 of 8 forks fast-forwarded",
                                                                     at: Date()))
        // Each of these is a different field of the row, and a search that only
        // looked at the title would pass the first and fail the rest.
        let hits = ["fork", "FORK", "11:10", "forks synced", "fast-forwarded", "needs you"]
        for query in hits where !SchedulesCardView.matches(schedule, query: query) {
            print("  FAIL \"\(query)\" should match")
            ok = false
        }
        if SchedulesCardView.matches(schedule, query: "kubernetes") {
            print("  FAIL \"kubernetes\" should not match")
            ok = false
        }
        if !SchedulesCardView.matches(schedule, query: "") {
            print("  FAIL an empty query must match everything")
            ok = false
        }
        if ok { print("  OK - title, cadence, notify setting, last-run summary and group name") }
    }

    // MARK: 5 - the tiles and the panels agree with the rows

    private static func checkTilesAndPanelsMatchTheRows(_ ok: inout Bool) {
        print("\n-- the tiles, the feed and the chart come from the rows' own data --")
        let store = scratchStore()
        let needsYou = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10),
                                          lastRun: ScheduleRunRecord(verdict: .changed,
                                                                     summary: "2 of 8 forks fast-forwarded",
                                                                     at: Date()))
        let clean = AutomationSchedule(action: .toolUpdateCheck, cadence: .daily(hour: 9, minute: 0),
                                       lastRun: ScheduleRunRecord(verdict: .clean, summary: "all up to date",
                                                                  at: Date()))
        let paused = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0),
                                        isEnabled: false)
        for schedule in [needsYou, clean, paused] { store.add(schedule) }

        let controller = SchedulesController(scheduleStore: store)
        let window = mount(controller)
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()

        guard let card = controller.debugSchedulesCard else {
            print("  FAIL no schedules card")
            ok = false
            return
        }
        if card.debugRowCount != 3 {
            print("  FAIL \(card.debugRowCount) rows rendered, expected 3")
            ok = false
        }
        // All three groups present, in reading order.
        let sections = card.debugSectionTitles
        if sections != ["NEEDS YOU", "RUNNING ON THEIR OWN", "PAUSED"] {
            print("  FAIL sections = \(sections)")
            ok = false
        }

        let stats = controller.debugStatValues
        // Counted off the very same array the rows were built from - which is
        // the property worth guarding: a tile computing its own count from a
        // second read is how a header comes to disagree with the list under it.
        if stats.active != "2" {
            print("  FAIL active tile reads \(stats.active), expected 2 (paused is not active)")
            ok = false
        }
        if stats.attention != "1" {
            print("  FAIL attention tile reads \(stats.attention), expected 1")
            ok = false
        }
        // No runs are in the real (scratch) history store, so the honest answer
        // is zero - never the three `lastRun` records on the schedules, which
        // are a different fact.
        if stats.runs != "0" {
            print("  FAIL runs tile reads \(stats.runs) with an empty history store, expected 0")
            ok = false
        }
        if !controller.debugActivityShowsEmptyState {
            print("  FAIL an empty history must say so rather than render a blank feed")
            ok = false
        }
        if controller.debugOverviewChartAxis.count != ScheduleRunStats.dayCount {
            print("  FAIL chart axis has \(controller.debugOverviewChartAxis.count) labels")
            ok = false
        }
        if ok { print("  OK - 2 active / 1 needing you / 0 recorded runs, and an honest empty feed") }
    }

    // MARK: 6 - the "Review" hand-off

    private static func checkReviewHandOff(_ ok: inout Bool) {
        print("\n-- Review appears only where a run surfaced something --")
        let store = scratchStore()
        let needsYou = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10),
                                          lastRun: ScheduleRunRecord(verdict: .changed,
                                                                     summary: "2 of 8 forks fast-forwarded",
                                                                     at: Date()))
        let clean = AutomationSchedule(action: .toolUpdateCheck, cadence: .daily(hour: 9, minute: 0),
                                       lastRun: ScheduleRunRecord(verdict: .clean, summary: "all up to date",
                                                                  at: Date()))
        for schedule in [needsYou, clean] { store.add(schedule) }

        let controller = SchedulesController(scheduleStore: store)
        var opened: [RailDestination] = []
        controller.onNavigateToDestination = { opened.append($0) }
        let window = mount(controller)
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()

        guard let card = controller.debugSchedulesCard else {
            print("  FAIL no schedules card")
            ok = false
            return
        }
        if card.debugReviewButton(for: clean.id) != nil {
            print("  FAIL a clean run offered a Review button")
            ok = false
        }
        guard let review = card.debugReviewButton(for: needsYou.id) else {
            print("  FAIL the needs-you row has no Review button")
            ok = false
            return
        }
        // The real summary, not a fabricated "Review 2 changes" count.
        if review.toolTip?.contains("2 of 8 forks fast-forwarded") != true {
            print("  FAIL the button must carry the run's own sentence: \(review.toolTip ?? "nil")")
            ok = false
        }
        // Driven through the real target/action - a button wired to nothing
        // renders identically.
        review.performClick(nil)
        if opened != [.githubSync] {
            print("  FAIL Review opened \(opened), expected [.githubSync] (fork sync's own page)")
            ok = false
        }
        // Every action has a page that owns it, or the overflow's "Open ..."
        // item would point somewhere arbitrary.
        for action in ScheduledActionKind.allCases where action.reviewDestination == .homeCanvas {
            print("  FAIL \(action) has no owning page")
            ok = false
        }
        if ok { print("  OK - needs-you only, the real summary in the tooltip, lands on GitHub Sync") }
    }

    // MARK: 7 - the behaviour the redesign had to preserve

    private static func checkTogglePreserved(_ ok: inout Bool) {
        print("\n-- the toggle and the overflow menu still work --")
        let store = scratchStore()
        let schedule = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10))
        store.add(schedule)

        let controller = SchedulesController(scheduleStore: store)
        let window = mount(controller)
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()

        guard let card = controller.debugSchedulesCard,
              let toggle = card.debugToggle(for: schedule.id) else {
            print("  FAIL no toggle rendered")
            ok = false
            return
        }
        if !toggle.isOn {
            print("  FAIL a new schedule must render enabled")
            ok = false
        }
        // The real user-interaction path, not `store.setEnabled` directly.
        toggle.isOn = false
        toggle.onToggle?()
        if store.schedules.first?.isEnabled != false {
            print("  FAIL toggling off did not reach the store")
            ok = false
        }
        // And the row moved into the paused group on the re-render the store
        // change triggers.
        if card.debugSectionTitles != ["PAUSED"] {
            print("  FAIL after pausing, sections = \(card.debugSectionTitles)")
            ok = false
        }

        let titles = card.debugMenu(for: schedule).items.map(\.title)
        for want in ["Run Now", "Edit\u{2026}", "View History\u{2026}", "Delete"] where !titles.contains(want) {
            print("  FAIL the overflow menu lost \"\(want)\": \(titles)")
            ok = false
        }
        if !titles.contains(where: { $0.hasPrefix("Open ") }) {
            print("  FAIL the overflow menu has no \"Open ...\" hand-off: \(titles)")
            ok = false
        }
        if ok { print("  OK - toggle writes through and regroups, menu keeps all four actions") }
    }
}


// MARK: - The sidebar and the width (fm/grand-line-schedules-sidebar-fullwidth-fix)
//
// The captain's two corrections after using the redesign: the reference's left
// navigation column was missing, and the page did not use its width.
//
// The width half is the one worth a measured guard. The redesign opted its rows
// into D2's `recordContentWidth` (900), which is right for a page whose list
// column is already about that wide and wrong for this one - a single
// gutter-to-gutter column, where it stranded the trailing cluster mid-row. So
// the check measures where the controls actually land relative to the card's
// own trailing edge, rather than asserting the absence of a constraint: a
// future re-cap at any value fails it, and so does a re-cap that happens to be
// spelled differently.

extension SchedulesRedesignSelfTest {

    /// Every id the sidebar offers, in order.
    private static var expectedSidebarIDs: [String] {
        SchedulesCardView.StatusFilter.allCases.map(\.rawValue) + ["run-history"]
    }

    private static func mountedPage(_ store: ScheduleStore,
                                    width: CGFloat = 1512) -> (SchedulesController, NSWindow) {
        let controller = SchedulesController(scheduleStore: store)
        let window = mount(controller, width: width)
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// A schedule per collection, so no count is trivially zero.
    private static func seedOnePerCollection(_ store: ScheduleStore) {
        store.add(AutomationSchedule(action: .forkSync,
                                     cadence: .daily(hour: 11, minute: 0), notifyOn: .changeOnly))
        store.add(AutomationSchedule(action: .toolUpdateCheck,
                                     cadence: .daily(hour: 9, minute: 30), notifyOn: .always))
        var needsYou = AutomationSchedule(action: .configBackupExport,
                                          cadence: .daily(hour: 6, minute: 0), notifyOn: .always)
        needsYou.lastRun = ScheduleRunRecord(verdict: .changed,
                                             summary: "2 of 8 forks fast-forwarded", at: Date())
        store.add(needsYou)
        var paused = AutomationSchedule(action: .vaultRecipeExport,
                                        cadence: .daily(hour: 7, minute: 0), notifyOn: .changeOnly)
        paused.isEnabled = false
        store.add(paused)
    }

    // MARK: 8 - the column exists, and says only what it can back

    static func checkSidebarShape(_ ok: inout Bool) {
        print("\n-- the page has its own nav column, and no row that opens nothing --")
        let store = scratchStore()
        seedOnePerCollection(store)
        let (controller, _) = mountedPage(store)
        let sidebar = controller.debugSidebar

        if sidebar.debugRowIDs != expectedSidebarIDs {
            print("  FAIL rows \(sidebar.debugRowIDs), expected \(expectedSidebarIDs)")
            ok = false
        }
        if sidebar.debugHeaders != ["Workspace", "Manage"] {
            print("  FAIL headers \(sidebar.debugHeaders), expected Workspace then Manage")
            ok = false
        }
        // The reference lists "Preferences"; this app has no schedule-settings
        // surface at all, so a row for it would open nothing. Absent on
        // purpose - the same call `CredentialVaultSidebar` made about the
        // reference's own Favorites/Recently-deleted rows.
        if sidebar.debugRowTitles.contains(where: { $0.localizedCaseInsensitiveContains("preferences") }) {
            print("  FAIL a Preferences row is present with no preferences behind it")
            ok = false
        }
        // It opens on the no-filter state, so the page a captain lands on is
        // the whole list.
        if sidebar.debugSelectedIndex != 0 {
            print("  FAIL the column should open on All Schedules, got \(String(describing: sidebar.debugSelectedIndex))")
            ok = false
        }
        print("  rows: \(sidebar.debugRowTitles)")
    }

    // MARK: 9 - a filter really narrows the list

    static func checkSidebarFiltersNarrowTheList(_ ok: inout Bool) {
        print("\n-- each collection narrows the list, driven through the real row --")
        let store = scratchStore()
        seedOnePerCollection(store)
        let (controller, _) = mountedPage(store)
        let sidebar = controller.debugSidebar

        // Counted off the store rather than hardcoded, so the case cannot drift
        // from the seed.
        let all = store.schedules
        let expected: [SchedulesCardView.StatusFilter: Int] = [
            .all: all.count,
            .needsYou: all.filter { SchedulesCardView.group(for: $0) == .needsYou }.count,
            .active: all.filter(\.isEnabled).count,
            .paused: all.filter { !$0.isEnabled }.count,
        ]
        // A fixture that cannot tell the filters apart proves nothing.
        if Set(expected.values).count < 3 {
            print("  FAIL the fixture must give the collections different counts, got \(expected)")
            ok = false
        }

        for (index, filter) in SchedulesCardView.StatusFilter.allCases.enumerated() {
            sidebar.debugClickRow(index)
            controller.view.layoutSubtreeIfNeeded()
            let rows = controller.debugVisibleScheduleRowCount
            if rows != expected[filter] {
                print("  FAIL \(filter.title): \(rows) rows, expected \(expected[filter] ?? -1)")
                ok = false
            }
            if sidebar.debugSelectedIndex != index {
                print("  FAIL \(filter.title) should be selected after a click")
                ok = false
            }
        }
        // The counts the column reports have to agree with what it then shows.
        let counts = SchedulesCardView.filterCounts(all, query: "")
        for (filter, count) in expected where counts[filter] != count {
            print("  FAIL \(filter.title) counted \(counts[filter] ?? -1), shows \(count)")
            ok = false
        }
        print("  \(expected.map { "\($0.key.title)=\($0.value)" }.sorted().joined(separator: " "))")
    }

    // MARK: 10 - the counts are "under the current search", not "in the store"

    static func checkSidebarCountsFollowTheSearch(_ ok: inout Bool) {
        print("\n-- a collection counts what matches the search, not what exists --")
        let store = scratchStore()
        seedOnePerCollection(store)
        let all = store.schedules

        let unfiltered = SchedulesCardView.filterCounts(all, query: "")
        // A query that matches one action and not the others.
        let narrowed = SchedulesCardView.filterCounts(all, query: "Fork sync")
        if narrowed[.all] == unfiltered[.all] {
            print("  FAIL the search did not narrow the All count (\(narrowed[.all] ?? -1))")
            ok = false
        }
        if (narrowed[.all] ?? 0) < 1 {
            print("  FAIL the search matched nothing, so the case proves nothing")
            ok = false
        }
        // Every collection must be a subset of All under the same query.
        for filter in SchedulesCardView.StatusFilter.allCases where (narrowed[filter] ?? 0) > (narrowed[.all] ?? 0) {
            print("  FAIL \(filter.title) counted more than All under the same search")
            ok = false
        }
        print("  all=\(unfiltered[.all] ?? -1) -> \(narrowed[.all] ?? -1) under a search")
    }

    // MARK: 11 - Run History reveals, it does not filter

    static func checkRunHistoryIsAnActionNotAFilter(_ ok: inout Bool) {
        print("\n-- Run History reveals the panel this page already has --")
        let store = scratchStore()
        seedOnePerCollection(store)
        let (controller, _) = mountedPage(store)
        let sidebar = controller.debugSidebar

        sidebar.debugClickRow(1)
        controller.view.layoutSubtreeIfNeeded()
        let selectedBefore = sidebar.debugSelectedIndex
        let rowsBefore = controller.debugVisibleScheduleRowCount

        guard let historyIndex = sidebar.debugRowIDs.firstIndex(of: "run-history") else {
            print("  FAIL no Run History row")
            ok = false
            return
        }
        sidebar.debugClickRow(historyIndex)
        controller.view.layoutSubtreeIfNeeded()

        // An action must not latch: a nav row showing as selected would claim
        // the list below it had been filtered to something.
        if sidebar.debugSelectedIndex != selectedBefore {
            print("  FAIL Run History moved the selection to \(String(describing: sidebar.debugSelectedIndex))")
            ok = false
        }
        if controller.debugVisibleScheduleRowCount != rowsBefore {
            print("  FAIL Run History changed the list (\(rowsBefore) -> \(controller.debugVisibleScheduleRowCount))")
            ok = false
        }
        // It has to actually reveal something, or it is a row that does nothing.
        if controller.debugScrollOffsetY <= 0 {
            print("  FAIL Run History did not scroll to the activity panel (y=\(controller.debugScrollOffsetY))")
            ok = false
        }
        print("  selection held at \(String(describing: selectedBefore)), scrolled to y=\(Int(controller.debugScrollOffsetY))")
    }

    // MARK: 12 - the row uses the width it is given

    static func checkRowsUseTheFullWidth(_ ok: inout Bool) {
        print("\n-- a row's controls reach the card's trailing edge --")
        let store = scratchStore()
        seedOnePerCollection(store)

        // Wide enough that a 900pt content cap is unmistakable, which is the
        // regression this guards.
        for width in [CGFloat(1512), 1900] {
            let (controller, _) = mountedPage(store, width: width)
            guard let card = controller.debugSchedulesCard,
                  let schedule = store.schedules.first,
                  let columns = card.debugTrailingColumns(for: schedule.id) else {
                print("  FAIL no rendered row to measure at \(Int(width))")
                ok = false
                continue
            }
            let cardWidth = card.card.bounds.width
            // The time column is followed only by the overflow glyph and the
            // toggle, so its own trailing edge sits a fixed, small distance
            // from the card's. Pre-fix this measured in the hundreds.
            let gap = cardWidth - columns.timeFrameInCard.maxX
            if cardWidth <= 0 {
                print("  FAIL the card never laid out at \(Int(width))")
                ok = false
                continue
            }
            if gap > Self.trailingGapCeiling {
                print("  FAIL at \(Int(width)): the time column ends \(Int(gap))pt short of the card, "
                      + "expected under \(Int(Self.trailingGapCeiling)) - the row is capped again")
                ok = false
            } else {
                print("  \(Int(width))pt window: card \(Int(cardWidth))pt, controls end \(Int(gap))pt from its edge")
            }
        }
    }

    /// The overflow glyph plus the toggle plus their spacing, with headroom.
    /// Comfortably under what a re-introduced content cap produces at any
    /// window this page is used at.
    private static let trailingGapCeiling: CGFloat = 160
}

#endif
