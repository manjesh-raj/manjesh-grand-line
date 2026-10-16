// Grand Line - native macOS app.
//
// P2 of the Grand Line vs Automic Vault polish report: a refresh updates the
// rows and cards already on screen instead of tearing them down and
// building new ones.
//
// **What is asserted is identity, not time.** The report's own verify step
// is "a check that a refresh keeps the same row view objects": each case
// renders a surface, records the `ObjectIdentifier` of every row or card it
// shows, drives the real refresh path with changed data, and asserts that
// the same objects are still on screen - and that they now *say* the new
// data, because a refresh that kept the objects and dropped the update would
// pass an identity check alone. Then that a genuinely new item gets a new row
// and a removed one loses its row, which is the half that keeps the
// reconciler honest.
//
// Run with:
//   swift build && FM_RUN_KEYED_REFRESH_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: real controllers in a real window. Listed in
// `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum KeyedRefreshSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true
        checkHomeRefreshesInPlace(&ok)
        checkHomeFollowsAClipWidthChange(&ok)
        checkFleetRefreshesInPlace(&ok)
        checkNotificationsRefreshInPlace(&ok)
        checkTasksBoardRefreshesInPlace(&ok)
        checkCompactPopoverRefreshesInPlace(&ok)
        print(ok ? "KeyedRefreshSelfTest: all checks passed" : "KeyedRefreshSelfTest: FAILED")
        return ok
    }

    // MARK: Home

    private static func checkHomeRefreshesInPlace(_ ok: inout Bool) {
        print("\n-- P2: Home updates its cards in place --")
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        shell.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        // Pinned to the legacy scroller a CI runner ends up with. A runner
        // can switch scroller style after launch, which narrows the clip and
        // (correctly) rebuilds the grid - so without the pin this case could
        // see a legitimate rebuild in the middle of the refresh it measures.
        // The switch itself is `checkHomeFollowsAClipWidthChange`'s case.
        canvas.debugSetScrollerStyle(.legacy)
        ReviewTourLab.seedDemoHome(canvas)
        canvas.debugRenderNow()
        shell.view.layoutSubtreeIfNeeded()
        let before = canvas.moduleCardsForTests.map(ObjectIdentifier.init)
        check(!before.isEmpty, "Home shows no module cards to measure", &ok)

        // The real refresh path: Fleet's two renders (snapshot first, then the
        // PR scan) reach Home through `applyFleet`, each scheduling a render.
        canvas.debugInputsPinned = false
        let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                     queuedCount: 31, doneCount: 21, projectsCount: 4,
                                     watcher: WatcherHealth(status: "healthy"))
        canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: nil)
        canvas.applyFleet(snapshot: snapshot, mergedPRs: [], prFetchFailure: nil)
        canvas.debugInputsPinned = true
        pump(timeout: 0.5) { false }
        shell.view.layoutSubtreeIfNeeded()
        let afterRefresh = canvas.moduleCardsForTests.map(ObjectIdentifier.init)
        check(afterRefresh == before,
              "a fleet refresh rebuilt Home's cards (\(Set(afterRefresh).subtracting(before).count) of \(afterRefresh.count) are new objects)", &ok)
        // Read off the painted text fields, not the content model: the refresh
        // must reach what the captain sees.
        let fleetCard = canvas.moduleCardsForTests.first { texts(in: $0).contains("31") }
        check(fleetCard != nil, "after the refresh no Home card shows the new queued count (31)", &ok)

        // Refreshed in place must lay out exactly as built fresh. The refresh
        // above emptied the Merge queue, so its card's own height moved, and
        // an in-place path that kept the old constant would show here.
        func layout() -> [(CGRect, [String])] {
            canvas.moduleCardsForTests.map { ($0.convert($0.bounds, to: nil), texts(in: $0)) }
        }
        let refreshed = layout()
        canvas.debugRebuildGridFromScratch()
        shell.view.layoutSubtreeIfNeeded()
        let rebuilt = layout()
        check(Set(canvas.moduleCardsForTests.map(ObjectIdentifier.init)).isDisjoint(with: before),
              "the from-scratch build reused cards, so it cannot be compared with the in-place refresh", &ok)
        check(refreshed.count == rebuilt.count, "the refreshed grid has \(refreshed.count) cards, a fresh build \(rebuilt.count)", &ok)
        for (index, (a, b)) in zip(refreshed, rebuilt).enumerated() {
            let same = abs(a.0.minX - b.0.minX) <= 0.5 && abs(a.0.minY - b.0.minY) <= 0.5
                && abs(a.0.width - b.0.width) <= 0.5 && abs(a.0.height - b.0.height) <= 0.5
            check(same, "card \(index) refreshed in place is at \(a.0), built fresh at \(b.0)", &ok)
            check(a.1 == b.1, "card \(index) refreshed in place reads \(a.1), built fresh \(b.1)", &ok)
        }
        let rebuiltIDs = canvas.moduleCardsForTests.map(ObjectIdentifier.init)

        // A revisit with nothing new rebuilds nothing either.
        shell.show(.settings)
        shell.show(.homeCanvas)
        shell.view.layoutSubtreeIfNeeded()
        let afterVisit = canvas.moduleCardsForTests.map(ObjectIdentifier.init)
        check(afterVisit == rebuiltIDs, "a revisit rebuilt Home's cards", &ok)
        if ok { print("  OK   \(before.count) cards kept across a fleet refresh and a revisit, updated, and laid out as a fresh build") }
    }

    /// Found by this suite on CI: a runner's scroller turned legacy after Home
    /// had rendered, which narrowed the clip view by a scroller's width
    /// without resizing the window. Home only re-laid its grid on a window
    /// resize, so its cards stayed 15pt too wide and ran under the scroller
    /// track until the next render. The same happens on a Mac set to always
    /// show scroll bars when a page's content first overflows.
    private static func checkHomeFollowsAClipWidthChange(_ ok: inout Bool) {
        print("\n-- P2: Home re-lays its grid when the clip narrows without a resize --")
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        shell.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        canvas.debugSetScrollerStyle(.overlay)
        ReviewTourLab.seedDemoHome(canvas)
        canvas.debugRenderNow()
        shell.view.layoutSubtreeIfNeeded()
        let start = canvas.debugGridWidths
        check(abs(start.built - start.container) <= 0.5,
              "the fixture's grid was built for \(start.built)pt in a \(start.container)pt container", &ok)

        canvas.debugSetScrollerStyle(.legacy)
        shell.view.layoutSubtreeIfNeeded()
        let narrowed = canvas.debugGridWidths.container
        // Discriminating power: the legacy scroller really took width.
        check(narrowed < start.container - 5,
              "a legacy scroller did not narrow the container (\(start.container) -> \(narrowed))", &ok)
        // One main-queue turn, and no more: a longer pump lets an unrelated
        // window's resize reach Home's global resize observer, which is the
        // luck this check must not depend on (CI did not have it).
        var turned = false
        DispatchQueue.main.async { turned = true }
        pump(timeout: 2.0) { turned }
        shell.view.layoutSubtreeIfNeeded()
        let after = canvas.debugGridWidths
        check(abs(after.built - after.container) <= 0.5,
              "the grid is still \(after.built)pt wide in a \(after.container)pt container", &ok)
        if ok { print("  OK   the grid followed the clip from \(start.container)pt to \(after.container)pt") }
    }

    // MARK: Fleet

    private static func checkFleetRefreshesInPlace(_ ok: inout Bool) {
        print("\n-- P2: Fleet updates its stat tiles and task rows in place --")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyed-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }
        let fleet = FleetController(shiftStore: ShiftStore())
        let window = OffScreenProbe.window(width: 1300, height: 900, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        window.contentView = fleet.view
        window.orderFront(nil)

        func task(_ id: String, _ status: String, detail: String) -> FleetTask {
            var t = FleetTask(id: id, repo: "manjesh-grand-line", kind: "ship", pr: nil)
            t.status = status
            t.detail = detail
            return t
        }
        func snapshot(_ tasks: [FleetTask], queued: Int) -> FleetSnapshot {
            FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: tasks, queuedCount: queued,
                          doneCount: 3, projectsCount: 4, watcher: WatcherHealth(status: "healthy"))
        }
        let first = [task("alpha", "working", detail: "step 1"), task("beta", "working", detail: "step 1")]
        fleet.debugRender(snapshot: snapshot(first, queued: 5), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        let tiles = fleet.debugStatTileViews.map(ObjectIdentifier.init)
        let rows = fleet.debugInFlightRowViews.map(ObjectIdentifier.init)
        check(rows.count == 2, "the fixture shows \(rows.count) in-flight rows, expected 2", &ok)

        // The same two tasks moved on a step, and a third started.
        let second = [task("alpha", "working", detail: "step 2"), task("beta", "working", detail: "step 2"),
                      task("gamma", "working", detail: "step 1")]
        fleet.debugRender(snapshot: snapshot(second, queued: 6), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        check(fleet.debugStatTileViews.map(ObjectIdentifier.init) == tiles, "a refresh rebuilt the stat tiles", &ok)
        check(fleet.debugStatTiles.contains { $0.value == "6" && $0.caption == "queued" },
              "the queued tile does not show the refreshed count", &ok)
        let after = fleet.debugInFlightRowViews.map(ObjectIdentifier.init)
        check(after.count == 3, "after a third task started there are \(after.count) rows, expected 3", &ok)
        check(Array(after.prefix(2)) == rows, "a refresh rebuilt the rows for tasks that were already listed", &ok)
        let metas = fleet.debugInFlightRowViews.compactMap { ($0 as? HelmAccentRow)?.debugMetaText }
        check(metas.prefix(2).allSatisfy { $0 == "step 2" }, "the kept rows still say \(Array(metas.prefix(2))), not step 2", &ok)

        // A task that finished leaves; the others stay the same objects.
        let third = [task("beta", "working", detail: "step 3"), task("gamma", "working", detail: "step 2")]
        fleet.debugRender(snapshot: snapshot(third, queued: 6), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        let last = fleet.debugInFlightRowViews.map(ObjectIdentifier.init)
        check(last == [after[1], after[2]], "after alpha finished the rows are not beta's and gamma's own", &ok)
        if ok { print("  OK   six tiles and the in-flight rows kept, updated, inserted and removed by task id") }

        // The "needs you" list: a parked task keeps its row across a refresh,
        // and an open Reply composer keeps its place under it, its text and
        // its row's Cancel button.
        var okNeeds = true
        func parked(_ id: String, detail: String) -> FleetTask {
            var t = task(id, "needs_decision", detail: detail)
            t.state = "parked"
            return t
        }
        fleet.debugRender(snapshot: snapshot([parked("delta", detail: "which region?"),
                                              parked("echo", detail: "ship it?")], queued: 6), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        guard let reply = fleet.debugReplyButton(taskID: "delta") else {
            fail("a parked task has no Reply button", &ok)
            return
        }
        reply.performClick(nil)
        fleet.view.layoutSubtreeIfNeeded()
        guard let composer = fleet.debugOpenReplyComposerView else {
            fail("Reply opened no composer", &ok)
            return
        }
        composer.debugType("Use eu-west-1.")
        let needsBefore = fleet.debugNeedsRowViews.map(ObjectIdentifier.init)
        check(needsBefore.count == 3, "two parked rows and a composer should be listed, found \(needsBefore.count)", &okNeeds)
        fleet.debugRender(snapshot: snapshot([parked("delta", detail: "which region? (asked again)"),
                                              parked("echo", detail: "ship it?")], queued: 6), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        check(fleet.debugNeedsRowViews.map(ObjectIdentifier.init) == needsBefore,
              "a refresh rebuilt the needs-you rows or moved the composer", &okNeeds)
        check(fleet.debugOpenReplyComposerView === composer && composer.debugTextView.string == "Use eu-west-1.",
              "a refresh lost the composer or what was typed into it", &okNeeds)
        check(fleet.debugReplyButton(taskID: "delta")?.title == "Cancel",
              "the open row's button reads \(fleet.debugReplyButton(taskID: "delta")?.title ?? "nil"), not Cancel", &okNeeds)
        check(texts(in: fleet.debugNeedsRowViews[0]).contains { $0.contains("asked again") },
              "the kept row does not show the refreshed detail", &okNeeds)

        // The task with the open composer is answered elsewhere and leaves:
        // its row and its composer go, and the other row stays.
        fleet.debugRender(snapshot: snapshot([parked("echo", detail: "ship it?")], queued: 6), mergedPRs: [])
        fleet.view.layoutSubtreeIfNeeded()
        check(fleet.debugNeedsRowViews.map(ObjectIdentifier.init) == [needsBefore[2]],
              "after delta left the list is not echo's own row alone", &okNeeds)
        check(fleet.debugOpenReplyComposerView == nil, "the composer outlived its task", &okNeeds)
        if okNeeds { print("  OK   needs-you rows kept by task id, with the open composer, its text and Cancel") }
        ok = ok && okNeeds
    }

    // MARK: Notifications

    private static func checkNotificationsRefreshInPlace(_ ok: inout Bool) {
        print("\n-- P2: the notification list updates its rows in place --")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        center.clock = { now }
        defer { center.resetForTesting() }
        func publish(_ id: String, _ title: String, subtext: String, kind: AppNotificationKind = .actionNeeded,
                     children: [AppNotificationChild] = []) {
            center.set(AppNotification(id: id, title: title, subtext: subtext, source: "Tests",
                                       clearCondition: "Clears when it is done.", kind: kind, tint: .warn,
                                       date: now.addingTimeInterval(-60), children: children,
                                       navigate: {}), id: id)
        }
        let kids = [AppNotificationChild(id: "k1", name: "commit.gpgsign", meta: "expected true",
                                         actionLabel: "Fix", perform: {})]
        publish("one", "First", subtext: "a")
        publish("two", "Second", subtext: "b", children: kids)
        publish("three", "Third", subtext: "c", kind: .informational)

        let controller = NotificationCenterController()
        let content = controller.debugPanelContent
        content.clock = { now }
        let window = OffScreenProbe.window(width: 500, height: 900, styleMask: [.titled])
        defer { window.orderOut(nil) }
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        content.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: host.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        ])
        window.orderFront(nil)
        content.reload()
        host.layoutSubtreeIfNeeded()

        let views = content.debugListViews.map(ObjectIdentifier.init)
        let rows = content.debugRows
        check(rows.count == 3, "the fixture drew \(rows.count) rows, expected 3", &ok)
        guard rows.count == 3 else { return }

        // One entry's text changes while the pointer is over its row: the same
        // views are kept, the row says the new text and keeps its hover action.
        rows[0].debugSetHovering(true)
        check(rows[0].debugActionVisible, "hovering the first row does not reveal its action", &ok)
        publish("one", "First, revised", subtext: "a2")
        content.reload()
        host.layoutSubtreeIfNeeded()
        check(content.debugListViews.map(ObjectIdentifier.init) == views,
              "changing one entry rebuilt the list's views", &ok)
        check(rows[0].debugTitle == "First, revised" && rows[0].debugDetail == "Tests: a2",
              "the kept row reads \(rows[0].debugTitle) / \(rows[0].debugDetail)", &ok)
        check(rows[0].debugActionVisible, "a refresh under the pointer hid the row's hover action", &ok)
        rows[0].debugSetHovering(false)

        // Read state and expansion are updates too: the dot goes, and the
        // children block is the only new view.
        center.setRead(true, id: "one")
        rows[1].debugClickDisclosure()
        host.layoutSubtreeIfNeeded()
        check(!rows[0].debugUnreadDotVisible, "the kept row still shows its unread dot after it was read", &ok)
        let expanded = content.debugListViews.map(ObjectIdentifier.init)
        let added = Set(expanded).subtracting(views)
        check(added.count == 1 && Set(views).isSubset(of: Set(expanded)),
              "expanding a row should add one view and keep the rest, added \(added.count)", &ok)
        check(content.debugChildRows.map(\.debugName) == ["commit.gpgsign"],
              "the expanded row shows children \(content.debugChildRows.map(\.debugName))", &ok)

        // An entry that clears takes its row and its hairline with it.
        center.set(nil, id: "one")
        content.reload()
        host.layoutSubtreeIfNeeded()
        check(content.debugRows.count == 2 && content.debugRows[0] === rows[1] && content.debugRows[1] === rows[2],
              "after an entry cleared the rows are not the other two entries' own", &ok)
        if ok { print("  OK   rows kept by entry id across an edit, a read, an expansion and a removal, hover kept") }
    }

    // MARK: Tasks board

    private static func checkTasksBoardRefreshesInPlace(_ ok: inout Bool) {
        print("\n-- P2: the Tasks board updates its cards in place --")
        func task(_ id: String, _ title: String, status: ShiftTaskStatus = .todo) -> ShiftTask {
            ShiftTask(id: id, title: title, description: "", status: status, priority: .normal,
                      dueDate: nil, dueTime: nil, projectID: nil, tags: [],
                      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                      completedAt: nil, notes: nil, subtasks: [], hasAttachment: false)
        }
        let theme = ThemeManager.shared.theme
        let board = ShiftBoardView()
        let window = OffScreenProbe.window(width: 1100, height: 800, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        window.contentView = host
        board.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(board)
        NSLayoutConstraint.activate([
            board.topAnchor.constraint(equalTo: host.topAnchor),
            board.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        window.orderFront(nil)
        board.setTasks([.backlog: [task("a", "Write the runbook"), task("b", "Rotate the keys")],
                        .inProgress: [task("c", "Ship the fix", status: .inProgress)]],
                       projects: [], theme: theme)
        host.layoutSubtreeIfNeeded()
        let backlog = board.debugColumn(.backlog)?.debugCardViews ?? []
        let doing = board.debugColumn(.inProgress)?.debugCardViews ?? []
        check(backlog.count == 2 && doing.count == 1,
              "the fixture shows \(backlog.count) and \(doing.count) cards, expected 2 and 1", &ok)
        guard backlog.count == 2, doing.count == 1 else { return }
        window.makeFirstResponder(backlog[0])
        check(window.firstResponder === backlog[0], "the first card did not take the keyboard", &ok)

        // A refresh: a renamed card, a new card, and one moved to Done.
        board.setTasks([.backlog: [task("a", "Write the incident runbook"), task("d", "Renew the cert")],
                        .inProgress: [task("c", "Ship the fix", status: .inProgress)],
                        .done: [task("b", "Rotate the keys", status: .completed)]],
                       projects: [], theme: theme)
        host.layoutSubtreeIfNeeded()
        let backlogAfter = board.debugColumn(.backlog)?.debugCardViews ?? []
        check(backlogAfter.first === backlog[0], "a refresh rebuilt a card whose task stayed in its lane", &ok)
        check(backlog[0].debugRow.debugTitle == "Write the incident runbook",
              "the kept card reads \(backlog[0].debugRow.debugTitle)", &ok)
        check(window.firstResponder === backlog[0], "a refresh took the keyboard off the focused card", &ok)
        check(board.debugColumn(.inProgress)?.debugCardViews.first === doing[0],
              "a refresh rebuilt an unchanged lane's card", &ok)
        check(backlogAfter.count == 2 && backlogAfter[1] !== backlog[1]
              && backlogAfter[1].debugRow.debugTitle == "Renew the cert",
              "the new task does not have a card of its own in Backlog", &ok)
        let done = board.debugColumn(.done)?.debugCardViews ?? []
        check(done.count == 1 && done[0].taskID == "b", "the moved task is not in Done", &ok)
        if ok { print("  OK   cards kept by task id across a rename, an insert and a move, with keyboard focus") }
    }

    // MARK: Compact popover

    private static func checkCompactPopoverRefreshesInPlace(_ ok: inout Bool) {
        print("\n-- P2: the compact popover updates its rows in place --")
        let theme = ThemeManager.shared.theme
        let window = OffScreenProbe.window(width: 360, height: 600, styleMask: [.titled])
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        window.contentView = host
        let today = CompactTodayPane()
        let notes = CompactNotesPane()
        let column = NSStackView(views: [today, notes])
        column.orientation = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.widthAnchor.constraint(equalToConstant: 360),
        ])
        window.orderFront(nil)

        func digest(_ rows: [CompactTaskRow]) -> CompactTodayDigest {
            CompactTodayDigest(rows: rows, overdueCount: rows.filter { $0.urgency == .overdue }.count,
                               focusChip: nil, followUpChip: nil)
        }
        today.present(digest([CompactTaskRow(id: "t1", title: "Renew the cert", detail: "tomorrow", urgency: .later),
                              CompactTaskRow(id: "t2", title: "Rotate the keys", detail: "due today", urgency: .today)]),
                      theme: theme)
        notes.present([CompactNoteRow(id: "n1", title: "Invoice fee", detail: "call the bank", color: .yellow),
                       CompactNoteRow(id: "n2", title: "Trip", detail: "1 of 3 done", color: .pink)], theme: theme)
        host.layoutSubtreeIfNeeded()
        let taskRows = today.debugRows
        let noteRows = notes.debugRows
        check(taskRows.count == 2 && noteRows.count == 2,
              "the fixture shows \(taskRows.count) task and \(noteRows.count) note rows, expected 2 and 2", &ok)
        guard taskRows.count == 2, noteRows.count == 2 else { return }
        let laterColor = taskRows[0].debugCheckboxBorderColor

        // A day later: the first task is overdue, the second was done, a third
        // is new; a note's checklist moved on.
        today.present(digest([CompactTaskRow(id: "t1", title: "Renew the cert", detail: "overdue", urgency: .overdue),
                              CompactTaskRow(id: "t3", title: "Review the values", detail: "tomorrow", urgency: .later)]),
                      theme: theme)
        notes.present([CompactNoteRow(id: "n1", title: "Invoice fee", detail: "call the bank", color: .yellow),
                       CompactNoteRow(id: "n2", title: "Trip", detail: "2 of 3 done", color: .pink)], theme: theme)
        host.layoutSubtreeIfNeeded()
        let tasksAfter = today.debugRows
        check(tasksAfter.first === taskRows[0], "a refresh rebuilt the Today row whose task is still listed", &ok)
        check(tasksAfter.count == 2 && tasksAfter[1] !== taskRows[1] && tasksAfter[1].debugTitle == "Review the values",
              "the Today tab does not show the new task in a row of its own", &ok)
        check(taskRows[0].debugDetail == "overdue" && taskRows[0].debugUrgency == .overdue,
              "the kept Today row reads \(taskRows[0].debugDetail)", &ok)
        check(!taskRows[0].debugCheckboxBorderColor.isEqual(laterColor),
              "the kept row's checkbox was not repainted for its new urgency", &ok)
        check(notes.debugRows.map(ObjectIdentifier.init) == noteRows.map(ObjectIdentifier.init),
              "a refresh rebuilt the Notes rows", &ok)
        check(noteRows[1].debugDetail == "2 of 3 done", "the kept note row reads \(noteRows[1].debugDetail)", &ok)
        if ok { print("  OK   Today and Notes rows kept by id, updated, repainted, inserted and removed") }
    }

    // MARK: Helpers

    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor { out.append(field.stringValue) }
        for sub in view.subviews { out += texts(in: sub) }
        return out
    }

    private static func pump(timeout: TimeInterval, until landed: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

#endif
