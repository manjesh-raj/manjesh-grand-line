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
        checkFleetRefreshesInPlace(&ok)
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
