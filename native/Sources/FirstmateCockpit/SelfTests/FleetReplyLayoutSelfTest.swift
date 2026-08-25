// Manjesh Grand Line - native macOS app.
//
// F7's rendering half: the "Needs your call" rows, their Reply affordance,
// and the composer expanding in place under the row it answers.
//
// Separate from `FleetActionsSelfTest` on purpose. That one is pure logic and
// runs in CI; this one mounts a real `FleetController` in a real `NSWindow`
// and drives real `NSButton` target/action clicks, so it belongs in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list with its window-backed
// peers. This app cannot be launched from a worktree to look at the page (one
// bundle identity across builds - see the README), so a real off-screen mount
// is the only way to check this geometry at all.
//
// The fleet is never fetched: `debugRenderNeeds` renders synthetic tasks
// straight into the real row builder, so nothing here reads or writes the
// captain's real crew state, and no reply is ever sent.
//
// Run: `FM_RUN_FLEET_REPLY_LAYOUT_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only - see `Phase3PolishSelfTest`.
#if FM_SELFTESTS

import AppKit

enum FleetReplyLayoutSelfTest {

    static func run() -> Bool {
        var ok = true
        // A scratch Shift root, so constructing the controller cannot touch
        // the captain's real task data (or its git clone).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-reply-layout-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = NSApplication.shared
        checkSymbolsResolve(&ok)
        checkRowsAndComposer(&ok)
        print(ok ? "FleetReplyLayoutSelfTest: all checks passed" : "FleetReplyLayoutSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition { fail(message, &ok) }
    }

    /// `NSImage(systemSymbolName:)` returns nil silently, and this app has
    /// shipped an invisible icon that way before (the Hosts list's "anchor",
    /// which is not an SF Symbol at all). Every glyph F7 introduces is
    /// checked rather than assumed.
    private static func checkSymbolsResolve(_ ok: inout Bool) {
        for name in ["arrowshape.turn.up.left",
                     "exclamationmark.bubble.fill", "paperplane.fill", "xmark"] {
            check(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                  "SF Symbol \"\(name)\" resolves", &ok)
        }
    }

    private static func task(_ id: String, status: String) -> FleetTask {
        var t = FleetTask(id: id, repo: "checkout-api", kind: "ship", pr: nil)
        t.status = status
        t.state = status == "blocked" ? "blocked" : "parked"
        t.detail = "waiting on the captain"
        return t
    }

    private static func checkRowsAndComposer(_ ok: inout Bool) {
        let controller = FleetController(shiftStore: ShiftStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 800), display: false)
        controller.view.layoutSubtreeIfNeeded()

        // Nothing parked: the section stays out of the way entirely. The
        // banner above already says nothing needs the captain, so a second
        // empty state under it would be noise.
        controller.debugRenderNeeds([])
        check(controller.debugNeedsSectionHidden, "with nothing parked the section is hidden", &ok)
        check(controller.debugNeedsRowCount == 0, "and renders no rows", &ok)

        let tasks = [task("task-142", status: "needs_decision"), task("task-138", status: "blocked")]
        controller.debugRenderNeeds(tasks)
        check(!controller.debugNeedsSectionHidden, "two parked tasks show the section", &ok)
        check(controller.debugNeedsRowCount == 2, "one row per parked task", &ok)

        guard let reply142 = controller.debugReplyButton(taskID: "task-142") else {
            fail("a needs-decision row has no Reply button", &ok)
            return
        }
        check(controller.debugReplyButton(taskID: "task-138") != nil,
              "a blocked row gets a Reply button too - it is just as parked", &ok)
        check(reply142.frame.width > 0 && reply142.frame.height > 0,
              "the Reply button has real geometry", &ok)

        // The real click path: target/action, exactly as a mouse would.
        reply142.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        check(controller.debugOpenReplyTaskID == "task-142", "clicking Reply opens that task's composer", &ok)
        check(controller.debugComposerFollowsItsRow(taskID: "task-142"),
              "the composer expands in place, directly under its own row", &ok)

        guard let composer = controller.debugOpenReplyComposerView else {
            fail("no composer view after Reply", &ok)
            return
        }
        check(composer.frame.height > 60,
              "the composer has real height, not a collapsed zero-height card (got \(composer.frame.height))", &ok)
        check(composer.frame.width > 400,
              "and fills the row column rather than shrinking to its content (got \(composer.frame.width))", &ok)
        check(!composer.debugSendEnabled, "Send is disabled with nothing typed", &ok)

        composer.debugType("Patch forward - v2.3.1 has the token bug too.")
        check(composer.debugSendEnabled, "Send enables once there is real text", &ok)
        composer.debugType("   \n  ")
        check(!composer.debugSendEnabled, "whitespace alone is not real text", &ok)

        // Only one row's composer at a time, and it moves with the click.
        guard let reply138 = controller.debugReplyButton(taskID: "task-138") else {
            fail("lost the blocked row's Reply button", &ok)
            return
        }
        reply138.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        check(controller.debugOpenReplyTaskID == "task-138", "opening another row's composer moves it", &ok)
        check(controller.debugComposerFollowsItsRow(taskID: "task-138"), "and it lands under the new row", &ok)

        // A re-render (what a background refresh does) must not throw away a
        // half-typed answer.
        controller.debugOpenReplyComposerView?.debugType("need the staging key from ops")
        controller.debugRenderNeeds(tasks)
        check(controller.debugOpenReplyTaskID == "task-138", "a refresh keeps the composer open", &ok)
        check(controller.debugOpenReplyComposerView?.text == "need the staging key from ops",
              "and keeps what the captain had typed", &ok)

        // A task that is no longer parked has nothing left to answer.
        controller.debugRenderNeeds([tasks[0]])
        check(controller.debugOpenReplyTaskID == nil,
              "a composer whose task stopped needing a call is closed", &ok)

        // Pressing the same row's Reply again collapses it.
        guard let again = controller.debugReplyButton(taskID: "task-142") else {
            fail("lost the Reply button after a re-render", &ok)
            return
        }
        again.performClick(nil)
        check(controller.debugOpenReplyTaskID == "task-142", "reopened", &ok)
        controller.debugReplyButton(taskID: "task-142")?.performClick(nil)
        check(controller.debugOpenReplyTaskID == nil, "pressing it again collapses the composer", &ok)

        window.contentViewController = nil
    }
}

#endif
